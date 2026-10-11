import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';

const pure = 'int twice(int x) => x * 2;\n';
const spec = "void main() {\n  test('a', () {});\n}\n";

void main() {
  late Directory dir;
  late List<String> out;
  late List<String> err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('test_gates_');
    out = [];
    err = [];
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void write(String path, String content) {
    File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  Map<String, Object?> gate(String path) => {
    'path': path,
    'decides': 'd',
    'impact': 'i',
  };

  Map<String, Object?> candidate(String path) => {
    'path': path,
    'decides': 'd',
    'blocker': 'b',
  };

  void manifest(
    List<String> gates, {
    List<String> candidates = const [],
    Map<String, Object?>? settings,
  }) => write(
    'test-gates.json',
    jsonEncode({
      'gates': gates.map(gate).toList(),
      'candidates': candidates.map(candidate).toList(),
      'settings': ?settings,
    }),
  );

  int check() =>
      run(['check', '--dir', dir.path], Io(out: out.add, err: err.add));

  group('exit code 0', () {
    test('pure gates with their tests, next to the gate or under test/', () {
      manifest(
        ['lib/a.dart', 'lib/m/b.dart'],
        candidates: ['lib/blocs', 'lib/c.dart'],
      );
      write('pubspec.yaml', 'name: app\n');
      write('lib/a.dart', "import 'package:app/m/b.dart';\n$pure");
      write('lib/a_test.dart', spec);
      write('lib/m/b.dart', pure);
      write('test/m/b_test.dart', spec);
      write('lib/blocs/basket.dart', '');
      write('lib/c.dart', '');
      expect(check(), 0);
      expect(out, ['test_gates check: OK (2 gate(s), 2 candidate(s))']);
      expect(err, isEmpty);
    });

    test('spec.suffixes: [] turns the test checks off', () {
      manifest(
        ['lib/a.dart'],
        settings: {
          'gateExtensions': ['.dart'],
          'spec': {'suffixes': <String>[]},
        },
      );
      write('lib/a.dart', pure);
      // Named like a test, skipped, and still not looked at.
      write(
        'lib/a_test.dart',
        "void main() {\n  test('a', () {}, skip: true);\n}\n",
      );
      expect(check(), 0);
      expect(out, ['test_gates check: OK (1 gate(s), 0 candidate(s))']);
    });

    test('no pubspec.yaml is not an error', () {
      manifest(['lib/a.dart']);
      write('lib/a.dart', pure);
      write('lib/a_test.dart', spec);
      expect(check(), 0);
    });
  });

  group('exit code 1', () {
    test('every violation is reported, on stderr', () {
      manifest(
        [
          'lib/a.dart',
          'lib/missing.dart',
          'lib/a.ts',
          'lib/a_test.dart',
          '../x.dart',
          'lib/lonely.dart',
          'lib/both.dart',
          'lib/skipped.dart',
          'lib/m.g.dart',
        ],
        candidates: ['lib/gone', '../up'],
      );
      write(
        'lib/a.dart',
        "import 'dart:io';\n\nfinal home = Platform.environment['HOME'];\n",
      );
      write('lib/a_test.dart', spec);
      write('lib/a.ts', '');
      write('lib/lonely.dart', pure);
      write('lib/both.dart', pure);
      write('lib/both_test.dart', spec);
      write('test/both_test.dart', spec);
      write('lib/skipped.dart', pure);
      write(
        'test/skipped_test.dart',
        "void main() {\n  test('a', () {}, skip: true);\n}\n",
      );
      write('lib/m.g.dart', pure);
      write('lib/m.g_test.dart', spec);
      expect(check(), 1);
      expect(out, isEmpty);
      expect(err, [
        'test_gates check: 12 violation(s)',
        '  - lib/a.dart:1: import of "dart:io" (file system / network / process access)',
        '  - lib/a.dart:3: reads Platform.environment (not a pure module). Take the value as an argument',
        '  - lib/missing.dart: file not found (the check is case-sensitive)',
        '  - lib/a.ts: a gate must be one of .dart (settings.gateExtensions)',
        '  - lib/a_test.dart: a test cannot be a gate',
        '  - test-gates.json: ../x.dart: write the path relative to the package, with "/" and without ".."',
        '  - lib/lonely.dart: test not found (looked for lib/lonely_test.dart, test/lonely_test.dart; the check is case-sensitive)',
        '  - lib/both.dart: more than one test (lib/both_test.dart, test/both_test.dart). Keep one, or narrow settings.spec',
        '  - test/skipped_test.dart:2: skip: (a skipped or focused test)',
        '  - lib/m.g.dart: cannot be a gate (generated file). Move it to candidates',
        '  - test-gates.json: lib/gone: candidate not found. Remove it, or fix the path',
        '  - test-gates.json: ../up: candidate not found. Remove it, or fix the path',
      ]);
    });

    test('problems of the list come first', () {
      write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            gate('lib/a.dart'),
            gate('lib/a.dart'),
            {'path': 'lib/b.dart', 'decides': 'd'},
          ],
          'candidates': [candidate('lib/a.dart')],
        }),
      );
      write('lib/a.dart', pure);
      write('lib/a_test.dart', spec);
      write('lib/b.dart', pure);
      write('lib/b_test.dart', spec);
      expect(check(), 1);
      expect(err, [
        'test_gates check: 3 violation(s)',
        '  - test-gates.json: lib/a.dart: listed twice in gates',
        '  - test-gates.json: lib/b.dart: "impact" is missing in gates',
        '  - test-gates.json: lib/a.dart: listed in both gates and candidates',
      ]);
    });

    test('the spelling of a gate and of its test is case-sensitive', () {
      manifest(['lib/Basket.dart', 'lib/b.dart']);
      write('lib/basket.dart', pure);
      write('lib/basket_test.dart', spec);
      write('lib/b.dart', pure);
      write('lib/B_test.dart', spec);
      expect(check(), 1);
      expect(err.skip(1), [
        '  - lib/Basket.dart: file not found (the check is case-sensitive)',
        '  - lib/b.dart: test not found (looked for lib/b_test.dart, test/b_test.dart; the check is case-sensitive)',
      ]);
    });

    test('a directory is not a gate; a candidate may be one', () {
      manifest(['lib/a.dart'], candidates: ['lib/a.dart']);
      Directory('${dir.path}/lib/a.dart').createSync(recursive: true);
      expect(check(), 1);
      expect(err.skip(1), [
        '  - test-gates.json: lib/a.dart: listed in both gates and candidates',
        '  - lib/a.dart: file not found (the check is case-sensitive)',
      ]);
    });

    test('settings change what is checked', () {
      manifest(
        ['lib/a.dart'],
        settings: {
          'spec': {
            'suffixes': ['_spec.dart'],
            'rewrite': [
              {'from': '^lib/', 'to': 'spec/'},
            ],
          },
          'impureImports': {
            'allow': ['^dart:io\$'],
            'add': [
              {'pattern': '^package:app/blocs/', 'reason': 'bloc'},
            ],
          },
          'forbiddenSource': {
            'defaults': false,
            'add': [
              {'pattern': r'\bprint\(', 'reason': 'prints'},
            ],
          },
        },
      );
      write('pubspec.yaml', 'name: app\n');
      write('lib/a.dart', '''
import 'dart:io';
import 'package:app/blocs/basket.dart';

final home = Platform.environment['HOME'];
void f() => print(home);
''');
      write('lib/a_test.dart', spec);
      expect(check(), 1);
      expect(err.skip(1), [
        '  - lib/a.dart:2: import of "package:app/blocs/basket.dart" (bloc)',
        '  - lib/a.dart:5: prints',
        '  - lib/a.dart: test not found (looked for spec/a_spec.dart; the check is case-sensitive)',
      ]);
    });

    test('allowlist mode knows the package from pubspec.yaml', () {
      manifest(
        ['lib/a.dart'],
        settings: {
          'spec': {'suffixes': <String>[]},
          'imports': {'mode': 'allowlist'},
        },
      );
      write('pubspec.yaml', '# the app\nname: app\n');
      write(
        'lib/a.dart',
        "import 'package:app/b.dart';\nimport 'package:other/b.dart';\n",
      );
      expect(check(), 1);
      expect(err.skip(1), [
        startsWith(
          '  - lib/a.dart:2: import of "package:other/b.dart" is not in settings.imports.allow',
        ),
      ]);
    });
  });

  group('exit code 2', () {
    test('no test-gates.json', () {
      expect(check(), 2);
      expect(
        err.single,
        startsWith('test_gates: test-gates.json not found in '),
      );
    });

    test('a broken setting of check', () {
      manifest(
        ['lib/a.dart'],
        settings: {
          'impureImports': {
            'add': ['('],
          },
        },
      );
      expect(check(), 2);
      expect(
        err.single,
        startsWith(
          'test_gates: test-gates.json: settings.impureImports.add[0]: '
          'invalid regular expression "("',
        ),
      );
      expect(out, isEmpty);
    });
  });
}
