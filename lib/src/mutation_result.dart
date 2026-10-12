import 'dart:convert';

import 'json.dart';
import 'manifest.dart';
import 'types.dart';

/// A position in a source: 1-based line and column.
class ReportPosition {
  const ReportPosition(this.line, this.column);

  final int line;
  final int column;
}

/// One mutant of a report in the mutation-testing-elements (Stryker) schema.
class ReportMutant {
  const ReportMutant({
    required this.mutatorName,
    required this.status,
    required this.start,
    required this.end,
    this.replacement,
    this.statusReason,
  });

  final String mutatorName;
  final String status;
  final ReportPosition start;

  /// Exclusive.
  final ReportPosition end;
  final String? replacement;

  /// What the tool says about the status, when it does: the message of the
  /// compiler for a mutant that does not compile.
  final String? statusReason;
}

/// The mutants of one file, with the source they were made from.
class ReportFile {
  const ReportFile({this.source, this.mutants = const []});

  final String? source;
  final List<ReportMutant> mutants;
}

/// The part of a mutation report that the verdict depends on.
class MutationReport {
  const MutationReport(this.files, {this.part});

  /// By path, as written in the report.
  final Map<String, ReportFile> files;

  /// `2/4` when the report is that of a part of a run (`config.shard` of a
  /// report of `dart_mutant run --shard`), else `null`. The mutants of the
  /// other parts were not evaluated in it.
  final String? part;
}

/// Thrown by [parseMutationReport] when the text is not a mutation report.
class ReportFormatError implements Exception {
  ReportFormatError(this.message);

  final String message;

  @override
  String toString() => message;
}

ReportPosition? _position(Object? value) {
  final object = asObject(value);
  final line = asInteger(object?['line']);
  final column = asInteger(object?['column']);
  return line == null || column == null ? null : ReportPosition(line, column);
}

/// Reads a report in the mutation-testing-elements JSON schema. Throws
/// [ReportFormatError] when a mutant lacks what the verdict needs: a mutant
/// that cannot be read must not be skipped.
MutationReport parseMutationReport(String text) {
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } on FormatException catch (error) {
    throw ReportFormatError('not valid JSON: ${error.message}');
  }
  final root = asObject(raw);
  if (root == null) {
    throw ReportFormatError('must be a JSON object');
  }
  final files = <String, ReportFile>{};
  final rawFiles = root['files'];
  if (rawFiles != null && rawFiles is! JsonObject) {
    throw ReportFormatError('"files" must be an object');
  }
  for (final MapEntry(key: path, :value)
      in (asObject(rawFiles) ?? {}).entries) {
    final file = asObject(value);
    if (file == null) {
      throw ReportFormatError('files[${quote(path)}] must be an object');
    }
    final source = file['source'];
    if (source != null && source is! String) {
      throw ReportFormatError('files[${quote(path)}].source must be a string');
    }
    final rawMutants = file['mutants'];
    if (rawMutants != null && rawMutants is! List) {
      throw ReportFormatError('files[${quote(path)}].mutants must be an array');
    }
    final mutants = <ReportMutant>[];
    for (final (index, item) in (rawMutants as List? ?? const []).indexed) {
      final at = 'files[${quote(path)}].mutants[$index]';
      final mutant = asObject(item);
      final location = asObject(mutant?['location']);
      final start = _position(location?['start']);
      final end = _position(location?['end']);
      final name = mutant?['mutatorName'];
      final status = mutant?['status'];
      final replacement = mutant?['replacement'];
      if (mutant == null ||
          name is! String ||
          status is! String ||
          start == null ||
          end == null ||
          (replacement != null && replacement is! String)) {
        throw ReportFormatError(
          '$at must have mutatorName, status and location.start / end',
        );
      }
      mutants.add(
        ReportMutant(
          mutatorName: name,
          status: status,
          start: start,
          end: end,
          replacement: replacement as String?,
          statusReason: asText(mutant['statusReason']),
        ),
      );
    }
    files[path] = ReportFile(source: source as String?, mutants: mutants);
  }
  final shard = asObject(root['config'])?['shard'];
  final numbers = asObject(shard);
  return MutationReport(
    files,
    part: shard == null
        ? null
        : '${numbers?['index'] ?? '?'}/${numbers?['count'] ?? '?'}',
  );
}

/// A mutant as it is listed for the reader. [allowance] can be pasted into
/// `equivalentMutants` or `expectedTimeouts`.
class ListedMutant {
  const ListedMutant({
    required this.file,
    required this.line,
    required this.column,
    required this.status,
    required this.mutator,
    required this.original,
    required this.replacement,
    required this.occurrence,
    required this.sameKeyCount,
    this.statusReason,
  });

