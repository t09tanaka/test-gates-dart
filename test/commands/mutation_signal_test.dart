// Signals are not delivered to a process on Windows.
@TestOn('!windows')
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../package_root.dart';
import 'package_fixture.dart';

/// `mutation` interrupted while the tool is at work. The tool is one that
/// TEST_GATES_DART_MUTANT names, a shell script that starts it, the way
/// `dart pub global activate` installs an executable: the process that
/// `mutation` starts is the shell, and the shell does not pass a signal on.
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      inPackage('test/fixtures/mutation/fake_dart_mutant.dart.txt'),
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
      [inPackage('bin/test_gates.dart'), 'mutation', '--dir', '.'],
      workingDirectory: package.dir.path,
      environment: {
        'TEST_GATES_DART_MUTANT': '${package.dir.path}/bin/dart_mutant',
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
    // The command with two seconds of grace in place of sixty. It is a
    // process of its own: a signal to the process of the tests would reach
    // every test that waits for one.
    package.write('short_grace.dart', '''
import 'dart:io';

import 'package:test_gates/src/commands/mutation.dart';
import 'package:test_gates/src/commands/output.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runMutation(
    '.',
    null,
    const [],
    Io(out: stdout.writeln, err: stderr.writeln),
    candidates: [arguments],
    grace: const Duration(seconds: 2),
  );
}
''');
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${inPackage('.dart_tool/package_config.json')}',
      'short_grace.dart',
      '${package.dir.path}/bin/dart_mutant',
    ], workingDirectory: package.dir.path);
    final stderrText = process.stderr.transform(systemEncoding.decoder).join();
    unawaited(process.stdout.drain<void>());
    var ended = false;
    unawaited(process.exitCode.then((_) => ended = true));
    final started = package.file('started');
    while (!started.existsSync() || started.readAsStringSync().isEmpty) {
      if (ended) {
        fail('the command ended before the tool ran: ${await stderrText}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    final tool = int.parse(started.readAsStringSync());
    process.kill(ProcessSignal.sighup);
    expect(await process.exitCode, 129);
    expect((await stderrText).trim().split('\n'), [
      'test_gates mutation: dart_mutant did not end within 2 seconds of the '
          'signal and was killed. It may not have put back what it changed: '
          'look at "git status" for a gate with a mutant in it',
      'test_gates mutation: interrupted. Nothing was judged',
    ]);
    expect(package.read('signals.log').trim(), '${ProcessSignal.sighup}');
    expect(alive(tool), isFalse, reason: 'the tool is still there');
  });

  test('a launcher that ends before the tool behind it, and a signal right '
      'after: the tool is still waited for', () async {
    // The other tests send the signal to the command, which hands it on.
    // Here the launcher is gone when the signal comes, as it can be after
    // Ctrl-C in a terminal, and the tool has the signal by itself.
    package.write('fake.json', jsonEncode({'launcher': true}));
    package.write('wait_for_tool.dart', '''
import 'dart:io';

import 'package:test_gates/src/commands/mutation.dart';
import 'package:test_gates/src/commands/output.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runMutation(
    '.',
    null,
    const [],
    Io(out: stdout.writeln, err: stderr.writeln),
    candidates: [arguments],
  );
  // What was there when the command returned.
  File('returned').writeAsStringSync(
    File('put-back').existsSync() ? 'after the tool' : 'before the tool',
  );
}
''');
    final process = await Process.start(Platform.resolvedExecutable, [
      '--packages=${inPackage('.dart_tool/package_config.json')}',
      'wait_for_tool.dart',
      Platform.resolvedExecutable,
      '${package.dir.path}/fake_dart_mutant.dart',
    ], workingDirectory: package.dir.path);
    final stderrText = process.stderr.transform(systemEncoding.decoder).join();
    unawaited(process.stdout.drain<void>());

    expect(await process.exitCode, 143);
    expect(
      await stderrText,
      contains('test_gates mutation: interrupted. Nothing was judged'),
    );
    expect(package.read('returned'), 'after the tool');
  });

  test('a listing taken after the launcher ended does not lose the tool '
      'behind it', () async {
    // What the command lists of its descendants, decided here: the tool is
    // seen once, and then no more, as in a listing taken in the moment
    // between the end of the launcher and the moment that end is seen.
    package.write('fake.json', jsonEncode({'launcher': true}));
    package.write('listing.dart', '''
import 'dart:io';

import 'package:test_gates/src/io/process.dart';

Future<void> main(List<String> command) async {
  var seen = false;
  // Empty listings while the launcher was there: without one the old way
  // would have kept the tool as well, and this would test nothing.
  var emptied = 0;
  List<int> listing(int root) {
    if (seen) {
      if (Process.runSync('kill', ['-0', '\$root']).exitCode == 0) {
        emptied++;
      }
      return const [];
    }
    final found = descendantsOf(root);
    final started = File('started');
    final tool = started.existsSync()
        ? int.tryParse(started.readAsStringSync())
        : null;
    seen = found.contains(tool);
    return found;
  }

  final signals = SignalWatch();
  final result = await runCommand(
    command,
    workingDirectory: '.',
    capture: false,
    signals: signals,
    handOver: true,
    listDescendants: listing,
  );
  await signals.cancel();
  stdout.writeln(result.signal);
  stdout.writeln(emptied > 0 ? 'emptied' : 'never emptied');
  File('returned').writeAsStringSync(
    File('put-back').existsSync() ? 'after the tool' : 'before the tool',
  );
}
''');
    final result = await Process.run(Platform.resolvedExecutable, [
      '--packages=${inPackage('.dart_tool/package_config.json')}',
      'listing.dart',
      Platform.resolvedExecutable,
      '${package.dir.path}/fake_dart_mutant.dart',
      'run',
    ], workingDirectory: package.dir.path);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect((result.stdout as String).trim().split('\n'), [
      '${ProcessSignal.sigterm}',
      'emptied',
    ]);
    expect(package.read('returned'), 'after the tool');
  });
}
