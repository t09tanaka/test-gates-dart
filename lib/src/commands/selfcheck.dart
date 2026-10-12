import 'dart:io';
import 'dart:typed_data';

import '../io/files.dart';
import '../io/process.dart';
import '../lcov.dart';
import '../selfcheck.dart';
import 'lcov.dart';
import 'output.dart';
import 'test.dart';

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) {
    return false;
  }
  for (var index = 0; index < a.length; index++) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}

/// A gate file with a probe appended.
class _Injected {
  _Injected({
    required this.gate,
    required this.file,
    required this.originalLength,
    required this.withProbe,
  });

  final ProbedGate gate;
  final File file;
  final int originalLength;
  final Uint8List withProbe;
}

void _truncate(File file, int length) {
  final handle = file.openSync(mode: FileMode.append);
  try {
    handle.truncateSync(length);
  } finally {
    handle.closeSync();
  }
}

/// Appends the probe. The bytes already in the file are not written again, so
/// a run that dies here leaves the original content in place, followed at
/// most by a part of the probe.
_Injected _inject(String dir, String gatePath) {
  final file = File(resolveInPackage(dir, gatePath));
  final original = file.readAsBytesSync();
  final probe = buildProbe(original, gatePath);
  try {
    file.writeAsBytesSync(probe.suffix, mode: FileMode.append, flush: true);
  } on FileSystemException {
    // A full disk can leave a part of the probe behind, which nothing would
    // recognise later.
    try {
      if (file.lengthSync() > original.length) {
        _truncate(file, original.length);
      }
    } on FileSystemException {
      // The caller reports the gate; there is nothing more to try.
    }
    rethrow;
  }
  return _Injected(
    gate: ProbedGate(path: gatePath, line: probe.line),
    file: file,
    originalLength: original.length,
    withProbe: Uint8List.fromList([...original, ...probe.suffix]),
  );
}

/// Takes the probe out again. Returns a message when the file is not as this
/// run left it.
String? _restore(_Injected injected) {
  final path = injected.gate.path;
  try {
    final current = injected.file.readAsBytesSync();
    if (_sameBytes(current, injected.withProbe)) {
      _truncate(injected.file, injected.originalLength);
      return null;
    }
    // Somebody saved the file during the run. Their content is kept; only a
    // probe at its end is removed.
    final length = lengthWithoutProbe(current);
    if (length == null) {
      return '$path changed during the run and no longer ends with the probe. '
          'It was left as it is; check it for the line "$probeMarker…"';
    }
    _truncate(injected.file, length);
    return '$path changed during the run. The probe was removed and the '
        'change was kept';
  } on FileSystemException catch (error) {
    return '$path: CANNOT REMOVE THE PROBE '
        '(${error.osError?.message ?? error.message}). '
        'Delete the last two lines of the file by hand';
  }
}

/// Removes probes that a killed run (SIGKILL, power loss) left behind.
void _removeLeftovers(LoadedManifest manifest, Io io) {
  for (final gate in manifest.gates) {
    final file = File(resolveInPackage(manifest.dir, gate.path));
    try {
      if (!file.existsSync()) {
        continue;
      }
      final length = lengthWithoutProbe(file.readAsBytesSync());
      if (length != null) {
        _truncate(file, length);
        io.err(
          '$executable selfcheck: removed a probe that an interrupted run '
          'left in ${gate.path}',
        );
      }
    } on FileSystemException {
      // Reported where the gate is read for the probe.
    }
  }
}

