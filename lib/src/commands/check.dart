import 'dart:io';

import '../dart_source.dart';
import '../gate_path.dart';
import '../import_policy.dart';
import '../io/files.dart';
import '../manifest.dart';
import '../pubspec.dart';
import '../scan.dart';
import '../spec_path.dart';
import '../types.dart';
import 'output.dart';

String? _pubspec(String dir) {
  try {
    return readText('$dir${Platform.pathSeparator}pubspec.yaml');
  } on FileSystemException {
    return null;
  }
}

String _read(String dir, String relativePath) => readText(
  '$dir${Platform.pathSeparator}'
  '${relativePath.replaceAll('/', Platform.pathSeparator)}',
);

/// Every static rule of the gates. Returns all violations, not just the first.
///
/// The gates whose `package:` imports could not be told from imports of the
/// package itself, because there is no pubspec.yaml that names the package,
/// are added to [notFollowed].
List<Violation> checkGates(
  LoadedManifest manifest, {
  List<String>? notFollowed,
}) {
  final dir = manifest.dir;
  final settings = manifest.settings;
  final pubspec = _pubspec(dir);
  final packageName = pubspec == null ? null : packageNameOf(pubspec);
  final violations = [
    ...manifest.violations,
    // Without the name, `package:<name>/` is taken for another package and
    // is not followed.
    if (pubspec != null && packageName == null)
      const Violation(
        file: 'pubspec.yaml',
        message:
            'the name of the package is not found (looked for a line '
            '"name: <name>"), so imports of its own files with '
            '"package:<name>/" cannot be followed',
      ),
  ];
  // A file that several gates reach is read once.
  final sources = <String, String?>{};
  String? readSource(String path) => sources.putIfAbsent(path, () {
    if (!existsExact(dir, path)) {
      return null;
    }
    try {
      return _read(dir, path);
    } on FileSystemException {
      return null;
    }
  });

  for (final gate in manifest.gates) {
    final path = gate.path;
    if (!isPlainRelativePath(path)) {
      violations.add(
        Violation(
          file: manifestFile,
          message:
              '$path: write the path relative to the package, with "/" and '
              'without ".."',
        ),
      );
      continue;
    }
    if (gateExtensionOf(path, settings.gateExtensions) == null) {
      violations.add(
        Violation(
          file: path,
          message:
              'a gate must be one of ${settings.gateExtensions.join(' / ')} '
              '(settings.gateExtensions)',
        ),
      );
      continue;
    }
    if (looksLikeSpec(path, settings)) {
      violations.add(Violation(file: path, message: 'a test cannot be a gate'));
      continue;
    }
    for (final rule in settings.impurePaths) {
      if (rule.regex.hasMatch(path)) {
        violations.add(
          Violation(
            file: path,
            message: 'cannot be a gate (${rule.reason}). Move it to candidates',
          ),
        );
      }
    }

    if (!existsExact(dir, path)) {
      violations.add(
        Violation(
          file: path,
          message: 'file not found (the check is case-sensitive)',
        ),
      );
      continue;
    }
    final source = _read(dir, path);
    violations.addAll(
      scanGateSource(
        path,
        source,
        settings,
        packageName: packageName,
        readSource: readSource,
      ),
    );
    if (pubspec == null &&
        parseDartSource(source).imports.any(
          (imported) =>
              imported.uri.startsWith('package:') &&
              resolveUri(imported.uri, path, settings.importAliases) == null,
        )) {
      notFollowed?.add(path);
    }

    final candidates = specCandidatesFor(path, settings);
    if (candidates.isEmpty) {
      continue; // settings.spec.suffixes is empty: no spec convention
    }
    final existing = [
      for (final candidate in candidates)
        if (existsExact(dir, candidate)) candidate,
    ];
    if (existing.isEmpty) {
      violations.add(
        Violation(
          file: path,
          message:
              'test not found (looked for ${candidates.join(', ')}; the '
              'check is case-sensitive)',
        ),
      );
      continue;
    }
    if (existing.length > 1) {
      violations.add(
        Violation(
          file: path,
          message:
              'more than one test (${existing.join(', ')}). Keep one, or '
              'narrow settings.spec',
        ),
      );
      continue;
    }
    violations.addAll(
      scanSpecSource(existing.single, _read(dir, existing.single)),
    );
  }

  for (final candidate in manifest.candidates) {
    // A candidate may be a directory ("everything under lib/services").
    if (!isPlainRelativePath(candidate.path) ||
        !existsExact(dir, candidate.path, orDirectory: true)) {
      violations.add(
        Violation(
          file: manifestFile,
          message:
              '${candidate.path}: candidate not found. Remove it, or fix '
              'the path',
        ),
      );
    }
  }

  return violations;
}

/// Static checks, before the gate run.
///
/// Returns the exit code: 0 when nothing is wrong, 1 on a violation. Throws
/// [ManifestError] (exit code 2) when the manifest is unusable.
int runCheck(String dir, Io io) {
  final manifest = readManifest(dir);
  final notFollowed = <String>[];
  final violations = checkGates(manifest, notFollowed: notFollowed);
  if (notFollowed.isNotEmpty) {
    // Not a violation: a directory of files without a pubspec is a way to
    // use the checks. But what was not looked at is said.
    io.out(
      '$executable check: note: no pubspec.yaml here, so the "package:" '
      'imports of ${notFollowed.join(', ')} were not followed: without the '
      'name of the package, each is taken for an import of another package',
    );
  }
  if (violations.isNotEmpty) {
    printViolations(io, 'check', violations);
    return 1;
  }
  io.out(
    '$executable check: OK (${manifest.gates.length} gate(s), '
    '${manifest.candidates.length} candidate(s))',
  );
  return 0;
}
