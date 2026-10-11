// Signals are not delivered to a process on Windows.
@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';

import 'package_fixture.dart';

// Two mutants: `*` → `/`, `-` → `+`. The fake test run never ends on the
// first.
const source = 'int a(int x) => x * 2 - 1;\n';
const mutated = 'int a(int x) => x / 2 - 1;\n';
const backup = '.dart_tool/test_gates/mutation/backup/lib/a.dart';

/// `mutation` interrupted while the tests run on a mutant.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      'test/fixtures/mutation/fake_test.dart.txt',
    ).copySync('${package.dir.path}/fake_test.dart');
    package.write('lib/a.dart', source);
    package.write(
      'lib/a_test.dart',
      '// gate: lib/a.dart\n// hang-if: x / 2\n// expect: x * 2 - 1\n',
    );
    package.manifest(['lib/a.dart']);
  });

  tearDown(() => package.delete());

  final arguments = [
    'bin/test_gates.dart',
    'mutation',
    '--dir',
    '.',
    '--',
    Platform.resolvedExecutable,
    'fake_test.dart',
  ];

  /// Starts the command line and waits until the tests run on the mutant.
  /// Returns the process and the pid of the test run.
  Future<(Process, int)> start() async {
    final process = await Process.start(Platform.resolvedExecutable, [
      File(arguments.first).absolute.path,
      ...arguments.skip(1),
    ], workingDirectory: package.dir.path);
    final started = package.file('started');
    while (!started.existsSync() || started.readAsStringSync().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    // The mutant is in place while the tests run.
    expect(package.read('lib/a.dart'), mutated);
    expect(package.read(backup), source);
    return (process, int.parse(started.readAsStringSync()));
  }

  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  for (final (signal, code) in [
    (ProcessSignal.sigint, 130),
    (ProcessSignal.sigterm, 143),
    (ProcessSignal.sighup, 129),
  ]) {
    test('$signal: the test run is ended, the gate is put back, exit code '
        '$code', () async {
      final (process, child) = await start();
      final stderrText = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      unawaited(process.stdout.drain<void>());

      process.kill(signal);
      expect(await process.exitCode, code);
      expect(
        await stderrText,
        contains('test_gates mutation: interrupted. The gates were put back'),
      );
      expect(package.read('lib/a.dart'), source);
      expect(package.file(backup).existsSync(), isFalse);
      expect(alive(child), isFalse, reason: 'the test run is still there');
      // An interrupted run writes no report.
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });
  }

  test('SIGKILL: the mutant stays in the gate, and the next run takes it '
      'out first', () async {
    final (process, child) = await start();
    unawaited(process.stdout.drain<void>());
    unawaited(process.stderr.drain<void>());
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
    Process.killPid(child, ProcessSignal.sigkill);
    expect(package.read('lib/a.dart'), mutated);
    expect(package.read(backup), source);

    // Nothing hangs this time: the next run goes through.
    package.write(
      'lib/a_test.dart',
      '// gate: lib/a.dart\n// expect: x * 2 - 1\n',
    );
    final code = await runAsync([
      'mutation',
      '--dir',
      package.dir.path,
      '--',
      Platform.resolvedExecutable,
      'fake_test.dart',
    ], package.io);
    expect(package.err, [
      'test_gates mutation: put back lib/a.dart, which an interrupted run '
          'left with a mutant in it',
    ]);
    expect(code, 0);
    expect(package.read('lib/a.dart'), source);
    expect(package.file(backup).existsSync(), isFalse);
  });
}
