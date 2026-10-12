import 'dart:math';

import 'types.dart';

/// Coverage of one source file in an lcov tracefile.
class LcovFile {
  const LcovFile({
    required this.found,
    required this.hit,
    required this.uncovered,
    required this.branchesFound,
    required this.branchesHit,
    required this.untakenBranchLines,
  });

  /// Instrumented lines.
  final int found;

  /// Instrumented lines executed at least once.
  final int hit;

  /// Instrumented lines never executed, ascending. Empty when the record has
  /// no `DA:` entry.
  final List<int> uncovered;

  /// `BRDA:` entries, counted by line + block + branch.
  final int branchesFound;

  /// `BRDA:` entries taken at least once.
  final int branchesHit;

  /// Lines of the `BRDA:` entries never taken, ascending, each line once.
  final List<int> untakenBranchLines;
}

/// A parsed tracefile.
class LcovReport {
  const LcovReport({
    required this.files,
    required this.hasBranchData,
    this.problems = const [],
  });

  final Map<String, LcovFile> files;

  /// False when the tracefile has no `BRDA:` entry at all. Dart writes one for
  /// the entry of every function, so this means the coverage was collected
  /// without `--branch-coverage`.
  final bool hasBranchData;

  /// What makes the tracefile unreliable as a whole: a `DA:` / `BRDA:` entry
  /// that cannot be read, or a last record that is not closed (a truncated
  /// file). An entry that is dropped could be the one that was not covered.
  final List<String> problems;
}

class _Accumulator {
  final lines = <int, num>{};
  final branches = <String, num>{};
  final branchLines = <String, int>{};
  int found = 0;
  int hit = 0;
}

/// The record being read. `LF:` / `LH:` only count when the record turns out
/// to have no `DA:` entry.
class _OpenRecord {
  _OpenRecord(this.file);

  final _Accumulator file;
  bool hasDa = false;
  int found = 0;
  int hit = 0;
}

num _max(num? a, num b) => a == null ? b : max(a, b);

