import 'dart:convert';

import 'json.dart';
import 'mutation_result.dart';
import 'mutators.dart';
import 'version.dart';

/// The limit of one test, passed to the test runner as `--timeout`. A test
/// that waits for something a mutant no longer does then fails (Killed)
/// instead of holding the run for the 30 seconds of the runner's default.
const perTestTimeoutSeconds = 10;

/// How long the test run of one mutant may take: three times the run without
/// a mutant, plus 20 seconds. Only a mutant that keeps the process itself
/// from ending (a loop that never yields) gets this far; it is a Timeout.
Duration processLimit(Duration baseline) =>
    baseline * 3 + const Duration(seconds: 20);

/// How long the run without a mutant may take.
const baselineLimit = Duration(minutes: 10);

final _flutterSdk = RegExp(r'^\s+sdk:\s*flutter\s*(#.*)?$', multiLine: true);

/// True when the pubspec has a dependency from the Flutter SDK: the tests
/// then need `flutter test`.
bool usesFlutter(String pubspec) =>
    _flutterSdk.hasMatch(pubspec.replaceAll('\r\n', '\n'));

/// The command that runs test files, program first: [override] when given,
/// else `flutter test --no-pub` for a Flutter package and `dart test` for any
/// other.
List<String> testCommandFor({
  required bool flutter,
  List<String> override = const [],
}) => override.isNotEmpty
    ? override
    : flutter
    ? const ['flutter', 'test', '--no-pub']
    : const ['dart', 'test'];

/// [command] for the tests in [specs]: the first failing test ends the run,
/// and a test gets [perTestTimeoutSeconds].
List<String> mutantCommand(List<String> command, List<String> specs) => [
  ...command,
  '--fail-fast',
  '--timeout',
  '${perTestTimeoutSeconds}s',
  ...specs,
];

/// The compiler's `file.dart:12:3: Error: ...`, and what `flutter test`
/// prints when a test file cannot be loaded.
final _compileError = RegExp(r'(\.dart:\d+:\d+: Error: |Compilation failed)');

/// The status of a mutant from the test run on it.
///
/// - the process limit was reached → `Timeout`
/// - the tests passed → `Survived`
/// - the code did not compile → `CompileError` (nothing was evaluated)
/// - anything else → `Killed`
String classifyRun({
  required int? exitCode,
  required String output,
  required bool timedOut,
}) {
  if (timedOut) {
    return 'Timeout';
  }
  if (exitCode == 0) {
    return 'Survived';
  }
  return _compileError.hasMatch(output) ? 'CompileError' : 'Killed';
}

/// 1-based line and column of [offset]. Lines end at `\n`, as they do where
/// the report is judged; a `\r` before it belongs to the line.
({int line, int column}) positionOf(String source, int offset) {
  final before = source.substring(0, offset);
  return (
    line: '\n'.allMatches(before).length + 1,
    // lastIndexOf gives -1 on the first line, whose start is 0.
    column: offset - before.lastIndexOf('\n'),
  );
}

/// What a run found out about one gate.
class GateRun {
  const GateRun({
    required this.source,
    required this.mutants,
    required this.statuses,
    required this.milliseconds,
  });

  /// The gate as it was mutated.
  final String source;
  final List<Mutant> mutants;

  /// One per mutant, in the same order.
  final List<String> statuses;

  /// One per mutant. 0 for a result taken from an earlier run.
  final List<int> milliseconds;
}

/// The report of a run in the mutation-testing-elements (Stryker) JSON
/// schema, version 2: what `mutation-result` judges, and what the Stryker
/// report viewers read.
///
/// [others] are the files of an earlier report that this run did not touch
/// (see [otherReportFiles]). They are written as they were.
JsonObject buildReport(
  Map<String, GateRun> gates, {
  JsonObject others = const {},
}) => {
  'schemaVersion': '2',
  'thresholds': {'high': 100, 'low': 100},
  'framework': {'name': 'test_gates', 'version': packageVersion},
  'files': {
    ...others,
    for (final MapEntry(key: path, value: run) in gates.entries)
      path: {
        'language': 'dart',
        'source': run.source,
        'mutants': [
          for (final (index, mutant) in run.mutants.indexed)
            {
              'id': '$path#$index',
              'mutatorName': mutant.mutator,
              'replacement': mutant.replacement,
              'status': run.statuses[index],
              'duration': run.milliseconds[index],
              'location': {
                'start': _json(positionOf(run.source, mutant.offset)),
                'end': _json(positionOf(run.source, mutant.end)),
              },
            },
        ],
      },
  },
};

