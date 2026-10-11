import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../gate_path.dart';
import '../io/files.dart';
import '../io/process.dart';
import '../json.dart';
import '../mutation_run.dart';
import '../mutators.dart';
import '../spec_path.dart';
import 'lcov.dart';
import 'mutation_result.dart';
import 'output.dart';

/// Where a run keeps what must survive it, below the package. `.dart_tool` is
/// ignored by git in every Dart project.
const mutationStateDir = '.dart_tool/test_gates/mutation';

final _separator = Platform.pathSeparator;

String _native(String path) => path.replaceAll('/', _separator);

String _inPackage(String dir, String relativePath) =>
    '$dir$_separator${_native(relativePath)}';

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

String _reason(FileSystemException error) =>
    error.osError?.message ?? error.message;

/// The files of a run below [mutationStateDir].
class _State {
  _State(String dir) : root = _inPackage(dir, mutationStateDir);

  final String root;

  Directory get backups => Directory('$root${_separator}backup');

  /// The copy of a gate as it was before the run changed it.
  File backupOf(String gatePath) =>
      File('${backups.path}$_separator${_native(gatePath)}');

  File get incremental => File('$root${_separator}incremental.json');

  File get _staging => File('$root${_separator}staging');

  /// Gives [target] the content [bytes] in one step: the file is written
  /// next to the backups and renamed over the gate, so the gate is never
  /// half-written, whenever the process dies.
  void put(File target, List<int> bytes) {
    _staging.parent.createSync(recursive: true);
    _staging.writeAsBytesSync(bytes, flush: true);
    _staging.renameSync(target.path);
  }

  void removeStaging() {
    if (_staging.existsSync()) {
      _staging.deleteSync();
    }
  }
}

/// A gate while a mutant may be in it.
class _Active {
  _Active(this.path, this.file, this.original, this.backup);

  final String path;
  final File file;
  final Uint8List original;
  final File backup;

  /// What the run wrote last, when it is not [original].
  List<int>? written;
}

