// Signals are not delivered to a process on Windows.
@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'package_fixture.dart';

/// `timezones` interrupted while the tests run in the first zone.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      'test/fixtures/zones/fake_zone_test.dart.txt',
    ).copySync('${package.dir.path}/fake_zone_test.dart');
    package.write(
      'lib/due.dart',
      'bool isDue(DateTime now, DateTime due) => now.isAfter(due);\n',
    );
    package.write('lib/due_test.dart', '');
    package.manifest(['lib/due.dart']);
    package.write('hang-in', 'Pacific/Kiritimati\n');
  });

  tearDown(() => package.delete());

  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  for (final (signal, code) in [
    (ProcessSignal.sigint, 130),
    (ProcessSignal.sigterm, 143),
    (ProcessSignal.sighup, 129),
  ]) {
    test('$signal: the tests are ended, the other zone is not run, exit '
        'code $code', () async {
      final process = await Process.start(Platform.resolvedExecutable, [
        'bin/test_gates.dart',
        'timezones',
        '--dir',
        package.dir.path,
        '--',
        Platform.resolvedExecutable,
        'fake_zone_test.dart',
      ]);
      final stderrText = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      unawaited(process.stdout.drain<void>());

      final started = package.file('started');
      while (!started.existsSync() || started.readAsStringSync().isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      final tests = int.parse(started.readAsStringSync());

      process.kill(signal);
      expect(await process.exitCode, code);
      expect(await stderrText, 'test_gates timezones: interrupted\n');
      expect(alive(tests), isFalse, reason: 'the tests are still running');
      expect(
        package.read('zones.log'),
        'TZ=Pacific/Kiritimati lib/due_test.dart\n',
      );
    });
  }
}