/// What a run starts from in the file of the results of the last run
/// ([saved], path → entry) and writes back with its own results.
///
/// Without `--force` that is everything. With it nothing of the gates of
/// this run may be left, also when the run does not get to them: the next
/// run must not reuse what `--force` was given to measure again. [selected]
/// are the gates of a run with `--gate` (`null`: every gate); the results of
/// the other gates are not this run's to forget.
JsonObject carriedResults(
  JsonObject saved, {
  required bool force,
  required List<String>? selected,
}) => {
  for (final MapEntry(key: path, :value) in saved.entries)
    if (!force || (selected != null && !selected.contains(path))) path: value,
};

/// The gates a run is limited to with `--gate`: the paths of [requested]
/// that are gates, in the order of test-gates.json and each once, and the
/// ones that are not. No request means every gate.
({List<String> selected, List<String> unknown}) selectGates(
  List<String> gatePaths,
  List<String> requested,
) => (
  selected: [
    for (final path in gatePaths)
      if (requested.isEmpty || requested.contains(path)) path,
  ],
  unknown: [
    for (final path in requested.toSet())
      if (!gatePaths.contains(path)) path,
  ],
);

/// What a run that is limited to the gates [selected] keeps of the report
/// that is already there ([existing], `null` when there is none): the files
/// of the other gates, as they are written. The results of a full run are
/// then still in the report after one gate was run again.
///
/// The paths are compared as the judgement compares them, so the result of
/// a selected gate is not kept under another spelling of its path
/// (`./lib/a.dart`).
///
/// Nothing is kept of a file that is not a report.
JsonObject otherReportFiles(String? existing, List<String> selected) {
  if (existing == null) {
    return {};
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(existing);
  } on FormatException {
    return {};
  }
  final files = asObject(asObject(decoded)?['files']) ?? {};
  final left = selected.map(normalizeReportPath).toSet();
  return {
    for (final MapEntry(key: path, :value) in files.entries)
      if (!left.contains(normalizeReportPath(path))) path: value,
  };
}

JsonObject _json(({int line, int column}) position) => {
  'line': position.line,
  'column': position.column,
};

/// What decides the result of a gate: when all of it is the same as in an
/// earlier run, that run's statuses are still true.
///
/// A file the gate imports is not part of it: a change there is only seen by
/// a run with `--force`.
class GateInput {
  const GateInput({
    required this.source,
    required this.specs,
    required this.command,
  });

  /// The gate.
  final String source;

  /// The tests of the gate: path → content.
  final Map<String, String> specs;

  /// The test command, without the test files.
  final List<String> command;

  JsonObject toJson() => {
    'toolVersion': packageVersion,
    'mutatorsVersion': mutatorsVersion,
    'command': command,
    'source': source,
    'specs': specs,
  };
}

bool _sameJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _sameJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        a.indexed.every((item) => _sameJson(item.$2, b[item.$1]));
  }
  return a == b;
}

/// The statuses of [mutantCount] mutants that an earlier run ([entry], as
/// [incrementalEntry] wrote it) found for exactly [input], or `null` when
/// that run was on something else.
///
/// A `Timeout` is given as `null`: it can come from the load of the machine,
/// so it is measured again.
List<String?>? reusableStatuses(
  Object? entry,
  GateInput input,
  int mutantCount,
) {
  final object = asObject(entry);
  final statuses = object?['statuses'];
  if (object == null ||
      statuses is! List ||
      statuses.length != mutantCount ||
      statuses.any((status) => status is! String) ||
      !_sameJson(object['input'], input.toJson())) {
    return null;
  }
  return [
    for (final status in statuses)
      status == 'Timeout' ? null : status as String,
  ];
}

/// What is kept of a gate for [reusableStatuses] of a later run.
JsonObject incrementalEntry(GateInput input, List<String> statuses) => {
  'input': input.toJson(),
  'statuses': statuses,
};

/// True when [current] is what a run that was killed can have left in a gate
/// whose content was [original]: one of its mutants. (A mutant is put in
/// place with a rename, so there is no half-written state.)
///
/// False when [current] is [original], and for anything else: somebody
/// edited the file, and their content must not be overwritten.
bool isLeftoverOf(String original, String current) =>
    current != original &&
    findMutants(
      original,
    ).mutants.any((mutant) => mutant.applyTo(original) == current);
