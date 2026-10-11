import 'package:test/test.dart';
import 'package:test_gates/src/dart_source.dart';

List<String> lines(List<SourceFinding> findings) => [
  for (final finding in findings) '${finding.line}: ${finding.what}',
];

void main() {
  group('directives', () {
    test('imports, exports and parts, with their lines', () {
      final parsed = parseDartSource('''
library;

import 'dart:math';
import 'package:a/a.dart' as a;
import "../b.dart" deferred as b;
export 'src/c.dart';
part 'd.g.dart';

int f() => 1;
''');
      expect(
        parsed.imports.map((ref) => '${ref.line} ${ref.kind.name} ${ref.uri}'),
        [
          '3 import dart:math',
          '4 import package:a/a.dart',
          '5 import ../b.dart',
          '6 export src/c.dart',
          '7 part d.g.dart',
        ],
      );
      expect(parsed.imports.map((ref) => ref.shown), everyElement(isNull));
      expect(parsed.partOfLine, isNull);
      expect(parsed.syntaxErrors, isEmpty);
    });

    test('show lists the names; hide leaves the library whole', () {
      final parsed = parseDartSource('''
import 'dart:math' show max, min;
import 'dart:async' show Future show Timer;
import 'dart:convert' hide utf8;
export 'a.dart' show A;
''');
      expect(parsed.imports.map((ref) => ref.shown), [
        ['max', 'min'],
        ['Future', 'Timer'],
        null,
        ['A'],
      ]);
    });

    test('a conditional import gives every URI', () {
      final parsed = parseDartSource('''
import 'stub.dart'
    if (dart.library.io) 'io.dart'
    if (dart.library.js_interop) 'web.dart' show open;
''');
      expect(parsed.imports.map((ref) => '${ref.line} ${ref.uri}'), [
        '1 stub.dart',
        '2 io.dart',
        '3 web.dart',
      ]);
      expect(parsed.imports.map((ref) => ref.shown), everyElement(['open']));
    });

    test('an annotation is not a directive, and not an error', () {
      final parsed = parseDartSource('''
import 'package:json_annotation/json_annotation.dart';

part 'shipping_fee.g.dart';

@JsonSerializable()
class ShippingFee {
  @JsonKey(name: 'flat_cents')
  final int? flatCents;
  ShippingFee(this.flatCents);
}
''');
      expect(parsed.imports, hasLength(2));
      expect(parsed.syntaxErrors, isEmpty);
    });

    test('an import in a comment or a string is not an import', () {
      final parsed = parseDartSource('''
// import 'dart:io';
/* import 'dart:ffi'; */
/// import 'dart:html';
const text = "import 'dart:io';";
const more = \'\'\'
import 'dart:io';
\'\'\';
''');
      expect(parsed.imports, isEmpty);
    });

    test('part of', () {
      expect(
        parseDartSource(
          "// a part\npart of 'a.dart';\nint f() => 1;\n",
        ).partOfLine,
        2,
      );
      expect(parseDartSource('part of a.b;\n').partOfLine, 1);
    });

    test('a URI with an interpolation cannot be checked', () {
      final parsed = parseDartSource("import 'a\${1}.dart';\n");
      expect(parsed.imports, isEmpty);
      expect(parsed.uncheckableUris, [1]);
    });
  });

  group('syntax errors', () {
    test('are reported with their line', () {
      final parsed = parseDartSource('int f() {\n  return 1\n}\n');
      expect(parsed.syntaxErrors.single.line, anyOf(2, 3));
      expect(parsed.syntaxErrors.single.what, isNotEmpty);
    });

    test('a byte order mark is not one, and moves no line', () {
      final parsed = parseDartSource("\uFEFFimport 'dart:io';\n");
      expect(parsed.syntaxErrors, isEmpty);
      expect(
        (parsed.imports.single.uri, parsed.imports.single.line),
        ('dart:io', 1),
      );
    });

    test('an empty file is fine', () {
      final parsed = parseDartSource('');
      expect(parsed.syntaxErrors, isEmpty);
      expect(parsed.imports, isEmpty);
      expect(parsed.identifiers, isEmpty);
    });
  });

  group('reads of the environment', () {
    test('every spelling', () {
      final parsed = parseDartSource('''
import 'dart:io' as io;
const a = String.fromEnvironment('A');
const b = bool.fromEnvironment('B', defaultValue: true);
const c = int.fromEnvironment('C');
const d = bool.hasEnvironment('D');
final e = Platform.environment['E'];
final f = io.Platform.environment;
final g = Platform
    .environment;
final h = const String.fromEnvironment('H');
final i = "\${Platform.environment['I']}";
final j = [1].map(String.fromEnvironment);
''');
      expect(lines(parsed.environmentReads), [
        '2: String.fromEnvironment',
        '3: bool.fromEnvironment',
        '4: int.fromEnvironment',
        '5: bool.hasEnvironment',
        '6: Platform.environment',
        '7: Platform.environment',
        '8: Platform.environment',
        '10: String.fromEnvironment',
        '11: Platform.environment',
        '12: String.fromEnvironment',
      ]);
    });

    test('a comment, a string and other members are not reads', () {
      final parsed = parseDartSource('''
// Platform.environment
/// String.fromEnvironment('A')
const text = 'Platform.environment and bool.fromEnvironment';
final os = Platform.operatingSystem;
final s = String.fromCharCode(65);
final n = int.parse('1');
final m = config.environment;
final x = MyPlatform.environment;
final y = double.fromEnvironment;
''');
      expect(parsed.environmentReads, isEmpty);
    });
  });

  test('a read: the name and the member are joined by . or ?.', () {
    expect(
      parseDartSource(
        'final a = [Platform, environment];\n'
        'final b = (String, fromEnvironment);\n',
      ).environmentReads,
      isEmpty,
    );
    expect(
      lines(
        parseDartSource('final a = Platform?.environment;\n').environmentReads,
      ),
      ['1: Platform.environment'],
    );
  });

  test('identifiers: names and keywords, no other token', () {
    expect(parseDartSource("int f(int x) => g(x + 1, 'y');\n").identifiers, {
      'int',
      'f',
      'x',
      'g',
    });
  });

  test('identifiers are those of the code only', () {
    final parsed = parseDartSource('''
// Random
import 'dart:math';
const text = 'Timer';
int roll(Random random) => random.nextInt(6);
''');
    expect(parsed.identifiers, containsAll(['Random', 'random', 'nextInt']));
    expect(parsed.identifiers, isNot(contains('Timer')));
    expect(parsed.identifiers, isNot(contains('dart')));
  });

  group('blocks that start on one line', () {
    List<String> shared(String source) =>
        lines(parseDartSource(source).sharedBlockLines);

    test('formatted code has none', () {
      expect(
        shared('''
int a(bool x, bool y) {
  if (x) {
    return 1;
  } else if (y) {
    return 2;
  } else {
    return 3;
  }
}

int b(int n) {
  if (n < 0) return -1;
  var total = 0;
  for (var i = 0; i < n; i++) {
    total += i;
  }
  while (total > 100) {
    total -= 100;
  }
  do {
    total++;
  } while (total < 3);
  for (final x in [1, 2]) total += x;
  return total;
}

int c(int n) {
  switch (n) {
    case 1:
      return 10;
    case 2:
    case 3:
      return 20;
    default:
      return 0;
  }
}

String d(int n) => switch (n) {
  1 => 'a',
  _ => 'b',
};

int e(bool x) {
  try {
    if (x) throw StateError('x');
    return 1;
  } on StateError catch (_) {
    return 2;
  } catch (_) {
    return 3;
  } finally {
    x = !x;
  }
}

List<int> f(bool x, List<int> xs) => [
  if (x) 1 else 2,
  for (final y in xs)
    if (y > 0) y,
];

int g(List<int> xs) => xs.map((y) => y * 2).fold(0, (p, y) => p + y);

void h() {}

class K {
  K(this.v);
  final int v;
  int get twice => v * 2;
  int add(int o) {
    return v + o;
  }
}
'''),
        isEmpty,
      );
    });

    test('if and else on one line', () {
      expect(
        shared(
          'int f(bool a) {\n  if (a) { return 1; } else { return 2; }\n}\n',
        ),
        ['2: 2'],
      );
    });

    test('the whole function on one line', () {
      expect(shared('int f(bool a) { if (a) { return 1; } return 2; }\n'), [
        '1: 2',
      ]);
      expect(
        shared('int f(bool a) { if (a) { return 1; } else { return 2; } }\n'),
        ['1: 3'],
      );
    });

    test('nested control flow without braces, formatted or not', () {
      expect(
        shared('''
int f(bool a, bool b, List<int> xs) {
  var n = 0;
  if (a) if (b) return 1;
  for (final x in xs) if (x > 0) n += x;
  while (n > 9) if (a) n--;
  return n;
}
'''),
        ['3: 2', '4: 2', '5: 2'],
      );
    });

    test('switch members and arms on one line', () {
      expect(
        shared('''
int f(int x) {
  switch (x) { case 1: return 10; case 2: return 20; default: return 0; }
}

String g(int x) => switch (x) { 1 => 'a', 2 => 'b', _ => 'c' };
'''),
        ['2: 3', '5: 3'],
      );
    });

    test('try and catch on one line', () {
      expect(
        shared('''
int f(bool a) {
  try { return 1; } catch (e) { return 2; } finally { a = !a; }
}
'''),
        ['2: 3'],
      );
    });

    test('the body of do … while', () {
      expect(
        shared('''
void f(bool a) {
  do { if (a) { g(); } } while (a);
}
'''),
        ['2: 2'],
      );
    });

    test('blocks inside a do, a case, an arm and a try are looked at', () {
      expect(
        shared('''
void f(bool a, int x) {
  do {
    if (a) { g(); } else { h(); }
  } while (a);
  switch (x) {
    case 1:
      if (a) { g(); } else { h(); }
  }
  final k = switch (x) {
    1 => () {
      if (a) { g(); } else { h(); }
    },
    _ => null,
  };
  try {
    if (a) { g(); } else { h(); }
  } finally {
    k?.call();
  }
}
'''),
        ['3: 2', '7: 2', '11: 2', '16: 2'],
      );
    });

    test('a closure counts with the blocks of its own body only', () {
      expect(
        shared('''
void f(bool a, List<int> xs) {
  if (a) xs.forEach((x) { print(x); });
  xs.forEach((x) { if (x > 0) { print(x); } });
}
'''),
        ['3: 2'],
      );
    });
  });

  group('skipped and focused tests', () {
    List<String> disabled(String source) =>
        lines(parseDartSource(source).disabledTests);

    test('skip, solo and @Skip', () {
      expect(
        disabled('''
@Skip('later')
library;

import 'package:test/test.dart';

void main() {
  test('a', () {}, skip: true);
  test('b', () {}, skip: 'flaky');
  group('c', () {}, skip: isBroken);
  test('d', () {}, solo: true);
  test(
    'e',
    () {},
    skip: !enabled,
  );
  test('f', () {}, skip: false || true);
}
'''),
        [
          '1: @Skip',
          '7: skip:',
          '8: skip:',
          '9: skip:',
          '10: solo:',
          '14: skip:',
          '16: skip:',
        ],
      );
    });

    test('markTestSkipped', () {
      expect(
        disabled(
          "void main() {\n  test('a', () {\n    markTestSkipped('x');\n  });\n}\n",
        ),
        ['3: markTestSkipped()'],
      );
      expect(disabled('final f = markTestSkipped;\n'), isEmpty);
    });

    test('@Skip through an import prefix', () {
      expect(
        disabled('@t.Skip()\nlibrary;\n\n@t.Timeout(x)\nvoid main() {}\n'),
        ['1: @Skip'],
      );
    });

    test('what leaves the test on', () {
      expect(
        disabled('''
// test('a', () {}, skip: true);
void main() {
  test('a', () {}, skip: false);
  test('b', () {}, skip: null);
  test('c', () {}, solo: false, skip: false);
  test('skip: true', () {});
  final skip = 1;
  final map = {skip: 2};
  final x = flag ? skip : 0;
  markSkipped(skip);
}
'''),
        isEmpty,
      );
    });
  });
}
