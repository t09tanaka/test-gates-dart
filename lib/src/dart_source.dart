import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/token.dart';
import 'package:analyzer/dart/ast/visitor.dart';

/// What a directive does with the library it names.
enum DirectiveKind { import, export, part }

/// One `import`, `export` or `part` of a Dart file.
class ImportRef {
  const ImportRef({
    required this.kind,
    required this.uri,
    required this.line,
    this.shown,
  });

  final DirectiveKind kind;

  /// The URI as it is written: `dart:io`, `package:a/a.dart`, `../b.dart`.
  final String uri;

  /// 1-based line of the URI.
  final int line;

  /// The names of the `show` combinators, or `null` when the whole library is
  /// reachable (no `show`). Always `null` for a part.
  final List<String>? shown;
}

/// A finding at a line of the source.
class SourceFinding {
  const SourceFinding(this.line, this.what);

  final int line;
  final String what;
}

/// What the checks need to know about a Dart file. Everything is read from
/// the tokens and the syntax tree, so a comment or a string that mentions
/// `dart:io` is not an import.
class DartSource {
  const DartSource({
    required this.imports,
    required this.partOfLine,
    required this.uncheckableUris,
    required this.syntaxErrors,
    required this.environmentReads,
    required this.identifiers,
    required this.sharedBlockLines,
    required this.disabledTests,
  });

  /// Imports, exports and parts, in the order of the file. A conditional
  /// import (`if (dart.library.io) 'x_io.dart'`) gives one entry per URI.
  final List<ImportRef> imports;

  /// Line of `part of`, when the file is a part of another library.
  final int? partOfLine;

  /// Lines of a directive whose URI is not a plain string.
  final List<int> uncheckableUris;

  /// Syntax errors: the file could not be read as Dart.
  final List<SourceFinding> syntaxErrors;

  /// Reads of the environment: `Platform.environment`,
  /// `String.fromEnvironment`, ...
  final List<SourceFinding> environmentReads;

  /// Every identifier of the code (not of comments or strings).
  final Set<String> identifiers;

  /// Lines on which more than one block starts, with the number of blocks.
  /// See [parseDartSource].
  final List<SourceFinding> sharedBlockLines;

  /// Skipped or focused tests: `skip:`, `solo:`, `@Skip`,
  /// `markTestSkipped()`.
  final List<SourceFinding> disabledTests;
}

const _environmentConstructors = {'fromEnvironment', 'hasEnvironment'};
const _environmentTypes = {'String', 'bool', 'int'};

