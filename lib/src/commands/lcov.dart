import 'dart:io';

import '../io/files.dart';
import '../lcov.dart';
import '../manifest.dart';
import '../types.dart';
import 'output.dart';

/// [file] as given on the command line or in the settings: relative to the
/// package unless absolute.
String resolveInPackage(String dir, String file) =>
    File(file).isAbsolute ? file : '$dir${Platform.pathSeparator}$file';

/// The tracefile a command works on: `--file`, or `settings.lcov.file`.
/// Throws [ManifestError] when neither is given.
String tracefileOf(LoadedManifest manifest, String? fileOption) {
  final file = fileOption ?? manifest.settings.lcovFile;
  if (file == null) {
    throw ManifestError(
      'no lcov file given. Pass --file <lcov.info> or set settings.lcov.file',
    );
  }
  return file;
}

/// Parses a tracefile of the package of [manifest].
LcovReport parseTracefile(LoadedManifest manifest, String text) {
  // `dart test` writes absolute paths with symbolic links resolved (on macOS
  // /tmp is /private/tmp), so both spellings of the directory are stripped.
  return parseLcov(
    text,
    rootDirs: {
      manifest.dir,
      Directory(manifest.dir).resolveSymbolicLinksSync(),
    }.toList(),
  );
}

/// Per-file 100% line and branch coverage from an lcov tracefile.
///
/// Returns the exit code: 0 when every gate passes, 1 on a violation or when
/// the tracefile cannot be read. Throws [ManifestError] (exit code 2) when the
/// manifest is unusable or no tracefile is named.
int runLcov(String dir, String? fileOption, Io io) {
  final manifest = readManifest(dir);
  return judgeTracefile(manifest, tracefileOf(manifest, fileOption), io);
}

/// The judgement of [runLcov] on the tracefile [file] of a manifest that has
/// been read already.
int judgeTracefile(LoadedManifest manifest, String file, Io io) {
  final String text;
  try {
    text = readText(resolveInPackage(manifest.dir, file));
  } on FileSystemException catch (error) {
    io.err(
      '$executable lcov: cannot read $file (${error.osError?.message ?? error.message}). '
      'Run the tests with coverage first',
    );
    return 1;
  }

  final violations = [...manifest.violations];
  final existing = <String>[];
  for (final gate in manifest.gates) {
    if (existsExact(manifest.dir, gate.path)) {
      existing.add(gate.path);
    } else {
      violations.add(
        Violation(
          file: gate.path,
          message:
              'file not found (the check is case-sensitive). '
              'Update test-gates.json if it moved',
        ),
      );
    }
  }

  final report = parseTracefile(manifest, text);
  final total = summarizeLcov(report, manifest.settings.lcovSummaryExclude);
  io.out(
    total.found == 0
        ? 'reference: no instrumented lines in the lcov file'
        : 'reference: overall line coverage '
              '${(total.hit / total.found * 100).toStringAsFixed(2)}% '
              '(${total.hit}/${total.found}, not gated)',
  );

  final verdict = judgeLcov(existing, report, tracefile: file);
  for (final result in verdict.results) {
    // A gate without a usable record has no numbers to show; its violation
    // says why. Upstream prints the passing gates only.
    if (result.found > 0) {
      io.out(
        '  ${result.ok ? '✓' : '✗'} ${result.path}: '
        '${result.hit}/${result.found} lines, '
        '${result.branchesHit}/${result.branchesFound} branches',
      );
    }
  }
  violations.addAll(verdict.violations);
  if (violations.isNotEmpty) {
    printViolations(io, 'lcov', violations);
    return 1;
  }
  io.out(
    '$executable lcov: OK (${verdict.results.length} gate(s) at 100% line and '
    'branch coverage)',
  );
  return 0;
}