  final String file;
  final int line;
  final int column;
  final String status;
  final String mutator;
  final String original;
  final String replacement;

  /// 1-based position among the mutants of the file with the same
  /// mutator / original / replacement.
  final int occurrence;

  /// How many mutants of the file share that key. `occurrence` is required
  /// when this is > 1.
  final int sameKeyCount;

  /// What the report says about the status, or `null`.
  final String? statusReason;

  /// The entry that would cover this mutant, with an empty `reason`.
  Map<String, Object?> get allowance => {
    'mutator': mutator,
    'original': original,
    'replacement': replacement,
    if (sameKeyCount > 1) 'occurrence': occurrence,
    'reason': '',
  };
}

class MutationSummary {
  int total = 0;

  /// Killed + Timeout.
  int detected = 0;

  /// The Timeout part of [detected]. Shown on its own: under heavy load
  /// mutants time out that would otherwise survive.
  int timeout = 0;

  /// Survived / NoCoverage mutants matched by an allowance.
  int allowed = 0;

  /// CompileError + RuntimeError: the mutated code is not a program, so
  /// nothing was evaluated.
  int notEvaluable = 0;

  /// Survived / NoCoverage mutants with no allowance.
  int unallowed = 0;

  /// The part of [timeout] that `expectedTimeouts` entries cover.
  int expectedTimeout = 0;
}

class MutationVerdict {
  MutationVerdict();

  final violations = <Violation>[];
  final survivors = <ListedMutant>[];

  /// Timed-out mutants that no `expectedTimeouts` entry covers. When there
  /// are more of them than `maxTimeouts`, [violations] says so.
  final unexpectedTimeouts = <ListedMutant>[];

  /// The mutants that could not be evaluated (CompileError, RuntimeError).
  /// They do not fail the run; the summary counts them.
  final notEvaluable = <ListedMutant>[];
  final summary = MutationSummary();
}

const _detected = {'Killed', 'Timeout'};
const _survived = {'Survived', 'NoCoverage'};
const _notEvaluable = {'RuntimeError', 'CompileError'};

/// Whitespace is not part of the key, so reformatting a gate does not
/// invalidate an allowance.
String normalizeCode(String text) =>
    text.replaceAll(RegExp(r'\s+'), ' ').trim();

