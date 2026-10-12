// Signals are not delivered to a process on Windows.
@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/commands/mutation.dart';

import 'package_fixture.dart';

/// `mutation` interrupted while the tool is at work. The tool is found on
/// PATH, as a shell script that starts it, the way `dart pub global activate`
/// installs an executable: the process that `mutation` starts is the shell,
/// and the shell does not pass a signal on.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      'test/fixtures/mutation/fake_dart_mutant.dart.txt',
    ).copySync('${package.dir.path}/fake_dart_mutant.dart');
    package.write('lib/a.dart', 'int a(int x) => x + 1;\n');
    package.write('lib/a_test.dart', '');
    package.manifest(['lib/a.dart']);
    package.write('fake.json', jsonEncode({'hang': true}));
    package.write(
      'bin/dart_mutant',
      '#!/bin/sh\n'
          '"${Platform.resolvedExecutable}" '
          '"${package.dir.path}/fake_dart_mutant.dart" "\$@"\n',
    );
    Process.runSync('chmod', ['+x', '${package.dir.path}/bin/dart_mutant']);
  });

  tearDown(() => package.delete());

  /// Starts the command line and waits until the tool is at work. Returns
  /// the process and the pid of the tool (not of the shell that started it).
  Future<(Process, int)> start() async {
    final process = await Process.start(
      Platform.resolvedExecutable,
      [File('bin/test_gates.dart').absolute.path, 'mutation', '--dir', '.'],
      workingDirectory: package.dir.path,
      environment: {
        'PATH': '${package.dir.path}/bin:${Platform.environment['PATH']}',
      },
    );
    final started = package.file('started');
    while (!started.existsSync() || started.readAsStringSync().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    return (process, int.parse(started.readAsStringSync()));
  }

  bool alive(int pid) => Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

  for (final (signal, code) in [
    (ProcessSignal.sigint, 130),
    (ProcessSignal.sigterm, 143),
    (ProcessSignal.sighup, 129),
  ]) {
    test('$signal: it is handed to the tool behind its launcher, the tool '
        'is waited for while it puts things back, exit code $code', () async {
      final (process, tool) = await start();
      final stderrText = process.stderr
          .transform(systemEncoding.decoder)
          .join();
      unawaited(process.stdout.drain<void>());

      process.kill(signal);
      expect(await process.exitCode, code);
      expect(
        await stderrText,
        contains('test_gates mutation: interrupted. Nothing was judged'),
      );
      // The tool got the signal, and had ended when the command returned.
      expect(package.read('signals.log').trim(), '$signal');
      expect(package.file('put-back').existsSync(), isTrue);
      expect(alive(tool), isFalse, reason: 'the tool is still there');
      expect(
        package.file('reports/mutation/mutation.json').existsSync(),
        isFalse,
      );
    });
  }

  test('a tool that does not end after the signal is killed when its time '
      'is up, and the message says what that can leave behind', () async {
    package.write('fake.json', jsonEncode({'hang': true, 'deaf': true}));
    final exit = runMutation(
      package.dir.path,
      null,
      const [],
      package.io,
      candidates: [
        ['${package.dir.path}/bin/dart_mutant'],
      ],
      grace: const Duration(seconds: 2),
    );
    final started = package.file('started');
    while (!started.existsSync() || started.readAsStringSync().isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final tool = int.parse(started.readAsStringSync());
    Process.killPid(pid, ProcessSignal.sighup);
    expect(await exit, 129);
    expect(package.err, [
      'test_gates mutation: dart_mutant did not end within 2 seconds of the '
          'signal and was killed. It may not have put back what it changed: '
          'look at "git status" for a gate with a mutant in it',
      'test_gates mutation: interrupted. Nothing was judged',
    ]);
    expect(package.read('signals.log').trim(), '${ProcessSignal.sighup}');
    expect(alive(tool), isFalse, reason: 'the tool is still there');
  });
}
