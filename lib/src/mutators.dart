import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// Changes whenever the mutators would produce other mutants for the same
/// source. A result of an earlier run is only reused for the same number.
const mutatorsVersion = 2;

/// One change to a source: the text from [offset] to [end] (exclusive, in
/// UTF-16 code units) becomes [replacement].
class Mutant {
  const Mutant(this.mutator, this.offset, this.end, this.replacement);

  /// The name of the mutator, as Stryker spells it where it has the same one.
  final String mutator;
  final int offset;
  final int end;
  final String replacement;

  /// [source] with this change applied.
  String applyTo(String source) =>
      source.replaceRange(offset, end, replacement);
}

/// The mutants of a Dart file, in the order of the source.
class MutantSet {
  const MutantSet({required this.mutants, required this.syntaxErrors});

  final List<Mutant> mutants;

  /// True when the file cannot be read as Dart. [mutants] is then empty.
  final bool syntaxErrors;
}

const _arithmetic = {
  '+': '-',
  '-': '+',
  '*': '/',
  '/': '*',
  '%': '*',
  '~/': '*',
};

const _equality = {
  '<': ['<=', '>='],
  '<=': ['<', '>'],
  '>': ['>=', '<='],
  '>=': ['>', '<'],
  '==': ['!='],
  '!=': ['=='],
};

const _assignment = {
  '+=': '-=',
  '-=': '+=',
  '*=': '/=',
  '/=': '*=',
  '%=': '*=',
  '~/=': '*=',
  '??=': '=',
};

/// True when the tree below [node] has a `return <value>;` that belongs to
/// [node] itself, not to a function inside it.
bool _returnsValue(AstNode node) {
  final finder = _ReturnFinder();
  node.accept(finder);
  return finder.found;
}

class _ReturnFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitReturnStatement(ReturnStatement node) {
    if (node.expression != null) {
      found = true;
    }
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

/// True when [condition] holds a test that promotes a variable (`x != null`,
/// `x is T`). The code that follows depends on the test staying there.
bool _promotes(Expression condition) {
  final finder = _PromotionFinder();
  condition.accept(finder);
  return finder.found;
}

class _PromotionFinder extends RecursiveAstVisitor<void> {
  bool found = false;

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final operator = node.operator.lexeme;
    if ((operator == '==' || operator == '!=') &&
        (node.leftOperand is NullLiteral || node.rightOperand is NullLiteral)) {
      found = true;
    }
    super.visitBinaryExpression(node);
  }

  @override
  void visitIsExpression(IsExpression node) {
    found = true;
  }

  @override
  void visitFunctionExpression(FunctionExpression node) {}
}

/// True when a function with the declared return type [type] (as written)
/// may end without `return`.
bool _mayEndWithoutValue(String type, {required bool isAsync}) {
  var text = type.replaceAll(RegExp(r'\s+'), '');
  if (isAsync) {
    final future = RegExp(r'^Future(Or)?<(.*)>$').firstMatch(text);
    if (future == null) {
      // `Future` without an argument, or a type this cannot read.
      return text == 'Future' || text == 'void' || text == 'dynamic';
    }
    text = future[2]!;
  }
  return text == 'void' ||
      text == 'dynamic' ||
      text == 'Null' ||
      text.endsWith('?');
}

class _Finder extends RecursiveAstVisitor<void> {
  _Finder(this.source);

  final String source;
  final mutants = <Mutant>[];

  // Every caller replaces the text with another one: an empty block, an
  // empty list and a literal condition are left out where they are found.
  void _add(String mutator, int offset, int end, String replacement) =>
      mutants.add(Mutant(mutator, offset, end, replacement));

  void _node(String mutator, AstNode node, String replacement) =>
      _add(mutator, node.offset, node.end, replacement);

  void _token(String mutator, Token token, String replacement) =>
      _add(mutator, token.offset, token.end, replacement);

  String _text(AstNode node) => source.substring(node.offset, node.end);

  // Nothing a test can observe: annotations, directives, and assertions
  // (which are off in a release build).
  @override
  void visitAnnotation(Annotation node) {}

  @override
  void visitImportDirective(ImportDirective node) {}

  @override
  void visitExportDirective(ExportDirective node) {}

  @override
  void visitPartDirective(PartDirective node) {}

  @override
  void visitPartOfDirective(PartOfDirective node) {}

  @override
  void visitLibraryDirective(LibraryDirective node) {}

  @override
  void visitAssertStatement(AssertStatement node) {}

  @override
  void visitAssertInitializer(AssertInitializer node) {}

