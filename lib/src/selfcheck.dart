import 'dart:convert';
import 'dart:math';

import 'lcov.dart';

/// The comment line of a probe starts with this. The digit that follows is the
/// number of line breaks (0 or 1) that were added in front of the comment,
/// so that removing the probe gives back the file byte for byte.
const probeMarker = '// test_gates selfcheck probe ';

const _probeHint =
    'Never executed. Removed when the run ends; delete these two lines if '
    'they are left behind.';

final _probeTail = RegExp(
  '(\n?)${RegExp.escape(probeMarker)}([01])\\. [^\n]*\n'
  r'int testGatesSelfcheckProbe[0-9a-f]{8}\(\) => 0;'
  '\n\$',
);

/// How far from the end of a file a probe can start. The probe is two lines
/// of fixed length; this is well above it.
const _tailBytes = 512;

const _lineFeed = 0x0A;

/// The name of the function a probe adds to [gatePath].
///
/// It differs per file: two gates can be parts of one library, where the same
/// name twice would not compile, and every gate would then fail for a reason
/// that proves nothing.
String probeFunctionName(String gatePath) {
  // FNV-1a, 32 bit.
  var hash = 0x811C9DC5;
  for (final byte in utf8.encode(gatePath)) {
    hash = ((hash ^ byte) * 0x01000193) & 0xFFFFFFFF;
  }
  return 'testGatesSelfcheckProbe${hash.toRadixString(16).padLeft(8, '0')}';
}

/// Code that no test executes, to be appended to a gate.
class Probe {
  const Probe({required this.suffix, required this.line});

  /// What to append to the file. ASCII only. The bytes already in the file are
  /// not rewritten, so cutting the file back to its old length restores it.
  final List<int> suffix;

  /// 1-based line of the function. Dart writes `DA:<line>,0` and
  /// `BRDA:<line>,0,0,0` for the entry of a function that is never called.
  final int line;
}

/// Builds the probe for a gate whose content is [original].
///
/// The probe is a top-level function at the end of the file. That position is
/// valid after any directive (`import`, `part`), and in a `part of` file.
Probe buildProbe(List<int> original, String gatePath) {
  final needsLineBreak = original.isNotEmpty && original.last != _lineFeed;
  final lineBreaks = original.where((byte) => byte == _lineFeed).length;
  final text =
      '${needsLineBreak ? '\n' : ''}'
      '$probeMarker${needsLineBreak ? 1 : 0}. $_probeHint\n'
      'int ${probeFunctionName(gatePath)}() => 0;\n';
  return Probe(
    suffix: ascii.encode(text),
    // The comment is on the line after the last line break, the function on
    // the next one.
    line: lineBreaks + (needsLineBreak ? 1 : 0) + 2,
  );
}

/// The length [bytes] had before a probe was appended, or `null` when it does
/// not end with a probe.
int? lengthWithoutProbe(List<int> bytes) {
  final start = max(0, bytes.length - _tailBytes);
  final tail = latin1.decode(bytes.sublist(start));
  final match = _probeTail.firstMatch(tail);
  if (match == null) {
    return null;
  }
  // Group 1 is a line break in front of the comment. It belongs to the probe
  // only when the marker says that one was added.
  final added = match.group(2) == '1' ? 1 : 0;
  final own = match.group(1)!.length;
  return start + match.start + own - added;
}

/// A gate with its probe in place.
class ProbedGate {
  const ProbedGate({required this.path, required this.line});

  final String path;
  final int line;
}

/// Decides whether the coverage command produced a measurement at all. A
/// tracefile from a failed or interrupted run proves nothing about the gates.
///
/// [exitCode] is `null` when the command could not be started; [startError]
/// then says why. [tracefileRead] is false when the command left no readable
/// tracefile behind.
///
/// Returns why nothing can be concluded, or `null`.
String? judgeCoverageRun({
  required String command,
  required int? exitCode,
  String? startError,
  required bool tracefileRead,
  required String tracefile,
}) {
  if (exitCode == null) {
    return 'cannot start "$command"${startError == null ? '' : ' ($startError)'}';
  }
  if (exitCode != 0) {
    return '"$command" failed (exit $exitCode) with the probes in place. '
        'It has to pass and only write the tracefile; the verdict is taken '
        'from the tracefile';
  }
  if (!tracefileRead) {
    return '"$command" passed but did not write $tracefile. '
        'Does the command write the tracefile named by settings.lcov.file?';
  }
  return null;
}