/// A path as the judgement compares it: with `/`, and without a leading
/// `./`. A report of another tool may spell the path of a gate either way.
String normalizeReportPath(String file) =>
    file.replaceAll(r'\', '/').replaceFirst(RegExp(r'^\./'), '');

String _normalizeNewlines(String text) => text.replaceAll('\r\n', '\n');

String _slice(String text, int start, [int? end]) {
  final from = start.clamp(0, text.length);
  final to = (end ?? text.length).clamp(from, text.length);
  return text.substring(from, to);
}

/// Cuts the text a report location points at. Lines and columns are 1-based
/// and the end is exclusive. Returns `null` when the location is outside the
/// source.
String? sliceByLocation(
  String source,
  ReportPosition start,
  ReportPosition end,
) {
  final lines = source.split('\n');
  // An end line below 1 is before the start line, which is checked below.
  if (start.line < 1 ||
      start.line > lines.length ||
      end.line > lines.length ||
      start.column < 1 ||
      end.column < 1 ||
      end.line < start.line ||
      (end.line == start.line && end.column < start.column)) {
    return null;
  }
  final first = lines[start.line - 1];
  final last = lines[end.line - 1];
  if (start.line == end.line) {
    return _slice(first, start.column - 1, end.column - 1);
  }
  return [
    _slice(first, start.column - 1),
    ...lines.sublist(start.line, end.line - 1),
    _slice(last, 0, end.column - 1),
  ].join('\n');
}

String _keyOf(String mutator, String original, String replacement) =>
    jsonEncode([mutator, normalizeCode(original), normalizeCode(replacement)]);

class _Located {
  _Located(this.mutant, this.original, this.replacement, this.occurrence);

  final ReportMutant mutant;
  final String original;
  final String replacement;
  final int occurrence;

  /// Set when every mutant of the file has been located.
  late int sameKeyCount;

  ListedMutant listed(String file) => ListedMutant(
    file: file,
    line: mutant.start.line,
    column: mutant.start.column,
    status: mutant.status,
    mutator: mutant.mutatorName,
    original: normalizeCode(original),
    replacement: normalizeCode(replacement),
    occurrence: occurrence,
    sameKeyCount: sameKeyCount,
    statusReason: mutant.statusReason,
  );
}

String _describeAllowance(EquivalentMutant entry) {
  final occurrence = entry.occurrence == null
      ? ''
      : ' / occurrence ${entry.occurrence}';
  return '${entry.mutator} / ${normalizeCode(entry.original)} → '
      '${normalizeCode(entry.replacement)}$occurrence';
}

/// Decides whether a mutation run passes. Same rules as upstream.
///
/// Killed and Timeout mutants are detected. Survived and NoCoverage mutants
/// must each be covered by one allowance of the gate (`equivalentMutants`),
/// matched by mutator + original source text + replacement. CompileError and
/// RuntimeError are counted but do not fail. Ignored, Pending and any unknown
/// status fail: a mutant that was not evaluated proves nothing.
///
/// An allowance fails the run when it matches no surviving mutant (stale),
/// when it matches several mutants and has no `occurrence`, or when two
/// allowances point at the same mutant.
///
/// The report of a part of a run (`dart_mutant run --shard`) is refused as a
/// whole: it is not a result, whatever the statuses in it are.
///
/// [readSource] gives the source of a gate on disk, or `null` when it cannot
/// be read. It is used when the report carries no source, and to reject a
/// report made from an older file. The problems of the entries themselves
/// (a missing `reason`, ...) are reported where the manifest is parsed.
MutationVerdict judgeMutationReport({
  required List<Gate> gates,
  required MutationReport report,
  required String? Function(String gatePath) readSource,
  int maxTimeouts = 0,
}) {
  final verdict = MutationVerdict();
  final violations = verdict.violations;
  final summary = verdict.summary;

  if (report.part != null) {
    violations.add(
      Violation(
        file: 'mutation report',
        message:
            'is part ${report.part} of a run (--shard), not a result. Put '
            'the parts together with "dart_mutant merge" and judge the '
            'report that writes',
      ),
    );
    return verdict;
  }

  final files = {
    for (final MapEntry(:key, :value) in report.files.entries)
      normalizeReportPath(key): value,
  };

  for (final gate in gates) {
    final result = files[normalizeReportPath(gate.path)];
    if (result == null || result.mutants.isEmpty) {
      violations.add(
        Violation(
          file: gate.path,
          message:
              'no mutants in the report (the gate was not mutation tested)',
        ),
      );
      continue;
    }

    final diskSource = readSource(gate.path);
    final source = result.source ?? diskSource;
    if (source == null) {
      violations.add(
        Violation(
          file: gate.path,
          message: 'source is neither in the report nor readable on disk',
        ),
      );
      continue;
    }
    if (result.source != null &&
        diskSource != null &&
        _normalizeNewlines(result.source!) != _normalizeNewlines(diskSource)) {
      violations.add(
        Violation(
          file: gate.path,
          message:
              'the report was made from a different version of this file. '
              'Run the mutation test again',
        ),
      );
      continue;
    }

    final located = <_Located>[];
    final byKey = <String, List<_Located>>{};
    // A stable sort, so that mutants at the same place keep their order.
    final sorted = [
      for (final (index, mutant) in result.mutants.indexed) (index, mutant),
    ];
    sorted.sort((a, b) {
      final byLine = a.$2.start.line - b.$2.start.line;
      if (byLine != 0) {
        return byLine;
      }
      final byColumn = a.$2.start.column - b.$2.start.column;
      return byColumn != 0 ? byColumn : a.$1 - b.$1;
    });
    var locationsValid = true;
    for (final (_, mutant) in sorted) {
      final original = sliceByLocation(
        _normalizeNewlines(source),
        mutant.start,
        mutant.end,
      );
      if (original == null) {
        violations.add(
          Violation(
            file: gate.path,
            line: mutant.start.line,
            message:
                'the report location of a ${mutant.mutatorName} mutant is '
                'outside the source',
          ),
        );
        locationsValid = false;
        continue;
      }
      final replacement = mutant.replacement ?? '';
      final group = byKey.putIfAbsent(
        _keyOf(mutant.mutatorName, original, replacement),
        () => [],
      );
      final entry = _Located(mutant, original, replacement, group.length + 1);
      group.add(entry);
      located.add(entry);
    }
    for (final group in byKey.values) {
      for (final entry in group) {
        entry.sameKeyCount = group.length;
      }
    }
    if (!locationsValid) {
      continue;
    }

    // Decides which mutant each entry of a list points at. `accept` returns
    // why the mutant cannot be claimed, or null when it can.
    Set<_Located> claim(
      String field,
      List<EquivalentMutant> entries,
      String noun,
      String? Function(String status) accept,
    ) {
      final claimed = <_Located>{};
      for (final (place, entry) in entries.indexed) {
        final index = entry.index ?? place;
        final at =
            '${gate.path}: $field[$index] (${_describeAllowance(entry)})';
        final group =
            byKey[_keyOf(entry.mutator, entry.original, entry.replacement)] ??
            const <_Located>[];
        if (entry.occurrence == null && group.length > 1) {
          violations.add(
            Violation(
              file: manifestFile,
              message:
                  '$at: matches ${group.length} mutants in the file. '
                  'Add "occurrence" (1-based) to pick one',
            ),
          );
          continue;
        }
        final position = (entry.occurrence ?? 1) - 1;
        final target = position < group.length ? group[position] : null;
        final refusal = target == null
            ? 'stale $noun (no such mutant in this run). Remove it'
            : accept(target.mutant.status);
        if (target == null || refusal != null) {
          violations.add(
            Violation(file: manifestFile, message: '$at: $refusal'),
          );
          continue;
        }
        if (!claimed.add(target)) {
          violations.add(
            Violation(
              file: manifestFile,
              message: '$at: another $noun already covers this mutant',
            ),
          );
        }
      }
      return claimed;
    }

    final allowed = claim(
      'equivalentMutants',
      gate.equivalentMutants,
      'allowance',
      (status) => _survived.contains(status)
          ? null
          : 'stale allowance (the mutant is now $status). Remove it',
    );
    // An expected timeout that is Killed is accepted: a test that never ends
    // is reported as Timeout or as Killed depending on which limit fires
    // first. One that survives is not a timeout at all.
    final expected = claim(
      'expectedTimeouts',
      gate.expectedTimeouts,
      'entry',
      (status) => _survived.contains(status)
          ? 'the mutant '
                '${status == 'NoCoverage' ? 'has no coverage' : 'survived'} '
                'instead of timing out. Detect it with a test'
          : null,
    );

    for (final entry in located) {
      final mutant = entry.mutant;
      summary.total++;
      if (_detected.contains(mutant.status)) {
        summary.detected++;
        if (mutant.status == 'Timeout') {
          summary.timeout++;
          if (expected.contains(entry)) {
            summary.expectedTimeout++;
          } else {
            verdict.unexpectedTimeouts.add(entry.listed(gate.path));
          }
        }
      } else if (_notEvaluable.contains(mutant.status)) {
        summary.notEvaluable++;
        verdict.notEvaluable.add(entry.listed(gate.path));
      } else if (_survived.contains(mutant.status)) {
        if (allowed.contains(entry)) {
          summary.allowed++;
          continue;
        }
        summary.unallowed++;
        verdict.survivors.add(entry.listed(gate.path));
      } else {
        violations.add(
          Violation(
            file: gate.path,
            line: mutant.start.line,
            message: mutant.status == 'Ignored'
                ? 'a ${mutant.mutatorName} mutant was ignored. Taking mutants '
                      'out of the evaluation is not allowed'
                : 'a ${mutant.mutatorName} mutant was not evaluated '
                      '(status: ${mutant.status})',
          ),
        );
      }
    }
  }

  if (summary.total == 0) {
    violations.add(
      const Violation(
        file: manifestFile,
        message: 'no mutants were evaluated (the mutation test ran on nothing)',
      ),
    );
  }

  if (verdict.unexpectedTimeouts.length > maxTimeouts) {
    violations.add(
      Violation(
        file: manifestFile,
        message:
            '${verdict.unexpectedTimeouts.length} mutant(s) timed out outside '
            'expectedTimeouts; settings.mutation.maxTimeouts allows '
            '$maxTimeouts',
      ),
    );
  }

  return verdict;
}

/// `file:line:column / mutator / original → replacement / occurrence n of m`.
String formatListedMutant(ListedMutant mutant) {
  final occurrence = mutant.sameKeyCount > 1
      ? ' / occurrence ${mutant.occurrence} of ${mutant.sameKeyCount}'
      : '';
  return '${mutant.file}:${mutant.line}:${mutant.column} / ${mutant.mutator} / '
      '${mutant.original} → ${mutant.replacement}$occurrence '
      '(${mutant.status})';
}

/// The real numbers, on one line. Deliberately not a percentage.
String formatSummary(MutationSummary summary) =>
    'mutants ${summary.total} / detected ${summary.detected} '
    '(timeout ${summary.timeout}) / allowed equivalent ${summary.allowed} / '
    'not evaluable ${summary.notEvaluable} / '
    'unallowed survivors ${summary.unallowed}';
