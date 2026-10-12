@Timeout(Duration(minutes: 2))
library;

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';

import 'package_fixture.dart';

const gates = ['lib/a.dart', 'lib/b.dart'];
const sourceA = 'int a() => 1;\n';
// No line break at the end.
const sourceB = 'int b() => 2;';

/// `test --selfcheck`: one run of the tests that is the coverage run and the
/// negative control. What it leaves and says about the coverage is compared
/// with `test`, on the same package and the same command.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', sourceA);
    package.write('lib/b.dart', sourceB);
  });

  tearDown(() => package.delete());

  Future<int> run(String command, [List<String> arguments = const []]) {
    package.out.clear();
    package.err.clear();
    return runAsync([
      ...command.split(' '),
      '--dir',
      package.dir.path,
      ...arguments,
    ], package.io);
  }

  void honest([String mode = 'honest']) => package.manifest(
    gates,
    settings: {'gateCommand': package.fake(mode, gates)},
  );

  /// What `test` leaves and says, to compare with.
  Future<({int code, String? tracefile, List<String> out, List<String> err})>
  plain() async {
    final code = await run('test');
    final file = package.file('coverage/lcov.info');
    return (
      code: code,
      tracefile: file.existsSync() ? file.readAsStringSync() : null,
      out: [...package.out],
      err: [...package.err],
    );
  }

  test('every control holds and every gate is at 100%: exit code 0, the '
      'gates are put back, and the tracefile is the one test leaves', () async {
    honest();
    final expected = await plain();
    expect(expected.code, 0);

    expect(await run('test --selfcheck'), 0);
    expect(package.out, [
      'running "${package.fake('honest', gates).join(' ')}" '
          'with a probe in 2 gate(s)',
      '  ✓ lib/a.dart: with unexecuted code at line 3 the gate fails',
      '  ✓ lib/b.dart: with unexecuted code at line 3 the gate fails',
      'test_gates selfcheck: OK (2 negative control(s) failed as they should)',
      ...expected.out,
    ]);
    expect(package.err, isEmpty);
    expect(package.read('lib/a.dart'), sourceA);
    expect(package.read('lib/b.dart'), sourceB);
    expect(package.read('coverage/lcov.info'), expected.tracefile);
    // The next lcov judges that file, and passes.
    expect(await run('lcov'), 0);
  });

  test('a gate with code that no test runs: the controls hold, the coverage '
      'fails as it fails for test, with the same lines', () async {
    package.write('lib/a.dart', 'int a() => 1;\nint untested() => 2;\n');
    honest();
    final expected = await plain();
    expect(expected.code, 1);
    expect(expected.err, isNotEmpty);

    expect(await run('test --selfcheck'), 1);
    expect(package.out, [
      'running "${package.fake('honest', gates).join(' ')}" '
          'with a probe in 2 gate(s)',
      '  ✓ lib/a.dart: with unexecuted code at line 4 the gate fails',
      '  ✓ lib/b.dart: with unexecuted code at line 3 the gate fails',
      'test_gates selfcheck: OK (2 negative control(s) failed as they should)',
      ...expected.out,
    ]);
    expect(package.err, expected.err);
    expect(package.read('coverage/lcov.info'), expected.tracefile);
  });

  test('a measurement that does not see the files: the coverage alone would '
      'pass, the controls fail, exit code 1', () async {
    honest('blind');
    expect((await plain()).code, 0);
    expect(await run('test --selfcheck'), 1);
    expect(package.err, [
      startsWith('  ✗ lib/a.dart: the probe at line 3 is not reported'),
      startsWith('  ✗ lib/b.dart: the probe at line 3 is not reported'),
      'test_gates selfcheck: FAILED (2 of 2 negative control(s))',
    ]);
    expect(
      package.out.last,
      'test_gates lcov: OK (2 gate(s) at 100% line and branch coverage)',
    );
  });

  test('coverage without branches fails both', () async {
    honest('no-branches');
    final expected = await plain();
    expect(expected.code, 1);
    expect(await run('test --selfcheck'), 1);
    expect(package.err.take(3), [
      startsWith(
        '  ✗ lib/a.dart: the probe at line 3 is not reported as a '
        'branch',
      ),
      startsWith(
        '  ✗ lib/b.dart: the probe at line 3 is not reported as a '
        'branch',
      ),
      'test_gates selfcheck: FAILED (2 of 2 negative control(s))',
    ]);
    expect(package.err.skip(3), expected.err);
    expect(package.read('coverage/lcov.info'), expected.tracefile);
  });

  test('the command fails: nothing was measured, no tracefile is left, and '
      'the coverage is not judged', () async {
    honest('failing');
    package.write('coverage/lcov.info', 'SF:lib/a.dart\nend_of_record\n');
    expect(await run('test --selfcheck'), 1);
    expect(package.file('coverage/lcov.info').existsSync(), isFalse);
    expect(
      package.err.last,
      'test_gates selfcheck: FAILED (nothing was measured, 2 negative '
      'control(s))',
    );
    expect(package.out, hasLength(1));
    expect(package.out.single, startsWith('running "'));
    expect(package.read('lib/a.dart'), sourceA);
  });

  test('the command writes no tracefile', () async {
    honest('silent');
    expect(await run('test --selfcheck'), 1);
    expect(package.file('coverage/lcov.info').existsSync(), isFalse);
    expect(package.err.first, contains('did not write coverage/lcov.info'));
  });

  test('settings.selfcheck.mode: first puts a probe in the first gate only; '
      'the coverage of every gate is judged', () async {
    package.manifest(
      gates,
      settings: {
        'gateCommand': package.fake('honest', gates),
        'selfcheck': {'mode': 'first'},
      },
    );
    final expected = await plain();
    expect(await run('test --selfcheck'), 0);
    expect(package.out, [
      'running "${package.fake('honest', gates).join(' ')}" '
          'with a probe in 1 gate(s)',
      '  ✓ lib/a.dart: with unexecuted code at line 3 the gate fails',
      'test_gates selfcheck: OK (1 negative control(s) failed as they should)',
      ...expected.out,
    ]);
    expect(package.read('coverage/lcov.info'), expected.tracefile);
  });

  test('--file and the command after "--"', () async {
    honest('failing');
    final command = [...package.fake('honest', gates)]..[3] = 'other.info';
    expect(
      await run('test --selfcheck', ['--file', 'other.info', '--', ...command]),
      0,
    );
    expect(package.file('other.info').existsSync(), isTrue);
    expect(package.file('coverage/lcov.info').existsSync(), isFalse);
  });

  test('a gate that is gone fails the control and the coverage', () async {
    package.manifest(
      [...gates, 'lib/gone.dart'],
      settings: {'gateCommand': package.fake('honest', gates)},
    );
    final expected = await plain();
    expect(await run('test --selfcheck'), 1);
    expect(package.err, [
      '  ✗ lib/gone.dart: file not found (the check is case-sensitive). '
          'Update test-gates.json if it moved',
      'test_gates selfcheck: FAILED (1 of 3 negative control(s))',
      ...expected.err,
    ]);
  });

  test('--selfcheck belongs to test', () async {
    honest();
    expect(await run('selfcheck', ['--selfcheck']), 2);
    expect(await run('lcov', ['--selfcheck']), 2);
    expect(await run('test', ['--selfcheck=1']), 2);
    expect(
      package.err.first,
      'test_gates: --selfcheck does not take a value\n',
    );
  });
}
