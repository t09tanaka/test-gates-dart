import 'dart:convert';

import 'dart_source.dart';
import 'import_policy.dart';
import 'json.dart';
import 'mutation_result.dart';
import 'types.dart';

/// Which gates `mutation` runs again, and which keep the results of the last
/// run.
///
/// The unit is the gate, never the mutant: `dart_mutant` reuses the result of
/// a file when the file, its tests, the test command and the tool are
/// unchanged, and does not look at what they import. A gate keeps its
/// results here only when nothing it can depend on changed: the gate, its
/// tests, and every file of the package that one of them imports, exports or
/// has as a part, however many imports away. Anything that may change the
/// results of every gate (a configuration, the lock file, the SDK, a tool,
/// an argument) makes the run one of every mutant.
///
/// The fingerprints of the files are made by the caller: this file compares
/// them as strings.

/// Where the record of the last run is kept, below the package.
const recordFile = '.dart_tool/test_gates/mutation-record.json';

/// The files at the top of the package whose change may affect the results
/// of every gate.
const configFiles = [
  'pubspec.yaml',
  'pubspec.lock',
  'pubspec_overrides.yaml',
  'analysis_options.yaml',
  'dart_test.yaml',
  'build.yaml',
  'test-gates.json',
];

final _flutterDependency = RegExp(
  r'^\s+sdk:[ \t]*flutter[ \t]*$',
  multiLine: true,
);
final _workspaceMember = RegExp(
  r'^resolution:[ \t]*workspace[ \t]*$',
  multiLine: true,
);
final _workspaceRoot = RegExp(r'^workspace:', multiLine: true);

/// True when the pubspec [pubspec] has a dependency from the Flutter SDK:
/// then the tests run with `flutter test`, and the Dart of that SDK.
bool usesFlutter(String pubspec) => _flutterDependency.hasMatch(pubspec);

/// True when the pubspec [pubspec] is of a member of a pub workspace: its
/// dependencies are resolved by the root, in the lock file of the root.
bool inWorkspace(String pubspec) => _workspaceMember.hasMatch(pubspec);

/// True when the pubspec [pubspec] is the root of a pub workspace.
bool isWorkspaceRoot(String pubspec) => _workspaceRoot.hasMatch(pubspec);

/// The files of the root of a workspace [levels] directories above the
/// package that may affect every gate, relative to the package: the
/// pubspec (with its `dependency_overrides`) and the lock file.
List<String> workspaceFiles(int levels) {
  final up = '../' * levels;
  return ['${up}pubspec.yaml', '${up}pubspec.lock'];
}

/// The version of Flutter for the context of a run: from the output of
/// `flutter --version --machine` ([machine]), else the first lines of
/// `flutter --version` ([plain]), else that it cannot be told. A value that
/// cannot be told is compared like any other.
String flutterVersionOf(String? machine, String? plain) {
  // Flutter can print a line about an upgrade in front of the object.
  final start = machine?.indexOf('{');
  final object = start == null || start < 0
      ? null
      : _decodeObject(machine!.substring(start));
  if (object != null) {
    String field(String name) => asText(object[name]) ?? '?';
    return 'Flutter ${field('frameworkVersion')} '
        '(${field('frameworkRevision')}), engine ${field('engineRevision')}, '
        'Dart ${field('dartSdkVersion')}';
  }
  final text = plain?.trim() ?? '';
  return text.isEmpty ? 'cannot be told' : text;
}

/// Libraries with which a test can read a file that no import names.
const _fileReaders = ['dart:io', 'package:file/', 'package:test_descriptor/'];

/// Names with which a Flutter test reads a file that no import names: a
/// golden file, an asset.
const _fileReadingNames = ['matchesGoldenFile', 'rootBundle'];

/// What the results of a gate depend on among the files of the package.
///
/// [files]: the files that [starts] reach, the starts included, sorted.
/// [readsFiles]: one of them can read files that no import names (see
/// [_fileReaders]); then every file of the package counts. [problem]: why
/// what they reach cannot be told from the text, or `null`.
typedef Reach = ({List<String> files, bool readsFiles, String? problem});

/// The files that [starts] (the gate, its tests) reach through imports,
/// exports and parts inside the package, with the rules of [resolveUri].
/// [readSource] gives the content of a file of the package, `null` when it
/// cannot be read.
Reach reachOf(
  List<String> starts,
  List<ImportAlias> aliases,
  String? Function(String path) readSource,
) {
  final seen = {...starts};
  final queue = [...starts];
  var readsFiles = false;
  String? problem;
  for (var index = 0; index < queue.length; index++) {
    final path = queue[index];
    final source = readSource(path);
    if (source == null) {
      problem ??= '$path cannot be read';
      continue;
    }
    final parsed = parseDartSource(source);
    for (final line in parsed.uncheckableUris) {
      problem ??= '$path:$line: a URI that is not written out as it is read';
    }
    readsFiles =
        readsFiles || _fileReadingNames.any(parsed.identifiers.contains);
    for (final imported in parsed.imports) {
      final uri = imported.uri;
      readsFiles = readsFiles || _fileReaders.any(uri.startsWith);
      final target = resolveUri(uri, path, aliases);
      if (target == null) {
        continue;
      }
      if (target.startsWith('../')) {
        problem ??= '$path:${imported.line}: "$uri" is outside the package';
      } else if (seen.add(target)) {
        queue.add(target);
      }
    }
  }
  return (files: [...seen]..sort(), readsFiles: readsFiles, problem: problem);
}

