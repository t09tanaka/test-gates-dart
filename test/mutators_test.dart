import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:test/test.dart';
import 'package:test_gates/src/mutators.dart';

/// `Mutator: original → replacement`, in the order of the source.
List<String> mutantsOf(String source) {
  final found = findMutants(source);
  expect(found.syntaxErrors, isFalse, reason: source);
  return [
    for (final mutant in found.mutants)
      '${mutant.mutator}: ${source.substring(mutant.offset, mutant.end)} → '
          '${mutant.replacement}',
  ];
}

/// The mutants of one mutator.
List<String> only(String mutator, String source) => [
  for (final line in mutantsOf(source))
    if (line.startsWith('$mutator: ')) line.substring(mutator.length + 2),
];

void main() {
  test('ArithmeticOperator', () {
    expect(
      only(
        'ArithmeticOperator',
        'num f(num a, num b) => a + b - a * b / a % b ~/ a;',
      ),
      ['+ → -', '- → +', '* → /', '/ → *', '% → *', '~/ → *'],
    );
  });

  test('ArithmeticOperator leaves a concatenation with a string literal '
      'alone', () {
    expect(
      only(
        'ArithmeticOperator',
        "String f(String a) => 'x' + a + \"y\${a}\";\nint g(int a) => a + 1;",
      ),
      ['+ → -'],
    );
  });

  test('EqualityOperator', () {
    expect(
      only(
        'EqualityOperator',
        'bool f(int a, int b) => a < b || a <= b || a > b || a >= b || '
            'a == b || a != b;',
      ),
      [
        '< → <=',
        '< → >=',
        '<= → <',
        '<= → >',
        '> → >=',
        '> → <=',
        '>= → >',
        '>= → <',
        '== → !=',
        '!= → ==',
      ],
    );
  });

  test('a type argument is not a comparison', () {
    expect(
      only(
        'EqualityOperator',
        'List<Map<String, int>> f() => <Map<String, int>>[];',
      ),
      isEmpty,
    );
  });

  test('LogicalOperator', () {
    expect(
      only(
        'LogicalOperator',
        'bool f(bool a, bool b, bool? c) => a && b || (c ?? a);',
      ),
      ['&& → ||', '|| → &&', 'c ?? a → a'],
    );
  });

  test('the other binary operators have no mutant', () {
    expect(
      mutantsOf('int f(int a, int b) => a & b | a ^ b << 2 >> 1 >>> 1;'),
      isEmpty,
    );
  });

  group('ConditionalExpression', () {
    test('if, the conditional operator and a collection if', () {
      expect(
        only(
          'ConditionalExpression',
          'List<int> f(bool a, bool b, bool c) { if (a) {} '
              'return [b ? 1 : 2, if (c) 3]; }',
        ),
        [
          'a → true',
          'a → false',
          'b → true',
          'b → false',
          'c → true',
          'c → false',
        ],
      );
    });

    test('a loop only gets "false": always true would never end', () {
      expect(
        only(
          'ConditionalExpression',
          'void f(int a) { while (a > 0) {} do {} while (a > 1); '
              'for (var i = 0; i < a; i++) {} for (;;) {} '
              'for (final x in [a]) {} }',
        ),
        ['a > 0 → false', 'a > 1 → false', 'i < a → false'],
      );
    });

    test('a null test or a type test keeps the promotion that still '
        'holds', () {
      expect(
        only(
          'ConditionalExpression',
          'int f(int? a, Object b, int c) { if (a != null) { return a; } '
              'if (null == a && c > 0) {} if (b is int) { return b; } '
              'return c > 0 ? 1 : 2; }',
        ),
        [
          'a != null → (a != null) || true',
          'a != null → (a != null) && false',
          'null == a && c > 0 → (null == a && c > 0) || true',
          'null == a && c > 0 → (null == a && c > 0) && false',
          'b is int → (b is int) || true',
          'b is int → (b is int) && false',
          'c > 0 → true',
          'c > 0 → false',
        ],
      );
    });

    test('a null test inside a closure of the condition does not count', () {
      expect(
        only(
          'ConditionalExpression',
          'void f(List<int?> a) { if (a.any((x) => x == null)) {} }',
        ),
        ['a.any((x) => x == null) → true', 'a.any((x) => x == null) → false'],
      );
    });

    test('a pattern (`if (x case ...)`) is left alone', () {
      expect(
        only(
          'ConditionalExpression',
          'void f(Object a) { if (a case int b when b > 0) {} }',
        ),
        isEmpty,
      );
    });

    test('a pattern in a collection if is left alone as well', () {
      expect(
        only(
          'ConditionalExpression',
          'List<int> f(Object a) => [if (a case int b when b > 0) b];',
        ),
        isEmpty,
      );
    });

    test('a literal condition is left to BooleanLiteral: one mutant, not '
        'two', () {
      for (final source in [
        'void f() { while (true) {} }',
        'void f() { if (false) {} }',
        'void f() { do {} while (true); }',
        'int f() => true ? 1 : 2;',
      ]) {
        expect(only('ConditionalExpression', source), isEmpty, reason: source);
        expect(only('BooleanLiteral', source), hasLength(1), reason: source);
      }
    });

    test('the condition of a collection for', () {
      expect(
        only(
          'ConditionalExpression',
          'List<int> f(int a) => [for (var i = 0; i < a; i++) i];',
        ),
        ['i < a → false'],
      );
    });
  });

  test('what is inside a collection if, a for and a collection for is '
      'mutated', () {
    expect(mutantsOf('List<int> f(bool a, int b) => [if (a) b + 1];'), [
      'ArrayDeclaration: [if (a) b + 1] → []',
      'ConditionalExpression: a → true',
      'ConditionalExpression: a → false',
      'ArithmeticOperator: + → -',
    ]);
    expect(
      only(
        'ArithmeticOperator',
        'void f(int n) { for (var i = 0; i < n; i = i + 1) {} }',
      ),
      ['+ → -'],
    );
    expect(
      only(
        'ArithmeticOperator',
        'List<int> f(int n) => [for (var i = 0; i < n; i++) i * 2];',
      ),
      ['* → /'],
    );
  });

  test('BooleanLiteral: the literals, and "!" removed', () {
    expect(only('BooleanLiteral', 'bool f(bool a) => !a ? true : false;'), [
      '!a → a',
      'true → false',
      'false → true',
    ]);
  });

  test('UnaryOperator, UpdateOperator, AssignmentOperator', () {
    const source =
        'num f(num a, int? b, String s) { a++; --a; a--; ++a; a += 1; a -= 1; '
        "a *= 2; a /= 2; a ~/= 2; a %= 2; b ??= 1; a = 3; s += 'x'; s += s; "
        'return -a; }';
    expect(only('UpdateOperator', source), [
      '++ → --',
      '-- → ++',
      '-- → ++',
      '++ → --',
    ]);
    expect(only('AssignmentOperator', source), [
      '+= → -=',
      '-= → +=',
      '*= → /=',
      '/= → *=',
      '~/= → *=',
      '%= → *=',
      '??= → =',
      // `s += s`: nothing in the syntax says that s is a String.
      '+= → -=',
    ]);
    expect(only('UnaryOperator', source), ['-a → a']);
  });

  test('the other prefix and postfix operators have no mutant', () {
    expect(mutantsOf('int f(int a, int? b) => ~a & b!;'), isEmpty);
  });

  test('what is inside a prefix, a postfix and an assignment is mutated', () {
    expect(
      mutantsOf(
        'void f(List<int> a, int b, int c) { -(b + c); a[b + 1]++; '
        'c += b * 2; }',
      ),
      [
        startsWith('BlockStatement: '),
        'UnaryOperator: -(b + c) → (b + c)',
        'ArithmeticOperator: + → -',
        'ArithmeticOperator: + → -',
        'UpdateOperator: ++ → --',
        'AssignmentOperator: += → -=',
        'ArithmeticOperator: * → /',
      ],
    );
  });

  group('BlockStatement', () {
    test('a block with statements is emptied, an empty one is not', () {
      expect(
        only(
          'BlockStatement',
          'void f(bool a) { if (a) { g(); } else {} }\nvoid g() {}',
        ),
        ['{ if (a) { g(); } else {} } → {}', '{ g(); } → {}'],
      );
    });

    test('the body of a function that returns a value is not emptied', () {
      for (final source in [
        'int f() { return 1; }',
        'Future<int> f() async { return 1; }',
        'Future<void> f() { return g(); }\nFuture<void> g() async {}',
        'class A { int get a { return 1; } }',
        'class A { A(); factory A.b() { return A(); } }',
        'class A { factory A() { throw StateError(\'no\'); } }',
        'class A { int a() { throw StateError(\'no\'); } }',
        'class A { int operator +(int b) { return b; } }',
        // No declared type: the type comes from the body.
        'f() { return 1; }',
        'final f = () { return 1; };',
        // async without a type that says what the future holds.
        'Result f() async { return g(); }',
        'FutureOr f() async { return g(); }',
      ]) {
        expect(only('BlockStatement', source), isEmpty, reason: source);
      }
      // A local function: only the function around it is emptied.
      expect(
        only('BlockStatement', 'void g() { int h() { return 1; } h(); }'),
        ['{ int h() { return 1; } h(); } → {}'],
      );
    });

    test('the body of a function that may end without a value is '
        'emptied', () {
      for (final source in [
        'void f() { g(); }\nvoid g() {}',
        'Future<void> f() async { g(); }\nvoid g() {}',
        'Future<int?> f() async { return 1; }',
        'FutureOr<void> f() async { g(); }\nvoid g() {}',
        'int? f() { return 1; }',
        'dynamic f() { return 1; }',
        'Null f() { g(); return null; }\nvoid g() {}',
        'Iterable<int> f() sync* { yield 1; }',
        'Stream<int> f() async* { yield 1; }',
        'class A { A() { g(); } }\nvoid g() {}',
        'class A { set a(int b) { g(); } }\nvoid g() {}',
        'f() { g(); }\nvoid g() {}',
        'final f = () { g(); };\nvoid g() {}',
        // No declared type, and no value is returned.
        'f() { g(); return; }\nvoid g() {}',
        // A setter has no declared type and may return a void call.
        'class A { set a(int b) { g(); return g(); } }\nvoid g() {}',
        // A method: the declared type counts, not what the body returns.
        'class A { int? a() { return 1; } }',
        'f() { h(() { return 1; }); }',
        // async without a type argument.
        'Future f() async { g(); }\nvoid g() {}',
        'void f() async { g(); }\nvoid g() {}',
        'dynamic f() async { g(); }\nvoid g() {}',
        // The type as it is written, with spaces.
        'Future< void > f() async { g(); }\nvoid g() {}',
        'Future<int ?> f() async { return 1; }',
        // The `return 1` belongs to the closure, not to f.
        'void f() { final h = () { return 1; }; h(); }',
      ]) {
        expect(only('BlockStatement', source), isNotEmpty, reason: source);
        expect(
          only('BlockStatement', source).first,
          startsWith('{'),
          reason: source,
        );
      }
      expect(
        only('BlockStatement', 'void f() { final h = () { return 1; }; h(); }'),
        ['{ final h = () { return 1; }; h(); } → {}'],
      );
    });

    test('the last block on a path of a function that returns a value is '
        'not emptied', () {
      expect(
        only(
          'BlockStatement',
          'int f(bool a, bool b) { if (a) { return 1; } '
              'if (b) { return 2; } else if (a) { return 3; } else { '
              'try { return 4; } catch (e) { return 5; } } }',
        ),
        // Only the block that code follows.
        ['{ return 1; } → {}'],
      );
    });

    test('a last block that only returns nothing is not emptied: the '
        'function returns the same without it', () {
      expect(
        only(
          'BlockStatement',
          'int? f(bool a, bool b) { if (a) { return null; } '
              'if (b) { return 1; } else { return null; } }\n'
              'void g(bool a) { if (a) { h(); } else { return; } }\n'
              'void h() { return; }\n'
              'Future<int?> i() async { return null; }',
        ),
        [
          startsWith('{ if (a) { return null; } if (b)'),
          // Code follows: the function goes on instead of returning.
          '{ return null; } → {}',
          '{ return 1; } → {}',
          '{ if (a) { h(); } else { return; } } → {}',
          '{ h(); } → {}',
        ],
      );
    });

    test('an if without else at the end of a function ends it as well', () {
      expect(
        only(
          'BlockStatement',
          'void f(bool a) { h(); if (a) { return; } }\nvoid h() {}',
        ),
        ['{ h(); if (a) { return; } } → {}'],
      );
      expect(
        only(
          'BlockStatement',
          'void f(bool a) { if (a) { return; } h(); }\nvoid h() {}',
        ),
        ['{ if (a) { return; } h(); } → {}', '{ return; } → {}'],
      );
      // The function ends without a value on the path that skips the if,
      // so its block can be emptied although a value is returned elsewhere.
      expect(
        only(
          'BlockStatement',
          'f(bool a, bool b) { if (b) return 5; if (a) { h(); } }\n'
              'void h() {}',
        ),
        ['{ h(); } → {}'],
      );
      expect(
        only(
          'BlockStatement',
          'f(bool a, bool b) { if (b) return 5; '
              'if (a) { try { h(); } catch (e) { return null; } } }\n'
              'void h() {}',
        ),
        ['{ try { h(); } catch (e) { return null; } } → {}', '{ h(); } → {}'],
      );
    });

    test('with a finally, and in a function without a value, the last '
        'blocks are emptied', () {
      expect(
        only(
          'BlockStatement',
          'int f() { try { return 1; } catch (e) { return 2; } '
              'finally { g(); } }\nvoid g() {}',
        ),
        ['{ return 1; } → {}', '{ return 2; } → {}', '{ g(); } → {}'],
      );
      expect(
        only(
          'BlockStatement',
          'void f(bool a) { if (a) { g(); } else { g(); } }\nvoid g() {}',
        ),
        hasLength(3),
      );
    });
  });

  group('RemoveCall', () {
    test('a call whose result is not used, awaited or not', () {
      expect(
        only(
          'RemoveCall',
          'Future<void> f(void Function() h) async { g(); await g(); h(); '
              'final a = g(); a; }\nFuture<void> g() async {}',
        ),
        ['g(); → ;', 'await g(); → ;', 'h(); → ;'],
      );
    });

    test('the only statement of a block is left to BlockStatement', () {
      const source = 'void f(bool a) { if (a) { g(); } }\nvoid g() {}';
      expect(only('RemoveCall', source), isEmpty);
      expect(only('BlockStatement', source), contains('{ g(); } → {}'));
    });

    test('a call that is the whole branch of an if stays a statement', () {
      const source = 'void f(bool a) { if (a) g(); g(); }\nvoid g() {}';
      expect(only('RemoveCall', source), ['g(); → ;', 'g(); → ;']);
      final mutant = findMutants(
        source,
      ).mutants.firstWhere((mutant) => mutant.mutator == 'RemoveCall');
      expect(
        mutant.applyTo(source),
        'void f(bool a) { if (a) ; g(); }\nvoid g() {}',
      );
    });
  });

  group('StringLiteral', () {
    test('a string is emptied, an empty one is filled', () {
      expect(
        only(
          'StringLiteral',
          "String f(int a) => 'x' + \"\" + 'a\$a' + r'\\d';",
        ),
        ["'x' → ''", "\"\" → 'mutated'", "'a\$a' → ''", "r'\\d' → ''"],
      );
    });

    test('adjacent strings are one string; the expressions inside are '
        'still mutated', () {
      expect(mutantsOf("String f(int a) => 'x' 'y\${a + 1}';"), [
        "StringLiteral: 'x' 'y\${a + 1}' → ''",
        'ArithmeticOperator: + → -',
      ]);
    });

    test('a string inside an interpolation', () {
      expect(only('StringLiteral', "String f(bool a) => '\${a ? 'y' : ''}';"), [
        "'\${a ? 'y' : ''}' → ''",
        "'y' → ''",
        "'' → 'mutated'",
      ]);
    });
  });

  test('ArrayDeclaration keeps the type arguments and const', () {
    const source =
        'final a = const <int>[1, 2]; final b = <int>[]; final c = [a];';
    expect(only('ArrayDeclaration', source), ['[1, 2] → []', '[a] → []']);
  });

  test('directives, annotations and assertions are not mutated', () {
    expect(
      mutantsOf('''
library a;

import 'dart:math';
export 'dart:math' show max;
part 'a.g.dart';

@Deprecated('x' 'y')
class A {
  A(int a) : assert(a > 0, 'positive');

  @pragma('vm:prefer-inline')
  void f(int a) {
    assert(a > 0 && true, 'm');
  }
}
'''),
      isEmpty,
    );
    expect(mutantsOf("part of 'a.dart';\n"), isEmpty);
  });

  test('comments and the content of strings are not mutated', () {
    expect(
      mutantsOf(
        "// a + b && true\n/* if (a) {} */\nconst a = 'b + c == true';\n",
      ),
      ["StringLiteral: 'b + c == true' → ''"],
    );
  });

  test('the mutants are in the order of the source; at one place, in the '
      'order they are found', () {
    const source =
        'bool f(int a) { if (a == 1) { return true; } return false; }';
    final found = findMutants(source).mutants;
    expect(
      [for (final mutant in found) mutant.offset],
      [
        ...[for (final mutant in found) mutant.offset],
      ]..sort(),
    );
    expect(mutantsOf(source), [
      'ConditionalExpression: a == 1 → true',
      'ConditionalExpression: a == 1 → false',
      'EqualityOperator: == → !=',
      'BlockStatement: { return true; } → {}',
      'BooleanLiteral: true → false',
      'BooleanLiteral: false → true',
    ]);
  });

  test('at one place the order is kept in a long file as well', () {
    // More mutants than a sort keeps in order by itself (Dart's is only
    // stable for short lists).
    const comparisons = 40;
    final source =
        'bool f(int a, int b) => ${List.filled(comparisons, 'a < b').join(' || ')};';
    expect(only('EqualityOperator', source), [
      for (var i = 0; i < comparisons; i++) ...['< → <=', '< → >='],
    ]);
  });

  test('every mutant of a file is still Dart', () {
    const source = r'''
import 'dart:math';

class Price {
  Price(this.cents, {this.label = 'x'});

  final int cents;
  final String? label;

  bool get isFree => cents == 0;

  int discounted(int percent, {bool round = true}) {
    if (percent < 0 || percent > 100) {
      throw ArgumentError('percent $percent');
    }
    var value = cents * (100 - percent) / 100;
    if (!round) {
      value -= 1;
    }
    for (var i = 0; i < 2; i++) {
      value = max(0, value);
    }
    final names = [label ?? '', 'b'];
    names.clear();
    return isFree ? 0 : -value.round();
  }
}
''';
    final found = findMutants(source).mutants;
    expect(found.length, greaterThan(25));
    for (final mutant in found) {
      final mutated = mutant.applyTo(source);
      expect(mutated, isNot(source));
      expect(
        parseString(content: mutated, throwIfDiagnostics: false).errors,
        isEmpty,
        reason: '${mutant.mutator} → ${mutant.replacement}',
      );
    }
  });

  test('a byte order mark is kept in front of the offsets', () {
    const source = '﻿int f(int a) => a + 1;\n';
    final mutant = findMutants(source).mutants.single;
    expect(source.substring(mutant.offset, mutant.end), '+');
    expect(mutant.applyTo(source), '﻿int f(int a) => a - 1;\n');
  });

  test('a file that is not Dart has no mutants and says so', () {
    final found = findMutants('int f( => 1;');
    expect(found.syntaxErrors, isTrue);
    expect(found.mutants, isEmpty);
  });
}