/// Parses [source] without resolving it: no dependency of the project has to
/// be installed, and nothing is read from disk.
///
/// A "block" is what Dart's branch coverage has one entry for: the branches of
/// an `if`, the body of a loop, a `case`, an arm of a switch expression, `try`
/// / `catch` / `finally`. The entry is keyed by the line the block starts on,
/// so two blocks on one line share an entry, and it is taken as soon as one
/// of them runs. The same holds for a block on the line that opens the body
/// of its function.
///
/// Not counted, because formatted code has them on one line as well and the
/// finding could not be acted on: `else if` (the `else` and the `then` inside
/// it), `if` / `else` inside a collection literal, and a closure.
DartSource parseDartSource(String source) {
  // The Dart tools accept a byte order mark; `parseString` reports it as an
  // illegal character. It has no width, so no line or column moves.
  final content = source.startsWith('\uFEFF') ? source.substring(1) : source;
  final result = parseString(content: content, throwIfDiagnostics: false);
  final unit = result.unit;
  int lineOf(int offset) => result.lineInfo.getLocation(offset).lineNumber;

  final imports = <ImportRef>[];
  final uncheckable = <int>[];
  int? partOfLine;
  void add(DirectiveKind kind, StringLiteral uri, [List<String>? shown]) {
    final value = uri.stringValue;
    if (value == null) {
      uncheckable.add(lineOf(uri.offset));
    } else {
      imports.add(
        ImportRef(
          kind: kind,
          uri: value,
          line: lineOf(uri.offset),
          shown: shown,
        ),
      );
    }
  }

  for (final directive in unit.directives) {
    if (directive is NamespaceDirective) {
      final shows = directive.combinators.whereType<ShowCombinator>();
      final shown = shows.isEmpty
          ? null
          : [
              for (final combinator in shows)
                for (final name in combinator.shownNames) name.name,
            ];
      final kind = directive is ImportDirective
          ? DirectiveKind.import
          : DirectiveKind.export;
      add(kind, directive.uri, shown);
      for (final configuration in directive.configurations) {
        add(kind, configuration.uri, shown);
      }
    } else if (directive is PartDirective) {
      add(DirectiveKind.part, directive.uri);
    } else if (directive is PartOfDirective) {
      partOfLine = lineOf(directive.offset);
    }
  }

  final identifiers = <String>{};
  final environmentReads = <SourceFinding>[];
  final disabledTests = <SourceFinding>[];
  for (
    var token = unit.beginToken;
    token.type != TokenType.EOF;
    token = token.next!
  ) {
    final next = token.next!;
    // `@Skip(…)`, or `@prefix.Skip(…)` when the library is imported with a
    // prefix.
    if (token.type == TokenType.AT &&
        (next.lexeme == 'Skip' ||
            (next.next!.type == TokenType.PERIOD &&
                next.next!.next!.lexeme == 'Skip'))) {
      disabledTests.add(SourceFinding(lineOf(token.offset), '@Skip'));
    }
    if (!token.isKeywordOrIdentifier) {
      continue;
    }
    final name = token.lexeme;
    identifiers.add(name);
    if (name == 'markTestSkipped' && next.type == TokenType.OPEN_PAREN) {
      disabledTests.add(SourceFinding(lineOf(token.offset), '$name()'));
    }
    final member = next.next!.lexeme;
    if (next.type == TokenType.PERIOD ||
        next.type == TokenType.QUESTION_PERIOD) {
      if ((name == 'Platform' && member == 'environment') ||
          (_environmentTypes.contains(name) &&
              _environmentConstructors.contains(member))) {
        environmentReads.add(
          SourceFinding(lineOf(token.offset), '$name.$member'),
        );
      }
    }
    // A named argument: `test('…', () {…}, skip: true)`. `skip: false` and
    // `skip: null` leave the test on. A record field with that name looks
    // the same in the tokens and is reported too.
    final before = token.previous?.type;
    if ((name == 'skip' || name == 'solo') &&
        next.type == TokenType.COLON &&
        (before == TokenType.COMMA || before == TokenType.OPEN_PAREN)) {
      final end = next.next!.next!.type;
      final off =
          (member == 'false' || member == 'null') &&
          (end == TokenType.COMMA || end == TokenType.CLOSE_PAREN);
      if (!off) {
        disabledTests.add(SourceFinding(lineOf(token.offset), '$name:'));
      }
    }
  }

  final visitor = _Visitor(lineOf);
  unit.accept(visitor);
  final sharedBlockLines = [
    for (final MapEntry(key: line, value: count) in visitor.blockLines.entries)
      if (count > 1) SourceFinding(line, '$count'),
  ]..sort((a, b) => a.line.compareTo(b.line));

  return DartSource(
    imports: imports,
    partOfLine: partOfLine,
    uncheckableUris: uncheckable,
    syntaxErrors: [
      for (final error in result.errors)
        SourceFinding(lineOf(error.offset), error.message),
    ],
    environmentReads: environmentReads,
    identifiers: identifiers,
    sharedBlockLines: sharedBlockLines,
    disabledTests: disabledTests,
  );
}

class _Visitor extends RecursiveAstVisitor<void> {
  _Visitor(this.lineOf);

  final int Function(int offset) lineOf;

  /// Line → number of blocks that start on it.
  final blockLines = <int, int>{};
  void _block(AstNode? node) {
    if (node != null) {
      blockLines.update(
        lineOf(node.offset),
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
  }

  @override
  void visitBlockFunctionBody(BlockFunctionBody node) {
    // The entry of a function shares the line with the blocks of its own
    // body that start on the line of its "{". A closure that merely sits on
    // the line of an `if` is not counted: formatted code has those.
    final line = lineOf(node.block.offset);
    final before = blockLines[line] ?? 0;
    super.visitBlockFunctionBody(node);
    if ((blockLines[line] ?? 0) > before) {
      blockLines[line] = blockLines[line]! + 1;
    }
  }

  @override
  void visitIfStatement(IfStatement node) {
    _block(node.thenStatement);
    final otherwise = node.elseStatement;
    if (otherwise is! IfStatement) {
      _block(otherwise);
    }
    super.visitIfStatement(node);
  }

  @override
  void visitForStatement(ForStatement node) {
    _block(node.body);
    super.visitForStatement(node);
  }

  @override
  void visitWhileStatement(WhileStatement node) {
    _block(node.body);
    super.visitWhileStatement(node);
  }

  @override
  void visitDoStatement(DoStatement node) {
    _block(node.body);
    super.visitDoStatement(node);
  }

  @override
  void visitSwitchStatement(SwitchStatement node) {
    node.members.forEach(_block);
    super.visitSwitchStatement(node);
  }

  @override
  void visitSwitchExpression(SwitchExpression node) {
    node.cases.forEach(_block);
    super.visitSwitchExpression(node);
  }

  @override
  void visitTryStatement(TryStatement node) {
    _block(node.body);
    for (final clause in node.catchClauses) {
      _block(clause.body);
    }
    _block(node.finallyBlock);
    super.visitTryStatement(node);
  }
}
