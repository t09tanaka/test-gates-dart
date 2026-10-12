import 'dart:convert';

import 'package:test/test.dart';
import 'package:test_gates/src/mutation_run.dart';

Map<String, Object?> mutant(String status) => {
  'mutatorName': 'ArithmeticOperator',
  'status': status,
};

String report(Map<String, List<String>> statusesByFile) => jsonEncode({
  'schemaVersion': '2',
  'files': {
    for (final MapEntry(key: path, value: statuses) in statusesByFile.entries)
      path: {
        'mutants': [for (final status in statuses) mutant(status)],
      },
  },
});

void main() {
  group('the commands that are tried', () {
    test('the executable on PATH first, then the globally activated package '
        'through the dart that runs this program', () {
      expect(dartMutantCommands('/sdk/bin/dart'), [
        ['dart_mutant'],
        ['/sdk/bin/dart', 'pub', 'global', 'run', 'dart_mutant'],
      ]);
    });

    test('the command that installs the tool', () {
      expect(dartMutantInstall, 'dart pub global activate dart_mutant');
    });
  });

  group('dartMutantVersionOf', () {
    test('the version, when the command printed one and ended with 0', () {
      expect(dartMutantVersionOf(0, '0.1.0\n'), '0.1.0');
      expect(dartMutantVersionOf(0, '  12.30.4\r\n'), '12.30.4');
      expect(dartMutantVersionOf(0, '0.2.0-dev.1'), '0.2.0-dev.1');
      expect(dartMutantVersionOf(0, '1.0.0+build.5'), '1.0.0+build.5');
    });

    test('null when the command failed or could not be started', () {
      expect(dartMutantVersionOf(1, '0.1.0\n'), isNull);
      expect(dartMutantVersionOf(65, '0.1.0\n'), isNull);
      expect(dartMutantVersionOf(null, '0.1.0\n'), isNull);
    });

    test('null when what it printed is not a version', () {
      for (final output in [
        '',
        'Dart SDK version: 3.9.0',
        '0.1',
        '0.1.0.0',
        'v0.1.0',
        '0.1.0 (stable)',
        '0.1.0\nand more',
        'more\n0.1.0',
        '0.1.x',
        '0.1.0?',
        '0.1.0-a b',
      ]) {
        expect(dartMutantVersionOf(0, output), isNull, reason: output);
      }
    });
  });

  group('the supported versions', () {
    test('are 0.1.0 and every later 0.1.x, said in one place', () {
      expect(supportedDartMutant, (major: 0, minor: 1, patch: 0));
      expect(dartMutantConstraint(), '^0.1.0');
      expect(dartMutantRange(), '0.1.0 or later, below 0.2.0');
    });

    test('a higher lowest version: one constant decides the check and both '
        'texts', () {
      const lowest = (major: 0, minor: 1, patch: 1);
      expect(isSupportedDartMutant('0.1.0', lowest), isFalse);
      expect(isSupportedDartMutant('0.1.1', lowest), isTrue);
      expect(isSupportedDartMutant('0.1.2', lowest), isTrue);
      expect(isSupportedDartMutant('0.2.1', lowest), isFalse);
      expect(isSupportedDartMutant('1.1.1', lowest), isFalse);
      expect(dartMutantConstraint(lowest), '^0.1.1');
      expect(dartMutantRange(lowest), '0.1.1 or later, below 0.2.0');
      const other = (major: 2, minor: 9, patch: 3);
      expect(isSupportedDartMutant('2.9.3', other), isTrue);
      expect(isSupportedDartMutant('2.9.2', other), isFalse);
      expect(dartMutantConstraint(other), '^2.9.3');
      expect(dartMutantRange(other), '2.9.3 or later, below 2.10.0');
    });

    test('every patch of it, with or without a suffix', () {
      for (final version in ['0.1.0', '0.1.1', '0.1.27', '0.1.3-dev.1']) {
        expect(isSupportedDartMutant(version), isTrue, reason: version);
      }
    });

    test('no other minor and no other major', () {
      for (final version in ['0.2.0', '0.0.1', '1.1.0', '0.10.0', '0.11.1']) {
        expect(isSupportedDartMutant(version), isFalse, reason: version);
      }
    });
  });

  group('passThroughProblem', () {
    test('options of the tool are handed on', () {
      for (final rest in [
        ['--jobs', '3'],
        ['--shard=1/4', '--jobs=2'],
        ['--html', 'report.html'],
        ['--force'],
        ['--jobs', '2', '--', 'fvm', 'flutter', 'test', '--no-pub'],
        ['--', 'dart', 'test'],
        <String>[],
      ]) {
        expect(passThroughProblem(rest), isNull, reason: '$rest');
      }
    });

    test('an option that mutation sets by itself is refused, with the option '
        'that says the same', () {
      expect(
        passThroughProblem(['--jobs', '2', '--report', 'x.json']),
        '--report cannot be handed to dart_mutant run: mutation sets it from '
        'test-gates.json. Give --report in front of "--"',
      );
      expect(
        passThroughProblem(['--dir=..']),
        '--dir cannot be handed to dart_mutant run: mutation sets it from '
        'test-gates.json. Give --dir in front of "--"',
      );
      expect(
        passThroughProblem(['--only', 'lib/a.dart']),
        '--only cannot be handed to dart_mutant run: mutation sets it from '
        'test-gates.json. Give --gate in front of "--"',
      );
      expect(
        passThroughProblem(['--force', '--plan=p.json']),
        '--plan cannot be handed to dart_mutant run: mutation sets it from '
        'test-gates.json',
      );
    });

    test('an option with which the tool runs nothing is refused', () {
      for (final option in ['--help', '-h', '--version', '-v']) {
        expect(
          passThroughProblem(['--jobs', '2', option]),
          '$option cannot be handed to dart_mutant run: the tool would print '
          'its help or its version and run nothing',
        );
      }
      expect(passThroughProblem(['--', 'dart', 'test', '-h', '-v']), isNull);
      expect(passThroughProblem(['--helpful']), isNull);
    });

    test('behind the second "--" is the test command, which may hold '
        'anything', () {
      expect(
        passThroughProblem(['--', 'tool/test.sh', '--report', '--dir', 'x']),
        isNull,
      );
      expect(
        passThroughProblem(['--jobs', '1', '--', 'run', '--plan', 'p']),
        isNull,
      );
    });

    test('a test command directly behind the first "--" is refused, with '
        'how it is written now', () {
      expect(
        passThroughProblem(['flutter', 'test', '--no-pub']),
        'what follows "--" is handed to dart_mutant run, and "flutter" is '
        'not one of its options. The command that runs test files goes '
        'behind a second "--": mutation -- -- flutter test --no-pub',
      );
    });

    test('an option that only starts like one of them is not refused '
        'here', () {
      expect(passThroughProblem(['--directory', 'x']), isNull);
      expect(passThroughProblem(['--only-this']), isNull);
    });
  });

  group('asksForPart', () {
    test('--shard, with the value apart or with "="', () {
      expect(asksForPart(['--shard', '1/4']), isTrue);
      expect(asksForPart(['--jobs', '2', '--shard=2/4']), isTrue);
    });

    test('nothing else', () {
      expect(asksForPart([]), isFalse);
      expect(asksForPart(['--jobs', '2', '--html', 'm.html']), isFalse);
      expect(asksForPart(['--shards', '1/4']), isFalse);
      // Behind the second "--" it is an argument of the test command.
      expect(asksForPart(['--', 'dart', 'test', '--shard', '1/4']), isFalse);
    });
  });

  group('buildPlan', () {
    test('each gate with its tests, in the order given', () {
      expect(
        buildPlan([
          (file: 'lib/b.dart', tests: ['test/b_test.dart']),
          (file: 'lib/a.dart', tests: ['lib/a_test.dart', 'test/a_test.dart']),
        ]),
        {
          'version': 1,
          'targets': [
            {
              'file': 'lib/b.dart',
              'tests': ['test/b_test.dart'],
            },
            {
              'file': 'lib/a.dart',
              'tests': ['lib/a_test.dart', 'test/a_test.dart'],
            },
          ],
        },
      );
    });

    test('no gate: a plan without targets', () {
      expect(buildPlan([]), {'version': 1, 'targets': <Object?>[]});
    });

    test('the plan file is below .dart_tool', () {
      expect(planFile, '.dart_tool/test_gates/mutation-plan.json');
    });
  });

  group('dartMutantArguments', () {
    test('the package, the plan and the report', () {
      expect(
        dartMutantArguments(
          dir: '/p',
          plan: '/p/.dart_tool/plan.json',
          report: '/p/reports/m.json',
          force: false,
          only: null,
        ),
        [
          'run',
          '--dir',
          '/p',
          '--plan',
          '/p/.dart_tool/plan.json',
          '--report',
          '/p/reports/m.json',
        ],
      );
    });

    test('--force, --gate as --only, and the rest as it is, last', () {
      expect(
        dartMutantArguments(
          dir: 'd',
          plan: 'p',
          report: 'r',
          force: true,
          only: ['lib/a.dart', 'lib/b.dart'],
          rest: ['--jobs', '2', '--', 'dart', 'test'],
        ),
        [
          'run',
          '--dir',
          'd',
          '--plan',
          'p',
          '--report',
          'r',
          '--force',
          '--only',
          'lib/a.dart',
          '--only',
          'lib/b.dart',
          '--jobs',
          '2',
          '--',
          'dart',
          'test',
        ],
      );
    });
  });

  group('exitCodeWithoutVerdict', () {
    test('0 and 1 are judged by the report', () {
      expect(exitCodeWithoutVerdict(0), isNull);
      expect(exitCodeWithoutVerdict(1), isNull);
    });

    test('any other exit code is passed on', () {
      for (final code in [2, 3, 65, 129, 130, 143, 255]) {
        expect(exitCodeWithoutVerdict(code), code);
      }
    });

    test('a process that a signal ended: 128 + the signal', () {
      expect(exitCodeWithoutVerdict(-9), 137);
      expect(exitCodeWithoutVerdict(-15), 143);
      expect(exitCodeWithoutVerdict(-1), 129);
    });
  });

  group('missingFromReport', () {
    test('the gates the report has nothing about', () {
      final text = report({
        'lib/a.dart': ['Killed'],
        './lib/c.dart': ['Killed'],
      });
      expect(
        missingFromReport(text, ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']),
        ['lib/b.dart'],
      );
      expect(missingFromReport(text, ['./lib/a.dart']), isEmpty);
    });

    test('no report, or a file that is not one: every gate', () {
      for (final text in [
        null,
        'not json',
        '[]',
        '{}',
        '{"files": []}',
        '"text"',
      ]) {
        expect(missingFromReport(text, ['lib/a.dart']), [
          'lib/a.dart',
        ], reason: '$text');
      }
      expect(missingFromReport(null, []), isEmpty);
    });
  });

  group('explainsFailure', () {
    test('a mutant of one of the gates survived', () {
      final text = report({
        'lib/a.dart': ['Killed', 'CompileError'],
        'lib/b.dart': ['Killed', 'Survived'],
      });
      expect(explainsFailure(text, ['lib/a.dart', 'lib/b.dart']), isTrue);
      expect(explainsFailure(text, ['./lib/b.dart']), isTrue);
    });

    test('one of the gates is missing, or there is no report', () {
      final text = report({
        'lib/a.dart': ['Killed'],
      });
      expect(explainsFailure(text, ['lib/a.dart', 'lib/b.dart']), isTrue);
      expect(explainsFailure(null, ['lib/a.dart']), isTrue);
    });

    test('nothing survived and nothing is missing: the report does not say '
        'why', () {
      final text = report({
        'lib/a.dart': ['Killed', 'Timeout', 'CompileError', 'Pending'],
        'lib/b.dart': ['Killed'],
      });
      expect(explainsFailure(text, ['lib/a.dart', 'lib/b.dart']), isFalse);
      expect(explainsFailure(text, []), isFalse);
    });

    test('a survivor of a gate that is not one of this run explains '
        'nothing', () {
      final text = report({
        'lib/a.dart': ['Survived'],
        'lib/b.dart': ['Killed'],
      });
      expect(explainsFailure(text, ['lib/b.dart']), isFalse);
    });

    test('a file without a list of mutants, and a mutant that is not an '
        'object', () {
      expect(
        explainsFailure('{"files": {"lib/a.dart": {}}}', ['lib/a.dart']),
        isFalse,
      );
      expect(
        explainsFailure('{"files": {"lib/a.dart": {"mutants": "Survived"}}}', [
          'lib/a.dart',
        ]),
        isFalse,
      );
      expect(
        explainsFailure(
          '{"files": {"lib/a.dart": {"mutants": ["Survived"]}}}',
          ['lib/a.dart'],
        ),
        isFalse,
      );
      expect(
        explainsFailure('{"files": {"lib/a.dart": "Survived"}}', [
          'lib/a.dart',
        ]),
        isFalse,
      );
    });
  });

  group('selectGates (--gate)', () {
    const gates = ['lib/a.dart', 'lib/b.dart', 'lib/c.dart'];

    test('no request: every gate', () {
      final selection = selectGates(gates, []);
      expect(selection.selected, gates);
      expect(selection.unknown, isEmpty);
    });

    test('the requested gates, in the order of test-gates.json and each '
        'once', () {
      final selection = selectGates(gates, [
        'lib/c.dart',
        'lib/a.dart',
        'lib/c.dart',
      ]);
      expect(selection.selected, ['lib/a.dart', 'lib/c.dart']);
      expect(selection.unknown, isEmpty);
    });

    test('a path that is not a gate is named, once', () {
      final selection = selectGates(gates, [
        'lib/x.dart',
        'lib/b.dart',
        'lib/x.dart',
        './lib/a.dart',
      ]);
      expect(selection.selected, ['lib/b.dart']);
      expect(selection.unknown, ['lib/x.dart', './lib/a.dart']);
    });
  });

  group('isReport', () {
    test('a JSON object with files', () {
      expect(isReport('{"files": {}}'), isTrue);
      expect(isReport('{"schemaVersion": "2", "files": {"a": {}}}'), isTrue);
    });

    test('anything else is not', () {
      for (final text in ['', 'notes', '[]', '{}', '{"files": []}', '7']) {
        expect(isReport(text), isFalse, reason: text);
      }
    });
  });

  group('reportWithout', () {
    final existing = jsonEncode({
      'schemaVersion': '2',
      'framework': {'name': 'dart_mutant'},
      'files': {
        'lib/a.dart': {'mutants': <Object?>[]},
        './lib/b.dart': {'source': 'b'},
        r'lib\c.dart': {'source': 'c'},
      },
    });

    test('the report without the selected gates, the rest as it was', () {
      expect(jsonDecode(reportWithout(existing, ['lib/a.dart'])!), {
        'schemaVersion': '2',
        'framework': {'name': 'dart_mutant'},
        'files': {
          './lib/b.dart': {'source': 'b'},
          r'lib\c.dart': {'source': 'c'},
        },
      });
    });

    test('the paths are compared as the judgement compares them', () {
      expect(
        (jsonDecode(reportWithout(existing, ['lib/b.dart', 'lib/c.dart'])!)
            as Map)['files'],
        {
          'lib/a.dart': {'mutants': <Object?>[]},
        },
      );
      expect(
        (jsonDecode(reportWithout(existing, ['./lib/a.dart'])!) as Map)['files']
            as Map,
        hasLength(2),
      );
    });

    test('it is written with two spaces, as a report is', () {
      expect(
        reportWithout('{"files":{"lib/a.dart":{}}}', ['lib/b.dart']),
        '{\n  "files": {\n    "lib/a.dart": {}\n  }\n}',
      );
    });

    test('null when nothing is left', () {
      expect(
        reportWithout(existing, ['lib/a.dart', 'lib/b.dart', 'lib/c.dart']),
        isNull,
      );
      expect(reportWithout('{"files": {}}', ['lib/a.dart']), isNull);
    });
  });
}