  @override
  void visitBinaryExpression(BinaryExpression node) {
    final operator = node.operator.lexeme;
    final arithmetic = _arithmetic[operator];
    if (arithmetic != null) {
      // `'a' + b` is a concatenation: no other operator fits a String.
      if (node.leftOperand is! StringLiteral &&
          node.rightOperand is! StringLiteral) {
        _token('ArithmeticOperator', node.operator, arithmetic);
      }
    } else if (_equality.containsKey(operator)) {
      for (final replacement in _equality[operator]!) {
        _token('EqualityOperator', node.operator, replacement);
      }
    } else if (operator == '&&') {
      _token('LogicalOperator', node.operator, '||');
    } else if (operator == '||') {
      _token('LogicalOperator', node.operator, '&&');
    } else if (operator == '??') {
      // `a ?? b` → `b`. `a` alone is rarely a program: its type is nullable.
      _node('LogicalOperator', node, _text(node.rightOperand));
    }
    super.visitBinaryExpression(node);
  }

  /// `if (x != null) { x.y }` → `if (true) { x.y }` loses the type promotion
  /// and does not compile. `(c) || true` / `(c) && false` keep the promotion
  /// that still holds.
  void _condition(Expression condition, {bool onlyFalse = false}) {
    if (condition is BooleanLiteral) {
      // `while (true)`: BooleanLiteral makes the same change.
      return;
    }
    final promotes = _promotes(condition);
    final text = _text(condition);
    if (!onlyFalse) {
      _node(
        'ConditionalExpression',
        condition,
        promotes ? '($text) || true' : 'true',
      );
    }
    _node(
      'ConditionalExpression',
      condition,
      promotes ? '($text) && false' : 'false',
    );
  }

  @override
  void visitIfStatement(IfStatement node) {
    if (node.caseClause == null) {
      _condition(node.expression);
    }
    super.visitIfStatement(node);
  }

  @override
  void visitIfElement(IfElement node) {
    if (node.caseClause == null) {
      _condition(node.expression);
    }
    super.visitIfElement(node);
  }

  @override
  void visitConditionalExpression(ConditionalExpression node) {
    _condition(node.condition);
    super.visitConditionalExpression(node);
  }

  // A loop whose condition is always true never ends: only `false`.
  @override
  void visitWhileStatement(WhileStatement node) {
    _condition(node.condition, onlyFalse: true);
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _condition(node.condition, onlyFalse: true);
    super.visitDoStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    final parts = node.forLoopParts;
    if (parts is ForParts && parts.condition != null) {
      _condition(parts.condition!, onlyFalse: true);
    }
    super.visitForStatement(node);
  }

  @override
  void visitForElement(ForElement node) {
    final parts = node.forLoopParts;
    if (parts is ForParts && parts.condition != null) {
      _condition(parts.condition!, onlyFalse: true);
    }
    super.visitForElement(node);
  }

  @override
  void visitBooleanLiteral(BooleanLiteral node) {
    _node('BooleanLiteral', node, node.value ? 'false' : 'true');
  }

  @override
  void visitPrefixExpression(PrefixExpression node) {
    final operator = node.operator.lexeme;
    if (operator == '!') {
      _node('BooleanLiteral', node, _text(node.operand));
    } else if (operator == '-') {
      _node('UnaryOperator', node, _text(node.operand));
    } else if (operator == '++' || operator == '--') {
      _token('UpdateOperator', node.operator, operator == '++' ? '--' : '++');
    }
    super.visitPrefixExpression(node);
  }

  @override
  void visitPostfixExpression(PostfixExpression node) {
    final operator = node.operator.lexeme;
    if (operator == '++' || operator == '--') {
      _token('UpdateOperator', node.operator, operator == '++' ? '--' : '++');
    }
    super.visitPostfixExpression(node);
  }

  @override
  void visitAssignmentExpression(AssignmentExpression node) {
    final replacement = _assignment[node.operator.lexeme];
    if (replacement != null &&
        !(node.operator.lexeme == '+=' &&
            node.rightHandSide is StringLiteral)) {
      _token('AssignmentOperator', node.operator, replacement);
    }
    super.visitAssignmentExpression(node);
  }

  /// True when the function with the body [body] may end without `return`.
  bool _mayEnd(BlockFunctionBody body) {
    if (body.star != null) {
      // A generator yields; it never has to return.
      return true;
    }
    final isAsync = body.keyword?.lexeme == 'async';
    final owner = body.parent;
    if (owner is ConstructorDeclaration) {
      return owner.factoryKeyword == null;
    }
    final TypeAnnotation? returnType;
    if (owner is MethodDeclaration) {
      if (owner.isSetter) {
        // No declared type, and `return g();` of a void call is allowed.
        return true;
      }
      returnType = owner.returnType;
    } else {
      // A function, or a closure, which declares no type.
      final declaration = owner?.parent;
      returnType = declaration is FunctionDeclaration
          ? declaration.returnType
          : null;
    }
    // Without a declared type the return type is inferred from the body or
    // expected by the context.
    return returnType == null
        ? !_returnsValue(body.block)
        : _mayEndWithoutValue(_text(returnType), isAsync: isAsync);
  }