/// Negative control. Appends code that no test executes to every gate, runs
/// the tests with coverage once, and requires the lcov judgement to fail for
/// each gate on that very code. A gate that stays green with unexecuted code
/// in it measures nothing.
///
/// The gates are changed in place and put back when the run ends, also on an
/// error and on SIGINT / SIGTERM.
///
/// Returns the exit code: 0 when every control held, 1 otherwise, 130 / 143 /
/// 129 when interrupted by SIGINT / SIGTERM / SIGHUP.
///
/// With [coverage] (`test --selfcheck`) the same run is also the one the
/// coverage of the gates is judged on, as `test` judges it: the tracefile is
/// left behind without the entries of the probes, which is the tracefile
/// the command writes without them, and is judged as `lcov` does. The exit
/// code is then 0 only when the controls held and every gate is at 100%.
Future<int> runSelfcheck(
  String dir,
  String? fileOption,
  String? mode,
  List<String> commandOverride,
  Io io, {
  bool coverage = false,
}) async {
  final manifest = readManifest(dir);
  // Before anything can stop the run: what a killed run left behind.
  _removeLeftovers(manifest, io);
  // An empty list of gates is one of the violations.
  if (manifest.violations.isNotEmpty) {
    io.err('$executable selfcheck: test-gates.json has problems');
    for (final violation in manifest.violations) {
      io.err('  - $violation');
    }
    return 1;
  }
  final tracefile = tracefileOf(manifest, fileOption);
  final tracefilePath = resolveInPackage(manifest.dir, tracefile);
  final command = gateCommandOf(manifest, commandOverride);
  final shown = command.join(' ');
  final targets = (mode ?? manifest.settings.selfcheckMode) == 'first'
      ? manifest.gates.take(1).toList()
      : manifest.gates;

  final failures = <String, String>{};
  final injected = <_Injected>[];
  final restoreMessages = <String>[];
  // Read before anything is changed: when this throws, nothing was touched.
  final tracefileBefore = File(tracefilePath).existsSync()
      ? File(tracefilePath).readAsBytesSync()
      : null;
  CommandResult? result;
  String? tracefileText;

  // From here on a signal no longer ends the process: it ends the command,
  // and the code below puts the files back.
  final signals = SignalWatch();
  try {
    try {
      for (final gate in targets) {
        if (!existsExact(manifest.dir, gate.path)) {
          failures[gate.path] =
              'file not found (the check is case-sensitive). '
              'Update test-gates.json if it moved';
          continue;
        }
        try {
          injected.add(_inject(manifest.dir, gate.path));
        } on FileSystemException catch (error) {
          failures[gate.path] =
              'cannot write the probe (${error.osError?.message ?? error.message})';
        }
      }
      if (injected.isNotEmpty && signals.signal == null) {
        deleteTracefile(tracefilePath);
        io.out('running "$shown" with a probe in ${injected.length} gate(s)');
        result = await runCommand(
          command,
          workingDirectory: manifest.dir,
          capture: true,
          signals: signals,
        );
        if (result.exitCode == 0) {
          try {
            tracefileText = readText(tracefilePath);
          } on FileSystemException {
            // Judged below as "no tracefile".
          }
        }
      }
    } finally {
      for (final gate in injected) {
        final message = _restore(gate);
        if (message != null) {
          restoreMessages.add(message);
        }
      }
      // The tracefile of this run counts the probes. Leaving it behind would
      // fail the next `test_gates lcov`. Without [coverage] the one of
      // before the run is put back. With it, this run is the coverage run:
      // its tracefile stays, without the entries of the probes, and when it
      // wrote none, none is left, as after `test`.
      try {
        deleteTracefile(tracefilePath);
        final text = tracefileText;
        if (!coverage) {
          if (tracefileBefore != null) {
            File(tracefilePath).writeAsBytesSync(tracefileBefore);
          }
        } else if (text != null) {
          final resolved = Directory(manifest.dir).resolveSymbolicLinksSync();
          File(tracefilePath).writeAsStringSync(
            tracefileWithoutProbes(
              text,
              [for (final gate in injected) gate.gate],
              rootDirs: [manifest.dir, resolved],
            ),
          );
        }
      } on FileSystemException catch (error) {
        restoreMessages.add(
          '$tracefile: cannot '
          '${coverage ? 'write the tracefile of the run' : 'put back the tracefile of before the run'} '
          '(${error.osError?.message ?? error.message})',
        );
      }
      // Printed here, so that they are not lost when the run ends in an
      // exception.
      for (final message in restoreMessages) {
        io.err('$executable selfcheck: $message');
      }
    }
  } finally {
    await signals.cancel();
  }

  if (signals.signal != null) {
    io.err('$executable selfcheck: interrupted. The gates were put back');
    return signalExitCode(signals.signal!);
  }

  if (result != null) {
    final inconclusive = judgeCoverageRun(
      command: shown,
      exitCode: result.exitCode,
      startError: result.startError,
      tracefileRead: tracefileText != null,
      tracefile: tracefile,
    );
    if (inconclusive != null) {
      io.err('$executable selfcheck: $inconclusive');
      final tail = tailOf(result.output);
      if (tail.trim().isNotEmpty) {
        io.err(tail);
      }
      io.err(
        '$executable selfcheck: FAILED (nothing was measured, '
        '${targets.length} negative control(s))',
      );
      return 1;
    }
    final report = parseTracefile(manifest, tracefileText!);
    final verdict = judgeLcov(
      [for (final gate in injected) gate.gate.path],
      report,
      tracefile: tracefile,
    );
    for (final problem in report.problems) {
      io.err('$executable selfcheck: $tracefile: $problem');
    }
    for (final gate in injected) {
      final reason = report.problems.isNotEmpty
          ? 'the tracefile is unreliable'
          : judgeProbe(gate.gate, report, verdict);
      if (reason != null) {
        failures[gate.gate.path] = reason;
      }
    }
  }

  for (final gate in targets) {
    final reason = failures[gate.path];
    if (reason == null) {
      final line = injected
          .firstWhere((entry) => entry.gate.path == gate.path)
          .gate
          .line;
      io.out(
        '  ✓ ${gate.path}: with unexecuted code at line $line the gate fails',
      );
    } else {
      io.err('  ✗ ${gate.path}: $reason');
    }
  }
  final held = failures.isEmpty && restoreMessages.isEmpty;
  if (held) {
    io.out(
      '$executable selfcheck: OK (${targets.length} negative control(s) '
      'failed as they should)',
    );
  } else {
    io.err(
      '$executable selfcheck: FAILED (${failures.length} of ${targets.length} '
      'negative control(s))',
    );
  }
  if (!coverage) {
    return held ? 0 : 1;
  }
  // The same run, judged as `test` judges it. When nothing was measured
  // there is no tracefile, and that was said above.
  if (!File(tracefilePath).existsSync()) {
    return 1;
  }
  final covered = judgeTracefile(manifest, tracefile, io);
  return held && covered == 0 ? 0 : 1;
}
