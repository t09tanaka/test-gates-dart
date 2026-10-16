import 'dart:convert';
import 'dart:math' as math;

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
/// tests, and every file that one of them imports, exports or has as a part,
/// however many imports away, in the package, in another package at a path
/// or of the workspace, and outside the package. Anything that may change the
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
/// golden file (`flutter_test`, `golden_toolkit`, `alchemist`), an asset or
/// a font of the package (`rootBundle`, an [AssetBundle], an image of an
/// asset, and `X.asset(...)` below).
///
/// The names are those of the code where they are used. A file of another
/// package that the lock file pins (hosted, git) is not read, so a helper
/// there that reads files under a name of its own is not seen, and neither
/// is a call of `load` on a bundle that is not named here.
const _fileReadingNames = [
  'matchesGoldenFile',
  'rootBundle',
  'DefaultAssetBundle',
  'AssetBundle',
  'PlatformAssetBundle',
  'CachingAssetBundle',
  'AssetImage',
  'ExactAssetImage',
  'loadString',
  'loadStructuredData',
  'screenMatchesGolden',
  'multiScreenGolden',
  'testGoldens',
  'loadAppFonts',
  'goldenTest',
];

/// The member that reads an asset as a named constructor: `Image.asset`,
/// and those of other packages in the same way (`SvgPicture.asset`).
const _assetConstructor = '.asset';

/// Where the `lib/` of each other package is, relative to the package with
/// `/` and ending in `/` (`../other/lib/`), for a package whose files can
/// change without a change of the lock file: one at a path, a member of the
/// workspace. `null` for one that the lock file pins (hosted, git, an SDK):
/// a change of it is one of the lock file. [problem]: why the packages
/// cannot be told; then [roots] is empty.
typedef PackageRoots = ({Map<String, String?> roots, String? problem});

final _lockedPackage = RegExp(r'^  ([^\s:]+):\s*$');
final _lockedSource = RegExp(r'^    source:\s*"?([^\s"]+)"?\s*$');

/// The other packages, from the text of `.dart_tool/package_config.json`
/// ([config], at [configFile]) and of `pubspec.lock` ([lock]) of the root of
/// the resolution, for the package at the directory [package]. `null` for a
/// file that cannot be read.
PackageRoots packageRootsOf({
  required String? config,
  required String? lock,
  required Uri configFile,
  required Uri package,
}) {
  PackageRoots unknown(String why) =>
      (roots: const {}, problem: '$why (run dart pub get)');
  if (config == null) {
    return unknown('there is no .dart_tool/package_config.json');
  }
  if (lock == null) {
    return unknown('there is no pubspec.lock');
  }
  final sources = <String, String>{};
  String? current;
  for (final line in const LineSplitter().convert(lock)) {
    final name = _lockedPackage.firstMatch(line)?.group(1);
    final source = _lockedSource.firstMatch(line)?.group(1);
    if (name != null) {
      current = name;
    } else if (source != null && current != null) {
      sources[current] = source;
    }
  }
  final packages = _decodeObject(config)?['packages'];
  if (packages is! List<Object?>) {
    return unknown('the .dart_tool/package_config.json cannot be read');
  }
  final roots = <String, String?>{};
  for (final value in packages) {
    final entry = asObject(value);
    final name = asText(entry?['name']);
    final rootUri = asText(entry?['rootUri']);
    if (name == null || rootUri == null) {
      return unknown('the .dart_tool/package_config.json cannot be read');
    }
    final root = _directory(configFile.resolve(rootUri));
    if (root.scheme != 'file') {
      return unknown('$name is not on the disk: $rootUri');
    }
    final source = sources[name];
    roots[name] = source == null || source == 'path'
        ? _relative(
            package,
            _directory(root.resolve(asText(entry?['packageUri']) ?? '')),
          )
        : null;
  }
  return (roots: roots, problem: null);
}

/// [uri] as a directory: with a `/` at the end, so that a URI is resolved
/// below it. One that had a `/` has two, and an empty segment is no
/// directory (see [_relative]).
Uri _directory(Uri uri) => uri.replace(path: '${uri.path}/');

