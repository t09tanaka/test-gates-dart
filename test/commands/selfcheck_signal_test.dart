// Signals are not delivered to a process on Windows.
@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/selfcheck.dart';

import '../package_root.dart';
import 'package_fixture.dart';

const gates = ['lib/a.dart', 'lib/b.dart'];
const sourceA = 'int a() => 1;\n';
const sourceB = 'int b() => 2;';

/// `selfcheck` interrupted while the coverage command runs.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', sourceA);
    package.write('lib/b.dart', sourceB);
  });

  tearDown(() => package.delete());

  void expectGatesUntouched() {
    expect(package.read('lib/a.dart'), sourceA);
    expect(package.read('lib/b.dart'), sourceB);
  }

  for (final (signal, code) in [
    (ProcessSignal.sigint, 130),
    (ProcessSignal.sigterm, 143),
    (ProcessSignal.sighup, 129),
  ]) {
    test('$signal: the command is ended, the gates and the tracefile '
        'are put back, exit code $code', () async {
      package.manifest(
        gates,
        settings: {'gateCommand': package.fake('waiting', gates)},
      );
      package.write('coverage/lcov.info', 'old\n');
      final process = await Process.start(Platform.resolvedExecutable, [
        inPackage('bin/test_gates.dart'),
        'selfcheck',
        '--dir',
        package.dir.path,
      ], workingDirectory: packageRoot);
      final stderrText = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      unawaited(process.stdout.drain<void>());

      final started = package.file('started');
      while (!started.existsSync() || started.readAsStringSync().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      // The probes are in place while the command runs.
      for (final gate in gates) {
        expect(
          lengthWithoutProbe(package.file(gate).readAsBytesSync()),
          isNotNull,
        );
      }
      final child = int.parse(started.readAsStringSync());

      process.kill(signal);
      expect(await process.exitCode, code);
      expect(
        await stderrText,
        contains('test_gates selfcheck: interrupted. The gates were put back'),
      );
      expectGatesUntouched();
      expect(package.read('coverage/lcov.info'), 'old\n');
      expect(
        Process.runSync('kill', ['-0', '$child']).exitCode,
        isNot(0),
        reason: 'the command is still running',
      );
    });
  }
}
