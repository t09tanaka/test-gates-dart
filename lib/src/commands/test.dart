import 'dart:io';

import '../io/files.dart';
import '../io/process.dart';
import '../manifest.dart';
import 'lcov.dart';
import 'output.dart';

/// The command that runs the tests and writes the tracefile: what follows
/// `--`, or `settings.gateCommand`. Throws [ManifestError] when neither is
/// given.
List<String> gateCommandOf(LoadedManifest manifest, List<String> override) {
  final command = override.isNotEmpty
      ? override
      : manifest.settings.gateCommand;
  if (command == null) {
    throw ManifestError(
      'no command given. Set settings.gateCommand, for example '
      '["flutter", "test", "--coverage", "--branch-coverage"], '
      'or pass the command after "--"',
    );
  }
  return command;
}

/// Removes a tracefile of an earlier run, so that a command which writes none
/// is not judged on old numbers.
void deleteTracefile(String path) {
  final file = File(path);
  if (file.existsSync()) {
    file.deleteSync();
  }
}

/// Runs the tests with coverage (`settings.gateCommand`) and judges the
/// tracefile as `lcov` does.
///
/// Returns the exit code: 0 when the command passes and every gate is at
/// 100%, 1 otherwise, 130 / 143 / 129 when interrupted.
Future<int> runTest(
  String dir,
  String? fileOption,
  List<String> commandOverride,
  Io io,
) async {
  final manifest = readManifest(dir);
  final file = tracefileOf(manifest, fileOption);
  final command = gateCommandOf(manifest, commandOverride);
  final shown = command.join(' ');

  final signals = SignalWatch();
  final CommandResult result;
  try {
    deleteTracefile(resolveInPackage(manifest.dir, file));
    result = await runCommand(
      command,
      workingDirectory: manifest.dir,
      capture: false,
      signals: signals,
    );
  } finally {
    await signals.cancel();
  }
  // Also a signal that came when the command had just ended: in `all` the
  // next check would otherwise start.
  final signal = result.signal ?? signals.signal;
  if (signal != null) {
    io.err('$executable test: interrupted');
    return signalExitCode(signal);
  }
  if (result.exitCode != 0) {
    io.err(
      result.exitCode == null
          ? '$executable test: cannot start "$shown" (${result.startError})'
          : '$executable test: "$shown" failed (exit ${result.exitCode}). '
                'The coverage was not judged',
    );
    return 1;
  }
  return judgeTracefile(manifest, file, io);
}
