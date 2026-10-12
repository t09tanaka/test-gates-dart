import 'dart:convert';

import 'json.dart';
import 'mutation_result.dart';

/// The tool that makes the mutants and runs the tests on them. `mutation`
/// starts it as a program of its own and judges the report it writes.
const dartMutant = 'dart_mutant';

/// How the tool is installed, for the message that says it is missing.
const dartMutantInstall = 'dart pub global activate $dartMutant';

/// The versions of the tool this version works with: every `0.1.x`. The one
/// place that says so; the messages and the check are made from it.
const supportedDartMutant = (major: 0, minor: 1);

/// [supportedDartMutant] as it is shown: `0.1.x`.
String get supportedDartMutantRange =>
    '${supportedDartMutant.major}.${supportedDartMutant.minor}.x';

/// Where the plan for the tool is written, below the package. `.dart_tool`
/// is ignored by git in every Dart project.
const planFile = '.dart_tool/test_gates/mutation-plan.json';

/// The commands that are tried, in this order, to start the tool: the
/// executable on PATH, then the globally activated package through [dart]
/// (the `dart` that runs this program). The first that answers `--version`
/// is the one that is used.
List<List<String>> dartMutantCommands(String dart) => [
  const [dartMutant],
  [dart, 'pub', 'global', 'run', dartMutant],
];

final _version = RegExp(r'^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.+-]*)?$');

/// The version a command answered `--version` with, or `null` when what it
/// printed ([output]) is not the answer of the tool: it failed
/// ([exitCode] is not 0, or `null` when it could not be started), or it
/// printed something else.
String? dartMutantVersionOf(int? exitCode, String output) {
  final text = output.trim();
  return exitCode == 0 && _version.hasMatch(text) ? text : null;
}

/// True when [version] (as [dartMutantVersionOf] gives it) is one of
/// [supportedDartMutant].
bool isSupportedDartMutant(String version) {
  final match = _version.firstMatch(version)!;
  return int.parse(match[1]!) == supportedDartMutant.major &&
      int.parse(match[2]!) == supportedDartMutant.minor;
}

/// The options of `dart_mutant run` that `mutation` sets by itself, with the
/// option of this tool that says the same.
const _reserved = {
  '--dir': '--dir',
  '--plan': null,
  '--report': '--report',
  '--only': '--gate',
};

/// What of [rest] (what follows `--` on the command line of `mutation`) is
/// for the tool itself: everything in front of a second `--`. Behind that
/// one is the command that runs test files.
List<String> _ownOptions(List<String> rest) =>
    rest.takeWhile((argument) => argument != '--').toList();

String _nameOf(String argument) => argument.split('=').first;

/// Why [rest] cannot be handed to `dart_mutant run`, or `null` when it can.
///
/// It is handed over as it is, so what the tool does not know is refused by
/// the tool. Only what would make it run something else than the gates, or
/// write the report somewhere else than where it is judged, is refused here.
String? passThroughProblem(List<String> rest) {
  if (rest.isNotEmpty && !rest.first.startsWith('-')) {
    return 'what follows "--" is handed to $dartMutant run, and '
        '"${rest.first}" is not one of its options. The command that runs '
        'test files goes behind a second "--": '
        'mutation -- -- ${rest.join(' ')}';
  }
  for (final argument in _ownOptions(rest)) {
    final name = _nameOf(argument);
    if (_reserved.containsKey(name)) {
      final own = _reserved[name];
      return '$name cannot be handed to $dartMutant run: mutation sets it '
          'from test-gates.json'
          '${own == null ? '' : '. Give $own in front of "--"'}';
    }
  }
  return null;
}

/// True when [rest] asks for a part of a run (`--shard`). The report of a
/// part is not a result, so it is not judged.
bool asksForPart(List<String> rest) =>
    _ownOptions(rest).any((argument) => _nameOf(argument) == '--shard');

/// The plan file of the tool for [targets]: each gate with its tests, in
/// this order.
JsonObject buildPlan(List<({String file, List<String> tests})> targets) => {
  'version': 1,
  'targets': [
    for (final target in targets) {'file': target.file, 'tests': target.tests},
  ],
};