/// Where `flutter test` looks for a `flutter_test_config.dart` that it runs
/// around the test at [testPath] without an import: the directory of the
/// test and every one above it, up to the package.
List<String> testConfigsFor(String testPath) {
  final segments = testPath.split('/')..removeLast();
  return [
    for (var length = segments.length; length >= 0; length--)
      [...segments.take(length), 'flutter_test_config.dart'].join('/'),
  ];
}

/// A gate as it is now.
///
/// [files]: the fingerprint of each file its results depend on.
/// [everything]: for a gate whose tests can read files, a fingerprint of
/// every file of the package, or `null` when they cannot be listed.
class GateState {
  const GateState(
    this.path,
    this.files, {
    this.readsFiles = false,
    this.everything,
  });

  final String path;
  final Map<String, String> files;
  final bool readsFiles;
  final String? everything;
}

/// What a run wrote down: the [context] it ran in, the fingerprint of the
/// [report] it left, and the state of each gate whose results are in it.
class MutationRecord {
  const MutationRecord(this.context, this.report, this.gates);

  final Map<String, String> context;
  final String report;
  final Map<String, GateState> gates;
}

const _recordVersion = 1;

Map<String, String>? _strings(Object? value) {
  final object = asObject(value);
  if (object == null || object.values.any((entry) => entry is! String)) {
    return null;
  }
  return Map<String, String>.from(object);
}

/// The record as it is written to [recordFile].
String encodeRecord(MutationRecord record) =>
    const JsonEncoder.withIndent('  ').convert({
      'version': _recordVersion,
      'context': record.context,
      'report': record.report,
      'gates': {
        for (final gate in record.gates.values)
          gate.path: {
            'files': gate.files,
            'readsFiles': gate.readsFiles,
            'everything': ?gate.everything,
          },
      },
    });

/// The record in [text], or `null` when it is not one that this version
/// wrote.
MutationRecord? decodeRecord(String text) {
  final object = _decodeObject(text);
  final context = _strings(object?['context']);
  final report = asText(object?['report']);
  final entries = asObject(object?['gates']);
  if (object?['version'] != _recordVersion ||
      context == null ||
      report == null ||
      entries == null) {
    return null;
  }
  final gates = <String, GateState>{};
  for (final MapEntry(key: path, :value) in entries.entries) {
    final entry = asObject(value);
    final files = _strings(entry?['files']);
    final readsFiles = entry?['readsFiles'];
    final everything = entry?['everything'];
    if (files == null ||
        readsFiles is! bool ||
        (everything != null && everything is! String)) {
      return null;
    }
    gates[path] = GateState(
      path,
      files,
      readsFiles: readsFiles,
      everything: everything as String?,
    );
  }
  return MutationRecord(context, report, gates);
}

/// What a run does: every mutant of every gate ([full] says why), or every
/// mutant of the gates of [rerun] (each with why) while [reused] keep their
/// results.
class ReusePlan {
  const ReusePlan.full(String this.full) : rerun = const [], reused = const [];

  const ReusePlan.partly(this.rerun, this.reused) : full = null;

  final String? full;
  final List<({String gate, String why})> rerun;
  final List<String> reused;
}

String _listed(List<String> items, [int shown = 3]) {
  final more = items.length - shown;
  return [...items.take(shown), if (more > 0) 'and $more more'].join(', ');
}

/// The keys whose values differ between [before] and [now], sorted. A key
/// that is in one of them only differs.
List<String> _differing(Map<String, String> before, Map<String, String> now) =>
    {
      ...before.keys,
      ...now.keys,
    }.where((key) => before[key] != now[key]).toList()..sort();

/// True when the report as it is now ([report], a fingerprint) is the one
/// that the record [recordText] names, and the record was made in the same
/// [context]: then what the report says about a gate that is not run is what
/// the record says was measured.
bool reportVerified({
  required String? recordText,
  required Map<String, String> context,
  required String? report,
}) {
  final record = recordText == null ? null : decodeRecord(recordText);
  return record != null &&
      _differing(record.context, context).isEmpty &&
      report == record.report;
}