/// The path of a record as the judgement compares it: with `/`, without one
/// of [rootDirs] in front of it, and without a leading `./`.
String normalizeLcovPath(String file, [List<String> rootDirs = const []]) {
  var normalized = file.replaceAll(r'\', '/');
  for (final rootDir in rootDirs) {
    final root = rootDir.replaceAll(r'\', '/').replaceFirst(RegExp(r'/+$'), '');
    if (normalized.startsWith('$root/')) {
      normalized = normalized.substring(root.length + 1);
      break;
    }
  }
  return normalized.replaceFirst(RegExp(r'^\./'), '');
}

/// Reads an lcov tracefile into per-file line and branch coverage.
///
/// Lines are counted from the `DA:` entries and branches from the `BRDA:`
/// entries, never from the totals (`LF:` / `LH:` / `BRF:` / `BRH:`), which a
/// tracefile can carry out of step with its entries. `LF:` / `LH:` are only
/// used for a record that has no `DA:` entry at all. Dart writes no `BRF:` /
/// `BRH:`.
///
/// An entry that cannot be read, and a last record without `end_of_record`,
/// are returned as [LcovReport.problems] (upstream drops such entries).
///
/// When a file appears in several records (merged tracefiles), entries are
/// united: a line or a branch counts as hit if any record hit it.
///
/// `BRDA:<line>,<block>,<branch>,<taken>`: Dart always writes `0,0` for block
/// and branch and a number for `taken`. The lcov format also allows `-`
/// ("the block was never reached"), which is read as not taken.
///
/// Absolute `SF:` paths under one of [rootDirs] are made relative to it.
/// `flutter test` writes relative paths (`lib/a.dart`), `dart test` absolute
/// ones.
LcovReport parseLcov(String text, {List<String> rootDirs = const []}) {
  final files = <String, _Accumulator>{};
  _OpenRecord? record;
  var hasBranchData = false;
  final malformed = <int>[];
  var lineNumber = 0;

  void closeRecord() {
    final open = record;
    if (open != null && !open.hasDa) {
      open.file.found += open.found;
      open.file.hit += open.hit;
    }
    record = null;
  }

  for (final rawLine in text.split('\n')) {
    lineNumber++;
    final line = rawLine.trim();
    final open = record;
    if (line.startsWith('SF:')) {
      closeRecord();
      final path = normalizeLcovPath(line.substring(3), rootDirs);
      record = _OpenRecord(files.putIfAbsent(path, _Accumulator.new));
    } else if (line == 'end_of_record') {
      closeRecord();
    } else if (open == null) {
      // A line outside a record: nothing to count.
    } else if (line.startsWith('DA:')) {
      final fields = line.substring(3).split(',');
      // tryParse reads a number with blanks around it.
      final number = int.tryParse(fields[0]);
      final count = fields.length < 2 ? null : num.tryParse(fields[1]);
      if (number != null && count != null && count.isFinite) {
        open.hasDa = true;
        open.file.lines[number] = _max(open.file.lines[number], count);
      } else {
        malformed.add(lineNumber);
      }
    } else if (line.startsWith('BRDA:')) {
      final fields = line.substring(5).split(',');
      final number = int.tryParse(fields[0]);
      final taken = fields.length < 4
          ? null
          : (fields[3].trim() == '-' ? 0 : num.tryParse(fields[3]));
      if (number != null && taken != null && taken.isFinite) {
        hasBranchData = true;
        final key = '$number,${fields[1].trim()},${fields[2].trim()}';
        open.file.branches[key] = _max(open.file.branches[key], taken);
        open.file.branchLines[key] = number;
      } else {
        malformed.add(lineNumber);
      }
    } else if (line.startsWith('LF:')) {
      open.found = int.tryParse(line.substring(3)) ?? 0;
    } else if (line.startsWith('LH:')) {
      open.hit = int.tryParse(line.substring(3)) ?? 0;
    }
  }
  final unclosed = record != null;
  closeRecord();

  return LcovReport(
    hasBranchData: hasBranchData,
    problems: [
      if (malformed.isNotEmpty)
        'unreadable DA / BRDA entry at line ${_lineList(malformed)} of the '
            'tracefile. An entry that cannot be read cannot be counted',
      if (unclosed)
        'the last record is not closed with end_of_record. The tracefile '
            'looks truncated',
    ],
    files: {
      for (final MapEntry(key: path, value: file) in files.entries)
        path: _summarize(file),
    },
  );
}

LcovFile _summarize(_Accumulator file) {
  final uncovered = [
    for (final MapEntry(key: line, value: hits) in file.lines.entries)
      if (hits <= 0) line,
  ]..sort();
  final untaken = [
    for (final MapEntry(:key, value: taken) in file.branches.entries)
      if (taken <= 0) key,
  ];
  return LcovFile(
    found: file.lines.length + file.found,
    hit: file.lines.length - uncovered.length + file.hit,
    uncovered: uncovered,
    branchesFound: file.branches.length,
    branchesHit: file.branches.length - untaken.length,
    untakenBranchLines: {
      for (final key in untaken) file.branchLines[key]!,
    }.toList()..sort(),
  );
}

/// The record of [gatePath] in [report], or `null` when it has none. The path
/// is matched the way [judgeLcov] matches it.
LcovFile? lcovFileOf(LcovReport report, String gatePath) =>
    report.files[normalizeLcovPath(gatePath)];

/// The verdict for one gate. The counts are 0 when the gate has no record.
class LcovGateResult {
  const LcovGateResult({
    required this.path,
    this.found = 0,
    this.hit = 0,
    this.branchesFound = 0,
    this.branchesHit = 0,
    required this.ok,
  });

  final String path;
  final int found;
  final int hit;
  final int branchesFound;
  final int branchesHit;
  final bool ok;
}

class LcovVerdict {
  const LcovVerdict({required this.violations, required this.results});

  final List<Violation> violations;
  final List<LcovGateResult> results;
}

String _lineList(List<int> lines) =>
    lines.take(20).join(', ') + (lines.length > 20 ? ', …' : '');

/// Requires 100% line coverage and 100% branch coverage for every gate.
///
/// An absent measurement is never a pass:
/// - a tracefile with an unreadable entry or an unclosed record fails,
/// - a gate with no record (never loaded by a test) fails,
/// - a gate with no instrumented line fails,
/// - a tracefile without any `BRDA:` entry fails once, as a whole ([tracefile]
///   names it in the message): it was collected without branch coverage,
/// - a gate without `BRDA:` entry in a tracefile that has them fails.
LcovVerdict judgeLcov(
  List<String> gatePaths,
  LcovReport report, {
  required String tracefile,
}) {
  final violations = <Violation>[
    for (final problem in report.problems)
      Violation(file: tracefile, message: problem),
  ];
  final results = <LcovGateResult>[];
  if (!report.hasBranchData) {
    violations.add(
      Violation(
        file: tracefile,
        message:
            'no branch data (no BRDA entry). Collect the coverage with '
            '--branch-coverage: "flutter test --coverage --branch-coverage" '
            'or "dart test --coverage-path=<file> --branch-coverage"',
      ),
    );
  }
  for (final gatePath in gatePaths) {
    final file = lcovFileOf(report, gatePath);
    if (file == null) {
      violations.add(
        Violation(file: gatePath, message: 'no record in the lcov file'),
      );
      results.add(LcovGateResult(path: gatePath, ok: false));
      continue;
    }
    if (file.found == 0) {
      violations.add(
        Violation(
          file: gatePath,
          message: 'no instrumented lines in the lcov record',
        ),
      );
      results.add(LcovGateResult(path: gatePath, ok: false));
      continue;
    }
    final linesOk = file.hit == file.found;
    if (!linesOk) {
      final shown = _lineList(file.uncovered);
      violations.add(
        Violation(
          file: gatePath,
          line: file.uncovered.firstOrNull,
          message:
              '${file.hit}/${file.found} lines covered'
              '${shown.isEmpty ? '' : ' (uncovered: $shown)'}',
        ),
      );
    }
    var branchesOk = false;
    if (file.branchesFound == 0) {
      // Already reported once for the whole tracefile when it has none.
      if (report.hasBranchData) {
        violations.add(
          Violation(
            file: gatePath,
            message: 'no branch data (no BRDA entry) in the lcov record',
          ),
        );
      }
    } else if (file.branchesHit != file.branchesFound) {
      violations.add(
        Violation(
          file: gatePath,
          line: file.untakenBranchLines.firstOrNull,
          message:
              '${file.branchesHit}/${file.branchesFound} branches taken '
              '(not taken, at lines: ${_lineList(file.untakenBranchLines)})',
        ),
      );
    } else {
      branchesOk = true;
    }
    results.add(
      LcovGateResult(
        path: gatePath,
        found: file.found,
        hit: file.hit,
        branchesFound: file.branchesFound,
        branchesHit: file.branchesHit,
        ok: linesOk && branchesOk,
      ),
    );
  }
  return LcovVerdict(violations: violations, results: results);
}

/// Total line coverage over the records whose path matches none of [exclude].
/// Reference only: nothing is required of the total.
({int found, int hit}) summarizeLcov(LcovReport report, List<RegExp> exclude) {
  var found = 0;
  var hit = 0;
  for (final MapEntry(key: path, value: file) in report.files.entries) {
    if (exclude.any((regex) => regex.hasMatch(path))) {
      continue;
    }
    found += file.found;
    hit += file.hit;
  }
  return (found: found, hit: hit);
}