/// The arguments of the tool for a run of the gates of the plan at [plan],
/// in the package [dir], with the report at [report].
///
/// [only] are the gates of a run with `--gate` (`null`: every gate of the
/// plan). They are named with `--only`, so that the tool keeps what the
/// report says about the other gates. [rest] is handed over as it is.
List<String> dartMutantArguments({
  required String dir,
  required String plan,
  required String report,
  required bool force,
  required List<String>? only,
  List<String> rest = const [],
}) => [
  'run',
  '--dir',
  dir,
  '--plan',
  plan,
  '--report',
  report,
  if (force) '--force',
  for (final gate in only ?? const <String>[]) ...['--only', gate],
  ...rest,
];

/// What the exit code of the tool means for `mutation`.
///
/// 0 (no mutant survived) and 1 (one did, or a file could not be mutation
/// tested) say nothing about the verdict: the report does, and `null` is
/// returned. Any other code is the exit code of `mutation`, and nothing is
/// judged: 2 (the tool refused its command line), 130 / 143 / 129 (it was
/// interrupted), and whatever else it ended with. [exitCode] is negative
/// when a signal ended the process (-9 for SIGKILL); that is given as a
/// shell gives it, 128 + the number of the signal.
int? exitCodeWithoutVerdict(int exitCode) {
  if (exitCode < 0) {
    return 128 - exitCode;
  }
  return exitCode == 0 || exitCode == 1 ? null : exitCode;
}

/// The gates of [planned] that the report [text] has nothing about (`null`:
/// there is no report, or it cannot be read as one). The tool leaves out a
/// file it could not mutation test, and writes no report when it had to
/// stop.
List<String> missingFromReport(String? text, List<String> planned) {
  final files = _filesOf(text).keys.map(normalizeReportPath).toSet();
  return [
    for (final path in planned)
      if (!files.contains(normalizeReportPath(path))) path,
  ];
}

/// True when the report [text] shows why the tool ended with exit code 1 on
/// the gates [planned]: one of them has a mutant that survived, or is
/// missing. When it does not, the tool failed at something else (a page
/// that could not be written, say), and the run must not pass on a report
/// that does not say so.
bool explainsFailure(String? text, List<String> planned) {
  if (missingFromReport(text, planned).isNotEmpty) {
    return true;
  }
  final wanted = planned.map(normalizeReportPath).toSet();
  for (final MapEntry(key: path, :value) in _filesOf(text).entries) {
    final mutants = asObject(value)?['mutants'];
    if (wanted.contains(normalizeReportPath(path)) &&
        mutants is List &&
        mutants.any((mutant) => asObject(mutant)?['status'] == 'Survived')) {
      return true;
    }
  }
  return false;
}

JsonObject? _decode(String? text) {
  if (text == null) {
    return null;
  }
  try {
    return asObject(jsonDecode(text));
  } on FormatException {
    return null;
  }
}

JsonObject _filesOf(String? text) =>
    asObject(_decode(text)?['files']) ?? const {};

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

/// What a run of the gates [selected] leaves of the report that is already
/// there ([existing]) before the tool is started: the report without what it
/// says about these gates, or `null` when nothing is left and the file is
/// to be deleted. Whatever is judged after the run was then written by the
/// run, also when the tool ends without writing a report.
///
/// The paths are compared as the judgement compares them, so the result of
/// a selected gate is not kept under another spelling of its path
/// (`./lib/a.dart`). Nothing is kept of a file that is not a report.
String? reportWithout(String existing, List<String> selected) {
  final report = _decode(existing);
  final left = selected.map(normalizeReportPath).toSet();
  final others = {
    for (final MapEntry(key: path, :value) in _filesOf(existing).entries)
      if (!left.contains(normalizeReportPath(path))) path: value,
  };
  return others.isEmpty
      ? null
      : const JsonEncoder.withIndent(
          '  ',
        ).convert({...report!, 'files': others});
}
