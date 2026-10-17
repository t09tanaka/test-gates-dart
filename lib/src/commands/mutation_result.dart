import 'dart:convert';
import 'dart:io';

import '../args.dart';
import '../io/files.dart';
import '../mutation_result.dart';
import '../mutation_run.dart';
import '../types.dart';
import 'lcov.dart';
import 'output.dart';

/// The report a command works on: `--report`, or `settings.stryker.reportFile`
/// (default `reports/mutation/mutation.json`).
String reportFileOf(LoadedManifest manifest, String? reportOption) =>
    reportOption ?? manifest.settings.reportFile;

/// Judges an existing mutation report without running anything.
///
/// Returns the exit code: 0 when every mutant is detected or allowed, 1
/// otherwise or when the report cannot be read. Throws `ManifestError` (exit
/// code 2) when the manifest is unusable.
///
/// [only] limits the judgement to these gates (`--gate`); empty means every
/// gate. Throws [UsageError] (exit code 2) for a path that is not a gate.
int runMutationResult(
  String dir,
  String? reportOption,
  Io io, {
  List<String> only = const [],
  bool listNotEvaluable = false,
}) {
  final manifest = readManifest(dir);
  return judgeReportFile(
    manifest,
    reportFileOf(manifest, reportOption),
    io,
    only: selectedGatesOf(manifest, only),
    listNotEvaluable: listNotEvaluable,
  );
}

/// The gates `--gate` limits a command to, or `null` when it was not given.
/// Throws [UsageError] for a path that is not in test-gates.json: a typo
/// must not turn into a run that tests nothing.
List<String>? selectedGatesOf(LoadedManifest manifest, List<String> requested) {
  if (requested.isEmpty) {
    return null;
  }
  final selection = selectGates([
    for (final gate in manifest.gates) gate.path,
  ], requested);
  if (selection.unknown.isNotEmpty) {
    throw UsageError(
      '--gate: not a gate of test-gates.json: ${selection.unknown.join(', ')}',
    );
  }
  return selection.selected;
}

