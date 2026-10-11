@Timeout(Duration(minutes: 2))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/selfcheck.dart';

import 'package_fixture.dart';

const gates = ['lib/a.dart', 'lib/b.dart'];
const sourceA = 'int a() => 1;\n';
// No line break at the end.
const sourceB = 'int b() => 2;';

void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', sourceA);
    package.write('lib/b.dart', sourceB);
  });

  tearDown(() => package.delete());

  Future<int> selfcheck([List<String> arguments = const []]) => runAsync([
    'selfcheck',
    '--dir',
    package.dir.path,
    ...arguments,
  ], package.io);

  void expectGatesUntouched() {
    expect(package.read('lib/a.dart'), sourceA);
    expect(package.read('lib/b.dart'), sourceB);
  }

  group('exit code 0', () {
    test('every gate fails on its probe; the gates are put back', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('honest', gates)},
      );
      expect(await selfcheck(), 0);
      expect(package.out, [
        'running "${package.fake('honest', gates).join(' ')}" '
            'with a probe in 2 gate(s)',
        '  ✓ lib/a.dart: with unexecuted code at line 3 the gate fails',
        '  ✓ lib/b.dart: with unexecuted code at line 3 the gate fails',
        'test_gates selfcheck: OK (2 negative control(s) failed as they should)',
      ]);
      expect(package.err, isEmpty);
      expectGatesUntouched();
      // The tracefile of the run counts the probes, so it is not left behind.
      expect(package.file('coverage/lcov.info').existsSync(), isFalse);
    });

    test('the tracefile of before the run is put back', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('honest', gates)},
      );
      package.write('coverage/lcov.info', 'SF:lib/a.dart\nend_of_record\n');
      expect(await selfcheck(), 0);
      expect(
        package.read('coverage/lcov.info'),
        'SF:lib/a.dart\nend_of_record\n',
      );
    });

    test('--first and settings.selfcheck.mode: only the first gate', () async {
      package.manifest(
        gates,
        settings: {
          'gateCommand': package.fake('honest', gates),
          'selfcheck': {'mode': 'first'},
        },
      );
      expect(await selfcheck(), 0);
      expect(package.out.sublist(1), [
        '  ✓ lib/a.dart: with unexecuted code at line 3 the gate fails',
        'test_gates selfcheck: OK (1 negative control(s) failed as they should)',
      ]);
      package.out.clear();
      // The command line wins over the setting.
      expect(await selfcheck(['--all']), 0);
      expect(package.out, hasLength(4));

      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('honest', gates)},
      );
      package.out.clear();
      expect(await selfcheck(['--first']), 0);
      expect(package.out, hasLength(3));
    });

    test('the command after "--" wins over settings.gateCommand, and --file '
        'over settings.lcov.file', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('failing', gates)},
      );
      expect(
        await selfcheck([
          '--file',
          'other.info',
          '--',
          Platform.resolvedExecutable,
          'fake_coverage.dart',
          'honest',
          'other.info',
          ...gates,
        ]),
        0,
      );
    });

    test('a probe left by a killed run is removed first', () async {
      package.manifest(
        gates,
        settings: {
          'gateCommand': package.fake('honest', gates),
          'selfcheck': {'mode': 'first'},
        },
      );
      // lib/b.dart is not a target of this run, and is cleaned all the same.
      for (final gate in gates) {
        final file = package.file(gate);
        final probe = buildProbe(file.readAsBytesSync(), gate);
        file.writeAsBytesSync(probe.suffix, mode: FileMode.append);
      }
      expect(await selfcheck(), 0);
      expect(package.err, [
        'test_gates selfcheck: removed a probe that an interrupted run left '
            'in lib/a.dart',
        'test_gates selfcheck: removed a probe that an interrupted run left '
            'in lib/b.dart',
      ]);
      expectGatesUntouched();
    });
  });

  group('exit code 1', () {
    test('a measurement that does not see the probe', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('blind', gates)},
      );
      expect(await selfcheck(), 1);
      expect(package.err, [
        '  ✗ lib/a.dart: the probe at line 3 is not reported as a line that '
            'was not executed. The tracefile does not measure this file as it '
            'is on disk',
        '  ✗ lib/b.dart: the probe at line 3 is not reported as a line that '
            'was not executed. The tracefile does not measure this file as it '
            'is on disk',
        'test_gates selfcheck: FAILED (2 of 2 negative control(s))',
      ]);
      expectGatesUntouched();
    });

    test('one gate without a record, the other held', () async {
      package.manifest(
        gates,
        settings: {
          'gateCommand': package.fake('honest', ['lib/a.dart']),
        },
      );
      expect(await selfcheck(), 1);
      expect(package.out.sublist(1), [
        '  ✓ lib/a.dart: with unexecuted code at line 3 the gate fails',
      ]);
      expect(package.err, [
        '  ✗ lib/b.dart: no record in the tracefile, so the probe was not '
            'measured. No test loads this file',
        'test_gates selfcheck: FAILED (1 of 2 negative control(s))',
      ]);
    });

    test('coverage without branches', () async {
      package.manifest(
        ['lib/a.dart'],
        settings: {
          'gateCommand': package.fake('no-branches', ['lib/a.dart']),
        },
      );
      expect(await selfcheck(), 1);
      expect(package.err, [
        '  ✗ lib/a.dart: the probe at line 3 is not reported as a branch '
            'that was not taken. Collect the coverage with --branch-coverage',
        'test_gates selfcheck: FAILED (1 of 1 negative control(s))',
      ]);
    });

    test('a failing command proves nothing', () async {
      final command = package.fake('failing', gates);
      package.manifest(gates, settings: {'gateCommand': command});
      expect(await selfcheck(), 1);
      expect(package.err, [
        'test_gates selfcheck: "${command.join(' ')}" failed (exit 3) with '
            'the probes in place. It has to pass and only write the '
            'tracefile; the verdict is taken from the tracefile',
        '      00:01 +1 -1: Some tests failed.',
        'test_gates selfcheck: FAILED (nothing was measured, '
            '2 negative control(s))',
      ]);
      expectGatesUntouched();
    });

    test('a command that writes no tracefile is not judged on an old '
        'one', () async {
      final command = package.fake('silent', gates);
      package.manifest(gates, settings: {'gateCommand': command});
      const old =
          'SF:lib/a.dart\nDA:3,0\nBRDA:3,0,0,0\nend_of_record\n'
          'SF:lib/b.dart\nDA:3,0\nBRDA:3,0,0,0\nend_of_record\n';
      package.write('coverage/lcov.info', old);
      expect(await selfcheck(), 1);
      expect(
        package.err.first,
        startsWith(
          'test_gates selfcheck: "${command.join(' ')}" passed but did not '
          'write coverage/lcov.info.',
        ),
      );
      expect(package.read('coverage/lcov.info'), old);
    });

    test('a command that cannot be started', () async {
      package.manifest(
        gates,
        settings: {
          'gateCommand': ['no-such-program-test-gates', 'test'],
        },
      );
      expect(await selfcheck(), 1);
      expect(
        package.err.first,
        startsWith(
          'test_gates selfcheck: cannot start "no-such-program-test-gates test"',
        ),
      );
      expectGatesUntouched();
    });

    test('a truncated tracefile', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('truncated', gates)},
      );
      expect(await selfcheck(), 1);
      expect(package.err, [
        startsWith('test_gates selfcheck: coverage/lcov.info: '),
        '  ✗ lib/a.dart: the tracefile is unreliable',
        '  ✗ lib/b.dart: the tracefile is unreliable',
        'test_gates selfcheck: FAILED (2 of 2 negative control(s))',
      ]);
    });

    test('a gate whose file is missing gets no probe; the others are '
        'checked', () async {
      package.manifest(
        ['lib/a.dart', 'lib/A.dart', 'lib/missing.dart'],
        settings: {
          'gateCommand': package.fake('honest', ['lib/a.dart']),
        },
      );
      expect(await selfcheck(), 1);
      expect(package.err, [
        '  ✗ lib/A.dart: file not found (the check is case-sensitive). '
            'Update test-gates.json if it moved',
        '  ✗ lib/missing.dart: file not found (the check is case-sensitive). '
            'Update test-gates.json if it moved',
        'test_gates selfcheck: FAILED (2 of 3 negative control(s))',
      ]);
      expect(package.read('lib/a.dart'), sourceA);
      expect(package.file('lib/missing.dart').existsSync(), isFalse);
    });

    test('a broken entry in test-gates.json: nothing is touched', () async {
      package.write(
        'test-gates.json',
        '{"gates":[{"path":"lib/a.dart","decides":"d"}],'
            '"settings":{"lcov":{"file":"coverage/lcov.info"},'
            '"gateCommand":["no-such-program-test-gates"]}}',
      );
      expect(await selfcheck(), 1);
      expect(
        package.err.first,
        'test_gates selfcheck: test-gates.json has problems',
      );
      expect(package.err, hasLength(2));

      package.err.clear();
      package.manifest(
        [],
        settings: {
          'gateCommand': ['x'],
        },
      );
      expect(await selfcheck(), 1);
      expect(package.err, [
        'test_gates selfcheck: test-gates.json has problems',
        '  - test-gates.json: gates is empty. A project with nothing to gate '
            'should not have this file',
      ]);
    });

    test('a directory in the place of the tracefile: the gates are put '
        'back', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('honest', gates)},
      );
      package.write('coverage/lcov.info/keep', '');
      expect(await selfcheck(), 1);
      expect(package.err.last, startsWith('test_gates selfcheck: FAILED'));
      expectGatesUntouched();
    });

    test('a gate saved during the run keeps the change and loses the '
        'probe', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('editing', gates)},
      );
      expect(await selfcheck(), 1);
      expect(package.read('lib/a.dart'), '// edited\n$sourceA');
      expect(package.read('lib/b.dart'), sourceB);
      expect(package.err, [
        'test_gates selfcheck: lib/a.dart changed during the run. The probe '
            'was removed and the change was kept',
        // The edit moved the probe to another line.
        startsWith('  ✗ lib/a.dart: the probe at line 3 is not reported'),
        'test_gates selfcheck: FAILED (1 of 2 negative control(s))',
      ]);
    });

    test('a gate replaced during the run is left as it is', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('overwriting', gates)},
      );
      expect(await selfcheck(), 1);
      expect(package.read('lib/a.dart'), 'int replaced() => 2;\n');
      expect(package.read('lib/b.dart'), sourceB);
      expect(
        package.err.first,
        startsWith(
          'test_gates selfcheck: lib/a.dart changed during the run and no '
          'longer ends with the probe. It was left as it is',
        ),
      );
    });
  });

  group('exit code 2', () {
    test('no command', () async {
      package.manifest(gates);
      expect(await selfcheck(), 2);
      expect(package.err, [
        'test_gates: no command given. Set settings.gateCommand, for example '
            '["flutter", "test", "--coverage", "--branch-coverage"], '
            'or pass the command after "--"',
      ]);
      expectGatesUntouched();
    });

    test('a probe left by a killed run is removed even when the run '
        'cannot start', () async {
      package.manifest(gates);
      final file = package.file('lib/b.dart');
      final probe = buildProbe(file.readAsBytesSync(), 'lib/b.dart');
      file.writeAsBytesSync(probe.suffix, mode: FileMode.append);
      expect(await selfcheck(), 2);
      expect(package.err.first, contains('removed a probe'));
      expectGatesUntouched();
    });

    test('no tracefile named', () async {
      package.write(
        'test-gates.json',
        '{"gates":[{"path":"lib/a.dart","decides":"d","impact":"i"}],'
            '"settings":{"gateCommand":["x"]}}',
      );
      expect(await selfcheck(), 2);
      expect(package.err, [
        'test_gates: no lcov file given. Pass --file <lcov.info> or set '
            'settings.lcov.file',
      ]);
    });

    test('wrong usage', () async {
      expect(await selfcheck(['--all', '--first']), 2);
      expect(
        package.err.first,
        'test_gates: --all and --first cannot be combined\n',
      );
    });
  });
}
