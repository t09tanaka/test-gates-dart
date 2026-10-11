@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/mutation.dart';
import 'package:test_gates/src/mutation_result.dart';

import 'package_fixture.dart';

// One mutant: `+` → `-`.
const sourceA = 'int a(int x) => x + 1;\n';
// Two mutants: `*` → `/`, `-` → `+`.
const sourceB = 'int b(int x) => x * 2 - 1;';

const backup = '.dart_tool/test_gates/mutation/backup';

void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      'test/fixtures/mutation/fake_test.dart.txt',
    ).copySync('${package.dir.path}/fake_test.dart');
    package.write('lib/a.dart', sourceA);
    package.write('lib/b.dart', sourceB);
    package.manifest(['lib/a.dart', 'lib/b.dart']);
  });

  tearDown(() => package.delete());

  final fake = [Platform.resolvedExecutable, 'fake_test.dart'];
  String shown(String spec) =>
      '"${fake.join(' ')} --fail-fast --timeout 10s $spec"';

  /// The tests of a gate, as the fake runner reads them.
  void spec(String gate, List<String> rules, {String? at}) => package.write(
    at ?? gate.replaceFirst('.dart', '_test.dart'),
    ['// gate: $gate', for (final rule in rules) '// $rule', ''].join('\n'),
  );

  Future<int> mutation([List<String> arguments = const []]) => runAsync([
    'mutation',
    '--dir',
    package.dir.path,
    ...arguments,
    '--',
    ...fake,
  ], package.io);

  List<String> runs() => package.file('runs.log').existsSync()
      ? package.file('runs.log').readAsLinesSync()
      : [];

  void expectGatesUntouched() {
    expect(package.read('lib/a.dart'), sourceA);
    expect(package.read('lib/b.dart'), sourceB);
    final backups = Directory('${package.dir.path}/$backup');
    expect(
      backups.existsSync()
          ? backups.listSync(recursive: true).whereType<File>()
          : const <File>[],
      isEmpty,
    );
  }

  MutationReport report([String path = 'reports/mutation/mutation.json']) =>
      parseMutationReport(package.read(path));

  void killEverything() {
    spec('lib/a.dart', ['expect: x + 1']);
    spec('lib/b.dart', ['expect: x * 2 - 1']);
  }

  group('exit code 0', () {
    test('every mutant is killed; the gates are put back and the report is '
        'written', () async {
      killEverything();
      expect(await mutation(), 0);
      expect(package.err, isEmpty);
      expect(package.out, [
        '  lib/a.dart: 1 of 1 mutant(s) with ${shown('lib/a_test.dart')}',
        matches(
          r'^  lib/a\.dart: 1 mutants / killed 1 / survived 0 / timeout 0 '
          r'/ compile error 0 \(\d+\.\ds\)$',
        ),
        '  lib/b.dart: 2 of 2 mutant(s) with ${shown('lib/b_test.dart')}',
        matches(
          r'^  lib/b\.dart: 2 mutants / killed 2 / survived 0 / timeout 0 '
          r'/ compile error 0 \(\d+\.\ds\)$',
        ),
        'test_gates mutation: OK (mutants 3 / detected 3 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
      expectGatesUntouched();
      // One run without a mutant and one per mutant, for each gate.
      expect(runs(), hasLength(5));
      final files = report().files;
      expect(files.keys, ['lib/a.dart', 'lib/b.dart']);
      expect(files['lib/a.dart']!.source, sourceA);
      expect(
        [for (final mutant in files['lib/b.dart']!.mutants) mutant.status],
        ['Killed', 'Killed'],
      );
    });

    test('a survivor that the gate allows as equivalent', () async {
      killEverything();
      spec('lib/a.dart', []);
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
            {'path': 'lib/b.dart', 'decides': 'd', 'impact': 'i'},
          ],
        }),
      );
      expect(await mutation(), 0);
      expect(
        package.out.last,
        'test_gates mutation: OK (mutants 3 / detected 2 (timeout 0) / '
        'allowed equivalent 1 / not evaluable 0 / unallowed survivors 0)',
      );
    });

    test('a mutant that does not compile is counted, and shown in the '
        'summary', () async {
      spec('lib/a.dart', ['expect: x + 1']);
      spec('lib/b.dart', ['compile-error-if: x / 2', 'expect: x * 2 - 1']);
      expect(await mutation(), 0);
      expect(
        package.out[3],
        startsWith(
          '  lib/b.dart: 2 mutants / killed 1 / survived 0 / timeout 0 '
          '/ compile error 1 (',
        ),
      );
      expect(
        package.out.last,
        'test_gates mutation: OK (mutants 3 / detected 2 (timeout 0) / '
        'allowed equivalent 0 / not evaluable 1 / unallowed survivors 0)',
      );
      expect(
        report().files['lib/b.dart']!.mutants.first.status,
        'CompileError',
      );
    });

    test('the test under test/, and --report', () async {
      spec('lib/a.dart', ['expect: x + 1'], at: 'test/a_test.dart');
      package.manifest(['lib/a.dart']);
      expect(await mutation(['--report', 'out/m.json']), 0);
      expect(package.out.first, contains(shown('test/a_test.dart')));
      expect(report('out/m.json').files.keys, ['lib/a.dart']);
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });

    test('settings.stryker.reportFile names the report', () async {
      killEverything();
      package.manifest(
        ['lib/a.dart', 'lib/b.dart'],
        settings: {
          'stryker': {'reportFile': 'build/m.json'},
        },
      );
      expect(await mutation(), 0);
      expect(report('build/m.json').files, hasLength(2));
    });
  });

  group('exit code 1', () {
    test('a survivor is listed with the entry that would allow it', () async {
      spec('lib/a.dart', []);
      spec('lib/b.dart', ['expect: x * 2']);
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: 2 surviving mutant(s) not in the allow list',
        '  - lib/a.dart:1:19 / ArithmeticOperator / + → - (Survived)',
        '  - lib/b.dart:1:23 / ArithmeticOperator / - → + (Survived)',
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
        '  lib/b.dart',
        '    {"mutator":"ArithmeticOperator","original":"-",'
            '"replacement":"+","reason":""}',
        '',
        'test_gates mutation: FAILED (mutants 3 / detected 1 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 2)',
      ]);
      expectGatesUntouched();
    });

    test('the tests fail without a mutant: the gate is not measured, the '
        'others are', () async {
      spec('lib/a.dart', ['fail']);
      spec('lib/b.dart', ['expect: x * 2 - 1']);
      expect(await mutation(), 1);
      expect(package.err, [
        '      00:00 +0 -1: Some tests failed.',
        'test_gates mutation: 1 violation(s)',
        '  - lib/a.dart: the tests fail without a mutant (exit 1; a test '
            'gets 10s). Nothing was measured',
        'test_gates mutation: FAILED (mutants 2 / detected 2 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
      expectGatesUntouched();
    });

    test('a gate without a test, a gate that is gone, a gate that is not '
        'Dart, a gate with nothing to mutate', () async {
      package.write('lib/c.dart', 'int c( => 1;');
      spec('lib/c.dart', []);
      package.write('lib/d.dart', 'const d = 1;\n');
      spec('lib/d.dart', []);
      package.manifest([
        'lib/a.dart',
        'lib/gone.dart',
        'lib/c.dart',
        'lib/d.dart',
      ]);
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: 5 violation(s)',
        '  - lib/a.dart: no test found (looked for lib/a_test.dart, '
            'test/a_test.dart). The mutation test runs the test of each '
            'gate; see settings.spec',
        '  - lib/gone.dart: file not found (the check is case-sensitive). '
            'Update test-gates.json if it moved',
        '  - lib/c.dart: cannot be read as Dart (syntax error)',
        '  - lib/d.dart: nothing in this file can be mutated. A gate holds a '
            'decision',
        '  - test-gates.json: no mutants were evaluated (the mutation test '
            'ran on nothing)',
        'test_gates mutation: FAILED (mutants 0 / detected 0 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
      expect(runs(), isEmpty);
    });

    test('settings.spec.suffixes: [] leaves no test to run', () async {
      killEverything();
      package.manifest(
        ['lib/a.dart'],
        settings: {
          'spec': {'suffixes': <String>[]},
        },
      );
      expect(await mutation(), 1);
      expect(
        package.err[1],
        '  - lib/a.dart: no test is known for this gate: '
        'settings.spec.suffixes is empty. The mutation test runs the test of '
        'each gate',
      );
    });

    test('a wrong entry of test-gates.json: nothing is run', () async {
      killEverything();
      package.write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            {'path': 'lib/a.dart', 'decides': 'd'},
          ],
        }),
      );
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: test-gates.json has problems',
        '  - test-gates.json: lib/a.dart: "impact" is missing in gates',
      ]);
      expect(runs(), isEmpty);
    });

    test('the command cannot be started', () async {
      killEverything();
      expect(
        await runAsync([
          'mutation',
          '--dir',
          package.dir.path,
          '--',
          'no-such-test-runner',
        ], package.io),
        1,
      );
      expect(
        package.err.first,
        startsWith('test_gates mutation: cannot start "no-such-test-runner" ('),
      );
      expect(
        package.err.last,
        'test_gates mutation: FAILED (the run was stopped)',
      );
      expectGatesUntouched();
    });

    test('a report of an earlier run is not left behind', () async {
      killEverything();
      expect(await mutation(), 0);
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isTrue,
      );
      package.out.clear();
      expect(
        await runAsync([
          'mutation',
          '--dir',
          package.dir.path,
          '--force',
          '--',
          'no-such-test-runner',
        ], package.io),
        1,
      );
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });
  });

  group('timeouts', () {
    Future<int> quick() => runMutation(
      package.dir.path,
      null,
      fake,
      package.io,
      limitOf: (_) => const Duration(seconds: 2),
    );

    setUp(() {
      spec('lib/a.dart', ['expect: x + 1']);
      spec('lib/b.dart', ['hang-if: x / 2', 'expect: x * 2 - 1']);
    });

    test('a run that does not end within the limit is ended, with what it '
        'started; the timeout fails the run', () async {
      expect(await quick(), 1);
      expect(
        package.out[3],
        startsWith(
          '  lib/b.dart: 2 mutants / killed 1 / survived 0 / timeout 1 '
          '/ compile error 0 (',
        ),
      );
      expect(package.err, [
        'test_gates mutation: 1 mutant(s) timed out '
            '(settings.mutation.maxTimeouts: 0)',
        '  - lib/b.dart:1:19 / ArithmeticOperator / * → / (Timeout)',
        '',
        'A timeout counts as detected, but on a loaded machine a mutant that '
            'would survive',
        'can time out instead. Run again with less load (a timeout is always '
            'measured again).',
        'Only for a mutant that can never finish (a loop that no longer '
            'ends), add it to',
        '"expectedTimeouts" of the gate in test-gates.json and fill in '
            '"reason"',
        '(settings.mutation.maxTimeouts raises the limit for the whole '
            'project):',
        '    lib/b.dart: {"mutator":"ArithmeticOperator","original":"*",'
            '"replacement":"/","reason":""}',
        '',
        'test_gates mutation: 1 violation(s)',
        '  - test-gates.json: 1 mutant(s) timed out outside '
            'expectedTimeouts; settings.mutation.maxTimeouts allows 0',
        'test_gates mutation: FAILED (mutants 3 / detected 3 (timeout 1) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
      expectGatesUntouched();
      if (!Platform.isWindows) {
        final child = package.read('started');
        expect(
          Process.runSync('kill', ['-0', child]).exitCode,
          isNot(0),
          reason: 'the test run is still there',
        );
      }
    });

    test('expectedTimeouts accepts it; the next run measures only the '
        'timeout again', () async {
      package.write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            {'path': 'lib/a.dart', 'decides': 'd', 'impact': 'i'},
            {
              'path': 'lib/b.dart',
              'decides': 'd',
              'impact': 'i',
              'expectedTimeouts': [
                {
                  'mutator': 'ArithmeticOperator',
                  'original': '*',
                  'replacement': '/',
                  'reason': 'the fake never ends',
                },
              ],
            },
          ],
        }),
      );
      expect(await quick(), 0);
      expect(
        package.out.last,
        'test_gates mutation: OK (mutants 3 / detected 3 (timeout 1) / '
        'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      );
      final before = runs().length;
      package.out.clear();
      expect(await quick(), 0);
      // lib/a.dart is not run at all; lib/b.dart without a mutant and with
      // the one that timed out.
      expect(runs().length - before, 2);
      expect(package.out, [
        matches(
          r'^  lib/a\.dart: 1 mutants .* \(1 from the last run, 0\.0s\)$',
        ),
        '  lib/b.dart: 1 of 2 mutant(s) with ${shown('lib/b_test.dart')}',
        matches(
          r'^  lib/b\.dart: 2 mutants / killed 1 / survived 0 / timeout 1 '
          r'/ compile error 0 \(1 from the last run, \d+\.\ds\)$',
        ),
        startsWith('test_gates mutation: OK ('),
      ]);
    });
  });

  group('results of the last run', () {
    setUp(killEverything);

    test('an unchanged gate is not run again, and is still judged', () async {
      expect(await mutation(), 0);
      final before = runs().length;
      package.out.clear();
      expect(await mutation(), 0);
      expect(runs(), hasLength(before));
      expect(package.out, [
        matches(
          r'^  lib/a\.dart: 1 mutants / killed 1 .* \(1 from the last run, 0\.0s\)$',
        ),
        matches(
          r'^  lib/b\.dart: 2 mutants / killed 2 .* \(2 from the last run, 0\.0s\)$',
        ),
        'test_gates mutation: OK (mutants 3 / detected 3 (timeout 0) / '
            'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
      ]);
      expect(report().files, hasLength(2));
    });

    test('a survivor of the last run still fails', () async {
      spec('lib/a.dart', []);
      expect(await mutation(), 1);
      package.err.clear();
      expect(await mutation(), 1);
      expect(
        package.err[1],
        '  - lib/a.dart:1:19 / ArithmeticOperator / + → - (Survived)',
      );
    });

    test('a changed gate or a changed test is run again, the other gate is '
        'not', () async {
      expect(await mutation(), 0);
      var before = runs().length;
      spec('lib/a.dart', ['expect: x + 1', 'expect: int']);
      expect(await mutation(), 0);
      expect(runs().length - before, 2);

      before = runs().length;
      package.write('lib/b.dart', '$sourceB\n');
      expect(await mutation(), 0);
      expect(runs().length - before, 3);
      expect(runs().last, endsWith('lib/b_test.dart'));
    });

    test('--force runs everything', () async {
      expect(await mutation(), 0);
      final before = runs().length;
      expect(await mutation(['--force']), 0);
      expect(runs().length - before, 5);
    });

    test('a broken file of results is ignored', () async {
      expect(await mutation(), 0);
      package.write('.dart_tool/test_gates/mutation/incremental.json', '{');
      final before = runs().length;
      expect(await mutation(), 0);
      expect(runs().length - before, 5);
    });
  });

  group('what a killed run left behind', () {
    setUp(killEverything);

    test('a mutant in a gate is taken out before anything else', () async {
      package.write('$backup/lib/a.dart', sourceA);
      package.write('lib/a.dart', 'int a(int x) => x - 1;\n');
      package.write('.dart_tool/test_gates/mutation/staging', 'x');
      expect(await mutation(), 0);
      expect(package.err, [
        'test_gates mutation: put back lib/a.dart, which an interrupted run '
            'left with a mutant in it',
      ]);
      expectGatesUntouched();
      expect(
        package.file('.dart_tool/test_gates/mutation/staging').existsSync(),
        isFalse,
      );
    });

    test('a backup of a gate that is as it was is removed silently', () async {
      package.write('$backup/lib/a.dart', sourceA);
      expect(await mutation(), 0);
      expect(package.err, isEmpty);
      expectGatesUntouched();
    });

    test('a gate that was edited since is not overwritten, and nothing is '
        'run', () async {
      const edited = 'int a(int x) => x - 100;\n';
      package.write('$backup/lib/a.dart', sourceA);
      package.write('lib/a.dart', edited);
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: lib/a.dart: an interrupted run left a mutant '
            'in this file, and the file was changed since. It was left as it '
            'is. The content of before that run is in '
            '$backup/lib/a.dart; delete that file when you have compared '
            'the two',
        'test_gates mutation: FAILED (nothing was run)',
      ]);
      expect(package.read('lib/a.dart'), edited);
      expect(package.read('$backup/lib/a.dart'), sourceA);
      expect(runs(), isEmpty);
    });

    test('a backup of a file that is gone', () async {
      package.write('$backup/lib/old.dart', 'int old() => 1;\n');
      expect(await mutation(), 1);
      expect(
        package.err.first,
        startsWith(
          'test_gates mutation: lib/old.dart: an interrupted run left a '
          'backup of this file, and the file is gone.',
        ),
      );
    });
  });

  group('your files during the run', () {
    test('a gate that is saved while its mutant is tested is left as it '
        'is, and the run stops', () async {
      // The fake "test run" edits the gate, as an editor would.
      package.write('fake_test.dart', '''
import 'dart:io';

void main(List<String> arguments) {
  final gate = File('lib/a.dart');
  if (gate.readAsStringSync().contains('x - 1')) {
    gate.writeAsStringSync('// saved by somebody\\n');
  }
}
''');
      spec('lib/a.dart', []);
      package.manifest(['lib/a.dart']);
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: lib/a.dart changed during the run. It was left '
            'as it is, possibly with a mutant in it. The content of before '
            'the run is in $backup/lib/a.dart',
        'test_gates mutation: FAILED (the run was stopped)',
      ]);
      expect(package.read('lib/a.dart'), '// saved by somebody\n');
      expect(package.read('$backup/lib/a.dart'), sourceA);
    });

    test('a gate that is saved while its tests run without a mutant is '
        'not written to', () async {
      package.write('fake_test.dart', '''
import 'dart:io';

void main(List<String> arguments) {
  File('lib/a.dart').writeAsStringSync('// saved by somebody\\n');
}
''');
      spec('lib/a.dart', []);
      package.manifest(['lib/a.dart']);
      expect(await mutation(), 1);
      expect(package.err, [
        'test_gates mutation: lib/a.dart changed while its tests ran. '
            'Nothing was written to it; run again',
        'test_gates mutation: FAILED (the run was stopped)',
      ]);
      expect(package.read('lib/a.dart'), '// saved by somebody\n');
      expect(package.file('$backup/lib/a.dart').existsSync(), isFalse);
    });

    test('the bytes of a gate are put back as they were (CRLF, byte order '
        'mark)', () async {
      const source = '﻿int a(int x) =>\r\n    x + 1;\r\n';
      package.write('lib/a.dart', source);
      spec('lib/a.dart', ['expect: x + 1']);
      package.manifest(['lib/a.dart']);
      expect(await mutation(), 0);
      expect(package.file('lib/a.dart').readAsBytesSync(), utf8.encode(source));
      final mutant = report().files['lib/a.dart']!.mutants.single;
      expect((mutant.start.line, mutant.start.column), (2, 7));
    });

    test('a gate that is not UTF-8 is not touched', () async {
      package.file('lib/a.dart').writeAsBytesSync([0x2f, 0x2f, 0xff, 0x0a]);
      spec('lib/a.dart', []);
      package.manifest(['lib/a.dart']);
      expect(await mutation(), 1);
      expect(
        package.err[1],
        '  - lib/a.dart: is not valid UTF-8, so it cannot be written back',
      );
      expect(package.file('lib/a.dart').readAsBytesSync(), [
        0x2f,
        0x2f,
        0xff,
        0x0a,
      ]);
    });
  });

  group('--gate', () {
    const okFor1 =
        'test_gates mutation: OK for 1 of 2 gate(s) (--gate) '
        '(mutants 2 / detected 2 (timeout 0) / allowed equivalent 0 / '
        'not evaluable 0 / unallowed survivors 0)';

    test(
      'only that gate is run and judged, and the last line says so',
      () async {
        // lib/a.dart has a survivor and would fail a full run.
        spec('lib/a.dart', []);
        spec('lib/b.dart', ['expect: x * 2 - 1']);
        expect(await mutation(['--gate', 'lib/b.dart']), 0);
        expect(package.err, isEmpty);
        expect(package.out, [
          '  lib/b.dart: 2 of 2 mutant(s) with ${shown('lib/b_test.dart')}',
          startsWith('  lib/b.dart: 2 mutants / killed 2 '),
          okFor1,
        ]);
        expect(runs(), hasLength(3));
        expect(runs(), everyElement(endsWith('lib/b_test.dart')));
        expect(report().files.keys, ['lib/b.dart']);
        expectGatesUntouched();
      },
    );

    test('what is wrong with the other gates is not reported: no test, '
        'an allowance that matches nothing', () async {
      spec('lib/b.dart', ['expect: x * 2 - 1']);
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
                  'original': '*',
                  'replacement': '/',
                  'reason': 'matches nothing in lib/a.dart',
                },
              ],
            },
            {'path': 'lib/b.dart', 'decides': 'd', 'impact': 'i'},
          ],
        }),
      );
      expect(await mutation(['--gate=lib/b.dart']), 0);
      expect(package.err, isEmpty);
      expect(package.out.last, okFor1);
    });

    test('the gate itself is judged as in a full run', () async {
      killEverything();
      spec('lib/b.dart', ['expect: x * 2']);
      expect(await mutation(['--gate', 'lib/b.dart']), 1);
      expect(package.err.first, contains('1 surviving mutant(s)'));
      expect(package.err[1], startsWith('  - lib/b.dart:1:23 / '));
      expect(
        package.err.last,
        'test_gates mutation: FAILED for 1 of 2 gate(s) (--gate) '
        '(mutants 2 / detected 1 (timeout 0) / allowed equivalent 0 / '
        'not evaluable 0 / unallowed survivors 1)',
      );
      // A gate that cannot be tested at all fails as well.
      package.err.clear();
      package.file('lib/b_test.dart').deleteSync();
      expect(await mutation(['--gate', 'lib/b.dart']), 1);
      expect(
        package.err,
        contains(startsWith('  - lib/b.dart: no test found')),
      );
    });

    test('several gates', () async {
      killEverything();
      expect(
        await mutation(['--gate', 'lib/b.dart', '--gate', 'lib/a.dart']),
        0,
      );
      expect(
        package.out.last,
        startsWith('test_gates mutation: OK for 2 of 2 gate(s) (--gate) '),
      );
      expect(report().files.keys, ['lib/a.dart', 'lib/b.dart']);
    });

    test('a path that is not a gate is wrong usage, and nothing is '
        'run', () async {
      killEverything();
      expect(await mutation(), 0);
      final before = runs().length;
      final reportBefore = package.read('reports/mutation/mutation.json');
      expect(
        await mutation(['--gate', 'lib/c.dart', '--gate', 'lib/a.dart']),
        2,
      );
      expect(
        package.err.first,
        'test_gates: --gate: not a gate of test-gates.json: lib/c.dart\n',
      );
      expect(runs(), hasLength(before));
      expect(package.read('reports/mutation/mutation.json'), reportBefore);
    });

    test(
      'the report keeps what a full run found for the other gates',
      () async {
        killEverything();
        expect(await mutation(), 0);
        final full =
            jsonDecode(package.read('reports/mutation/mutation.json'))
                as Map<String, Object?>;
        // lib/b.dart now has a survivor.
        spec('lib/b.dart', ['expect: x * 2']);
        expect(await mutation(['--gate', 'lib/b.dart']), 1);
        final after =
            jsonDecode(package.read('reports/mutation/mutation.json'))
                as Map<String, Object?>;
        final files = after['files']! as Map<String, Object?>;
        expect(files.keys, ['lib/a.dart', 'lib/b.dart']);
        expect(
          files['lib/a.dart'],
          (full['files']! as Map<String, Object?>)['lib/a.dart'],
        );
        expect(
          [
            for (final mutant in report().files['lib/b.dart']!.mutants)
              mutant.status,
          ],
          ['Killed', 'Survived'],
        );
      },
    );

    test('a run that is stopped leaves the other gates in the report, and '
        'not the old result of its own gate', () async {
      killEverything();
      expect(await mutation(), 0);
      // The test runner cannot be started: the run stops before it writes
      // a report of its own.
      expect(
        await runAsync([
          'mutation',
          '--dir',
          package.dir.path,
          '--gate',
          'lib/b.dart',
          '--force',
          '--',
          'no-such-test-runner',
        ], package.io),
        1,
      );
      expect(package.err.last, contains('the run was stopped'));
      expect(report().files.keys, ['lib/a.dart']);
    });

    test('--force forgets the last result of a gate it could not measure, '
        'and keeps those of the gates it was not asked for', () async {
      killEverything();
      expect(await mutation(), 0);
      Iterable<String> savedGates() =>
          ((jsonDecode(
                        package.read(
                          '.dart_tool/test_gates/mutation/incremental.json',
                        ),
                      )
                      as Map<String, Object?>)['gates']!
                  as Map<String, Object?>)
              .keys;
      expect(savedGates(), ['lib/a.dart', 'lib/b.dart']);
      // The tests of lib/b.dart fail without a mutant.
      spec('lib/b.dart', ['fail']);
      expect(await mutation(['--force']), 1);
      expect(savedGates(), ['lib/a.dart']);
      killEverything();
      expect(await mutation(), 0);
      spec('lib/b.dart', ['fail']);
      expect(await mutation(['--force', '--gate', 'lib/b.dart']), 1);
      expect(savedGates(), ['lib/a.dart']);
    });

    test('a wrong entry of test-gates.json stops the run, whichever gate '
        'it is in', () async {
      killEverything();
      package.write(
        'test-gates.json',
        jsonEncode({
          'gates': [
            {
              'path': 'lib/a.dart',
              'decides': 'd',
              'impact': 'i',
              'equivalentMutants': [
                {'mutator': 'ArithmeticOperator', 'original': '+'},
              ],
            },
            {'path': 'lib/b.dart', 'decides': 'd', 'impact': 'i'},
          ],
        }),
      );
      expect(await mutation(['--gate', 'lib/b.dart']), 1);
      expect(
        package.err.first,
        'test_gates mutation: test-gates.json has problems',
      );
      expect(runs(), isEmpty);
    });

    test('the results of the last run of the other gates are kept, with '
        '--force as well', () async {
      killEverything();
      expect(await mutation(), 0);
      var before = runs().length;
      // Unchanged: nothing to run for the gate.
      expect(await mutation(['--gate', 'lib/b.dart']), 0);
      expect(runs(), hasLength(before));
      // --force runs the gate again, and only that one.
      expect(await mutation(['--gate', 'lib/b.dart', '--force']), 0);
      expect(runs().length - before, 3);
      // The next full run has nothing to do: lib/a.dart was not forgotten.
      before = runs().length;
      expect(await mutation(), 0);
      expect(runs(), hasLength(before));
    });

    test('mutation-result --gate judges that gate of a report', () async {
      spec('lib/a.dart', []);
      spec('lib/b.dart', ['expect: x * 2 - 1']);
      expect(await mutation(), 1);
      package.out.clear();
      package.err.clear();
      List<String> result(String gate) => [
        'mutation-result',
        '--dir',
        package.dir.path,
        '--gate',
        gate,
      ];
      expect(run(result('lib/b.dart'), package.io), 0);
      expect(package.out, [okFor1]);
      expect(run(result('lib/a.dart'), package.io), 1);
      expect(
        package.err.last,
        startsWith('test_gates mutation: FAILED for 1 of 2 gate(s) (--gate) '),
      );
      package.err.clear();
      expect(run(result('lib/c.dart'), package.io), 2);
      expect(
        package.err.first,
        'test_gates: --gate: not a gate of test-gates.json: lib/c.dart\n',
      );
    });

    test('mutation-result --gate on the report of a run on another gate '
        'fails: the gate is not in it', () async {
      killEverything();
      expect(await mutation(['--gate', 'lib/b.dart']), 0);
      expect(
        run([
          'mutation-result',
          '--dir',
          package.dir.path,
          '--gate',
          'lib/a.dart',
        ], package.io),
        1,
      );
      expect(
        package.err,
        contains(
          '  - lib/a.dart: no mutants in the report (the gate was not '
          'mutation tested)',
        ),
      );
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
        killEverything();
        expect(await mutation(), 0);
        final before = runs().length;
        package.out.clear();
        expect(result(), 0);
        expect(package.out, [
          'test_gates mutation: OK (mutants 3 / detected 3 (timeout 0) / '
              'allowed equivalent 0 / not evaluable 0 / unallowed survivors 0)',
        ]);
        expect(runs(), hasLength(before));
      },
    );

    test('a report made from another version of a gate fails', () async {
      killEverything();
      expect(await mutation(), 0);
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
                  'id': '7',
                  'mutatorName': 'arithmetic',
                  'replacement': '-',
                  'status': 'Survived',
                  'location': {
                    'start': {'line': 1, 'column': 19},
                    'end': {'line': 1, 'column': 20},
                  },
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
      package.write('reports/mutation/mutation.json', '[]');
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
        'reports/mutation/mutation.json',
        jsonEncode({
          'files': {
            'lib/a.dart': {
              'mutants': [
                {
                  'mutatorName': 'ArithmeticOperator',
                  'replacement': '-',
                  'status': 'Killed',
                  'location': {
                    'start': {'line': 1, 'column': 19},
                    'end': {'line': 1, 'column': 20},
                  },
                },
              ],
            },
          },
        }),
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
