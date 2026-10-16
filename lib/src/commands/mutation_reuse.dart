import 'dart:convert';
import 'dart:io';

import '../io/files.dart';
import '../mutation_reuse.dart';
import '../mutation_run.dart';
import '../pubspec.dart';
import '../types.dart';
import '../version.dart';

String _inPackage(String dir, String relativePath) =>
    '$dir${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}';

/// A fingerprint of [bytes]: their length and their 64-bit FNV-1a hash. It
/// tells a changed file from an unchanged one; nobody is expected to make
/// two files with the same one on purpose.
String fingerprint(List<int> bytes) {
  // The offset basis and the prime of FNV-1a, 64 bits. An int of the VM
  // wraps around at 64 bits, which is the arithmetic the hash is made for.
  var hash = 0xcbf29ce484222325;
  for (final byte in bytes) {
    hash = (hash ^ byte) * 0x100000001b3;
  }
  return '${bytes.length}:${hash.toUnsigned(64).toRadixString(16)}';
}

/// True when [relativePath] is a file of that spelling, from the package in
/// [dir] (see [existsExact]); a path outside it starts with `../`.
bool _exists(String dir, String relativePath) {
  final segments = relativePath.split('/');
  final up = segments.takeWhile((segment) => segment == '..').length;
  return existsExact(
    [dir, ...List.filled(up, '..')].join(Platform.pathSeparator),
    segments.skip(up).join('/'),
  );
}

String? _fingerprintOf(String path) {
  try {
    return fingerprint(File(path).readAsBytesSync());
  } on FileSystemException {
    return null;
  }
}