  /// The statement or block around [node] that ends where [node] ends:
  /// [node] is a branch of an `if`, the body or a handler of a `try` without
  /// `finally`, or the last statement of a block. `null` when code follows
  /// [node].
  AstNode? _endsWith(AstNode node) {
    final parent = node.parent;
    if (parent is IfStatement) {
      return parent;
    }
    if (parent is TryStatement) {
      return parent.finallyBlock == null && node == parent.body ? parent : null;
    }
    if (parent is CatchClause) {
      final statement = parent.parent;
      return statement is TryStatement && statement.finallyBlock == null
          ? statement
          : null;
    }
    return parent is Block && parent.statements.last == node ? parent : null;
  }

  /// The function body that ends where [node] ends: [node] is that body, or
  /// the last thing on one of the paths through it (see [_endsWith]). `null`
  /// when code follows [node].
  ///
  /// `open` is true when an `if` without `else` is on the way. The function
  /// then ends without a value on the path that skips the `if`, whatever its
  /// declared type says.
  ({BlockFunctionBody body, bool open})? _endsFunction(
    AstNode node, {
    bool open = false,
  }) {
    final parent = node.parent;
    if (parent is BlockFunctionBody) {
      return (body: parent, open: open);
    }
    final outer = _endsWith(node);
    return outer == null
        ? null
        : _endsFunction(
            outer,
            open: open || (outer is IfStatement && outer.elseStatement == null),
          );
  }

  /// False when emptying [block] gives nothing to test.
  ///
  /// - A function that has to return a value would end at the emptied block
  ///   (its whole body, or the last block on one of its paths): that does not
  ///   compile.
  /// - A function that may end without a value ends at the block, and the
  ///   block only says `return;` or `return null;`: the function returns the
  ///   same without it.
  bool _canBeEmptied(Block block) {
    final function = _endsFunction(block);
    if (function == null) {
      return true;
    }
    return (function.open || _mayEnd(function.body)) &&
        !block.statements.every(
          (statement) =>
              statement is ReturnStatement &&
              (statement.expression == null ||
                  statement.expression is NullLiteral),
        );
  }

  @override
  void visitBlock(Block node) {
    // A block of assertions only: emptying it changes nothing a release
    // build does.
    if (node.statements.any((statement) => statement is! AssertStatement) &&
        _canBeEmptied(node)) {
      _node('BlockStatement', node, '{}');
    }
    super.visitBlock(node);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    final expression = node.expression;
    final call = expression is AwaitExpression
        ? expression.expression
        : expression;
    final parent = node.parent;
    // The only statement of a block: emptying the block is the same mutant.
    final alone = parent is Block && parent.statements.length == 1;
    if ((call is MethodInvocation || call is FunctionExpressionInvocation) &&
        !alone) {
      _node('RemoveCall', node, ';');
    }
    super.visitExpressionStatement(node);
  }

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    _node('StringLiteral', node, node.value.isEmpty ? "'mutated'" : "''");
  }

  @override
  void visitStringInterpolation(StringInterpolation node) {
    _node('StringLiteral', node, "''");
    super.visitStringInterpolation(node);
  }

  @override
  void visitAdjacentStrings(AdjacentStrings node) {
    // One string written in pieces: one mutant, and the expressions inside.
    _node('StringLiteral', node, "''");
    for (final string in node.strings) {
      string.visitChildren(this);
    }
  }

  @override
  void visitListLiteral(ListLiteral node) {
    if (node.elements.isNotEmpty) {
      _add('ArrayDeclaration', node.leftBracket.offset, node.end, '[]');
    }
    super.visitListLiteral(node);
  }
}

/// The mutants of [source], found in the syntax tree (`package:analyzer`), so
/// a comment or a string that holds an operator is never changed and no
/// mutant is a syntax error.
///
/// Mutants that cannot compile are left out where the syntax shows it: the
/// emptied body of a function that returns a value, and an arithmetic
/// operator on a string literal. A condition with a null test or a type test
/// is not left out but replaced in a form that keeps the type promotion that
/// still holds. The one mutant that is equivalent by construction is left
/// out too: an emptied block that only says `return;` or `return null;` at
/// the end of a function.
MutantSet findMutants(String source) {
  // The Dart tools accept a byte order mark; the parser does not.
  final shift = source.startsWith('﻿') ? 1 : 0;
  final content = source.substring(shift);
  final result = parseString(content: content, throwIfDiagnostics: false);
  if (result.errors.isNotEmpty) {
    return const MutantSet(mutants: [], syntaxErrors: true);
  }
  final finder = _Finder(content);
  result.unit.accept(finder);
  final mutants = [
    for (final (index, mutant) in finder.mutants.indexed)
      (
        index,
        Mutant(
          mutant.mutator,
          mutant.offset + shift,
          mutant.end + shift,
          mutant.replacement,
        ),
      ),
  ];
  // Stable: mutants at the same place keep the order they were found in.
  mutants.sort((a, b) {
    final byOffset = a.$2.offset - b.$2.offset;
    return byOffset != 0 ? byOffset : a.$1 - b.$1;
  });
  return MutantSet(
    mutants: [for (final (_, mutant) in mutants) mutant],
    syntaxErrors: false,
  );
}
