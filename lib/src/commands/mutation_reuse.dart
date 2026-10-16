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
}) {
  final sources = <String, String?>{};
  String? readSource(String path) => sources.putIfAbsent(path, () {
    if (!existsExact(dir, path)) {
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
      report: fingerprint(utf8.encode(reportText)),
      ran: inputs.gates,
      written: written,
    ),
  );
}
