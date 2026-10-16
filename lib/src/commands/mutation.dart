import 'dart:convert';
import 'dart:io';

import '../args.dart';
import '../gate_path.dart';
import '../import_policy.dart';
import '../io/files.dart';
import '../io/process.dart';
import '../mutation_reuse.dart';
import '../mutation_run.dart';
import '../spec_path.dart';
import '../types.dart';
import 'lcov.dart';
import 'mutation_result.dart';
import 'mutation_reuse.dart';
import 'output.dart';

String _inPackage(String dir, String relativePath) =>
    '$dir${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}';

String? _readOrNull(String path) {
  try {
    return readText(path);
  } on FileSystemException {
    return null;
  }
}

/// The first of [candidates] that answers `--version` as the tool does, with
/// the version it gave; `null` when none does. What each of the others did
/// is added to [attempts].
Future<_Found?> _findDartMutant(
  List<List<String>> candidates,
  String dir,
  List<String> attempts,
) async {
  for (final command in candidates) {
    final ProcessResult result;
    try {
      result = await Process.run(
        command.first,
        [...command.sublist(1), '--version'],
        workingDirectory: dir,
        runInShell: Platform.isWindows,
      );
    } on ProcessException catch (error) {
      attempts.add(describeAttempt(command, startError: error.message));
      continue;
    }
    final version = dartMutantVersionOf(
      result.exitCode,
      result.stdout as String,
    );
    if (version != null) {
      return (command: command, version: version);
    }
    attempts.add(
      describeAttempt(
        command,
        exitCode: result.exitCode,
        output: '${result.stdout}\n${result.stderr}',
      ),
    );
  }
  return null;
}

typedef _Found = ({List<String> command, String version});

/// The lines that say how a tool the user installed is used instead.
void _printByHand(Io io) {
  io.err(
    '$executable mutation: to use one you installed yourself, install it '
    'and set $dartMutantVariable to the path of its executable '
    '(~/.pub-cache/bin/$dartMutant):',
  );
  io.err('  ${dartMutantInstall()}');
}

/// Fetches the tool into [target] with [command], which is run in [dir]
/// with `PUB_CACHE` set to a temporary directory: only the compiled program
/// is kept. It is written next to [target] and moved there, so a run that
/// starts the tool at the same moment reads the old file or the new one,
/// never half of one.
///
/// Returns `null` when [target] was written, else the exit code of
/// `mutation`, which has been told why.
Future<int?> _fetchDartMutant(
  List<String> command,
  String dir,
  File target,
  Io io,
) async {
  final cache = Directory.systemTemp.createTempSync('test_gates_dart_mutant_');
  try {
    final signals = SignalWatch();
    final CommandResult result;
    try {
      result = await runCommand(
        command,
        workingDirectory: dir,
        capture: true,
        signals: signals,
        environment: {'PUB_CACHE': cache.path},
      );
    } finally {
      await signals.cancel();
    }
    if (result.signal != null) {
      io.err('$executable mutation: interrupted. Nothing was judged');
      return signalExitCode(result.signal!);
    }
    final shown = '"${command.join(' ')}"';
    String? problem;
    if (result.exitCode == null) {
      problem = '$shown could not be started (${result.startError})';
    } else if (result.exitCode != 0) {
      problem = '$shown ended with exit code ${result.exitCode}';
    } else {
      final built = Directory(
        '${cache.path}/$fetchedSnapshotDirectory',
      ).absolute;
      final snapshots = built.existsSync()
          ? [
              for (final file in built.listSync().whereType<File>())
                if (isFetchedSnapshot(file.uri.pathSegments.last)) file,
            ]
          : const <File>[];
      if (snapshots.isEmpty) {
        problem = '$shown did not compile it';
      } else {
        try {
          target.parent.createSync(recursive: true);
          final part = '${target.path}.$pid.tmp';
          snapshots.first.copySync(part);
          File(part).renameSync(target.path);
        } on FileSystemException catch (error) {
          problem = '${target.path} cannot be written (${error.message})';
        }
      }
    }
    if (problem == null) {
      return null;
    }
    io.err(
      '$executable mutation: $dartMutant ${dartMutantConstraint()} could '
      'not be fetched from pub.dev: $problem',
    );
    for (final line in lastLines(result.output)) {
      io.err('    $line');
    }
    _printByHand(io);
    return 2;
  } finally {
    cache.deleteSync(recursive: true);
  }
}

