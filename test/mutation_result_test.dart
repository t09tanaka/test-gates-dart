import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/manifest.dart';
import 'package:test_gates/src/mutation_result.dart';
import 'package:test_gates/src/types.dart';

import 'package_root.dart';

// The cases of upstream's mutation-result.test.ts. The source is TypeScript
// there and stays so here: the judge never reads the language.
//
// The gate under test in most cases. Line 1 and line 3 hold the same
// expression on purpose.
final source = [
  'export const isAdult = (age: number) => age >= 18;',
  'export const label = (ok: boolean) => (ok ? "yes" : "no");',
  'export const isSenior = (age: number) => age >= 18;',
  '',
].join('\n');

const gatePath = 'src/age.ts';

ReportMutant mutant(
  String status,
  String mutatorName,
  String? replacement,
  int line,
  int startColumn,
  int endColumn, {
  int? endLine,
}) => ReportMutant(
  status: status,
  mutatorName: mutatorName,
  replacement: replacement,
  start: ReportPosition(line, startColumn),
  end: ReportPosition(endLine ?? line, endColumn),
);

// `age >= 18` sits at columns 41..50 of line 1 and columns 42..51 of line 3.
ReportMutant firstComparison(
  String status, [
  String replacement = 'age > 18',
]) => mutant(status, 'EqualityOperator', replacement, 1, 41, 50);
ReportMutant secondComparison(
  String status, [
  String replacement = 'age > 18',
]) => mutant(status, 'EqualityOperator', replacement, 3, 42, 51);
ReportMutant yesLiteral(String status) =>
    mutant(status, 'StringLiteral', '""', 2, 45, 50);

EquivalentMutant allowance({
  String mutator = 'EqualityOperator',
  String original = 'age >= 18',
  String replacement = 'age > 18',
  String reason = 'documented reason',
  int? occurrence,
}) => EquivalentMutant(
  mutator: mutator,
  original: original,
  replacement: replacement,
  reason: reason,
  occurrence: occurrence,
);

Gate gate({
  String path = gatePath,
  List<EquivalentMutant> equivalentMutants = const [],
  List<EquivalentMutant> expectedTimeouts = const [],
}) => Gate(
  path: path,
  decides: 'who counts as an adult',
  impact: 'minors get adult pricing',
  equivalentMutants: equivalentMutants,
  expectedTimeouts: expectedTimeouts,
);

MutationReport reportOf(Map<String, ReportFile> files) => MutationReport(files);

MutationVerdict judge(
  List<ReportMutant> mutants, {
  List<EquivalentMutant> equivalentMutants = const [],
  List<EquivalentMutant> expectedTimeouts = const [],
  int? maxTimeouts,
}) => judgeMutationReport(
  gates: [
    gate(
      equivalentMutants: equivalentMutants,
      expectedTimeouts: expectedTimeouts,
    ),
  ],
  report: reportOf({gatePath: ReportFile(source: source, mutants: mutants)}),
  readSource: (_) => source,
  maxTimeouts: maxTimeouts ?? 0,
);

List<String> messages(MutationVerdict verdict) => [
  for (final violation in verdict.violations) violation.toString(),
];

List<int> numbers(MutationSummary summary) => [
  summary.total,
  summary.detected,
  summary.timeout,
  summary.allowed,
  summary.notEvaluable,
  summary.unallowed,
  summary.expectedTimeout,
];

/// The gate as test-gates.json gives it: the entries are checked where the
/// manifest is parsed, and only the usable ones reach the judge.
({Gate gate, List<String> problems}) parsedGate(Map<String, Object?> extra) {
  final manifest = parseManifest(
    jsonEncode({
      'gates': [
        {'path': gatePath, 'decides': 'd', 'impact': 'i', ...extra},
      ],
    }),
  );
  return (
    gate: manifest.gates.single,
    problems: [for (final violation in manifest.violations) '$violation'],
  );
}

