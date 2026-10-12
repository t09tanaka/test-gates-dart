import 'dart:convert';
import 'dart:io';

import '../args.dart';
import '../gate_path.dart';
import '../io/files.dart';
import '../io/process.dart';
import '../mutation_run.dart';
import '../spec_path.dart';
import '../types.dart';
import 'lcov.dart';
import 'mutation_result.dart';
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
/// the version it gave; `null` when none does.
Future<({List<String> command, String version})?> _findDartMutant(
  List<List<String>> candidates,
  String dir,
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
    } on ProcessException {
      continue;
    }
    final version = dartMutantVersionOf(
      result.exitCode,
      result.stdout as String,
    );
    if (version != null) {
      return (command: command, version: version);
    }
  }
  return null;
}

/// Mutation test of the gates. The mutants are made and run by `dart_mutant`,
/// which is started as a program of its own; this command tells it which
/// files and tests (the gates of test-gates.json, as a plan file) and judges
/// the report it writes as `mutation-result` does.
///
/// [rest] (what follows `--`) is handed to `dart_mutant run` as it is.
/// [force] becomes its `--force`, and [only] (`--gate`) its `--only`.
///
/// [candidates] are the commands that are tried to start the tool. It is a
/// parameter for the tests of this package only; the command line always
/// uses [dartMutantCommands].
///
/// Returns the exit code: 0 when every mutant is detected or allowed, 1
/// otherwise, 2 when the tool is missing, is not a supported version or
/// refuses its command line, 130 / 143 / 129 when interrupted.
Future<int> runMutation(
  String dir,
  String? reportOption,
  List<String> rest,
  Io io, {
  bool force = false,
  List<String> only = const [],
  List<List<String>>? candidates,
}) async {
  final manifest = readManifest(dir);
  // Wrong usage changes nothing and starts nothing.
  final selected = selectedGatesOf(manifest, only);
  final problem = passThroughProblem(rest);
  if (problem != null) {
    throw UsageError(problem);
  }

  final tried = candidates ?? dartMutantCommands(Platform.resolvedExecutable);
  final found = await _findDartMutant(tried, manifest.dir);
  if (found == null) {
    io.err(
      '$executable mutation: $dartMutant was not found (tried '
      '${tried.map((command) => '"${command.join(' ')}"').join(' and ')}). '
      'It is the tool that makes the mutants and runs the tests on them. '
      'Install it with:',
    );
    io.err('  $dartMutantInstall');
    return 2;
  }
  if (!isSupportedDartMutant(found.version)) {
    io.err(
      '$executable mutation: $dartMutant ${found.version} '
      '("${found.command.join(' ')}") is not a version this $executable '
      'works with (${dartMutantRange()}). Install one that is:',
    );
    io.err("  $dartMutantInstall '${dartMutantConstraint()}'");
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

  // A report of an earlier run must not be judged if this run writes none.
  // With --gate that holds for the gates of this run; what the report says
  // about the other gates is kept.
  final existing = _readOrNull(reportPath);
  if (existing != null) {
    final left = selected == null ? null : reportWithout(existing, selected);
    if (left == null) {
      File(reportPath).deleteSync();
    } else {
      File(reportPath).writeAsStringSync(left);
    }
  }

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

  int? toolExitCode;
  if (targets.isNotEmpty) {
    final plan = File(_inPackage(manifest.dir, planFile));
    plan.parent.createSync(recursive: true);
    plan.writeAsStringSync(jsonEncode(buildPlan(targets)));
    final command = [
      ...found.command,
      ...dartMutantArguments(
        dir: manifest.dir,
        plan: plan.path,
        report: reportPath,
        force: force,
        only: selected == null ? null : planned,
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
      );
    } finally {
      await signals.cancel();
    }
    if (result.signal != null) {
      io.err('$executable mutation: interrupted. Nothing was judged');
      return signalExitCode(result.signal!);
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
  );
}
