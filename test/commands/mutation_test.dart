@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/mutation.dart';

import 'package_fixture.dart';

const sourceA = 'int a(int x) => x + 1;\n';
const sourceB = 'int b(int x) => x * 2 - 1;';

const reportFile = 'reports/mutation/mutation.json';

/// One mutant of a report: the operator at [column] of the first line.
Map<String, Object?> mutant(
  String replacement,
  String status,
  int column, {
  String mutator = 'ArithmeticOperator',
}) => {
  'mutatorName': mutator,
  'replacement': replacement,
  'status': status,
  'location': {
    'start': {'line': 1, 'column': column},
    'end': {'line': 1, 'column': column + 1},
  },
};

/// The `+` of lib/a.dart, and the `*` and the `-` of lib/b.dart.
Map<String, Object?> plus(String status) => mutant('-', status, 19);
Map<String, Object?> times(String status) => mutant('/', status, 19);
Map<String, Object?> minus(String status) => mutant('+', status, 23);

Map<String, Object?> reportOf(
  Map<String, List<Map<String, Object?>>> files, {
  Map<String, Object?>? config,
}) => {
  'schemaVersion': '2',
  'config': ?config,
  'files': {
    for (final MapEntry(key: path, value: mutants) in files.entries)
      path: {
        'language': 'dart',
        'source': path == 'lib/a.dart' ? sourceA : sourceB,
        'mutants': mutants,
      },
  },
};

final everythingKilled = reportOf({
  'lib/a.dart': [plus('Killed')],
  'lib/b.dart': [times('Killed'), minus('Killed')],
});

const ok3 =
    'test_gates mutation: OK (mutants 3 / detected 3 (timeout 0) / '
    'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)';