/// Decides whether one negative control held: with the probe in place, the
/// lcov judgement must fail for this gate, and it must fail on the probe.
/// A gate that is red for another reason proves nothing.
///
/// Returns why the control did not hold, or `null` when it held.
String? judgeProbe(ProbedGate gate, LcovReport report, LcovVerdict verdict) {
  final file = lcovFileOf(report, gate.path);
  if (file == null) {
    return 'no record in the tracefile, so the probe was not measured. '
        'No test loads this file';
  }
  final line = gate.line;
  if (!file.uncovered.contains(line)) {
    return 'the probe at line $line is not reported as a line that was not '
        'executed. The tracefile does not measure this file as it is on disk';
  }
  if (!file.untakenBranchLines.contains(line)) {
    return 'the probe at line $line is not reported as a branch that was not '
        'taken. Collect the coverage with --branch-coverage';
  }
  // A gate has one result: a path that is listed twice is a problem of
  // test-gates.json, and stops selfcheck before anything is judged.
  final failed = verdict.results.any(
    (result) => result.path == gate.path && !result.ok,
  );
  if (!failed) {
    return 'the probe at line $line was not executed, and the gate passed';
  }
  return null;
}

/// The line and the count of an entry `DA:<line>,<hits>` or
/// `BRDA:<line>,<block>,<branch>,<taken>`, read as the judgement reads them
/// (a `-` is 0), or `null` for any other line and for an entry that cannot
/// be read.
({int line, num hits})? _entry(String line) {
  final branch = line.startsWith('BRDA:');
  if (!branch && !line.startsWith('DA:')) {
    return null;
  }
  final fields = line.substring(branch ? 5 : 3).split(',');
  final count = branch ? 3 : 1;
  if (fields.length <= count) {
    return null;
  }
  final number = int.tryParse(fields[0]);
  final hits = fields[count].trim() == '-' ? 0 : num.tryParse(fields[count]);
  return number == null || hits == null ? null : (line: number, hits: hits);
}

final _total = RegExp(r'^(LF|FNF):(\d+)$');

/// One record of a tracefile ([lines], from its `SF:` line on) without what
/// the probe at [probeLine], a function called [probeName], added to it.
///
/// Nothing is taken out when one of the entries at that line says
/// "executed": the probe then is not what it is meant to be, and its
/// entries stay together, for the judgement to fail on.
List<String> _recordWithoutProbe(
  List<String> lines,
  int probeLine,
  String probeName,
) {
  final atProbe = [
    for (final line in lines)
      if (_entry(line.trim()) case final entry? when entry.line == probeLine)
        entry,
  ];
  if (atProbe.any((entry) => entry.hits > 0)) {
    return lines;
  }
  var removedLines = 0;
  var removedFunctions = 0;
  final kept = <String>[];
  for (final raw in lines) {
    final line = raw.trim();
    if (_entry(line)?.line == probeLine) {
      if (line.startsWith('DA:')) {
        removedLines++;
      }
      continue;
    }
    // With function coverage: `FN:<line>,<name>` and `FNDA:<hits>,<name>`.
    if ((line.startsWith('FN:') || line.startsWith('FNDA:')) &&
        line.endsWith(',$probeName')) {
      if (line.startsWith('FN:')) {
        removedFunctions++;
      }
      continue;
    }
    kept.add(raw);
  }
  return [
    for (final raw in kept)
      if (_total.firstMatch(raw.trim()) case final total?)
        raw.replaceFirst(
          total[2]!,
          '${int.parse(total[2]!) - (total[1] == 'LF' ? removedLines : removedFunctions)}',
        )
      else
        raw,
  ];
}

/// The tracefile of a run with probes in the gates, as the same run would
/// have written it without them: for each gate of [probes], the entries of
/// the probe are taken out of the record of the gate. Those are its line
/// entry and its branch entry (`DA:` / `BRDA:` at the line of the probe),
/// with function coverage also its `FN:` / `FNDA:` entries, and the totals
/// `LF:` and `FNF:` are that much less.
///
/// That is all a probe adds to a tracefile: it is a function at the end of
/// the file that nothing calls, so it moves no other line and no other
/// count. The entries are read as the judgement reads them. They are only
/// taken out when all of them say "not executed"; a probe that is reported
/// as executed stays, and fails the gate.
///
/// [rootDirs] are the directories a record may have in front of its path,
/// as for the judgement. Line ends are kept as they are, and so is
/// everything that is outside a record of a gate.
String tracefileWithoutProbes(
  String text,
  List<ProbedGate> probes, {
  List<String> rootDirs = const [],
}) {
  final byPath = {
    for (final probe in probes) normalizeLcovPath(probe.path): probe,
  };
  final kept = <String>[];
  // The lines of the record that is being read, when it is one of a gate.
  var record = <String>[];
  ProbedGate? gate;
  void close() {
    final probe = gate;
    kept.addAll(
      probe == null
          ? record
          : _recordWithoutProbe(
              record,
              probe.line,
              probeFunctionName(probe.path),
            ),
    );
    record = [];
    gate = null;
  }

  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      close();
      gate = byPath[normalizeLcovPath(line.substring(3), rootDirs)];
    }
    record.add(raw);
    if (line == 'end_of_record') {
      close();
    }
  }
  close();
  return kept.join('\n');
}