void main() {
  group('sliceByLocation', () {
    String? slice(String text, int l1, int c1, int l2, int c2) =>
        sliceByLocation(text, ReportPosition(l1, c1), ReportPosition(l2, c2));

    test('cuts a single-line range with 1-based columns and an exclusive '
        'end', () {
      expect(slice('abcdef', 1, 2, 1, 5), 'bcd');
    });

    test('cuts a range that spans lines, keeping the lines in between', () {
      expect(slice('one\ntwo\nthree\nfour', 1, 3, 3, 4), 'e\ntwo\nthr');
    });

    test('cuts a range that spans exactly two lines', () {
      expect(slice('one\ntwo', 1, 2, 2, 2), 'ne\nt');
    });

    test('accepts a range that starts at column 1 and one that ends at '
        'column 1 of a later line', () {
      expect(slice('abc', 1, 1, 1, 3), 'ab');
      expect(slice('one\ntwo', 1, 2, 2, 1), 'ne\n');
    });

    test('a column behind the end of its line is the end of the line', () {
      expect(slice('ab\ncd', 1, 9, 2, 2), '\nc');
      expect(slice('ab\ncd', 1, 2, 2, 9), 'b\ncd');
      expect(slice('abc', 1, 7, 1, 9), '');
      expect(slice('abc', 1, 2, 1, 9), 'bc');
    });

    test('returns null for a multi-line range that ends at column 0', () {
      expect(slice('one\ntwo', 1, 2, 2, 0), isNull);
    });

    test('returns an empty string for an empty range', () {
      expect(slice('abc', 1, 2, 1, 2), '');
    });

    for (final (name, l1, c1, l2, c2) in [
      ('start line after the last line', 2, 1, 2, 2),
      ('end line after the last line', 1, 1, 2, 1),
      ('line 0', 0, 1, 1, 2),
      ('start column 0', 1, 0, 1, 2),
      ('end column 0', 1, 1, 1, 0),
      ('end before start on one line', 1, 3, 1, 2),
    ]) {
      test('returns null for $name', () {
        expect(slice('abc', l1, c1, l2, c2), isNull);
      });
    }

    test('returns null when the end line is before the start line', () {
      expect(slice('abc\ndef', 2, 1, 1, 2), isNull);
    });

    test('a column beyond the end of the line cuts up to the end', () {
      expect(slice('abc', 1, 2, 1, 99), 'bc');
    });
  });

  group('normalizeCode', () {
    test('collapses every run of whitespace to one space and trims', () {
      expect(normalizeCode('  a  >=\n\t 18 '), 'a >= 18');
    });
  });

  group('judgeMutationReport: status handling', () {
    test('passes when every mutant is killed', () {
      final verdict = judge([firstComparison('Killed'), yesLiteral('Killed')]);
      expect(verdict.violations, isEmpty);
      expect(verdict.survivors, isEmpty);
      expect(numbers(verdict.summary), [2, 2, 0, 0, 0, 0, 0]);
    });

    test('counts Timeout as detected, and separately as a timeout', () {
      final verdict = judge([
        firstComparison('Timeout'),
        yesLiteral('Killed'),
        secondComparison('Timeout'),
      ], maxTimeouts: 2);
      expect(verdict.violations, isEmpty);
      expect(numbers(verdict.summary), [3, 3, 2, 0, 0, 0, 0]);
    });

    for (final status in ['Survived', 'NoCoverage']) {
      test('reports a $status mutant without an allowance', () {
        final verdict = judge([firstComparison(status), yesLiteral('Killed')]);
        expect(numbers(verdict.summary), [2, 1, 0, 0, 0, 1, 0]);
        final survivor = verdict.survivors.single;
        expect(
          [survivor.file, survivor.line, survivor.column, survivor.status],
          [gatePath, 1, 41, status],
        );
        expect(
          [survivor.mutator, survivor.original, survivor.replacement],
          ['EqualityOperator', 'age >= 18', 'age > 18'],
        );
        expect([survivor.occurrence, survivor.sameKeyCount], [1, 1]);
        expect(survivor.allowance, {
          'mutator': 'EqualityOperator',
          'original': 'age >= 18',
          'replacement': 'age > 18',
          'reason': '',
        });
      });
    }

    for (final status in ['RuntimeError', 'CompileError']) {
      test('counts $status as not evaluable without failing', () {
        final verdict = judge([firstComparison(status), yesLiteral('Killed')]);
        expect(verdict.violations, isEmpty);
        expect(verdict.survivors, isEmpty);
        expect(numbers(verdict.summary), [2, 1, 0, 0, 1, 0, 0]);
        expect(
          [
            for (final mutant in verdict.notEvaluable)
              formatListedMutant(mutant),
          ],
          [
            'src/age.ts:1:41 / EqualityOperator / age >= 18 → age > 18 ($status)',
          ],
        );
        expect(verdict.notEvaluable.single.statusReason, isNull);
      });
    }

    test('lists what could not be evaluated, in the order of the source, '
        'with what the report says about it', () {
      final report = parseMutationReport(
        jsonEncode({
          'files': {
            gatePath: {
              'source': source,
              'mutants': [
                for (final (line, column, status, reason) in [
                  (3, 42, 'CompileError', 'second'),
                  (2, 45, 'Killed', 'not listed'),
                  (1, 41, 'RuntimeError', 7),
                  (1, 1, 'Survived', null),
                ])
                  {
                    'mutatorName': 'M',
                    'replacement': 'x',
                    'status': status,
                    'statusReason': reason,
                    'location': {
                      'start': {'line': line, 'column': column},
                      'end': {'line': line, 'column': column + 1},
                    },
                  },
              ],
            },
          },
        }),
      );
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: report,
        readSource: (_) => source,
      );
      expect(
        [
          for (final mutant in verdict.notEvaluable)
            (mutant.line, mutant.status, mutant.statusReason),
        ],
        [(1, 'RuntimeError', null), (3, 'CompileError', 'second')],
      );
    });

    test('fails on an Ignored mutant and says why', () {
      final verdict = judge([firstComparison('Ignored'), yesLiteral('Killed')]);
      expect(messages(verdict), [
        'src/age.ts:1: a EqualityOperator mutant was ignored. Taking mutants '
            'out of the evaluation is not allowed',
      ]);
      expect(verdict.summary.total, 2);
    });

    for (final status in ['Pending', 'SomethingNew']) {
      test('fails on a mutant with status $status', () {
        final verdict = judge([firstComparison(status), yesLiteral('Killed')]);
        expect(messages(verdict), [
          'src/age.ts:1: a EqualityOperator mutant was not evaluated '
              '(status: $status)',
        ]);
      });
    }
  });

  group('judgeMutationReport: allow list', () {
    test('passes a survivor that an allowance matches', () {
      final verdict = judge(
        [firstComparison('Survived'), yesLiteral('Killed')],
        equivalentMutants: [allowance()],
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.survivors, isEmpty);
      expect(numbers(verdict.summary), [2, 1, 0, 1, 0, 0, 0]);
    });

    test('passes a NoCoverage mutant that an allowance matches', () {
      final verdict = judge(
        [firstComparison('NoCoverage')],
        equivalentMutants: [allowance()],
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.allowed, 1);
    });

    test('matches regardless of whitespace differences in original and '
        'replacement', () {
      final verdict = judge(
        [firstComparison('Survived', 'age  >  18')],
        equivalentMutants: [
          allowance(original: ' age\n  >=   18 ', replacement: 'age >\t18'),
        ],
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.allowed, 1);
    });

    test('takes the original from the source, not from the allowance or a '
        'line number', () {
      // Same mutator and replacement, but the allowance names different
      // original code.
      final verdict = judge(
        [firstComparison('Survived')],
        equivalentMutants: [allowance(original: 'age >= 21')],
      );
      expect(verdict.survivors, hasLength(1));
      expect(
        messages(verdict).single,
        contains('stale allowance (no such mutant in this run)'),
      );
    });

    for (final (field, entry) in [
      ('mutator', allowance(mutator: 'ConditionalExpression')),
      ('replacement', allowance(replacement: 'age < 18')),
    ]) {
      test('does not match when the $field differs', () {
        final verdict = judge(
          [firstComparison('Survived')],
          equivalentMutants: [entry],
        );
        expect(verdict.survivors, hasLength(1));
        expect(verdict.summary.allowed, 0);
      });
    }

    test('does not let one allowance cover a different mutant on the same '
        'line', () {
      final other = mutant(
        'Survived',
        'ConditionalExpression',
        'true',
        1,
        41,
        50,
      );
      final verdict = judge(
        [firstComparison('Survived'), other],
        equivalentMutants: [allowance()],
      );
      expect([verdict.summary.allowed, verdict.summary.unallowed], [1, 1]);
      expect(verdict.survivors.single.mutator, 'ConditionalExpression');
    });

    test('fails on a stale allowance whose mutant is now killed', () {
      final verdict = judge(
        [firstComparison('Killed')],
        equivalentMutants: [allowance()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[0] (EqualityOperator '
            '/ age >= 18 → age > 18): stale allowance (the mutant is now '
            'Killed). Remove it',
      ]);
      expect(verdict.summary.allowed, 0);
    });

    test('fails on a stale allowance whose mutant no longer exists', () {
      final verdict = judge(
        [yesLiteral('Killed')],
        equivalentMutants: [allowance()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[0] (EqualityOperator '
            '/ age >= 18 → age > 18): stale allowance (no such mutant in this '
            'run). Remove it',
      ]);
    });

    test('fails when two allowances point at the same mutant', () {
      final verdict = judge(
        [firstComparison('Survived')],
        equivalentMutants: [allowance(), allowance()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[1] (EqualityOperator '
            '/ age >= 18 → age > 18): another allowance already covers this '
            'mutant',
      ]);
      expect(verdict.summary.allowed, 1);
    });

    test('the position in a message is the one in test-gates.json, also '
        'after an entry that cannot be used', () {
      final parsed = parsedGate({
        'equivalentMutants': [
          {'mutator': 'A', 'original': 'a', 'replacement': 'b'},
          {
            'mutator': 'EqualityOperator',
            'original': 'age >= 18',
            'replacement': 'age > 18',
            'reason': 'r',
          },
        ],
      });
      expect(
        parsed.problems.single,
        contains('equivalentMutants[0]: "reason"'),
      );
      final verdict = judgeMutationReport(
        gates: [parsed.gate],
        report: reportOf({
          gatePath: ReportFile(
            source: source,
            mutants: [firstComparison('Killed')],
          ),
        }),
        readSource: (_) => source,
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[1] (EqualityOperator '
            '/ age >= 18 → age > 18): stale allowance (the mutant is now '
            'Killed). Remove it',
      ]);
    });

    test('an entry without a reason is reported by the manifest and not '
        'applied', () {
      final parsed = parsedGate({
        'equivalentMutants': [
          {
            'mutator': 'EqualityOperator',
            'original': 'age >= 18',
            'replacement': 'age > 18',
            'reason': '  ',
          },
        ],
      });
      expect(parsed.problems, [
        'test-gates.json: src/age.ts: equivalentMutants[0]: "reason" is '
            'missing (say why the mutant cannot be observed)',
      ]);
      final verdict = judgeMutationReport(
        gates: [parsed.gate],
        report: reportOf({
          gatePath: ReportFile(
            source: source,
            mutants: [firstComparison('Survived')],
          ),
        }),
        readSource: (_) => source,
      );
      expect([verdict.summary.allowed, verdict.summary.unallowed], [0, 1]);
    });

    test('equivalentMutants that is not an array is reported by the '
        'manifest', () {
      expect(parsedGate({'equivalentMutants': <String, Object?>{}}).problems, [
        'test-gates.json: src/age.ts: equivalentMutants must be an array',
      ]);
    });

    test('accepts an empty replacement in an allowance', () {
      final emptied = mutant('Survived', 'StringLiteral', '', 2, 45, 50);
      final verdict = judge(
        [emptied],
        equivalentMutants: [
          allowance(
            mutator: 'StringLiteral',
            original: '"yes"',
            replacement: '',
          ),
        ],
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.allowed, 1);
    });

    test('treats a mutant without a replacement field as an empty '
        'replacement', () {
      final verdict = judge([
        mutant('Survived', 'StringLiteral', null, 2, 45, 50),
      ]);
      expect(verdict.survivors.single.replacement, '');
    });
  });

  group('judgeMutationReport: occurrence', () {
    test('numbers identical mutants in source order, whatever the report '
        'order', () {
      final verdict = judge([
        secondComparison('Survived'),
        firstComparison('Survived'),
      ]);
      expect(
        [
          for (final survivor in verdict.survivors)
            [
              survivor.line,
              survivor.occurrence,
              survivor.sameKeyCount,
              survivor.allowance['occurrence'],
            ],
        ],
        [
          [1, 1, 2, 1],
          [3, 2, 2, 2],
        ],
      );
    });

    test('the line comes before the column', () {
      // The same expression: late on line 1, and at the start of line 2.
      const text = 'const f = (a: number) => a >= 18;\na >= 18;\n';
      final first = mutant('Survived', 'EqualityOperator', 'a > 18', 1, 26, 33);
      final second = mutant('Survived', 'EqualityOperator', 'a > 18', 2, 1, 8);
      for (final mutants in [
        [first, second],
        [second, first],
      ]) {
        final verdict = judgeMutationReport(
          gates: [gate()],
          report: reportOf({
            gatePath: ReportFile(source: text, mutants: mutants),
          }),
          readSource: (_) => text,
        );
        expect(
          [
            for (final survivor in verdict.survivors)
              (survivor.line, survivor.occurrence),
          ],
          [(1, 1), (2, 2)],
        );
      }
    });

    test('mutants at one place keep the order of the report', () {
      // More than a sort keeps in order by itself (Dart's is only stable
      // for short lists).
      for (final count in [2, 40]) {
        final verdict = judge([
          for (var i = 0; i < count; i++)
            mutant('Survived', 'EqualityOperator', 'age > $i', 1, 41, 50),
        ]);
        expect(
          [for (final survivor in verdict.survivors) survivor.replacement],
          [for (var i = 0; i < count; i++) 'age > $i'],
        );
      }
    });

    test('orders mutants on the same line by column', () {
      const line = 'export const f = (a: number) => a >= 18 || a >= 18;\n';
      final left = mutant('Survived', 'EqualityOperator', 'a > 18', 1, 33, 40);
      final right = mutant('Killed', 'EqualityOperator', 'a > 18', 1, 44, 51);
      final verdict = judgeMutationReport(
        gates: [
          gate(
            equivalentMutants: [
              allowance(
                original: 'a >= 18',
                replacement: 'a > 18',
                occurrence: 1,
              ),
            ],
          ),
        ],
        report: reportOf({
          gatePath: ReportFile(source: line, mutants: [right, left]),
        }),
        readSource: (_) => line,
      );
      expect(verdict.violations, isEmpty);
      expect([verdict.summary.allowed, verdict.summary.detected], [1, 1]);
      // The same when the report already has them in that order.
      final unchanged = judgeMutationReport(
        gates: [gate()],
        report: reportOf({
          gatePath: ReportFile(source: line, mutants: [left, right]),
        }),
        readSource: (_) => line,
      );
      expect(unchanged.survivors.single.occurrence, 1);
    });

    test('fails when an allowance without occurrence matches several '
        'mutants, even if one was killed', () {
      final verdict = judge(
        [firstComparison('Survived'), secondComparison('Killed')],
        equivalentMutants: [allowance()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[0] (EqualityOperator '
            '/ age >= 18 → age > 18): matches 2 mutants in the file. Add '
            '"occurrence" (1-based) to pick one',
      ]);
      expect([verdict.summary.allowed, verdict.summary.unallowed], [0, 1]);
    });

    test('allows only the mutant that occurrence points at', () {
      final verdict = judge(
        [firstComparison('Survived'), secondComparison('Survived')],
        equivalentMutants: [allowance(occurrence: 2)],
      );
      expect(verdict.violations, isEmpty);
      expect([verdict.summary.allowed, verdict.summary.unallowed], [1, 1]);
      expect(verdict.survivors.single.line, 1);
    });

    test('fails when occurrence points at a killed mutant', () {
      final verdict = judge(
        [firstComparison('Killed'), secondComparison('Survived')],
        equivalentMutants: [allowance(occurrence: 1)],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[0] (EqualityOperator '
            '/ age >= 18 → age > 18 / occurrence 1): stale allowance (the '
            'mutant is now Killed). Remove it',
      ]);
      expect(verdict.survivors.single.line, 3);
    });

    test('fails when occurrence is beyond the number of identical mutants', () {
      final verdict = judge(
        [firstComparison('Survived')],
        equivalentMutants: [allowance(occurrence: 2)],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[0] (EqualityOperator '
            '/ age >= 18 → age > 18 / occurrence 2): stale allowance (no such '
            'mutant in this run). Remove it',
      ]);
    });

    test('accepts occurrence 1 for a mutant that is unique', () {
      final verdict = judge(
        [firstComparison('Survived')],
        equivalentMutants: [allowance(occurrence: 1)],
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.allowed, 1);
    });

    for (final occurrence in <Object>[0, -1, 1.5, '1']) {
      test('occurrence ${jsonEncode(occurrence)} is rejected by the manifest '
          'and the entry is not applied', () {
        final parsed = parsedGate({
          'equivalentMutants': [
            {
              'mutator': 'EqualityOperator',
              'original': 'age >= 18',
              'replacement': 'age > 18',
              'reason': 'r',
              'occurrence': occurrence,
            },
          ],
        });
        expect(parsed.problems, [
          'test-gates.json: src/age.ts: equivalentMutants[0]: "occurrence" '
              'must be an integer >= 1',
        ]);
        expect(parsed.gate.equivalentMutants, isEmpty);
      });
    }
  });

  group('judgeMutationReport: the report itself', () {
    ReportFile killed() =>
        ReportFile(source: source, mutants: [firstComparison('Killed')]);

    test('fails when a gate is absent from the report', () {
      final verdict = judgeMutationReport(
        gates: [
          gate(),
          gate(path: 'src/other.ts'),
        ],
        report: reportOf({gatePath: killed()}),
        readSource: (_) => source,
      );
      expect(messages(verdict), [
        'src/other.ts: no mutants in the report (the gate was not mutation '
            'tested)',
      ]);
      expect(verdict.summary.total, 1);
    });

    for (final (name, files) in [
      (
        'a gate with an empty mutant list',
        {gatePath: ReportFile(source: source)},
      ),
      ('a report with no files', <String, ReportFile>{}),
    ]) {
      test('fails on $name', () {
        final verdict = judgeMutationReport(
          gates: [gate()],
          report: reportOf(files),
          readSource: (_) => source,
        );
        expect(messages(verdict), [
          'src/age.ts: no mutants in the report (the gate was not mutation '
              'tested)',
          'test-gates.json: no mutants were evaluated (the mutation test ran '
              'on nothing)',
        ]);
      });
    }

    test('fails when there are no gates at all', () {
      final verdict = judgeMutationReport(
        gates: const [],
        report: reportOf(const {}),
        readSource: (_) => null,
      );
      expect(messages(verdict), [
        'test-gates.json: no mutants were evaluated (the mutation test ran on '
            'nothing)',
      ]);
    });

    test('ignores report files that are not gates', () {
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: reportOf({
          gatePath: killed(),
          'src/not-a-gate.ts': ReportFile(
            source: source,
            mutants: [firstComparison('Survived')],
          ),
        }),
        readSource: (_) => source,
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.total, 1);
    });

    for (final (name, reportKey, path) in [
      ('a ./ prefix in the report', './src/age.ts', gatePath),
      ('backslashes in the report', r'src\age.ts', gatePath),
      ('a ./ prefix in the gate', gatePath, './src/age.ts'),
    ]) {
      test('finds the gate despite $name', () {
        final verdict = judgeMutationReport(
          gates: [gate(path: path)],
          report: reportOf({reportKey: killed()}),
          readSource: (_) => source,
        );
        expect(verdict.violations, isEmpty);
        expect(verdict.summary.detected, 1);
      });
    }

    test('drops only a leading ./ when comparing paths', () {
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: reportOf({'src/./age.ts': killed()}),
        readSource: (_) => source,
      );
      expect(
        messages(verdict).first,
        'src/age.ts: no mutants in the report (the gate was not mutation '
        'tested)',
      );
    });

    test('reads the source from disk when the report has none', () {
      final verdict = judgeMutationReport(
        gates: [
          gate(equivalentMutants: [allowance()]),
        ],
        report: reportOf({
          gatePath: ReportFile(mutants: [firstComparison('Survived')]),
        }),
        readSource: (path) => path == gatePath ? source : null,
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.allowed, 1);
    });

    test('uses the source of the report when the file cannot be read from '
        'disk', () {
      final verdict = judgeMutationReport(
        gates: [
          gate(equivalentMutants: [allowance()]),
        ],
        report: reportOf({
          gatePath: ReportFile(
            source: source,
            mutants: [firstComparison('Survived')],
          ),
        }),
        readSource: (_) => null,
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.summary.allowed, 1);
    });

    test('fails when the source is available nowhere', () {
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: reportOf({
          gatePath: ReportFile(mutants: [firstComparison('Killed')]),
        }),
        readSource: (_) => null,
      );
      expect(
        messages(verdict).first,
        'src/age.ts: source is neither in the report nor readable on disk',
      );
      expect(verdict.summary.total, 0);
    });

    test('fails when the report was made from a different version of the '
        'file', () {
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: reportOf({gatePath: killed()}),
        readSource: (_) => source.replaceFirst('18', '20'),
      );
      expect(
        messages(verdict).first,
        'src/age.ts: the report was made from a different version of this '
        'file. Run the mutation test again',
      );
      expect(verdict.summary.total, 0);
    });

    test('does not treat CRLF versus LF as a different version, and slices '
        'CRLF sources correctly', () {
      final crlf = source.replaceAll('\n', '\r\n');
      final twoLines = mutant(
        'Survived',
        'ArrowFunction',
        '() => undefined',
        1,
        41,
        7,
        endLine: 2,
      );
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: reportOf({
          gatePath: ReportFile(source: crlf, mutants: [twoLines]),
        }),
        readSource: (_) => source,
      );
      expect(verdict.violations, isEmpty);
      expect(verdict.survivors.single.original, 'age >= 18; export');
    });

    test('fails when a location is outside the source, without judging the '
        'file', () {
      final outside = mutant('Survived', 'EqualityOperator', 'x', 99, 1, 2);
      final verdict = judge([firstComparison('Killed'), outside]);
      expect(messages(verdict), [
        'src/age.ts:99: the report location of a EqualityOperator mutant is '
            'outside the source',
        'test-gates.json: no mutants were evaluated (the mutation test ran on '
            'nothing)',
      ]);
    });

    test('sums over several gates', () {
      final verdict = judgeMutationReport(
        gates: [
          gate(),
          gate(path: 'src/b.ts'),
        ],
        report: reportOf({
          gatePath: killed(),
          'src/b.ts': ReportFile(
            source: source,
            mutants: [yesLiteral('Survived'), yesLiteral('Timeout')],
          ),
        }),
        readSource: (_) => source,
        maxTimeouts: 1,
      );
      expect(numbers(verdict.summary), [3, 2, 1, 0, 0, 1, 0]);
      expect(verdict.survivors.single.file, 'src/b.ts');
    });
  });

  group('formatting', () {
    test('prints a survivor as file:line:column / mutator / original → '
        'replacement', () {
      final survivor = judge([firstComparison('Survived')]).survivors.single;
      expect(
        formatListedMutant(survivor),
        'src/age.ts:1:41 / EqualityOperator / age >= 18 → age > 18 (Survived)',
      );
    });

    test('adds the occurrence when the same mutant exists more than once', () {
      final survivor = judge([
        firstComparison('Killed'),
        secondComparison('NoCoverage'),
      ]).survivors.single;
      expect(
        formatListedMutant(survivor),
        'src/age.ts:3:42 / EqualityOperator / age >= 18 → age > 18 / '
        'occurrence 2 of 2 (NoCoverage)',
      );
      expect(survivor.allowance, {
        'mutator': 'EqualityOperator',
        'original': 'age >= 18',
        'replacement': 'age > 18',
        'occurrence': 2,
        'reason': '',
      });
    });

    test('prints the real numbers on one line', () {
      final summary = MutationSummary()
        ..total = 120
        ..detected = 110
        ..timeout = 4
        ..allowed = 6
        ..notEvaluable = 3
        ..unallowed = 1;
      expect(
        formatSummary(summary),
        'mutants 120 / detected 110 (timeout 4) / allowed equivalent 6 / '
        'not evaluable 3 / unallowed survivors 1',
      );
    });

    group('allowedSurvivorsNote', () {
      MutationSummary summaryOf({
        required int allowed,
        required int unallowed,
      }) => MutationSummary()
        ..total = 10
        ..detected = 10 - allowed - unallowed
        ..allowed = allowed
        ..unallowed = unallowed;

      test('says nothing when no survivor is allowed', () {
        expect(
          allowedSurvivorsNote(summaryOf(allowed: 0, unallowed: 0)),
          isNull,
        );
        expect(
          allowedSurvivorsNote(summaryOf(allowed: 0, unallowed: 2)),
          isNull,
        );
      });

      test('every survivor allowed: the FAILED of dart_mutant counts them', () {
        expect(
          allowedSurvivorsNote(summaryOf(allowed: 3, unallowed: 0)),
          'the FAILED of dart_mutant above counts the 3 survivor(s) that '
          'test-gates.json allows (equivalentMutants). The verdict is the '
          'last line, of test_gates',
        );
      });

      test('one allowed survivor is enough for the note', () {
        expect(
          allowedSurvivorsNote(summaryOf(allowed: 1, unallowed: 0)),
          startsWith('the FAILED of dart_mutant above counts the 1 survivor'),
        );
      });

      test('allowed and unallowed survivors: both are named', () {
        expect(
          allowedSurvivorsNote(summaryOf(allowed: 2, unallowed: 1)),
          'the FAILED of dart_mutant above counts the 2 survivor(s) that '
          'test-gates.json allows (equivalentMutants), besides the 1 that it '
          'does not allow (listed below). The verdict is the last line, of '
          'test_gates',
        );
      });
    });
  });

  group('judgeMutationReport: timeouts', () {
    EquivalentMutant expectedTimeout({int? occurrence}) => allowance(
      reason: 'the loop never ends, so the run always times out',
      occurrence: occurrence,
    );
    const limitMessage =
        'test-gates.json: %d mutant(s) timed out outside expectedTimeouts; '
        'settings.mutation.maxTimeouts allows %d';
    String limit(int count, int allowed) => limitMessage
        .replaceFirst('%d', '$count')
        .replaceFirst('%d', '$allowed');

    test('fails on any timeout when no limit is given: the default is 0', () {
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: reportOf({
          gatePath: ReportFile(
            source: source,
            mutants: [firstComparison('Timeout'), secondComparison('Timeout')],
          ),
        }),
        readSource: (_) => source,
      );
      expect(messages(verdict), [limit(2, 0)]);
      expect(numbers(verdict.summary).sublist(1, 3), [2, 2]);
      expect(
        [for (final m in verdict.unexpectedTimeouts) (m.line, m.status)],
        [(1, 'Timeout'), (3, 'Timeout')],
      );
    });

    test('passes when the number of timeouts equals the limit', () {
      final verdict = judge([
        firstComparison('Timeout'),
        yesLiteral('Timeout'),
      ], maxTimeouts: 2);
      expect(verdict.violations, isEmpty);
      expect(verdict.unexpectedTimeouts, hasLength(2));
    });

    test('fails when the number of timeouts exceeds the limit', () {
      final verdict = judge([
        firstComparison('Timeout'),
        yesLiteral('Timeout'),
      ], maxTimeouts: 1);
      expect(messages(verdict), [limit(2, 1)]);
      expect(numbers(verdict.summary).sublist(1, 3), [2, 2]);
    });

    test('fails on a single timeout when the limit is 0, and not on none', () {
      expect(messages(judge([firstComparison('Timeout')], maxTimeouts: 0)), [
        limit(1, 0),
      ]);
      expect(
        judge([firstComparison('Killed')], maxTimeouts: 0).violations,
        isEmpty,
      );
    });

    test('describes an unexpected timeout with an entry that can be pasted '
        'into expectedTimeouts', () {
      final verdict = judge([
        firstComparison('Timeout'),
        secondComparison('Killed'),
      ]);
      final listed = verdict.unexpectedTimeouts.single;
      expect(
        [listed.file, listed.line, listed.column, listed.status],
        [gatePath, 1, 41, 'Timeout'],
      );
      expect([listed.occurrence, listed.sameKeyCount], [1, 2]);
      expect(listed.allowance, {
        'mutator': 'EqualityOperator',
        'original': 'age >= 18',
        'replacement': 'age > 18',
        'occurrence': 1,
        'reason': '',
      });
    });

    test('does not count an expected timeout against the limit', () {
      final verdict = judge(
        [firstComparison('Timeout'), yesLiteral('Timeout')],
        maxTimeouts: 1,
        expectedTimeouts: [expectedTimeout()],
      );
      expect(verdict.violations, isEmpty);
      expect(numbers(verdict.summary), [2, 2, 2, 0, 0, 0, 1]);
      expect(verdict.unexpectedTimeouts.single.mutator, 'StringLiteral');
    });

    test('accepts an expected timeout that was killed instead', () {
      final verdict = judge(
        [firstComparison('Killed')],
        maxTimeouts: 0,
        expectedTimeouts: [expectedTimeout()],
      );
      expect(verdict.violations, isEmpty);
      expect(numbers(verdict.summary), [1, 1, 0, 0, 0, 0, 0]);
    });

    for (final (status, wording) in [
      ('Survived', 'survived'),
      ('NoCoverage', 'has no coverage'),
    ]) {
      test('fails when an expected timeout is $status', () {
        final verdict = judge(
          [firstComparison(status)],
          expectedTimeouts: [expectedTimeout()],
        );
        expect(messages(verdict), [
          'test-gates.json: src/age.ts: expectedTimeouts[0] (EqualityOperator '
              '/ age >= 18 → age > 18): the mutant $wording instead of timing '
              'out. Detect it with a test',
        ]);
        expect(verdict.survivors, hasLength(1));
      });
    }

    test('fails on an expected timeout whose mutant does not exist', () {
      final verdict = judge(
        [yesLiteral('Killed')],
        expectedTimeouts: [expectedTimeout()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: expectedTimeouts[0] (EqualityOperator / '
            'age >= 18 → age > 18): stale entry (no such mutant in this run). '
            'Remove it',
      ]);
    });

    test('requires occurrence when the key matches several mutants, and '
        'honours it', () {
      final mutants = [firstComparison('Timeout'), secondComparison('Timeout')];
      expect(
        messages(
          judge(mutants, maxTimeouts: 0, expectedTimeouts: [expectedTimeout()]),
        ),
        [
          'test-gates.json: src/age.ts: expectedTimeouts[0] (EqualityOperator '
              '/ age >= 18 → age > 18): matches 2 mutants in the file. Add '
              '"occurrence" (1-based) to pick one',
          limit(2, 0),
        ],
      );
      final picked = judge(
        mutants,
        maxTimeouts: 1,
        expectedTimeouts: [expectedTimeout(occurrence: 2)],
      );
      expect(picked.violations, isEmpty);
      expect(picked.unexpectedTimeouts.single.line, 1);
    });

    test('fails when two entries point at the same mutant', () {
      final verdict = judge(
        [firstComparison('Timeout')],
        expectedTimeouts: [expectedTimeout(), expectedTimeout()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: expectedTimeouts[1] (EqualityOperator / '
            'age >= 18 → age > 18): another entry already covers this mutant',
      ]);
      expect(verdict.summary.expectedTimeout, 1);
    });

    test('an entry without a reason is reported by the manifest and not '
        'applied', () {
      final parsed = parsedGate({
        'expectedTimeouts': [
          {
            'mutator': 'EqualityOperator',
            'original': 'age >= 18',
            'replacement': 'age > 18',
            'reason': '',
          },
        ],
      });
      expect(parsed.problems, [
        'test-gates.json: src/age.ts: expectedTimeouts[0]: "reason" is '
            'missing (say why the mutant cannot be observed)',
      ]);
      final verdict = judgeMutationReport(
        gates: [parsed.gate],
        report: reportOf({
          gatePath: ReportFile(
            source: source,
            mutants: [firstComparison('Timeout')],
          ),
        }),
        readSource: (_) => source,
      );
      expect(messages(verdict), [limit(1, 0)]);
    });

    test('expectedTimeouts that is not an array is reported by the '
        'manifest', () {
      expect(parsedGate({'expectedTimeouts': 'x'}).problems, [
        'test-gates.json: src/age.ts: expectedTimeouts must be an array',
      ]);
    });

    test('keeps equivalent mutants and expected timeouts apart', () {
      // An equivalentMutants entry cannot cover a timeout, and the timeout
      // stays unexpected.
      final verdict = judge(
        [firstComparison('Timeout')],
        maxTimeouts: 0,
        equivalentMutants: [allowance()],
      );
      expect(messages(verdict), [
        'test-gates.json: src/age.ts: equivalentMutants[0] (EqualityOperator '
            '/ age >= 18 → age > 18): stale allowance (the mutant is now '
            'Timeout). Remove it',
        limit(1, 0),
      ]);
    });

    test('counts timeouts over all gates', () {
      final verdict = judgeMutationReport(
        gates: [
          gate(),
          gate(path: 'src/b.ts'),
        ],
        report: reportOf({
          gatePath: ReportFile(
            source: source,
            mutants: [firstComparison('Timeout')],
          ),
          'src/b.ts': ReportFile(
            source: source,
            mutants: [yesLiteral('Timeout')],
          ),
        }),
        readSource: (_) => source,
        maxTimeouts: 1,
      );
      expect(messages(verdict), [limit(2, 1)]);
      expect(
        [for (final m in verdict.unexpectedTimeouts) m.file],
        [gatePath, 'src/b.ts'],
      );
    });
  });

  group('a report of dart_mutant', () {
    // A report as dart_mutant 0.1.0 wrote it for
    // test/fixtures/mutation/package (a function with one weak test):
    // `dart_mutant run --plan <plan> --report <this file>`. It is a record,
    // and its numbers are those of that version.
    // test/commands/real_mutation_test.dart runs the tool that is installed
    // on the same package, and expects no numbers.
    final text = File(
      inPackage('test/fixtures/mutation/dart_mutant_report.json'),
    ).readAsStringSync();
    const path = 'lib/steps.dart';

    MutationVerdict judged(List<EquivalentMutant> equivalentMutants) {
      final report = parseMutationReport(text);
      return judgeMutationReport(
        gates: [gate(path: path, equivalentMutants: equivalentMutants)],
        report: report,
        readSource: (_) => report.files[path]!.source,
      );
    }

    test('is read as it is: the mutators that use types, a replacement that '
        'is empty, and the same change in several places', () {
      final verdict = judged(const []);
      expect(verdict.violations, isEmpty);
      expect(numbers(verdict.summary), [14, 5, 0, 0, 0, 9, 0]);
      expect(
        [
          for (final survivor in verdict.survivors)
            formatListedMutant(survivor),
        ],
        [
          'lib/steps.dart:4:17 / ConditionalExpression / from < 0 → false '
              '(Survived)',
          'lib/steps.dart:4:22 / EqualityOperator / < → <= / occurrence 1 of '
              '2 (Survived)',
          'lib/steps.dart:4:24 / NumberLiteral / 0 → 1 / occurrence 1 of 4 '
              '(Survived)',
          'lib/steps.dart:4:28 / NumberLiteral / 0 → 1 / occurrence 2 of 4 '
              '(Survived)',
          'lib/steps.dart:5:16 / ConditionalExpression / to < 0 → false '
              '(Survived)',
          'lib/steps.dart:5:19 / EqualityOperator / < → <= / occurrence 2 of '
              '2 (Survived)',
          'lib/steps.dart:5:21 / NumberLiteral / 0 → 1 / occurrence 3 of 4 '
              '(Survived)',
          'lib/steps.dart:5:25 / NumberLiteral / 0 → 1 / occurrence 4 of 4 '
              '(Survived)',
          'lib/steps.dart:6:24 / MethodExpression / .abs() →  (Survived)',
        ],
      );
    });

    test('the entries that are printed for its survivors, pasted into '
        'test-gates.json with a reason, allow exactly those mutants', () {
      final survivors = judged(const []).survivors;
      final pasted = parsedGate({
        'equivalentMutants': [
          for (final survivor in survivors)
            // As the command prints it, and as a person fills it in.
            (jsonDecode(jsonEncode(survivor.allowance)) as Map<String, Object?>)
              ..['reason'] = 'for the test',
        ],
      });
      expect(pasted.problems, isEmpty);
      expect(
        [
          for (final entry in pasted.gate.equivalentMutants)
            (entry.mutator, entry.replacement, entry.occurrence),
        ],
        [
          ('ConditionalExpression', 'false', null),
          ('EqualityOperator', '<=', 1),
          ('NumberLiteral', '1', 1),
          ('NumberLiteral', '1', 2),
          ('ConditionalExpression', 'false', null),
          ('EqualityOperator', '<=', 2),
          ('NumberLiteral', '1', 3),
          ('NumberLiteral', '1', 4),
          ('MethodExpression', '', null),
        ],
      );
      final verdict = judged(pasted.gate.equivalentMutants);
      expect(verdict.violations, isEmpty);
      expect(verdict.survivors, isEmpty);
      expect(numbers(verdict.summary), [14, 5, 0, 9, 0, 0, 0]);
    });

    test('one pasted entry less leaves exactly that mutant', () {
      final entries = [
        for (final survivor in judged(const []).survivors)
          EquivalentMutant(
            mutator: survivor.mutator,
            original: survivor.original,
            replacement: survivor.replacement,
            occurrence: survivor.sameKeyCount > 1 ? survivor.occurrence : null,
            reason: 'for the test',
          ),
      ];
      final verdict = judged([...entries.take(3), ...entries.skip(4)]);
      expect(verdict.violations, isEmpty);
      expect(
        [
          for (final survivor in verdict.survivors)
            formatListedMutant(survivor),
        ],
        [
          'lib/steps.dart:4:28 / NumberLiteral / 0 → 1 / occurrence 2 of 4 '
              '(Survived)',
        ],
      );
    });
  });

  group('the report of a part of a run (dart_mutant run --shard)', () {
    String partJson(Object? config) => jsonEncode({
      'schemaVersion': '2',
      'config': config,
      'files': {
        gatePath: {
          'source': source,
          'mutants': [
            {
              'mutatorName': 'EqualityOperator',
              'replacement': 'age > 18',
              'status': 'Killed',
              'location': {
                'start': {'line': 1, 'column': 41},
                'end': {'line': 1, 'column': 50},
              },
            },
          ],
        },
      },
    });

    MutationVerdict judgedPart(Object? config) => judgeMutationReport(
      gates: [gate()],
      report: parseMutationReport(partJson(config)),
      readSource: (_) => source,
    );

    test('is refused as a whole, also when every mutant in it is killed', () {
      final report = parseMutationReport(
        partJson({
          'mutatorsVersion': 2,
          'shard': {'index': 2, 'count': 4, 'notTested': <String>[]},
        }),
      );
      expect(report.part, '2/4');
      final verdict = judgeMutationReport(
        gates: [gate()],
        report: report,
        readSource: (_) => source,
      );
      expect(messages(verdict), [
        'mutation report: is part 2/4 of a run (--shard), not a result. Put '
            'the parts together with "dart_mutant merge" and judge the '
            'report that writes',
      ]);
      expect(verdict.survivors, isEmpty);
      expect(numbers(verdict.summary), [0, 0, 0, 0, 0, 0, 0]);
    });

    test('1/1 is a part as well', () {
      expect(
        messages(
          judgedPart({
            'shard': {'index': 1, 'count': 1},
          }),
        ).single,
        startsWith('mutation report: is part 1/1 of a run'),
      );
    });

    test('a shard that does not say which part it is is a part all the '
        'same', () {
      for (final (config, part) in [
        ({'shard': 'text'}, '?/?'),
        ({'shard': <String, Object?>{}}, '?/?'),
        (
          {
            'shard': {'index': 3},
          },
          '3/?',
        ),
        (
          {
            'shard': {'count': 4},
          },
          '?/4',
        ),
      ]) {
        expect(parseMutationReport(partJson(config)).part, part);
        expect(
          messages(judgedPart(config)).single,
          startsWith('mutation report: is part $part of a run'),
        );
      }
    });

    test('a report without config.shard is the report of a whole run', () {
      for (final config in [
        null,
        {'mutatorsVersion': 2},
        {'shard': null},
        'text',
      ]) {
        expect(parseMutationReport(partJson(config)).part, isNull);
        expect(judgedPart(config).violations, isEmpty, reason: '$config');
      }
    });
  });

  group('parseMutationReport', () {
    String reportJson(Object? mutant) => jsonEncode({
      'schemaVersion': '2',
      'files': {
        gatePath: {
          'source': source,
          'mutants': [mutant],
        },
      },
    });

    test('reads what the verdict needs and ignores the rest', () {
      final report = parseMutationReport(
        reportJson({
          'id': '1',
          'mutatorName': 'EqualityOperator',
          'replacement': 'age > 18',
          'status': 'Killed',
          'duration': 12,
          'location': {
            'start': {'line': 1, 'column': 41},
            'end': {'line': 1, 'column': 50},
          },
        }),
      );
      final file = report.files[gatePath]!;
      expect(file.source, source);
      final parsed = file.mutants.single;
      expect(
        [parsed.mutatorName, parsed.replacement, parsed.status],
        ['EqualityOperator', 'age > 18', 'Killed'],
      );
      expect(
        [
          parsed.start.line,
          parsed.start.column,
          parsed.end.line,
          parsed.end.column,
        ],
        [1, 41, 1, 50],
      );
    });

    test('a report without files is an empty report', () {
      expect(parseMutationReport('{}').files, isEmpty);
    });

    test('source, mutants and replacement may be missing or null', () {
      final empty = parseMutationReport('{"files": {"lib/a.dart": {}}}');
      expect(empty.files['lib/a.dart']!.source, isNull);
      expect(empty.files['lib/a.dart']!.mutants, isEmpty);
      final nulls = parseMutationReport(
        '{"files": {"lib/a.dart": {"source": null, "mutants": null}}}',
      );
      expect(nulls.files['lib/a.dart']!.source, isNull);
      expect(nulls.files['lib/a.dart']!.mutants, isEmpty);
      for (final replacement in [
        <String, Object?>{},
        <String, Object?>{'replacement': null},
      ]) {
        final report = parseMutationReport(
          reportJson({
            'mutatorName': 'A',
            'status': 'Killed',
            ...replacement,
            'location': {
              'start': {'line': 1, 'column': 1},
              'end': {'line': 1, 'column': 2},
            },
          }),
        );
        expect(report.files[gatePath]!.mutants.single.replacement, isNull);
      }
    });

    for (final (name, text, message) in [
      ('text that is not JSON', 'x', startsWith('not valid JSON')),
      ('an array', '[]', equals('must be a JSON object')),
      (
        'files that is not an object',
        '{"files": []}',
        equals('"files" must be an object'),
      ),
      (
        'a file that is not an object',
        '{"files": {"lib/a.dart": 1}}',
        equals('files["lib/a.dart"] must be an object'),
      ),
      (
        'a source that is not a string',
        '{"files": {"lib/a.dart": {"source": 1}}}',
        equals('files["lib/a.dart"].source must be a string'),
      ),
      (
        'mutants that are not an array',
        '{"files": {"lib/a.dart": {"mutants": {}}}}',
        equals('files["lib/a.dart"].mutants must be an array'),
      ),
      (
        'a replacement that is not a string',
        reportJson({
          'mutatorName': 'A',
          'status': 'Killed',
          'replacement': 1,
          'location': {
            'start': {'line': 1, 'column': 1},
            'end': {'line': 1, 'column': 2},
          },
        }),
        contains('mutants[0] must have'),
      ),
      (
        'a location without a column',
        reportJson({
          'mutatorName': 'A',
          'status': 'Killed',
          'location': {
            'start': {'line': 1},
            'end': {'line': 1, 'column': 2},
          },
        }),
        contains('mutants[0] must have'),
      ),
      (
        'a mutant that is not an object',
        reportJson('Killed'),
        contains('mutants[0] must have mutatorName, status and location'),
      ),
      (
        'a location without an end',
        reportJson({
          'mutatorName': 'A',
          'status': 'Killed',
          'location': {
            'start': {'line': 1, 'column': 1},
          },
        }),
        contains('mutants[0] must have'),
      ),
      (
        'a mutant without a location',
        reportJson({'mutatorName': 'A', 'status': 'Killed'}),
        contains('mutants[0] must have mutatorName, status and location'),
      ),
      (
        'a mutant without a status',
        reportJson({
          'mutatorName': 'A',
          'location': {
            'start': {'line': 1, 'column': 1},
            'end': {'line': 1, 'column': 2},
          },
        }),
        contains('mutants[0] must have'),
      ),
    ]) {
      test('rejects $name', () {
        expect(
          () => parseMutationReport(text),
          throwsA(
            isA<ReportFormatError>()
                .having((e) => e.message, 'message', message)
                .having((e) => '$e', 'toString()', message),
          ),
        );
      });
    }
  });
}