void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      'test/fixtures/mutation/fake_dart_mutant.dart.txt',
    ).copySync('${package.dir.path}/fake_dart_mutant.dart');
    File(
      'test/fixtures/mutation/fake_fetch.dart.txt',
    ).copySync('${package.dir.path}/fake_fetch.dart');
    package.write('lib/a.dart', sourceA);
    package.write('lib/b.dart', sourceB);
    package.write('lib/a_test.dart', '');
    package.write('test/b_test.dart', '');
    package.manifest(['lib/a.dart', 'lib/b.dart']);
  });

  tearDown(() => package.delete());

  final fake = [Platform.resolvedExecutable, 'fake_dart_mutant.dart'];

  /// What the stand-in for the tool does, see the head of
  /// test/fixtures/mutation/fake_dart_mutant.dart.txt.
  void tool(Map<String, Object?> behaviour) =>
      package.write('fake.json', jsonEncode(behaviour));

  Future<int> mutation({
    List<String> rest = const [],
    bool force = false,
    List<String> only = const [],
    String? report,
    List<List<String>>? candidates,
    Map<String, String>? environment,
    bool ci = false,
    List<String>? flutter,
  }) => runMutation(
    package.dir.path,
    report,
    rest,
    package.io,
    force: force,
    only: only,
    // With an environment the tool is looked for as the command line does
    // it, with a stand-in for the command that fetches it.
    candidates: environment == null ? candidates ?? [fake] : null,
    fetch: [Platform.resolvedExecutable, 'fake_fetch.dart'],
    environment: environment,
    ci: ci,
    flutter: flutter,
  );

  /// What was printed, without the lines that say which results of the last
  /// run are reused (see the group "results of the last run").
  List<String> shown() => [
    for (final line in package.out)
      if (!line.startsWith('test_gates mutation: running every mutant') &&
          !line.startsWith('test_gates mutation: nothing that the'))
        line,
  ];

  /// The command lines the tool was started with (without `--version`).
  List<String> runs() => package.file('runs.log').existsSync()
      ? package.file('runs.log').readAsLinesSync()
      : [];

  // The package as the tool is told about it: with symbolic links as the
  // operating system resolves the temporary directory.
  String root() => Directory(package.dir.path).absolute.path;

  String standard({String more = ''}) =>
      'run --dir ${root()} '
      '--plan ${root()}/.dart_tool/test_gates/mutation-plan.json '
      '--report ${root()}/$reportFile$more';

  group('what the tool is started with', () {
    test('the gates and their tests as a plan, the package and the report as '
        'absolute paths', () async {
      tool({'report': everythingKilled});
      expect(await mutation(), 0);
      // With no record of a run, every mutant is run.
      expect(runs(), [standard(more: ' --force')]);
      expect(jsonDecode(package.read('plan.seen.json')), {
        'version': 1,
        'targets': [
          {
            'file': 'lib/a.dart',
            'tests': ['lib/a_test.dart'],
          },
          {
            'file': 'lib/b.dart',
            'tests': ['test/b_test.dart'],
          },
        ],
      });
      expect(shown(), [ok3]);
      expect(package.err, isEmpty);
    });

    test('--force, --report and what follows "--" are handed on', () async {
      tool({'report': everythingKilled});
      expect(
        await mutation(
          force: true,
          report: 'out/m.json',
          rest: ['--jobs', '3', '--', 'fvm', 'flutter', 'test'],
        ),
        0,
      );
      expect(runs(), [
        'run --dir ${root()} '
            '--plan ${root()}/.dart_tool/test_gates/mutation-plan.json '
            '--report ${root()}/out/m.json --force '
            '--jobs 3 -- fvm flutter test',
      ]);
      expect(package.file(reportFile).existsSync(), isFalse);
    });

    test('settings.stryker.reportFile names the report', () async {
      package.manifest(
        ['lib/a.dart', 'lib/b.dart'],
        settings: {
          'stryker': {'reportFile': 'build/m.json'},
        },
      );
      tool({'report': everythingKilled});
      expect(await mutation(), 0);
      expect(runs().single, contains('--report ${root()}/build/m.json'));
    });

    test('every test of a gate that exists is in the plan', () async {
      package.write('test/a_test.dart', '');
      tool({'report': everythingKilled});
      expect(await mutation(), 0);
      final plan = jsonDecode(package.read('plan.seen.json')) as Map;
      expect(((plan['targets'] as List).first as Map)['tests'], [
        'lib/a_test.dart',
        'test/a_test.dart',
      ]);
    });
  });

  group('the verdict is that of the report, not of the exit code', () {
    test('exit code 1 with a survivor that the gate does not allow', () async {
      tool({
        'exit': 1,
        'report': reportOf({
          'lib/a.dart': [plus('Survived')],
          'lib/b.dart': [times('Killed'), minus('CompileError')],
        }),
      });
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: 1 surviving mutant(s) not in the allow list',
        '  - lib/a.dart:1:19 / ArithmeticOperator / + → - (Survived)',
        '',
        'Fix the test so that it detects the mutant. Only when the mutant '
            'cannot be observed from',
        'outside (same return value, exception and side effects for every '
            'input), add it to',
        '"equivalentMutants" of the gate in test-gates.json and fill in '
            '"reason":',
        '',
        '  lib/a.dart',
        '    {"mutator":"ArithmeticOperator","original":"+",'
            '"replacement":"-","reason":""}',
        '',
        'test_gates mutation: FAILED (mutants 3 / detected 1 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 1 / unallowed survivors 1)',
      ]);
    });

    test('exit code 1 with a survivor that the gate allows: passes', () async {
      package.write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            {
              'path': 'lib/a.dart',
              'decides': 'd',
              'impact': 'i',
              'equivalentMutants': [
                {
                  'mutator': 'ArithmeticOperator',
                  'original': '+',
                  'replacement': '-',
                  'reason': 'for the test',
                },
              ],
            },
          ],
        }),
      );
      tool({
        'exit': 1,
        'report': reportOf({
          'lib/a.dart': [plus('Survived')],
        }),
      });
      expect(await mutation(), 0);
      expect(shown(), [
        'test_gates mutation: OK (mutants 1 / detected 0 (timeout 0) / '
            'allowed equivalent 1 / not evaluable 0 / unallowed survivors 0)',
      ]);
    });

    test('exit code 0 with a survivor in the report still fails', () async {
      tool({
        'report': reportOf({
          'lib/a.dart': [plus('Survived')],
          'lib/b.dart': [times('Killed'), minus('Killed')],
        }),
      });
      expect(await mutation(), 1);
      expect(package.err.last, startsWith('test_gates mutation: FAILED ('));
    });

    test('exit code 1 and a gate that the tool left out of the report: the '
        'gate fails', () async {
      tool({
        'exit': 1,
        'report': reportOf({
          'lib/a.dart': [plus('Killed')],
        }),
      });
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: 1 violation(s)',
        '  - lib/b.dart: dart_mutant wrote no result for this gate (exit '
            'code 1). What it printed says why',
        'test_gates mutation: FAILED (mutants 1 / detected 1 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
    });

    test('exit code 0 and a gate that is not in the report fails as '
        'well', () async {
      tool({
        'report': reportOf({
          'lib/a.dart': [plus('Killed')],
        }),
      });
      expect(await mutation(), 1);
      expect(
        package.err[1],
        '  - lib/b.dart: dart_mutant wrote no result for this gate (exit '
        'code 0). What it printed says why',
      );
    });

    test('exit code 1 without a report: nothing was mutation tested', () async {
      tool({'exit': 1});
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: 2 violation(s)',
        '  - lib/a.dart: dart_mutant wrote no result for this gate (exit '
            'code 1). What it printed says why',
        '  - lib/b.dart: dart_mutant wrote no result for this gate (exit '
            'code 1). What it printed says why',
        'test_gates mutation: FAILED (nothing was mutation tested)',
      ]);
    });

    test('exit code 1 and a report in which nothing survived and nothing is '
        'missing: the failure is not passed over', () async {
      tool({'exit': 1, 'report': everythingKilled});
      expect(await mutation(), 1);
      expect(shown(), isEmpty);
      expect(package.err, [
        'test_gates mutation: dart_mutant failed (exit code 1), and its '
            'report does not show why: no mutant of these gates survived and '
            'none is missing. What it printed says what went wrong',
        'test_gates mutation: FAILED (the run did not end as it should)',
      ]);
    });

    test('a mutant that was not evaluated (Pending) fails', () async {
      tool({
        'report': reportOf({
          'lib/a.dart': [plus('Pending')],
          'lib/b.dart': [times('Killed'), minus('Killed')],
        }),
      });
      expect(await mutation(), 1);
      expect(
        package.err[1],
        '  - lib/a.dart:1: a ArithmeticOperator mutant was not evaluated '
        '(status: Pending)',
      );
    });
  });

  group('any other exit code of the tool is passed on, and nothing is '
      'judged', () {
    for (final code in [2, 130, 143, 129, 70]) {
      test('exit code $code', () async {
        // A report that would pass.
        tool({'exit': code, 'report': everythingKilled});
        expect(await mutation(), code);
        expect(shown(), isEmpty);
        expect(package.err, [
          'test_gates mutation: dart_mutant ended with exit code $code. '
              'Nothing was judged',
        ]);
      });
    }

    test('ended by SIGKILL: 137', () async {
      tool({'killed': true, 'report': everythingKilled});
      expect(await mutation(), 137);
      expect(package.err, [
        'test_gates mutation: dart_mutant ended with exit code 137. '
            'Nothing was judged',
      ]);
    }, testOn: '!windows');
  });

  group('finding the tool', () {
    test('the first command that answers --version is used', () async {
      tool({'report': everythingKilled});
      expect(
        await mutation(
          candidates: [
            ['test_gates_no_such_program'],
            // Starts, and fails.
            [Platform.resolvedExecutable, 'no_such_script.dart'],
            fake,
            ['test_gates_never_tried'],
          ],
        ),
        0,
      );
      expect(runs(), hasLength(1));
    });

    test('not found: exit code 2, with the command that installs it', () async {
      expect(
        await mutation(
          candidates: [
            ['test_gates_no_such_program'],
            [Platform.resolvedExecutable, 'no_such_script.dart'],
          ],
        ),
        2,
      );
      expect(package.err.take(4), [
        'test_gates mutation: dart_mutant was not found. It is the tool '
            'that makes the mutants and runs the tests on them. Install it '
            'with:',
        "  dart pub global activate dart_mutant '^0.2.1'",
        'What was tried:',
        startsWith(
          '  - "test_gates_no_such_program --version" could not be started (',
        ),
      ]);
      // The dart that is there, and what it said about the missing script.
      expect(package.err, hasLength(5));
      expect(
        package.err.last,
        allOf(
          startsWith(
            '  - "${Platform.resolvedExecutable} no_such_script.dart '
            '--version" ended with exit code ',
          ),
          contains(' and printed "'),
        ),
      );
      expect(runs(), isEmpty);
    });

    test('a command that answers --version with something else is not the '
        'tool', () async {
      tool({'version': 'Dart SDK version: 3.9.0'});
      expect(await mutation(), 2);
      expect(package.err.first, contains('dart_mutant was not found'));
      expect(
        package.err.last,
        '  - "${fake.join(' ')} --version" ended with exit code 0 and '
        'printed "Dart SDK version: 3.9.0"',
      );
      package.err.clear();
      tool({'version': '0.1.0', 'versionExit': 1});
      expect(await mutation(), 2);
      expect(package.err.first, contains('dart_mutant was not found'));
      expect(
        package.err.last,
        '  - "${fake.join(' ')} --version" ended with exit code 1 and '
        'printed "0.1.0"',
      );
      expect(runs(), isEmpty);
    });

    for (final version in ['0.3.0', '1.2.0', '0.0.9', '0.1.1']) {
      test('version $version is not supported: exit code 2, nothing is '
          'run', () async {
        tool({'version': version, 'report': everythingKilled});
        package.write(reportFile, jsonEncode(everythingKilled));
        expect(await mutation(), 2);
        expect(package.err, [
          'test_gates mutation: dart_mutant $version '
              '("${fake.join(' ')}") is not a version this test_gates works '
              'with (0.2.1 or later, below 0.3.0). Install one that is:',
          "  dart pub global activate dart_mutant '^0.2.1'",
        ]);
        expect(runs(), isEmpty);
        // Nothing was changed.
        expect(package.file(reportFile).existsSync(), isTrue);
      });
    }

    test('0.2.7 is supported', () async {
      tool({'version': '0.2.7', 'report': everythingKilled});
      expect(await mutation(), 0);
    });
  });

  group('the tool is fetched', () {
    const place = '.dart_tool/test_gates/dart_mutant/0.2';
    const kept = '$place/dart_mutant.snapshot';
    const fetching =
        'test_gates mutation: fetching dart_mutant ^0.2.1 from pub.dev into '
        '$kept (once per package)';
    const byHand = [
      'test_gates mutation: to use one you installed yourself, install it '
          'and set TEST_GATES_DART_MUTANT to the path of its executable '
          '(~/.pub-cache/bin/dart_mutant):',
      "  dart pub global activate dart_mutant '^0.2.1'",
    ];

    /// The directories the stand-in was told to fetch into.
    List<String> fetches() => package.file('fetch.log').existsSync()
        ? package.file('fetch.log').readAsLinesSync()
        : [];

    test('not there yet: it is fetched into a cache of its own, only the '
        'compiled program is kept, and it is started with the dart that '
        'runs this program', () async {
      tool({'report': everythingKilled});
      expect(await mutation(environment: {}), 0);
      expect(shown(), [fetching, ok3]);
      expect(package.err, isEmpty);
      // A temporary directory, which is gone, and not the cache of the user.
      expect(fetches(), hasLength(1));
      expect(fetches().single, isNot(Platform.environment['PUB_CACHE']));
      expect(Directory(fetches().single).existsSync(), isFalse);
      expect(
        package.read(kept),
        File(
          'test/fixtures/mutation/fake_dart_mutant.dart.txt',
        ).readAsStringSync(),
      );
      expect(
        [for (final entry in package.file(kept).parent.listSync()) entry.path],
        [package.file(kept).path],
      );
      expect(runs(), hasLength(1));
    });

    test('there already: nothing is fetched', () async {
      tool({'report': everythingKilled});
      expect(await mutation(environment: {}), 0);
      package.out.clear();
      expect(await mutation(environment: {}), 0);
      expect(shown(), [ok3]);
      expect(fetches(), hasLength(1));
      expect(runs(), hasLength(2));
    });

    test('what is there is another version: it is fetched again', () async {
      package.write(kept, package.read('fake_dart_mutant.dart'));
      tool({
        'version': '0.1.1',
        'fetched': {'version': '0.2.3', 'report': everythingKilled},
      });
      expect(await mutation(environment: {}), 0);
      expect(shown(), [fetching, ok3]);
      expect(fetches(), hasLength(1));
    });

    test('what is there is an older 0.2.x (0.2.0): it is fetched again, not '
        'an error', () async {
      package.write(kept, package.read('fake_dart_mutant.dart'));
      tool({
        'version': '0.2.0',
        'fetched': {'version': '0.2.1', 'report': everythingKilled},
      });
      expect(await mutation(environment: {}), 0);
      expect(shown(), [fetching, ok3]);
      expect(package.err, isEmpty);
      expect(fetches(), hasLength(1));
    });

    test('what is there does not answer: it is fetched again', () async {
      package.write(kept, 'not a program');
      tool({'report': everythingKilled});
      expect(await mutation(environment: {}), 0);
      expect(shown(), [fetching, ok3]);
      expect(package.read(kept), package.read('fake_dart_mutant.dart'));
    });

    test('it cannot be fetched: exit code 2, with what the command printed '
        'and how the tool is installed by hand', () async {
      tool({
        'fetchExit': 69,
        'fetchOutput': 'Got socket error trying to find package dart_mutant\n',
        'report': everythingKilled,
      });
      package.write(reportFile, jsonEncode(everythingKilled));
      expect(await mutation(environment: {}), 2);
      expect(shown(), [fetching]);
      expect(package.err, [
        'test_gates mutation: dart_mutant ^0.2.1 could not be fetched from '
            'pub.dev: "${Platform.resolvedExecutable} fake_fetch.dart" '
            'ended with exit code 69',
        '    Got socket error trying to find package dart_mutant',
        ...byHand,
      ]);
      expect(package.file(place).existsSync(), isFalse);
      expect(Directory(fetches().single).existsSync(), isFalse);
      expect(runs(), isEmpty);
      // Nothing was changed.
      expect(package.file(reportFile).existsSync(), isTrue);
    });

    test(
      'the command that fetches it leaves no program: exit code 2',
      () async {
        tool({'fetchNothing': true});
        expect(await mutation(environment: {}), 2);
        expect(package.err, [
          'test_gates mutation: dart_mutant ^0.2.1 could not be fetched from '
              'pub.dev: "${Platform.resolvedExecutable} fake_fetch.dart" did '
              'not compile it',
          ...byHand,
        ]);
        expect(runs(), isEmpty);
      },
    );

    test('what was fetched does not answer as the tool: exit code 2', () async {
      tool({
        'fetched': {'version': 'something else'},
      });
      expect(await mutation(environment: {}), 2);
      expect(package.err, [
        'test_gates mutation: dart_mutant was fetched into $kept, and does '
            'not answer as the tool does: '
            '"${Platform.resolvedExecutable} $kept --version" ended with '
            'exit code 0 and printed "something else"',
        ...byHand,
      ]);
      expect(runs(), isEmpty);
    });

    test('what was fetched is another version: exit code 2', () async {
      tool({
        'fetched': {'version': '0.3.0'},
      });
      expect(await mutation(environment: {}), 2);
      expect(package.err, [
        'test_gates mutation: dart_mutant 0.3.0 '
            '("${Platform.resolvedExecutable} $kept") is not a version this '
            'test_gates works with (0.2.1 or later, below 0.3.0). Install '
            'one that is:',
        "  dart pub global activate dart_mutant '^0.2.1'",
      ]);
      expect(runs(), isEmpty);
    });

    group('TEST_GATES_DART_MUTANT names another one', () {
      late String named;

      setUp(() {
        named = '${package.dir.path}/my_dart_mutant';
        package.write(
          'my_dart_mutant',
          '#!/bin/sh\n'
              'exec "${Platform.resolvedExecutable}" fake_dart_mutant.dart '
              '"\$@"\n',
        );
        Process.runSync('chmod', ['+x', named]);
      });

      test('it is started, and nothing is fetched', () async {
        tool({'report': everythingKilled});
        expect(
          await mutation(environment: {'TEST_GATES_DART_MUTANT': named}),
          0,
        );
        expect(shown(), [ok3]);
        expect(fetches(), isEmpty);
        expect(package.file(place).existsSync(), isFalse);
        expect(runs(), hasLength(1));
      });

      test('its version is checked like that of the fetched one', () async {
        tool({'version': '0.1.1'});
        expect(
          await mutation(environment: {'TEST_GATES_DART_MUTANT': named}),
          2,
        );
        expect(package.err.first, contains('dart_mutant 0.1.1 ("$named")'));
        expect(fetches(), isEmpty);
      });

      test('it is not the tool: exit code 2, and nothing is fetched '
          'instead', () async {
        expect(
          await mutation(
            environment: {'TEST_GATES_DART_MUTANT': 'test_gates_no_such'},
          ),
          2,
        );
        expect(package.err.take(3), [
          'test_gates mutation: TEST_GATES_DART_MUTANT names '
              '"test_gates_no_such", and that is not dart_mutant, the tool '
              'that makes the mutants and runs the tests on them. Without '
              'the variable the tool is fetched from pub.dev. To install it '
              'yourself:',
          "  dart pub global activate dart_mutant '^0.2.1'",
          'What was tried:',
        ]);
        expect(package.err, hasLength(4));
        expect(fetches(), isEmpty);
        expect(runs(), isEmpty);
      });
    }, testOn: '!windows');
  });

  group('wrong usage (exit code 2), before anything is started', () {
    Future<int> cli(List<String> arguments) => runAsync([
      'mutation',
      '--dir',
      package.dir.path,
      ...arguments,
    ], package.io);

    test('an option that mutation sets by itself', () async {
      for (final (option, hint) in [
        ('--report', '. Give --report in front of "--"'),
        ('--dir=x', '. Give --dir in front of "--"'),
        ('--only', '. Give --gate in front of "--"'),
        ('--plan', ''),
      ]) {
        package.err.clear();
        expect(await cli(['--', '--force', option, 'x']), 2);
        expect(
          package.err.first,
          'test_gates: ${option.split('=').first} cannot be handed to '
          'dart_mutant run: mutation sets it from test-gates.json$hint\n',
        );
      }
    });

    test('a test command directly behind "--", as 0.1 took it', () async {
      expect(await cli(['--', 'flutter', 'test', '--no-pub']), 2);
      expect(
        package.err.first,
        'test_gates: what follows "--" is handed to dart_mutant run, and '
        '"flutter" is not one of its options. The command that runs test '
        'files goes behind a second "--": '
        'mutation -- -- flutter test --no-pub\n',
      );
    });

    test('nothing behind "--"', () async {
      expect(await cli(['--']), 2);
      expect(
        package.err.first,
        'test_gates: "--" must be followed by the options for dart_mutant '
        'run\n',
      );
    });

    test('--gate with a path that is not a gate: nothing is changed', () async {
      package.write(reportFile, 'kept');
      expect(await cli(['--gate', 'lib/c.dart']), 2);
      expect(
        package.err.first,
        'test_gates: --gate: not a gate of test-gates.json: lib/c.dart\n',
      );
      expect(package.read(reportFile), 'kept');
    });
  });

  group('a gate that cannot be given to the tool', () {
    test('a gate without a test and a gate that is gone are not in the '
        'plan, and fail', () async {
      package.write('lib/c.dart', 'int c() => 1;\n');
      package.manifest(['lib/a.dart', 'lib/c.dart', 'lib/gone.dart']);
      tool({
        'report': reportOf({
          'lib/a.dart': [plus('Killed')],
        }),
      });
      expect(await mutation(), 1);
      final plan = jsonDecode(package.read('plan.seen.json')) as Map;
      expect(
        [for (final target in plan['targets'] as List) (target as Map)['file']],
        ['lib/a.dart'],
      );
      expect(package.err, [
        'test_gates mutation: 2 violation(s)',
        '  - lib/c.dart: no test found (looked for lib/c_test.dart, '
            'test/c_test.dart). The mutation test runs the test of each '
            'gate; see settings.spec',
        '  - lib/gone.dart: file not found (the check is case-sensitive). '
            'Update test-gates.json if it moved',
        'test_gates mutation: FAILED (mutants 1 / detected 1 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
    });

    test('settings.spec.suffixes: [] leaves no test to run, and the tool is '
        'not started', () async {
      package.manifest(
        ['lib/a.dart'],
        settings: {
          'spec': {'suffixes': <String>[]},
        },
      );
      tool({'report': everythingKilled});
      expect(await mutation(), 1);
      expect(runs(), isEmpty);
      expect(package.err, [
        'test_gates mutation: 1 violation(s)',
        '  - lib/a.dart: no test is known for this gate: '
            'settings.spec.suffixes is empty. The mutation test runs the '
            'test of each gate',
        'test_gates mutation: FAILED (nothing was mutation tested)',
      ]);
    });

    test('a wrong entry of test-gates.json: nothing is run', () async {
      package.write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            {'path': 'lib/a.dart', 'decides': 'd'},
          ],
        }),
      );
      tool({'report': everythingKilled});
      expect(await mutation(), 1);
      expect(
        package.err.first,
        'test_gates mutation: test-gates.json has problems',
      );
      expect(runs(), isEmpty);
    });
  });

  group('the report of an earlier run', () {
    test('is deleted before the tool is started, so that a run that writes '
        'none is not judged on it', () async {
      package.write(reportFile, jsonEncode(everythingKilled));
      tool({'exit': 1});
      expect(await mutation(), 1);
      expect(package.file('report.before.json').existsSync(), isFalse);
      expect(package.file(reportFile).existsSync(), isFalse);
      expect(
        package.err.last,
        'test_gates mutation: FAILED (nothing was mutation tested)',
      );
    });

    test('a file that is no report is not deleted or written: the tool '
        'refuses to replace it', () async {
      for (final only in [
        <String>[],
        ['lib/a.dart'],
      ]) {
        package.write(reportFile, 'notes, not a report');
        // As the tool answers a file of another kind.
        tool({'exit': 2});
        expect(await mutation(only: only), 2);
        expect(package.read('report.before.json'), 'notes, not a report');
        expect(package.read(reportFile), 'notes, not a report');
      }
    });
  });

  group('results of the last run', () {
    const record = '.dart_tool/test_gates/mutation-record.json';
    const reused =
        'test_gates mutation: nothing that the 2 gate(s) depend on changed '
        'since the last run: their results are reused, and a Timeout is '
        'measured again';

    // lib/a.dart imports lib/c.dart, on its last line so that the mutants
    // keep their places; nothing imports lib/d.dart.
    const importing = "${sourceA}import 'c.dart';\n";
    Map<String, Object?> killed() {
      final report =
          jsonDecode(jsonEncode(everythingKilled)) as Map<String, Object?>;
      ((report['files'] as Map)['lib/a.dart'] as Map)['source'] = importing;
      return report;
    }

    setUp(() {
      package.write('lib/a.dart', importing);
      package.write('lib/c.dart', 'int c() => 1;\n');
      package.write('lib/d.dart', 'int d() => 1;\n');
      package.write('pubspec.lock', 'packages: {}\n');
      tool({'report': killed()});
    });

    test('no record: every mutant, and the run leaves one', () async {
      expect(await mutation(), 0);
      expect(
        package.out.first,
        'test_gates mutation: running every mutant of the gates (--force): '
        'there is no record of a run to reuse',
      );
      expect(runs(), [standard(more: ' --force')]);
      expect(package.file(record).existsSync(), isTrue);
    });

    test('nothing changed: the tool reuses its results, and is told nothing '
        'more', () async {
      expect(await mutation(), 0);
      package.out.clear();
      expect(await mutation(), 0);
      expect(package.out, [reused, ok3]);
      expect(runs().last, standard());
    });

    test('(a) a file the gate imports changed: every mutant of that gate, and '
        'the report keeps the other one', () async {
      expect(await mutation(), 0);
      package.write('lib/c.dart', 'int c() => 2;\n');
      package.out.clear();
      expect(await mutation(), 0);
      expect(package.out, [
        'test_gates mutation: 1 of 2 gate(s) reused, 1 run again with every '
            'mutant',
        '  lib/a.dart: changed lib/c.dart',
        ok3,
      ]);
      expect(runs().last, standard(more: ' --force --only lib/a.dart'));
      expect(
        (jsonDecode(package.read('report.before.json'))
            as Map<String, Object?>)['files'],
        {'lib/b.dart': isNotNull},
      );
    });

    test('(c) a file no gate reaches changed: nothing runs again', () async {
      expect(await mutation(), 0);
      package.write('lib/d.dart', 'int d() => 2;\n');
      package.out.clear();
      expect(await mutation(), 0);
      expect(package.out.first, reused);
      expect(runs().last, standard());
    });

    test('(d) pubspec.lock changed: every mutant', () async {
      expect(await mutation(), 0);
      package.write('pubspec.lock', 'packages: {a: {}}\n');
      package.out.clear();
      expect(await mutation(), 0);
      expect(
        package.out.first,
        'test_gates mutation: running every mutant of the gates (--force): '
        'changed since the last run: pubspec.lock',
      );
      expect(runs().last, standard(more: ' --force'));
    });

    test('CI is set: every mutant', () async {
      expect(await mutation(), 0);
      package.out.clear();
      expect(await mutation(ci: true), 0);
      expect(package.out.first, endsWith('(--force): CI is set'));
      expect(runs().last, standard(more: ' --force'));
    });

    test('a gate the tool wrote no result of runs again', () async {
      tool({
        'report': reportOf({
          'lib/b.dart': [times('Killed'), minus('Killed')],
        }),
        'exit': 1,
      });
      expect(await mutation(), 1);
      tool({'report': killed()});
      package.out.clear();
      expect(await mutation(), 0);
      expect(package.out.take(2), [
        'test_gates mutation: 1 of 2 gate(s) reused, 1 run again with every '
            'mutant',
        '  lib/a.dart: the last run left no result of it',
      ]);
    });

    test('--force --gate after a report that is not the recorded one keeps no '
        'result of the other gates for the next run', () async {
      expect(await mutation(), 0);
      // The report changes behind the record (another run, a hand edit):
      // what it says about lib/b.dart is no longer what was measured.
      final changed = jsonDecode(jsonEncode(killed())) as Map<String, Object?>;
      ((changed['files'] as Map)['lib/b.dart'] as Map)['mutants'] = [
        times('Killed'),
      ];
      package.write(reportFile, jsonEncode(changed));
      tool({'report': changed});
      expect(await mutation(force: true, only: ['lib/a.dart']), 0);
      tool({'report': killed()});
      package.out.clear();
      expect(await mutation(), 0);
      expect(package.out.take(3), [
        'test_gates mutation: 1 of 2 gate(s) reused, 1 run again with every '
            'mutant',
        '  lib/b.dart: the last run left no result of it',
        isNot(startsWith('  ')),
      ]);
    });

    test('a Flutter package: the version of Flutter is part of what every '
        'gate depends on', () async {
      package.write(
        'pubspec.yaml',
        'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n',
      );
      package.write('fake_flutter.dart', '''
import 'dart:io';
void main(List<String> arguments) {
  if (arguments.contains('--machine')) {
    stdout.write(File('flutter-version.json').readAsStringSync());
  }
}
''');
      final flutter = [Platform.resolvedExecutable, 'fake_flutter.dart'];
      String version(String revision) =>
          '{"frameworkVersion": "3.47.2", "frameworkRevision": "$revision", '
          '"engineRevision": "e", "dartSdkVersion": "3.13.2"}';
      package.write('flutter-version.json', version('a'));
      expect(await mutation(flutter: flutter), 0);
      package.out.clear();
      expect(await mutation(flutter: flutter), 0);
      expect(package.out.first, reused);
      package.write('flutter-version.json', version('b'));
      package.out.clear();
      expect(await mutation(flutter: flutter), 0);
      expect(
        package.out.first,
        'test_gates mutation: running every mutant of the gates (--force): '
        'changed since the last run: Flutter',
      );
    });

    test('a run that ends without a verdict leaves no record', () async {
      expect(await mutation(), 0);
      tool({'exit': 2});
      expect(await mutation(), 2);
      expect(package.file(record).existsSync(), isFalse);
    });
  });

  // Also for the default of --dir, `.`, run in the package itself.
  for (final here in [false, true]) {
    test(
      'a member of a pub workspace: the pubspec and the lock file of the '
      'root are part of what every gate depends on (${here ? '--dir .' : 'a path'})',
      () async {
        // The root of the workspace, with the package below it.
        package.write(
          'pubspec.yaml',
          'name: root\nworkspace:\n  - packages/app\n',
        );
        package.write('pubspec.lock', 'packages: {}\n');
        const member = 'packages/app';
        final dir = '${package.dir.path}/$member';
        package.write(
          '$member/pubspec.yaml',
          'name: app\nresolution: workspace\n',
        );
        package.write('$member/lib/a.dart', sourceA);
        package.write('$member/lib/b.dart', sourceB);
        package.write('$member/lib/a_test.dart', '');
        package.write('$member/test/b_test.dart', '');
        package.write(
          '$member/test-gates.json',
          package.read('test-gates.json'),
        );
        package.write(
          '$member/fake.json',
          jsonEncode({'report': everythingKilled}),
        );
        for (final name in ['fake_dart_mutant.dart', 'fake_fetch.dart']) {
          package.file(name).copySync('$dir/$name');
        }
        final before = Directory.current;
        if (here) {
          Directory.current = dir;
          addTearDown(() => Directory.current = before);
        }
        Future<int> run() => runMutation(
          here ? '.' : dir,
          null,
          const [],
          package.io,
          candidates: [fake],
          ci: false,
        );
        expect(await run(), 0, reason: package.err.join('\n'));
        package.out.clear();
        expect(await run(), 0);
        expect(
          package.out.first,
          startsWith('test_gates mutation: nothing that'),
        );
        package.write('pubspec.lock', 'packages: {a: {}}\n');
        package.out.clear();
        expect(await run(), 0);
        expect(
          package.out.first,
          'test_gates mutation: running every mutant of the gates (--force): '
          'changed since the last run: ../../pubspec.lock',
        );
        package.write(
          'pubspec.yaml',
          'name: root\nworkspace:\n  - packages/app\n'
              'dependency_overrides:\n  a: 1.0.0\n',
        );
        package.out.clear();
        expect(await run(), 0);
        expect(
          package.out.first,
          endsWith('changed since the last run: ../../pubspec.yaml'),
        );
      },
    );
  }

  group('--gate', () {
    test('the gate is named with --only, the plan has only that gate, and '
        'only that gate is judged', () async {
      tool({
        'report': reportOf({
          'lib/b.dart': [times('Killed'), minus('Killed')],
        }),
      });
      expect(await mutation(only: ['lib/b.dart'], force: true), 0);
      expect(runs(), [standard(more: ' --force --only lib/b.dart')]);
      final plan = jsonDecode(package.read('plan.seen.json')) as Map;
      expect(plan['targets'], [
        {
          'file': 'lib/b.dart',
          'tests': ['test/b_test.dart'],
        },
      ]);
      expect(shown(), [
        'test_gates mutation: OK for 1 of 2 gate(s) (--gate) (mutants 2 / '
            'detected 2 (timeout 0) / allowed equivalent 0 / not evaluable 0 '
            '/ unallowed survivors 0)',
      ]);
    });

    test('the report of an earlier run loses what it says about that gate '
        'before the tool is started, and keeps the rest', () async {
      package.write(
        reportFile,
        jsonEncode({...everythingKilled, 'framework': 'kept'}),
      );
      // A run that writes nothing.
      tool({'exit': 1});
      expect(await mutation(only: ['lib/b.dart']), 1);
      final before = jsonDecode(package.read('report.before.json')) as Map;
      expect((before['files'] as Map).keys, ['lib/a.dart']);
      expect(before['framework'], 'kept');
      expect(package.err, [
        'test_gates mutation: 2 violation(s)',
        '  - lib/b.dart: dart_mutant wrote no result for this gate (exit '
            'code 1). What it printed says why',
        '  - test-gates.json: no mutants were evaluated (the mutation test '
            'ran on nothing)',
        'test_gates mutation: FAILED for 1 of 2 gate(s) (--gate) (mutants 0 '
            '/ detected 0 (timeout 0) / allowed equivalent 0 / not evaluable '
            '0 / unallowed survivors 0)',
      ]);
    });

    test('a survivor of another gate in the report does not explain a '
        'failure of the tool on this one', () async {
      tool({
        'exit': 1,
        'report': reportOf({
          'lib/a.dart': [plus('Survived')],
          'lib/b.dart': [times('Killed'), minus('Killed')],
        }),
      });
      expect(await mutation(only: ['lib/b.dart']), 1);
      expect(
        package.err.last,
        'test_gates mutation: FAILED (the run did not end as it should)',
      );
    });

    test('a gate without a test: the tool is not started for it', () async {
      package.write('lib/c.dart', 'int c() => 1;\n');
      package.manifest(['lib/a.dart', 'lib/c.dart']);
      expect(await mutation(only: ['lib/c.dart']), 1);
      expect(runs(), isEmpty);
      expect(
        package.err.last,
        'test_gates mutation: FAILED (nothing was mutation tested)',
      );
    });
  });

  group('a part of a run (--shard)', () {
    final partOf2 = reportOf(
      {
        'lib/a.dart': [plus('Survived')],
        'lib/b.dart': [times('Pending'), minus('Killed')],
      },
      config: {
        'shard': {'index': 1, 'count': 2, 'notTested': <String>[]},
      },
    );

    test('is run and written, and not judged: exit code 0 also with a '
        'survivor in it', () async {
      tool({'exit': 1, 'report': partOf2});
      expect(await mutation(rest: ['--shard', '1/2'], report: 'part.json'), 0);
      expect(
        runs().single,
        endsWith('--report ${root()}/part.json --force --shard 1/2'),
      );
      expect(shown(), [
        'test_gates mutation: a part of a run (--shard) was written to '
            'part.json. It is not judged: put the parts together with '
            '"dart_mutant merge" and judge the result with '
            '"test_gates mutation-result"',
      ]);
      expect(package.err, isEmpty);
    });

    test('--shard=1/2 is a part as well', () async {
      tool({'report': partOf2});
      expect(await mutation(rest: ['--shard=1/2']), 0);
      expect(shown().single, contains('It is not judged'));
    });

    test('a gate that is not in the part fails', () async {
      tool({
        'exit': 1,
        'report': reportOf({
          'lib/a.dart': [plus('Killed')],
        }),
      });
      expect(await mutation(rest: ['--shard', '1/2']), 1);
      expect(package.err, [
        'test_gates mutation: 1 violation(s)',
        '  - lib/b.dart: dart_mutant wrote no result for this gate (exit '
            'code 1). What it printed says why',
        'test_gates mutation: FAILED (a part of a run, not judged)',
      ]);
    });

    test('mutation-result refuses the report of a part', () async {
      package.write(reportFile, jsonEncode(partOf2));
      expect(
        run(['mutation-result', '--dir', package.dir.path], package.io),
        1,
      );
      expect(package.err, [
        'test_gates mutation: 1 violation(s)',
        '  - mutation report: is part 1/2 of a run (--shard), not a result. '
            'Put the parts together with "dart_mutant merge" and judge the '
            'report that writes',
        'test_gates mutation: FAILED (mutants 0 / detected 0 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
    });
  });

  group('--not-evaluable', () {
    final report = reportOf({
      'lib/a.dart': [
        {
          ...plus('CompileError'),
          'statusReason': "The operator '-' isn't defined\n  for the type.",
        },
      ],
      'lib/b.dart': [times('Killed'), minus('RuntimeError')],
    });
    const summary =
        'test_gates mutation: OK (mutants 3 / detected 1 (timeout 0) / '
        'allowed equivalent 0 / not evaluable 2 / unallowed survivors 0)';

    test('without it the mutants that could not be evaluated are '
        'counted', () async {
      tool({'report': report});
      expect(await mutation(), 0);
      expect(shown(), [summary]);
    });

    test('with it they are listed, with what the tool says about them, and '
        'the verdict is the same', () async {
      tool({'report': report});
      expect(
        await runMutation(
          package.dir.path,
          null,
          const [],
          package.io,
          listNotEvaluable: true,
          candidates: [fake],
        ),
        0,
      );
      const listed = [
        'test_gates mutation: 2 mutant(s) could not be evaluated (no test '
            'run says anything about them):',
        '  ~ lib/a.dart:1:19 / ArithmeticOperator / + → - (CompileError)',
        "      The operator '-' isn't defined for the type.",
        '  ~ lib/b.dart:1:23 / ArithmeticOperator / - → + (RuntimeError)',
        summary,
      ];
      expect(shown(), listed);
      expect(package.err, isEmpty);
      package.out.clear();
      expect(
        run([
          'mutation-result',
          '--dir',
          package.dir.path,
          '--not-evaluable',
        ], package.io),
        0,
      );
      expect(shown(), listed);
    });

    test('nothing is said when every mutant was evaluated', () {
      package.write(reportFile, jsonEncode(everythingKilled));
      expect(
        run([
          'mutation-result',
          '--dir',
          package.dir.path,
          '--not-evaluable',
        ], package.io),
        0,
      );
      expect(shown(), [ok3]);
    });
  });

  group('mutation-result', () {
    int result([List<String> arguments = const []]) => run([
      'mutation-result',
      '--dir',
      package.dir.path,
      ...arguments,
    ], package.io);

    test(
      'judges the report of a run again, without running anything',
      () async {
        tool({'report': everythingKilled});
        expect(await mutation(), 0);
        package.out.clear();
        expect(result(), 0);
        expect(shown(), [ok3]);
        expect(runs(), hasLength(1));
      },
    );

    test('--gate judges that gate of a report', () {
      package.write(
        reportFile,
        jsonEncode(
          reportOf({
            'lib/a.dart': [plus('Survived')],
            'lib/b.dart': [times('Killed'), minus('Killed')],
          }),
        ),
      );
      expect(result(['--gate', 'lib/b.dart']), 0);
      expect(
        package.out.single,
        startsWith('test_gates mutation: OK for 1 of 2 gate(s) (--gate) '),
      );
      expect(result(['--gate', 'lib/a.dart']), 1);
      expect(
        package.err.last,
        startsWith('test_gates mutation: FAILED for 1 of 2 gate(s) (--gate) '),
      );
      package.err.clear();
      expect(result(['--gate', 'lib/c.dart']), 2);
      expect(
        package.err.first,
        'test_gates: --gate: not a gate of test-gates.json: lib/c.dart\n',
      );
    });

    test('--gate with a gate that is not in the report fails', () {
      package.write(
        reportFile,
        jsonEncode(
          reportOf({
            'lib/b.dart': [times('Killed'), minus('Killed')],
          }),
        ),
      );
      expect(result(['--gate', 'lib/a.dart']), 1);
      expect(
        package.err,
        contains(
          '  - lib/a.dart: no mutants in the report (the gate was not '
          'mutation tested)',
        ),
      );
    });

    test('a report made from another version of a gate fails', () {
      package.write(reportFile, jsonEncode(everythingKilled));
      package.write('lib/a.dart', 'int a(int x) => x + 2;\n');
      expect(result(), 1);
      expect(
        package.err[1],
        '  - lib/a.dart: the report was made from a different version of '
        'this file. Run the mutation test again',
      );
    });

    test('--report, and a report of another tool in the same schema', () {
      package.manifest(['lib/a.dart']);
      package.write(
        'other.json',
        jsonEncode({
          'schemaVersion': '1.0',
          'files': {
            'lib/a.dart': {
              'language': 'dart',
              'mutants': [
                {
                  ...mutant('-', 'Survived', 19, mutator: 'arithmetic'),
                  'id': '7',
                },
              ],
            },
          },
        }),
      );
      expect(result(['--report', 'other.json']), 1);
      expect(
        package.err[1],
        '  - lib/a.dart:1:19 / arithmetic / + → - (Survived)',
      );
    });

    test('no report, and a file that is not one', () {
      expect(result(), 1);
      expect(
        package.err.single,
        allOf(
          startsWith(
            'test_gates mutation: cannot read the report '
            'reports/mutation/mutation.json (',
          ),
          endsWith('). Run "test_gates mutation" first'),
        ),
      );
      package.err.clear();
      package.write(reportFile, '[]');
      expect(result(), 1);
      expect(
        package.err.single,
        'test_gates mutation: reports/mutation/mutation.json is not a '
        'mutation report (must be a JSON object)',
      );
    });

    test('a wrong entry of test-gates.json fails the judgement', () {
      package.write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            {
              'path': 'lib/a.dart',
              'decides': 'd',
              'impact': 'i',
              'equivalentMutants': [
                {'mutator': 'A', 'original': 'a', 'replacement': 'b'},
              ],
            },
          ],
        }),
      );
      package.write(
        reportFile,
        jsonEncode(
          reportOf({
            'lib/a.dart': [plus('Killed')],
          }),
        ),
      );
      expect(result(), 1);
      expect(package.err, [
        'test_gates mutation: 1 violation(s)',
        '  - test-gates.json: lib/a.dart: equivalentMutants[0]: "reason" is '
            'missing (say why the mutant cannot be observed)',
        'test_gates mutation: FAILED (mutants 1 / detected 1 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
    });
  });
}
