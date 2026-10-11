import 'dart:convert';
import 'dart:io';

import '../manifest.dart';
import '../settings.dart';
import '../types.dart';

/// True when [relativePath] is a file (or, with [orDirectory], a file or a
/// directory) under [rootDir] with exactly this spelling.
///
/// The default macOS and Windows file systems treat `Basket.dart` and
/// `basket.dart` as the same file; Linux (CI) does not. Each segment is
/// therefore compared with the directory listing.
bool existsExact(
  String rootDir,
  String relativePath, {
  bool orDirectory = false,
}) {
  var current = rootDir;
  for (final segment in relativePath.split('/')) {
    if (segment.isEmpty || segment == '.') {
      continue;
    }
    final List<String> entries;
    try {
      entries = [
        for (final entity in Directory(current).listSync())
          entity.uri.pathSegments.lastWhere((part) => part.isNotEmpty),
      ];
    } on FileSystemException {
      return false;
    }
    if (!entries.contains(segment)) {
      return false;
    }
    current = '$current${Platform.pathSeparator}$segment';
  }
  return FileSystemEntity.isFileSync(current) ||
      (orDirectory && FileSystemEntity.isDirectorySync(current));
}

/// Reads a file as UTF-8 the way Node.js does, so that both tools see the same
/// text: a byte that is not UTF-8 becomes U+FFFD instead of an error, and a
/// byte order mark is kept (JSON with one is then rejected, as upstream does).
String readText(String path) {
  final bytes = File(path).readAsBytesSync();
  final text = utf8.decode(bytes, allowMalformed: true);
  final hasBom =
      bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF;
  return hasBom && !text.startsWith('\uFEFF') ? '\uFEFF$text' : text;
}

class LoadedManifest {
  const LoadedManifest({
    required this.dir,
    required this.gates,
    required this.candidates,
    required this.settings,
    required this.violations,
  });

  /// Absolute path of the package.
  final String dir;
  final List<Gate> gates;
  final List<Candidate> candidates;
  final ResolvedSettings settings;

  /// Problems inside the manifest entries.
  final List<Violation> violations;
}

/// Reads `<dir>/test-gates.json`. Throws [ManifestError] when it cannot be
/// used at all.
LoadedManifest readManifest(String dir) {
  final absoluteDir = Directory(dir).absolute.uri.normalizePath().toFilePath();
  final root =
      absoluteDir.length > 1 && absoluteDir.endsWith(Platform.pathSeparator)
      ? absoluteDir.substring(0, absoluteDir.length - 1)
      : absoluteDir;
  final file = File('$root${Platform.pathSeparator}$manifestFile');
  if (!file.existsSync()) {
    throw ManifestError('$manifestFile not found in $root');
  }
  final String text;
  try {
    text = readText(file.path);
  } on FileSystemException catch (error) {
    throw ManifestError('cannot read ${file.path}: ${error.message}');
  }
  final parsed = parseManifest(text);
  final ResolvedSettings settings;
  try {
    settings = resolveSettings(parsed.settings);
  } on SettingsError catch (error) {
    throw ManifestError('$manifestFile: ${error.message}');
  }
  return LoadedManifest(
    dir: root,
    gates: parsed.gates,
    candidates: parsed.candidates,
    settings: settings,
    violations: parsed.violations,
  );
}