/// The tool that `mutation` keeps for the package in [dir]: the one that
/// was fetched by an earlier run when it is there and answers with a
/// supported version, else one that is fetched now with [fetch]. What is
/// there and does not answer (the SDK is another one, the file is damaged)
/// or is another version is replaced.
///
/// Returns the tool, or the exit code of `mutation`, which has been told
/// why.
Future<({_Found? found, int? exitCode})> _keptDartMutant(
  List<String> fetch,
  String dart,
  String dir,
  Io io,
) async {
  final place = dartMutantSnapshot().replaceAll('/', Platform.pathSeparator);
  final target = File(_inPackage(dir, dartMutantSnapshot()));
  // Relative to the package: that is where the tool is started.
  final command = dartMutantCommand(dart, place);
  if (target.existsSync()) {
    final kept = await _findDartMutant([command], dir, []);
    if (kept != null && isSupportedDartMutant(kept.version)) {
      return (found: kept, exitCode: null);
    }
  }
  io.out(
    '$executable mutation: fetching $dartMutant ${dartMutantConstraint()} '
    'from pub.dev into $place (once per package)',
  );
  final failed = await _fetchDartMutant(fetch, dir, target, io);
  if (failed != null) {
    return (found: null, exitCode: failed);
  }
  final attempts = <String>[];
  final fetched = await _findDartMutant([command], dir, attempts);
  if (fetched == null) {
    io.err(
      '$executable mutation: $dartMutant was fetched into $place, and does '
      'not answer as the tool does: ${attempts.single}',
    );
    _printByHand(io);
    return (found: null, exitCode: 2);
  }
  return (found: fetched, exitCode: null);
}