/// The files of the package in [dir] as git lists them (tracked, and
/// untracked ones that are not ignored), relative to it with `/`, or `null`
/// when git cannot list them.
List<String>? _listed(String dir) {
  final ProcessResult result;
  try {
    result = Process.runSync('git', [
      'ls-files',
      '-z',
      '--cached',
      '--others',
      '--exclude-standard',
    ], workingDirectory: dir);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  return [
    for (final path in (result.stdout as String).split('\u0000'))
      if (path.isNotEmpty) path,
  ];
}

/// What [planReuse] is given, read from the package.
class ReuseInputs {
  const ReuseInputs({
    required this.context,
    required this.gates,
    required this.problem,
    required this.report,
    required this.recordText,
    required this.timedOut,
  });

  final Map<String, String> context;
  final List<GateState> gates;
  final String? problem;
  final String? report;
  final String? recordText;
  final List<String> timedOut;
}

/// Reads what the results of the gates of [targets] depend on in the
/// package [dir] as it is now.
///
/// [reportText] is the report at [reportPath] before the run (`null`: none),
/// and the files of a run that are written by it ([reportFile], what
/// [rest] names) are not part of what a test can read.
ReuseInputs readReuseInputs(
  String dir,
  List<({String file, List<String> tests})> targets, {
  required List<ImportAlias> aliases,
  required String dartMutantVersion,
  required List<String> rest,
  required String reportFile,
  required String? reportText,
  List<String>? flutter,
}) {
  final sources = <String, String?>{};
  String? readSource(String path) => sources.putIfAbsent(path, () {
    if (!_exists(dir, path)) {
      return null;
    }
    try {
      return readText(_inPackage(dir, path));
    } on FileSystemException {
      return null;
    }
  });
  final fingerprints = <String, String>{};
  String fingerprintIn(String path) => fingerprints.putIfAbsent(
    path,
    () => _fingerprintOf(_inPackage(dir, path)) ?? 'missing',
  );

  String? everything;
  var listedYet = false;
  String? everythingNow() {
    if (!listedYet) {
      listedYet = true;
      final written = {
        reportFile,
        recordFile,
        planFile,
        for (final argument in rest) argument.split('=').last,
      };
      final listed = _listed(dir);
      if (listed != null) {
        final lines = [
          for (final path in listed..sort())
            if (!path.startsWith('.dart_tool/') && !written.contains(path))
              '$path\u0000${fingerprintIn(path)}',
        ];
        everything = fingerprint(utf8.encode(lines.join('\n')));
      }
    }
    return everything;
  }

  final resolution = _resolution(dir);
  final packages = resolution.root == null
      ? (roots: const <String, String?>{}, problem: resolution.why)
      : packageRootsOf(
          config: _readOrNull(
            '${resolution.root}${Platform.pathSeparator}.dart_tool'
            '${Platform.pathSeparator}package_config.json',
          ),
          lock: _readOrNull(
            '${resolution.root}${Platform.pathSeparator}pubspec.lock',
          ),
          configFile: Uri.directory(
            resolution.root!,
          ).resolve('.dart_tool/package_config.json'),
          package: Uri.directory(resolution.package),
        );

  String? problem;
  final gates = <GateState>[];
  for (final target in targets) {
    final configs = {
      for (final test in target.tests)
        for (final config in testConfigsFor(test))
          if (existsExact(dir, config)) config,
    };
    final reach = reachOf(
      [target.file, ...target.tests, ...configs],
      aliases,
      readSource,
      packages: packages,
    );
    problem ??= reach.problem;
    gates.add(
      GateState(
        target.file,
        {for (final path in reach.files) path: fingerprintIn(path)},
        readsFiles: reach.readsFiles,
        everything: reach.readsFiles ? everythingNow() : null,
      ),
    );
  }

  String? recordText;
  try {
    recordText = readText(_inPackage(dir, recordFile));
  } on FileSystemException {
    recordText = null;
  }
  return ReuseInputs(
    context: {
      'test_gates': packageVersion,
      dartMutant: dartMutantVersion,
      'the Dart SDK': Platform.version,
      'the options after --': jsonEncode(rest),
      '--report': reportFile,
      for (final file in configFiles) file: fingerprintIn(file),
      ..._packageContext(dir, resolution, flutter ?? const ['flutter']),
    },
    gates: gates,
    problem: problem,
    report: reportText == null ? null : fingerprint(utf8.encode(reportText)),
    recordText: recordText,
    timedOut: timedOutGates(reportText, [
      for (final target in targets) target.file,
    ]),
  );
}

/// Output of [command] with [arguments], or `null` when it cannot be
/// started or fails.
String? _outputOf(List<String> command, List<String> arguments, String dir) {
  try {
    final result = Process.runSync(
      command.first,
      [...command.sublist(1), ...arguments],
      workingDirectory: dir,
      runInShell: Platform.isWindows,
    );
    return result.exitCode == 0 ? result.stdout as String : null;
  } on ProcessException {
    return null;
  }
}

String? _readOrNull(String path) {
  try {
    return readText(path);
  } on FileSystemException {
    return null;
  }
}

/// Where the dependencies of the package in [dir] are resolved.
///
/// [package]: the package as a path on disk. [pubspec]: its pubspec, `null`
/// when it cannot be read. [root]: the directory of the lock file and of
/// `.dart_tool/package_config.json`, the package itself, or for a member of
/// a pub workspace the root of the workspace [levels] directories above it
/// (found by going up to the pubspec with `workspace:`), `null` when there
/// is none ([why]).
typedef _Resolution = ({
  String package,
  String? pubspec,
  String? root,
  int levels,
  String? why,
});

_Resolution _resolution(String dir) {
  // The path as it is on disk: `--dir .` (the default) or `packages/app/.`
  // would otherwise start the way up one directory too low.
  final package = Directory(dir).resolveSymbolicLinksSync();
  final pubspec = _readOrNull(_inPackage(package, 'pubspec.yaml'));
  if (pubspec == null || !inWorkspace(pubspec)) {
    return (
      package: package,
      pubspec: pubspec,
      root: package,
      levels: 0,
      why: null,
    );
  }
  var root = Directory(package).parent;
  var levels = 1;
  while (true) {
    final text = _readOrNull(
      '${root.path}${Platform.pathSeparator}pubspec.yaml',
    );
    if (text != null && isWorkspaceRoot(text)) {
      return (
        package: package,
        pubspec: pubspec,
        root: root.path,
        levels: levels,
        why: null,
      );
    }
    if (root.parent.path == root.path) {
      return (
        package: package,
        pubspec: pubspec,
        root: null,
        levels: levels,
        why: 'the root of the workspace is not found',
      );
    }
    root = root.parent;
    levels++;
  }
}

/// What the pubspec of the package adds to the context: for a member of a
/// pub workspace, the pubspec and the lock file of the root; for a Flutter
/// package, the version of Flutter that [flutter] reports.
Map<String, String> _packageContext(
  String dir,
  _Resolution resolution,
  List<String> flutter,
) {
  final pubspec = resolution.pubspec;
  if (pubspec == null) {
    return const {};
  }
  final context = <String, String>{};
  if (inWorkspace(pubspec)) {
    if (resolution.root == null) {
      context['the root of the workspace'] = 'not found';
    } else {
      for (final file in workspaceFiles(resolution.levels)) {
        context[file] =
            _fingerprintOf(_inPackage(resolution.package, file)) ?? 'missing';
      }
    }
  }
  if (usesFlutter(pubspec)) {
    // `--version` alone only when `--machine` gave nothing that can be read:
    // each start of flutter takes a while.
    final machine = flutterVersionOf(
      _outputOf(flutter, ['--version', '--machine'], dir),
      null,
    );
    context['Flutter'] = machine != flutterVersionOf(null, null)
        ? machine
        : flutterVersionOf(null, _outputOf(flutter, ['--version'], dir));
  }
  return context;
}

/// The package name from pubspec.yaml in [dir], or `null`.
String? packageNameIn(String dir) {
  try {
    return packageNameOf(readText(_inPackage(dir, 'pubspec.yaml')));
  } on FileSystemException {
    return null;
  }
}

/// Removes the record: a run that does not end as it should leaves none.
void deleteRecord(String dir) {
  final file = File(_inPackage(dir, recordFile));
  if (file.existsSync()) {
    file.deleteSync();
  }
}

/// Writes the record of a run that left [reportText] at its report, with
/// the gates of [written] in it.
void writeRecord(
  String dir,
  ReuseInputs inputs,
  String reportText,
  List<String> written,
) {
  final file = File(_inPackage(dir, recordFile));
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    recordAfterRun(
      last: inputs.recordText,
      context: inputs.context,
      reportVerified: reportVerified(
        recordText: inputs.recordText,
        context: inputs.context,
        report: inputs.report,
      ),
      report: fingerprint(utf8.encode(reportText)),
      ran: inputs.gates,
      written: written,
    ),
  );
}