/// Decides which gates are run again.
///
/// [forced]: why every mutant is run whatever changed (`--force`, `CI`), or
/// `null`. [problem]: why what a gate depends on cannot be told, or `null`.
/// [recordText]: the record of the last run, `null` when there is none.
/// [context]: what the results of every gate depend on, as it is now: the
/// versions, the arguments, the fingerprints of [configFiles]. [report]:
/// the fingerprint of the report as it is now, `null` when there is none.
/// [timedOut]: the gates with a mutant that timed out in that report.
ReusePlan planReuse({
  required String? forced,
  required String? problem,
  required String? recordText,
  required Map<String, String> context,
  required String? report,
  required List<String> timedOut,
  required List<GateState> gates,
}) {
  if (forced != null) {
    return ReusePlan.full(forced);
  }
  if (problem != null) {
    return ReusePlan.full(
      'what a gate depends on cannot be told from the imports: $problem',
    );
  }
  if (recordText == null) {
    return const ReusePlan.full('there is no record of a run to reuse');
  }
  final record = decodeRecord(recordText);
  if (record == null) {
    return const ReusePlan.full(
      'the record of the last run cannot be read: $recordFile',
    );
  }
  final changed = _differing(record.context, context);
  if (changed.isNotEmpty) {
    return ReusePlan.full('changed since the last run: ${_listed(changed)}');
  }
  if (report != record.report) {
    return const ReusePlan.full('the report is not the one the last run left');
  }
  final rerun = <({String gate, String why})>[];
  final reused = <String>[];
  for (final gate in gates) {
    final last = record.gates[gate.path];
    final files = last == null
        ? const <String>[]
        : _differing(last.files, gate.files);
    final why = last == null
        ? 'the last run left no result of it'
        : files.isNotEmpty
        ? 'changed ${_listed(files)}'
        : gate.readsFiles && gate.everything == null
        ? 'its tests can read any file, and the files of the package cannot '
              'be listed'
        : gate.readsFiles && gate.everything != last.everything
        ? 'its tests can read any file, and a file of the package changed'
        : null;
    if (why == null) {
      reused.add(gate.path);
    } else {
      rerun.add((gate: gate.path, why: why));
    }
  }
  if (rerun.isEmpty) {
    return ReusePlan.partly(rerun, reused);
  }
  // Only the gates that are run measure a Timeout again.
  for (final gate in [...reused]) {
    if (timedOut.contains(gate)) {
      reused.remove(gate);
      rerun.add((gate: gate, why: 'a mutant of it timed out in the last run'));
    }
  }
  return ReusePlan.partly(rerun, reused);
}

JsonObject? _decodeObject(String? text) {
  if (text == null) {
    return null;
  }
  try {
    return asObject(jsonDecode(text));
  } on FormatException {
    return null;
  }
}

/// The gates of [gates] with a mutant that timed out in [report].
List<String> timedOutGates(String? report, List<String> gates) {
  final files = asObject(_decodeObject(report)?['files']) ?? const {};
  final timed = {
    for (final MapEntry(key: path, :value) in files.entries)
      if (asObject(value)?['mutants'] case final List<Object?> mutants
          when mutants.any(
            (mutant) => asObject(mutant)?['status'] == 'Timeout',
          ))
        normalizeReportPath(path),
  };
  return [
    for (final gate in gates)
      if (timed.contains(normalizeReportPath(gate))) gate,
  ];
}

/// The record a run leaves: the gates of [ran] whose results are in the
/// report now ([written]), and those of the [last] record that the run did
/// not touch, when it ran in the same [context] and the report was checked
/// against that record before the run ([reportVerified]; this is checked
/// with `--force` and `CI` as well). Without it (no record, another
/// context, a report that is not the one the record names) what the report
/// says about the other gates is not known to be what the record says, and
/// they are left out.
String recordAfterRun({
  required String? last,
  required bool reportVerified,
  required Map<String, String> context,
  required String report,
  required List<GateState> ran,
  required List<String> written,
}) {
  final before = last == null ? null : decodeRecord(last);
  final kept =
      reportVerified &&
          before != null &&
          _differing(before.context, context).isEmpty
      ? before.gates
      : const <String, GateState>{};
  final names = ran.map((gate) => gate.path).toSet();
  return encodeRecord(
    MutationRecord(context, report, {
      for (final gate in kept.values)
        if (!names.contains(gate.path)) gate.path: gate,
      for (final gate in ran)
        if (written.contains(gate.path)) gate.path: gate,
    }),
  );
}

/// The lines that say what the run does, without the name of the command.
List<String> describeReuse(ReusePlan plan, {int shown = 5}) {
  final full = plan.full;
  if (full != null) {
    return ['running every mutant of the gates (--force): $full'];
  }
  final total = plan.rerun.length + plan.reused.length;
  if (plan.rerun.isEmpty) {
    return [
      'nothing that the $total gate(s) depend on changed since the last run: '
          'their results are reused, and a Timeout is measured again',
    ];
  }
  final more = plan.rerun.length - shown;
  return [
    '${plan.reused.length} of $total gate(s) reused, ${plan.rerun.length} '
        'run again with every mutant',
    for (final (:gate, :why) in plan.rerun.take(shown)) '  $gate: $why',
    if (more > 0) '  and $more more',
  ];
}
