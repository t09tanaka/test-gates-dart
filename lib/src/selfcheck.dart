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

/// A line entry and a branch entry that say "not executed", and the total
/// of the lines of a record, as Dart writes them.
final _unexecutedLine = RegExp(r'^DA:(\d+),0$');
final _untakenBranch = RegExp(r'^BRDA:(\d+),[^,]*,[^,]*,(0|-)$');
final _linesFound = RegExp(r'^LF:(\d+)$');

/// The tracefile of a run with probes in the gates, as the same run would
/// have written it without them: for each gate of [probes], the line entry
/// and the branch entry of the probe are taken out of the record of the
/// gate, and its `LF:` total is one less.
///
/// That is all a probe adds to a tracefile: it is a function at the end of
/// the file that nothing calls, so it moves no other line and no other
/// count. Only an entry that says "not executed" is taken out; a probe that
/// is reported as executed stays, and fails the gate.
///
/// [rootDirs] are the directories a record may have in front of its path,
/// as for the judgement. Line ends are kept as they are.
String tracefileWithoutProbes(
  String text,
  List<ProbedGate> probes, {
  List<String> rootDirs = const [],
}) {
  final lineOf = {
    for (final probe in probes) normalizeLcovPath(probe.path): probe.line,
  };
  final kept = <String>[];
  // The line of the probe of the record that is being read, when it is the
  // record of a gate, and how many line entries were taken out of it.
  int? probeLine;
  late int removed;
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (line.startsWith('SF:')) {
      probeLine = lineOf[normalizeLcovPath(line.substring(3), rootDirs)];
      removed = 0;
    } else if (line == 'end_of_record') {
      probeLine = null;
    } else {
      // In a record that is not of a gate no entry is at "the line of the
      // probe", and nothing was taken out.
      final entry =
          _unexecutedLine.firstMatch(line) ?? _untakenBranch.firstMatch(line);
      if (entry is RegExpMatch && int.parse(entry[1]!) == probeLine) {
        if (line.startsWith('D')) {
          removed++;
        }
        continue;
      }
      final found = _linesFound.firstMatch(line);
      if (found is RegExpMatch) {
        kept.add(
          raw.replaceFirst(found[1]!, '${int.parse(found[1]!) - removed}'),
        );
        continue;
      }
    }
    kept.add(raw);
  }
  return kept.join('\n');
}