/// Puts back the gates that a killed run (SIGKILL, power loss) left with a
/// mutant in them. Returns what could not be put back.
List<String> _recover(String dir, _State state, Io io) {
  final problems = <String>[];
  state.removeStaging();
  if (!state.backups.existsSync()) {
    return problems;
  }
  final prefix = '${state.backups.path}$_separator';
  for (final entity in state.backups.listSync(recursive: true)) {
    if (entity is! File) {
      continue;
    }
    final path = entity.path.substring(prefix.length).replaceAll(r'\', '/');
    final gate = File(_inPackage(dir, path));
    final kept =
        'The content of before that run is in '
        '$mutationStateDir/backup/$path; delete that file when you have '
        'compared the two';
    try {
      final original = entity.readAsBytesSync();
      if (!gate.existsSync()) {
        problems.add(
          '$path: an interrupted run left a backup of this file, and the file '
          'is gone. $kept',
        );
        continue;
      }
      final current = gate.readAsBytesSync();
      if (_sameBytes(original, current)) {
        entity.deleteSync();
        continue;
      }
      if (isLeftoverOf(
        utf8.decode(original, allowMalformed: true),
        utf8.decode(current, allowMalformed: true),
      )) {
        state.put(File(gate.resolveSymbolicLinksSync()), original);
        entity.deleteSync();
        io.err(
          '$executable mutation: put back $path, which an interrupted run '
          'left with a mutant in it',
        );
        continue;
      }
      problems.add(
        '$path: an interrupted run left a mutant in this file, and the file '
        'was changed since. It was left as it is. $kept',
      );
    } on FileSystemException catch (error) {
      problems.add(
        '$path: cannot put back the file of before an interrupted run '
        '(${_reason(error)}). $kept',
      );
    }
  }
  return problems;
}

/// Takes the mutant out of [active]. Returns a message when the file is not
/// as this run left it; the backup is then kept.
String? _restore(_Active active, _State state) {
  final written = active.written;
  if (written == null) {
    return null;
  }
  final kept =
      'The content of before the run is in '
      '$mutationStateDir/backup/${active.path}';
  try {
    final current = active.file.readAsBytesSync();
    if (_sameBytes(current, written)) {
      state.put(active.file, active.original);
      active.written = null;
      return null;
    }
    if (_sameBytes(current, active.original)) {
      active.written = null;
      return null;
    }
    return '${active.path} changed during the run. It was left as it is, '
        'possibly with a mutant in it. $kept';
  } on FileSystemException catch (error) {
    return '${active.path}: CANNOT TAKE THE MUTANT OUT (${_reason(error)}). '
        '$kept';
  }
}

JsonObject _readIncremental(_State state) {
  try {
    final decoded = jsonDecode(state.incremental.readAsStringSync());
    return asObject(asObject(decoded)?['gates']) ?? {};
  } on FileSystemException {
    return {};
  } on FormatException {
    return {};
  }
}

void _writeIncremental(_State state, JsonObject gates) {
  state.incremental.parent.createSync(recursive: true);
  state.incremental.writeAsStringSync(jsonEncode({'gates': gates}));
}

void _writeReport(String path, Map<String, GateRun> runs, JsonObject others) {
  File(path).parent.createSync(recursive: true);
  File(path).writeAsStringSync(
    const JsonEncoder.withIndent(
      '  ',
    ).convert(buildReport(runs, others: others)),
  );
}

String _seconds(int milliseconds) => (milliseconds / 1000).toStringAsFixed(1);

String _gateLine(String path, GateRun run, int ran, int milliseconds) {
  int count(String status) =>
      run.statuses.where((value) => value == status).length;
  final reused = run.statuses.length - ran;
  return '  $path: ${run.statuses.length} mutants / killed ${count('Killed')} '
      '/ survived ${count('Survived')} / timeout ${count('Timeout')} '
      '/ compile error ${count('CompileError')} '
      '(${reused == 0 ? '' : '$reused from the last run, '}'
      '${_seconds(milliseconds)}s)';
}

/// Mutation test of the gates. For each gate: the mutants are made from its
/// syntax tree, each is put in the file, and the tests of the gate are run on
/// it. The report is then judged as `mutation-result` does.
///
/// The gates are changed in place, one mutant at a time, and put back after
/// every mutant, on an error and on SIGINT / SIGTERM / SIGHUP. What a killed
/// run leaves behind is put back by the next run.
///
/// A gate whose source, tests, test command and tool version are those of an
/// earlier run is not run again unless [force] is set.
///
/// [limitOf] gives the time the test run of one mutant may take, from the
/// time of the run without a mutant. It is a parameter for the tests of this
/// package only; the command line always uses [processLimit].
///
/// Returns the exit code: 0 when every mutant is detected or allowed, 1
/// otherwise, 130 / 143 / 129 when interrupted.
Future<int> runMutation(
  String dir,
  String? reportOption,
  List<String> commandOverride,
  Io io, {
  bool force = false,
  List<String> only = const [],
  Duration Function(Duration baseline) limitOf = processLimit,
}) async {
  final manifest = readManifest(dir);
  // Wrong usage (--gate with a path that is not a gate) changes nothing.
  final selected = selectedGatesOf(manifest, only);
  final state = _State(manifest.dir);
  // Before anything else can stop the run: what a killed run left behind.
  final leftovers = _recover(manifest.dir, state, io);
  if (leftovers.isNotEmpty) {
    for (final problem in leftovers) {
      io.err('$executable mutation: $problem');
    }
    io.err('$executable mutation: FAILED (nothing was run)');
    return 1;
  }
  // An empty list of gates is one of the violations.
  if (manifest.violations.isNotEmpty) {
    io.err('$executable mutation: test-gates.json has problems');
    for (final violation in manifest.violations) {
      io.err('  - $violation');
    }
    return 1;
  }

  final reportFile = reportFileOf(manifest, reportOption);
  final reportPath = resolveInPackage(manifest.dir, reportFile);
  // A report of an earlier run must not be judged if this run writes none.
  // With --gate that holds for the gates of this run; what the report says
  // about the other gates is kept.
  JsonObject others = {};
  if (File(reportPath).existsSync()) {
    if (selected != null) {
      try {
        others = otherReportFiles(readText(reportPath), selected);
      } on FileSystemException {
        // Not readable: nothing is kept.
      }
    }
    if (others.isEmpty) {
      File(reportPath).deleteSync();
    } else {
      _writeReport(reportPath, const {}, others);
    }
  }

  var flutter = false;
  try {
    flutter = usesFlutter(readText(_inPackage(manifest.dir, 'pubspec.yaml')));
  } on FileSystemException {
    // No pubspec: `dart test` says what is wrong.
  }
  final command = testCommandFor(flutter: flutter, override: commandOverride);
  final shown = command.join(' ');
  // With --force nothing of the last run is reused, but what it found for
  // the gates that this run leaves out (--gate) stays in the file.
  final carried = carriedResults(
    _readIncremental(state),
    force: force,
    selected: selected,
  );
  final incremental = force ? <String, Object?>{} : carried;
  if (force) {
    // Now, not after the first gate: a run that is stopped before it has a
    // result must not leave the old one to be reused.
    _writeIncremental(state, carried);
  }
  final kept = <String, Object?>{};

  final runs = <String, GateRun>{};
  final failures = <String, String>{};
  String? aborted;

  // From here on a signal no longer ends the process: it ends the test run,
  // and the code below puts the gate back.
  final signals = SignalWatch();
  try {
    for (final gate in manifest.gates) {
      if (selected != null && !selected.contains(gate.path)) {
        continue;
      }
      if (signals.signal != null || aborted != null) {
        break;
      }
      final path = gate.path;
      if (!isPlainRelativePath(path) || !existsExact(manifest.dir, path)) {
        failures[path] =
            'file not found (the check is case-sensitive). '
            'Update test-gates.json if it moved';
        continue;
      }
      final candidates = specCandidatesFor(path, manifest.settings);
      final specs = [
        for (final candidate in candidates)
          if (existsExact(manifest.dir, candidate)) candidate,
      ];
      if (specs.isEmpty) {
        failures[path] = candidates.isEmpty
            ? 'no test is known for this gate: settings.spec.suffixes is '
                  'empty. The mutation test runs the test of each gate'
            : 'no test found (looked for ${candidates.join(', ')}). '
                  'The mutation test runs the test of each gate; see '
                  'settings.spec';
        continue;
      }

      final File file;
      final Uint8List original;
      final String source;
      final Map<String, String> specTexts;
      try {
        file = File(
          File(_inPackage(manifest.dir, path)).resolveSymbolicLinksSync(),
        );
        original = file.readAsBytesSync();
        specTexts = {
          for (final spec in specs)
            spec: readText(_inPackage(manifest.dir, spec)),
        };
      } on FileSystemException catch (error) {
        failures[path] = 'cannot read the gate or its test (${_reason(error)})';
        continue;
      }
      try {
        // The decoder drops a byte order mark; the file keeps it.
        final text = utf8.decode(original);
        final hasMark =
            original.length >= 3 &&
            original[0] == 0xEF &&
            original[1] == 0xBB &&
            original[2] == 0xBF;
        source = hasMark && !text.startsWith('\uFEFF') ? '\uFEFF$text' : text;
      } on FormatException {
        failures[path] = 'is not valid UTF-8, so it cannot be written back';
        continue;
      }
      final found = findMutants(source);
      if (found.syntaxErrors) {
        failures[path] = 'cannot be read as Dart (syntax error)';
        continue;
      }
      final mutants = found.mutants;
      if (mutants.isEmpty) {
        failures[path] =
            'nothing in this file can be mutated. A gate holds a decision';
        continue;
      }

      final input = GateInput(
        source: source,
        specs: specTexts,
        command: command,
      );
      final statuses =
          reusableStatuses(incremental[path], input, mutants.length) ??
          List<String?>.filled(mutants.length, null);
      final milliseconds = List<int>.filled(mutants.length, 0);
      final pending = [
        for (var index = 0; index < mutants.length; index++)
          if (statuses[index] == null) index,
      ];
      final watch = Stopwatch()..start();

      if (pending.isNotEmpty) {
        final run = mutantCommand(command, specs);
        io.out(
          '  $path: ${pending.length} of ${mutants.length} mutant(s) with '
          '"${run.join(' ')}"',
        );
        final baselineWatch = Stopwatch()..start();
        final baseline = await runCommand(
          run,
          workingDirectory: manifest.dir,
          capture: true,
          signals: signals,
          timeout: baselineLimit,
        );
        if (baseline.signal != null) {
          break;
        }
        if (baseline.exitCode == null && !baseline.timedOut) {
          aborted = 'cannot start "$shown" (${baseline.startError})';
          break;
        }
        if (baseline.exitCode != 0) {
          failures[path] = baseline.timedOut
              ? 'the tests did not end within '
                    '${baselineLimit.inMinutes} minutes without a mutant. '
                    'Nothing was measured'
              : 'the tests fail without a mutant (exit ${baseline.exitCode}; '
                    'a test gets ${perTestTimeoutSeconds}s). '
                    'Nothing was measured';
          final tail = tailOf(baseline.output);
          if (tail.trim().isNotEmpty) {
            io.err(tail);
          }
          continue;
        }
        final limit = limitOf(baselineWatch.elapsed);

        final active = _Active(path, file, original, state.backupOf(path));
        try {
          try {
            // The run without a mutant took a while: the gate may have been
            // saved since it was read.
            if (!_sameBytes(file.readAsBytesSync(), original)) {
              aborted =
                  '$path changed while its tests ran. Nothing was written '
                  'to it; run again';
            }
            active.backup.parent.createSync(recursive: true);
            active.backup.writeAsBytesSync(original, flush: true);
            for (final index in aborted == null ? pending : const <int>[]) {
              final mutantWatch = Stopwatch()..start();
              final bytes = utf8.encode(mutants[index].applyTo(source));
              active.written = bytes;
              state.put(file, bytes);
              final result = await runCommand(
                run,
                workingDirectory: manifest.dir,
                capture: true,
                signals: signals,
                timeout: limit,
              );
              final problem = _restore(active, state);
              if (problem != null) {
                aborted = problem;
                break;
              }
              if (result.signal != null || signals.signal != null) {
                break;
              }
              if (result.exitCode == null && !result.timedOut) {
                aborted = 'cannot start "$shown" (${result.startError})';
                break;
              }
              statuses[index] = classifyRun(
                exitCode: result.exitCode,
                output: result.output,
                timedOut: result.timedOut,
              );
              milliseconds[index] = mutantWatch.elapsedMilliseconds;
            }
          } finally {
            // Also when the loop ended in an exception.
            final problem = _restore(active, state);
            if (problem != null) {
              aborted ??= problem;
            } else if (active.backup.existsSync()) {
              active.backup.deleteSync();
            }
          }
        } on FileSystemException catch (error) {
          aborted ??= '$path: cannot write the mutant (${_reason(error)})';
        }
        if (signals.signal != null || aborted != null) {
          break;
        }
      }

      final run = GateRun(
        source: source,
        mutants: mutants,
        statuses: [for (final status in statuses) status!],
        milliseconds: milliseconds,
      );
      runs[path] = run;
      kept[path] = incrementalEntry(input, run.statuses);
      _writeIncremental(state, {...carried, ...kept});
      io.out(_gateLine(path, run, pending.length, watch.elapsedMilliseconds));
    }
  } finally {
    await signals.cancel();
  }

  if (signals.signal != null) {
    io.err(
      '$executable mutation: interrupted. '
      '${aborted ?? 'The gates were put back'}',
    );
    return signalExitCode(signals.signal!);
  }
  if (aborted != null) {
    io.err('$executable mutation: $aborted');
    io.err('$executable mutation: FAILED (the run was stopped)');
    return 1;
  }

  _writeReport(reportPath, runs, others);
  return judgeReportFile(
    manifest,
    reportFile,
    io,
    gateFailures: failures,
    only: selected,
  );
}
