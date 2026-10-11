@Timeout(Duration(minutes: 2))
library;

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';

import 'package_fixture.dart';

const gates = ['lib/a.dart', 'lib/b.dart'];

void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', 'int a() => 1;\n');
    package.write('lib/b.dart', 'int b() => 2;\n');
  });

  tearDown(() => package.delete());

  Future<int> runTest([List<String> arguments = const []]) =>
      runAsync(['test', '--dir', package.dir.path, ...arguments], package.io);

  test('runs settings.gateCommand, then judges the tracefile as lcov '
      'does', () async {
    package.manifest(
      gates,
      settings: {'gateCommand': package.fake('honest', gates)},
    );
    expect(await runTest(), 0);
    expect(package.out, [
      'reference: overall line coverage 100.00% (2/2, not gated)',
      '  ✓ lib/a.dart: 1/1 lines, 1/1 branches',
      '  ✓ lib/b.dart: 1/1 lines, 1/1 branches',
      'test_gates lcov: OK (2 gate(s) at 100% line and branch coverage)',
    ]);
    expect(package.err, isEmpty);
  });

  test('a gate below 100% fails', () async {
    package.manifest(
      gates,
      settings: {
        'gateCommand': package.fake('honest', ['lib/a.dart']),
      },
    );
    expect(await runTest(), 1);
    expect(package.err, [
      'test_gates lcov: 1 violation(s)',
      '  - lib/b.dart: no record in the lcov file',
    ]);
  });

  test('a failing command fails, and its tracefile is not judged', () async {
    final command = package.fake('failing', gates);
    package.manifest(gates, settings: {'gateCommand': command});
    expect(await runTest(), 1);
    expect(package.err, [
      'test_gates test: "${command.join(' ')}" failed (exit 3). '
          'The coverage was not judged',
    ]);
    expect(package.out, isEmpty);
  });

  test('a command that writes no tracefile is not judged on an old '
      'one', () async {
    package.manifest(
      gates,
      settings: {'gateCommand': package.fake('silent', gates)},
    );
    package.write(
      'coverage/lcov.info',
      'SF:lib/a.dart\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n'
          'SF:lib/b.dart\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n',
    );
    expect(await runTest(), 1);
    expect(package.err.single, startsWith('test_gates lcov: cannot read '));
  });

  test('a command that cannot be started', () async {
    package.manifest(gates);
    expect(await runTest(['--', 'no-such-program-test-gates', 'test']), 1);
    expect(
      package.err.single,
      startsWith(
        'test_gates test: cannot start "no-such-program-test-gates test" (',
      ),
    );
  });

  test('the command after "--" and --file win over the settings', () async {
    package.manifest(
      gates,
      settings: {'gateCommand': package.fake('failing', gates)},
    );
    final command = package.fake('honest', gates)..[3] = 'other.info';
    expect(await runTest(['--file', 'other.info', '--', ...command]), 0);
  });

  test('a directory in the place of the tracefile: exit code 1', () async {
    package.manifest(
      gates,
      settings: {'gateCommand': package.fake('honest', gates)},
    );
    // A directory in the place of the tracefile.
    package.write('coverage/lcov.info/keep', '');
    expect(await runTest(), 1);
    expect(package.err.single, startsWith('test_gates test: '));
    expect(package.out, isEmpty);
  });

  test('no command: exit code 2', () async {
    package.manifest(gates);
    expect(await runTest(), 2);
    expect(
      package.err.single,
      startsWith('test_gates: no command given. Set settings.gateCommand'),
    );
  });
}