/// The directory [to] from the directory [from], with `/`, ending in `/`
/// (empty for the same directory).
String _relative(Uri from, Uri to) {
  final start = from.pathSegments.where((part) => part.isNotEmpty).toList();
  final end = to.pathSegments.where((part) => part.isNotEmpty).toList();
  final common = Iterable<int>.generate(
    math.min(start.length, end.length),
  ).takeWhile((index) => start[index] == end[index]).length;
  return [
    ...List.filled(start.length - common, '..'),
    ...end.skip(common),
  ].map((part) => '$part/').join();
}

/// What the results of a gate depend on among the files of the package.
///
/// [files]: the files that [starts] reach, the starts included, sorted.
/// [readsFiles]: one of them can read files that no import names (see
/// [_fileReaders]); then every file of the package counts. [problem]: why
/// what they reach cannot be told from the text, or `null`.
typedef Reach = ({List<String> files, bool readsFiles, String? problem});

/// The files that [starts] (the gate, its tests) reach through imports,
/// exports and parts, with the rules of [resolveUri]: in the package, in the
/// other packages whose [PackageRoots.roots] are known (at a path, a member
/// of the workspace), and outside the package (`../shared/x.dart`, an alias
/// to `..`). A path outside the package starts with `../`. [readSource]
/// gives the content of a file, `null` when it cannot be read.
///
/// A file that a conditional import names and that is not there is one of
/// the files (its fingerprint says that it is missing), not a problem: the
/// file of another platform need not exist.
Reach reachOf(
  List<String> starts,
  List<ImportAlias> aliases,
  String? Function(String path) readSource, {
  required PackageRoots packages,
}) {
  final all = [
    ...aliases,
    for (final MapEntry(key: name, value: root) in packages.roots.entries)
      if (root != null) ImportAlias('package:$name/', root),
  ];
  final seen = {...starts};
  final queue = [...starts];
  final required = {...starts};
  final missing = <String>[];
  var readsFiles = false;
  String? problem;
  for (var index = 0; index < queue.length; index++) {
    final path = queue[index];
    final source = readSource(path);
    if (source == null) {
      missing.add(path);
      continue;
    }
    final parsed = parseDartSource(source);
    for (final line in parsed.uncheckableUris) {
      problem ??= '$path:$line: a URI that is not written out as it is read';
    }
    readsFiles =
        readsFiles ||
        _fileReadingNames.any(parsed.identifiers.contains) ||
        parsed.qualifiedNames.any((name) => name.endsWith(_assetConstructor));
    for (final imported in parsed.imports) {
      final uri = imported.uri;
      readsFiles = readsFiles || _fileReaders.any(uri.startsWith);
      final target = resolveUri(uri, path, all);
      if (target == null) {
        if (uri.startsWith('package:')) {
          problem ??= _otherPackage(packages, '$path:${imported.line}', uri);
        }
        continue;
      }
      if (!imported.conditional) {
        required.add(target);
      }
      if (seen.add(target)) {
        queue.add(target);
      }
    }
  }
  for (final path in missing) {
    if (required.contains(path)) {
      problem ??= '$path cannot be read';
    }
  }
  return (files: [...seen]..sort(), readsFiles: readsFiles, problem: problem);
}

/// Why the import of [uri] at [where], a package that is not followed, is a
/// problem, or `null` when the lock file pins it.
String? _otherPackage(PackageRoots packages, String where, String uri) {
  final why = packages.problem;
  if (why != null) {
    return '$where: "$uri" cannot be followed: $why';
  }
  final name = uri.substring('package:'.length).split('/').first;
  return packages.roots.containsKey(name)
      ? null
      : '$where: "$uri" is not a package of .dart_tool/package_config.json';
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
    // A file that the record does not have did not change: it was not
    // compared before (a new import, or a version that compared fewer
    // files). It is named apart from the files that changed.
    final added = [
      for (final path in files)
        if (!last!.files.containsKey(path)) path,
    ];
    final changed = [
      for (final path in files)
        if (!added.contains(path)) path,
    ];
    final why = last == null
        ? 'the last run left no result of it'
        : files.isNotEmpty
        ? [
            if (changed.isNotEmpty) 'changed ${_listed(changed)}',
            if (added.isNotEmpty)
              'not in the last record (new to the comparison): '
                  '${_listed(added)}',
          ].join('; ')
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