/// Mutation test of the gates. The mutants are made and run by `dart_mutant`,
/// which is started as a program of its own; this command tells it which
/// files and tests (the gates of test-gates.json, as a plan file) and judges
/// the report it writes as `mutation-result` does.
///
/// [rest] (what follows `--`) is handed to `dart_mutant run` as it is.
/// [force] becomes its `--force`, and [only] (`--gate`) its `--only`.
///
/// The tool is the one that [environment] names ([dartMutantVariable]), or
/// else one that is kept below `.dart_tool` of the package and fetched from
/// pub.dev when it is not there yet. What is on PATH is not looked at.
///
/// [candidates] are commands that are tried to start the tool instead,
/// [fetch] is the command that fetches it, and [grace] is how long the tool
/// gets to end after a signal. They are parameters for the tests of this
/// package only; the command line always uses [dartMutantFetch] and
/// [handOverGrace], and the environment of the process.
///
/// Returns the exit code: 0 when every mutant is detected or allowed, 1
/// otherwise, 2 when the tool cannot be fetched, is not a supported version
/// or refuses its command line, 130 / 143 / 129 when interrupted.
Future<int> runMutation(
  String dir,
  String? reportOption,
  List<String> rest,
  Io io, {
  bool force = false,
  List<String> only = const [],
  bool listNotEvaluable = false,
  List<List<String>>? candidates,
  List<String>? fetch,
  Map<String, String>? environment,
  bool? ci,
  Duration grace = handOverGrace,
}) async {
  final manifest = readManifest(dir);
  // Wrong usage changes nothing and starts nothing.
  final selected = selectedGatesOf(manifest, only);
  final problem = passThroughProblem(rest);
  if (problem != null) {
    throw UsageError(problem);
  }

  final named = namedDartMutant(environment ?? Platform.environment);
  final tried =
      candidates ??
      [
        if (named != null) [named],
      ];
  final _Found found;
  if (tried.isNotEmpty) {
    final attempts = <String>[];
    final answered = await _findDartMutant(tried, manifest.dir, attempts);
    if (answered == null) {
      io.err(
        candidates == null
            ? '$executable mutation: $dartMutantVariable names "$named", '
                  'and that is not $dartMutant, the tool that makes the '
                  'mutants and runs the tests on them. Without the variable '
                  'the tool is fetched from pub.dev. To install it '
                  'yourself:'
            : '$executable mutation: $dartMutant was not found. It is the '
                  'tool that makes the mutants and runs the tests on them. '
                  'Install it with:',
      );
      io.err('  ${dartMutantInstall()}');
      io.err('What was tried:');
      for (final attempt in attempts) {
        io.err('  - $attempt');
      }
      return 2;
    }
    found = answered;
  } else {
    final dart = dartOf(Platform.resolvedExecutable);
    final kept = await _keptDartMutant(
      fetch ?? dartMutantFetch(dart),
      dart,
      manifest.dir,
      io,
    );
    if (kept.found == null) {
      return kept.exitCode!;
    }
    found = kept.found!;
  }
  if (!isSupportedDartMutant(found.version)) {
    io.err(
      '$executable mutation: $dartMutant ${found.version} '
      '("${found.command.join(' ')}") is not a version this $executable '
      'works with (${dartMutantRange()}). Install one that is:',
    );
    io.err('  ${dartMutantInstall()}');
    return 2;
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
  final reportPath = File(
    resolveInPackage(manifest.dir, reportFile),
  ).absolute.path;
  final gates = selected ?? [for (final gate in manifest.gates) gate.path];

  // The gates the tool can be given, each with its tests, and why the
  // others cannot be mutation tested.
  final failures = <String, String>{};
  final targets = <({String file, List<String> tests})>[];
  for (final path in gates) {
    if (!isPlainRelativePath(path) || !existsExact(manifest.dir, path)) {
      failures[path] =
          'file not found (the check is case-sensitive). '
          'Update test-gates.json if it moved';
      continue;
    }
    final places = specCandidatesFor(path, manifest.settings);
    final specs = [
      for (final candidate in places)
        if (existsExact(manifest.dir, candidate)) candidate,
    ];
    if (specs.isEmpty) {
      failures[path] = places.isEmpty
          ? 'no test is known for this gate: settings.spec.suffixes is '
                'empty. The mutation test runs the test of each gate'
          : 'no test found (looked for ${places.join(', ')}). '
                'The mutation test runs the test of each gate; see '
                'settings.spec';
      continue;
    }
    targets.add((file: path, tests: specs));
  }
  final planned = [for (final target in targets) target.file];
  final part = asksForPart(rest);

  // Which gates keep the results of the last run, and why the others do
  // not. The tool is then told to run every mutant of the gates that do not
  // (--force with --only), and its own reuse of the results of a file is
  // left to the run in which nothing changed.
  final existing = _readOrNull(reportPath);
  final reportText = existing != null && isReport(existing) ? existing : null;
  final ReuseInputs? inputs;
  final ReusePlan? reuse;
  if (targets.isEmpty) {
    inputs = null;
    reuse = null;
  } else {
    final variables = environment ?? Platform.environment;
    final inCi = ci ?? (variables['CI'] ?? '').isNotEmpty;
    inputs = readReuseInputs(
      manifest.dir,
      targets,
      aliases: aliasesFor(
        packageNameIn(manifest.dir),
        manifest.settings.importAliases,
      ),
      dartMutantVersion: found.version,
      rest: rest,
      reportFile: reportFile,
      reportText: reportText,
    );
    reuse = planReuse(
      forced: force
          ? '--force'
          : part
          ? 'a part of a run (--shard)'
          : inCi
          ? 'CI is set'
          : null,
      problem: inputs.problem,
      recordText: inputs.recordText,
      context: inputs.context,
      report: inputs.report,
      timedOut: inputs.timedOut,
      gates: inputs.gates,
    );
    // The lines below the first say which gates, and are indented.
    for (final line in describeReuse(reuse)) {
      io.out(line.startsWith(' ') ? line : '$executable mutation: $line');
    }
  }
  final rerun = <String>[
    for (final entry in reuse?.rerun ?? const <({String gate, String why})>[])
      entry.gate,
  ];
  final runAll = reuse == null || reuse.full != null;

  // A report of an earlier run must not be judged if this run writes none.
  // That holds for the gates of this run: what the report says about the
  // other gates (with --gate), and about the gates whose results are reused,
  // is kept.
  // A file of another kind is left alone: the tool refuses to replace it,
  // and what it holds cannot pass for a result.
  if (reportText != null) {
    final cleared = rerun.isNotEmpty ? rerun : selected;
    final left = cleared == null ? null : reportWithout(reportText, cleared);
    if (left == null) {
      File(reportPath).deleteSync();
    } else {
      File(reportPath).writeAsStringSync(left);
    }
  }

  int? toolExitCode;
  if (targets.isNotEmpty) {
    final plan = File(_inPackage(manifest.dir, planFile));
    plan.parent.createSync(recursive: true);
    plan.writeAsStringSync(jsonEncode(buildPlan(targets)));
    // A run that does not end as it should leaves no record.
    deleteRecord(manifest.dir);
    final command = [
      ...found.command,
      ...dartMutantArguments(
        dir: manifest.dir,
        plan: plan.path,
        report: reportPath,
        force: runAll || rerun.isNotEmpty,
        only: rerun.isNotEmpty
            ? rerun
            : selected == null
            ? null
            : planned,
        rest: rest,
      ),
    ];

    // From here on a signal no longer ends this process: it is handed to
    // the tool, which puts the files back, and waited for.
    final signals = SignalWatch();
    final CommandResult result;
    try {
      result = await runCommand(
        command,
        workingDirectory: manifest.dir,
        capture: false,
        signals: signals,
        handOver: true,
        grace: grace,
      );
    } finally {
      await signals.cancel();
    }
    final signal = result.signal ?? signals.signal;
    if (signal != null) {
      if (result.killed) {
        io.err(
          '$executable mutation: $dartMutant did not end within '
          '${grace.inSeconds} seconds of the signal and was killed. It may '
          'not have put back what it changed: look at "git status" for a '
          'gate with a mutant in it',
        );
      }
      io.err('$executable mutation: interrupted. Nothing was judged');
      return signalExitCode(signal);
    }
    if (result.exitCode == null) {
      io.err(
        '$executable mutation: cannot start "${found.command.join(' ')}" '
        '(${result.startError})',
      );
      return 1;
    }
    toolExitCode = result.exitCode;
    final unjudged = exitCodeWithoutVerdict(result.exitCode!);
    if (unjudged != null) {
      io.err(
        '$executable mutation: $dartMutant ended with exit code $unjudged. '
        'Nothing was judged',
      );
      return unjudged;
    }
  }

  // What the tool left out, or did not get to: it has said why.
  final written = _readOrNull(reportPath);
  for (final path in missingFromReport(written, planned)) {
    failures[path] =
        '$dartMutant wrote no result for this gate (exit code '
        '$toolExitCode). What it printed says why';
  }
  if (toolExitCode == 1 && !explainsFailure(written, planned)) {
    io.err(
      '$executable mutation: $dartMutant failed (exit code 1), and its '
      'report does not show why: no mutant of these gates survived and none '
      'is missing. What it printed says what went wrong',
    );
    io.err('$executable mutation: FAILED (the run did not end as it should)');
    return 1;
  }

  // What the next run can reuse.
  if (inputs != null && !part && written != null && isReport(written)) {
    final missing = missingFromReport(written, planned);
    writeRecord(manifest.dir, inputs, written, [
      for (final path in planned)
        if (!missing.contains(path)) path,
    ]);
  }

  if (part) {
    if (failures.isNotEmpty) {
      printViolations(io, 'mutation', [
        for (final MapEntry(key: path, value: reason) in failures.entries)
          Violation(file: path, message: reason),
      ]);
      io.err('$executable mutation: FAILED (a part of a run, not judged)');
      return 1;
    }
    io.out(
      '$executable mutation: a part of a run (--shard) was written to '
      '$reportFile. It is not judged: put the parts together with '
      '"$dartMutant merge" and judge the result with '
      '"$executable mutation-result"',
    );
    return 0;
  }

  if (written == null && failures.length == gates.length) {
    // Nothing could be run, so there is no report to read.
    printViolations(io, 'mutation', [
      for (final MapEntry(key: path, value: reason) in failures.entries)
        Violation(file: path, message: reason),
    ]);
    io.err('$executable mutation: FAILED (nothing was mutation tested)');
    return 1;
  }
  return judgeReportFile(
    manifest,
    reportFile,
    io,
    gateFailures: failures,
    only: selected,
    listNotEvaluable: listNotEvaluable,
  );
}