/// The judgement of [runMutationResult] on the report [file] of a manifest
/// that has been read already.
///
/// [gateFailures] says why a gate could not be mutation tested at all (path →
/// reason); it replaces what the judgement says about that gate ("no mutants
/// in the report").
///
/// [afterFailedRun] is set when dart_mutant has just printed its output and
/// ended with exit code 1 (its FAILED): the first line then says which of
/// the survivors it counted are allowed.
int judgeReportFile(
  LoadedManifest manifest,
  String file,
  Io io, {
  Map<String, String> gateFailures = const {},
  List<String>? only,
  bool listNotEvaluable = false,
  bool afterFailedRun = false,
}) {
  final gates = [
    for (final gate in manifest.gates)
      if (only == null || only.contains(gate.path)) gate,
  ];
  // Said on the last line, so that a run on some gates is not taken for a
  // run on all of them.
  final scope = only == null
      ? ''
      : ' for ${gates.length} of ${manifest.gates.length} gate(s) (--gate)';
  final MutationReport report;
  try {
    report = parseMutationReport(
      readText(resolveInPackage(manifest.dir, file)),
    );
  } on FileSystemException catch (error) {
    io.err(
      '$executable mutation: cannot read the report $file '
      '(${error.osError?.message ?? error.message}). '
      'Run "$executable mutation" first',
    );
    return 1;
  } on ReportFormatError catch (error) {
    io.err(
      '$executable mutation: $file is not a mutation report '
      '(${error.message})',
    );
    return 1;
  }

  final verdict = judgeMutationReport(
    gates: gates,
    report: report,
    maxTimeouts: manifest.settings.maxTimeouts,
    readSource: (gatePath) {
      if (!existsExact(manifest.dir, gatePath)) {
        return null;
      }
      try {
        return readText(
          '${manifest.dir}${Platform.pathSeparator}'
          '${gatePath.replaceAll('/', Platform.pathSeparator)}',
        );
      } on FileSystemException {
        return null;
      }
    },
  );
  final violations = [
    // A wrong entry of test-gates.json: a missing "reason", a gate listed
    // twice, ...
    ...manifest.violations,
    for (final MapEntry(key: path, value: reason) in gateFailures.entries)
      Violation(file: path, message: reason),
    for (final violation in verdict.violations)
      if (!gateFailures.containsKey(violation.file)) violation,
  ];
  final summary = formatSummary(verdict.summary);

  // Right under the last line of dart_mutant, which it is about.
  if (afterFailedRun) {
    if (allowedSurvivorsNote(verdict.summary) case final note?) {
      io.out('$executable mutation: $note');
    }
  }

  // Not a failure: shown on request, before the verdict.
  if (listNotEvaluable && verdict.notEvaluable.isNotEmpty) {
    io.out(
      '$executable mutation: ${verdict.notEvaluable.length} mutant(s) '
      'could not be evaluated (no test run says anything about them):',
    );
    for (final mutant in verdict.notEvaluable) {
      io.out('  ~ ${formatListedMutant(mutant)}');
      if (mutant.statusReason case final reason?) {
        io.out('      ${normalizeCode(reason)}');
      }
    }
  }

  if (violations.isEmpty && verdict.survivors.isEmpty) {
    io.out('$executable mutation: OK$scope ($summary)');
    return 0;
  }

  if (verdict.survivors.isNotEmpty) {
    io.err(
      '$executable mutation: ${verdict.survivors.length} surviving mutant(s) '
      'not in the allow list',
    );
    for (final survivor in verdict.survivors) {
      io.err('  - ${formatListedMutant(survivor)}');
    }
    io.err('');
    io.err(
      'Fix the test so that it detects the mutant. Only when the mutant '
      'cannot be observed from',
    );
    io.err(
      'outside (same return value, exception and side effects for every '
      'input), add it to',
    );
    io.err(
      '"equivalentMutants" of the gate in test-gates.json and fill in '
      '"reason":',
    );
    final byFile = <String, List<ListedMutant>>{};
    for (final survivor in verdict.survivors) {
      byFile.putIfAbsent(survivor.file, () => []).add(survivor);
    }
    for (final MapEntry(key: path, value: survivors) in byFile.entries) {
      io.err('');
      io.err('  $path');
      for (final (index, survivor) in survivors.indexed) {
        final comma = index == survivors.length - 1 ? '' : ',';
        io.err('    ${jsonEncode(survivor.allowance)}$comma');
      }
    }
    io.err('');
  }
  final maxTimeouts = manifest.settings.maxTimeouts;
  if (verdict.unexpectedTimeouts.length > maxTimeouts) {
    io.err(
      '$executable mutation: ${verdict.unexpectedTimeouts.length} mutant(s) '
      'timed out (settings.mutation.maxTimeouts: $maxTimeouts)',
    );
    for (final mutant in verdict.unexpectedTimeouts) {
      io.err('  - ${formatListedMutant(mutant)}');
    }
    io.err('');
    io.err(
      'A timeout counts as detected, but on a loaded machine a mutant that '
      'would survive',
    );
    io.err(
      'can time out instead. Run again with less load (a timeout is always '
      'measured again).',
    );
    io.err(
      'Only for a mutant that can never finish (a loop that no longer ends), '
      'add it to',
    );
    io.err(
      '"expectedTimeouts" of the gate in test-gates.json and fill in "reason"',
    );
    io.err(
      '(settings.mutation.maxTimeouts raises the limit for the whole '
      'project):',
    );
    for (final mutant in verdict.unexpectedTimeouts) {
      io.err('    ${mutant.file}: ${jsonEncode(mutant.allowance)}');
    }
    io.err('');
  }
  if (violations.isNotEmpty) {
    printViolations(io, 'mutation', violations);
  }
  io.err('$executable mutation: FAILED$scope ($summary)');
  return 1;
}
