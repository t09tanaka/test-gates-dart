import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/lcov.dart';

/// The fixtures are real output for `test/fixtures/lcov/probe.dart.txt`,
/// measured with Flutter 3.47.2 / Dart 3.13.2:
/// - `*_partial`: every function called with one input only,
/// - `*_full`: every side of every function exercised,
/// - `flutter_test_*`: `flutter test --coverage --branch-coverage`,
/// - `dart_test_*`: `dart test --coverage-path=<file> --branch-coverage`.
String fixture(String name) =>
    File('test/fixtures/lcov/$name.info').readAsStringSync();

const probe = 'lib/probe.dart';

/// `BRDA` line -> taken, as written in the tracefile.
Map<int, int> brda(String name) => {
  for (final line in fixture(name).split('\n'))
    if (line.startsWith('BRDA:'))
      int.parse(line.substring(5).split(',')[0]): int.parse(line.split(',')[3]),
};

LcovFile probeOf(String name) => parseLcov(fixture(name)).files[probe]!;

void main() {
  group('what Dart records as a branch (measured)', () {
    final partial = brda('flutter_test_partial');

    test('the entry of every function is a block, called or not', () {
      expect(partial[1], 1, reason: 'ifElse, called');
      expect(partial[118], 1, reason: 'noBranch has no branch but one entry');
      expect(partial[111], 0, reason: 'notCalled');
    });

    test('a block that was not executed is written with 0, not left out', () {
      expect(fixture('flutter_test_partial'), contains('BRDA:4,0,0,0'));
      expect(fixture('flutter_test_partial'), isNot(contains(',-')));
    });

    test('if / else: both blocks are recorded', () {
      expect((partial[2], partial[4]), (1, 0));
    });

    test('else if: its block is recorded', () {
      expect((partial[123], partial[125]), (1, 0));
    });

    // `dart_test_else_if` is the output of `dart test` (Dart 3.13.2) for
    // `else_if.dart.txt`, run by `else_if_test.dart.txt`: both conditions are
    // false in every call, so no `else if` block ever runs.
    test('else if: its block shares the entry of the else it is in', () {
      final entries = brda('dart_test_else_if');
      // `} else if (b) {` at lines 4, 14 and 23: taken, although `return 2`
      // never ran. The entry is that of the `else`, which was entered.
      expect((entries[4], entries[14], entries[23]), (1, 1, 1));
      // The first `then` of each function did not run, and says so.
      expect((entries[2], entries[12], entries[21]), (0, 0, 0));
      // Only a call inside the block gives it away, as a line.
      final file = parseLcov(
        fixture('dart_test_else_if'),
        rootDirs: ['/abs/project'],
      ).files['lib/else_if.dart']!;
      expect(file.uncovered, [24]);
      expect(file.untakenBranchLines, [2, 12, 21]);
    });

    test('an early return without braces is a block', () {
      expect(partial[18], 0);
    });

    test('switch statement and switch expression: every case is a block', () {
      expect((partial[56], partial[58], partial[60]), (1, 0, 0));
      expect((partial[67], partial[68], partial[69]), (1, 0, 0));
    });

    test('loops: the body is a block', () {
      expect((partial[75], partial[83], partial[92]), (0, 0, 0));
    });

    test('try / catch: both are blocks', () {
      expect((partial[99], partial[102]), (1, 0));
    });

    test('LIMIT: an if without else has no entry for the skipped side', () {
      // ifNoElse(true) only: the `if` at line 11 was never skipped, and
      // nothing in the record says so.
      expect(partial[11], 1);
      expect(partial.keys.where((line) => line > 11 && line < 17), isEmpty);
    });

    test('LIMIT: ?:, &&, ||, ??, ?. and default parameters are not blocks', () {
      for (final line in [23, 27, 28, 29, 33, 37, 41, 45, 51]) {
        expect(partial.containsKey(line), isFalse, reason: 'line $line');
      }
      // defaultParam: only the function entry.
      expect(partial[109], 1);
    });

    test('LIMIT: blocks on one line are merged into one entry', () {
      // oneLineIfElse(true): entry + then taken, else not. One entry, hits 2.
      expect(partial[107], 2);
      expect(
        fixture(
          'flutter_test_partial',
        ).split('\n').where((line) => line.startsWith('BRDA:107,')),
        hasLength(1),
      );
    });

    test('no BRF / BRH totals are written', () {
      expect(fixture('flutter_test_full'), isNot(contains('BRF:')));
      expect(fixture('flutter_test_full'), isNot(contains('BRH:')));
    });

    test('without --branch-coverage there is no BRDA at all', () {
      expect(brda('flutter_test_partial_no_branch'), isEmpty);
    });

    test('dart test and flutter test differ only in the SF path', () {
      for (final run in ['partial', 'full']) {
        expect(
          fixture('dart_test_$run').replaceFirst('/abs/project/', ''),
          fixture('flutter_test_$run'),
        );
      }
    });
  });

  group('parseLcov', () {
    test('counts lines from DA and branches from BRDA', () {
      final file = probeOf('flutter_test_partial');
      expect((file.hit, file.found), (29, 42));
      expect(file.uncovered.take(4), [45, 48, 51, 58]);
      expect((file.branchesHit, file.branchesFound), (28, 44));
      expect(file.untakenBranchLines.take(4), [4, 18, 48, 58]);
    });

    test('a fully exercised file is at 100% on both', () {
      final file = probeOf('flutter_test_full');
      expect((file.hit, file.found), (42, 42));
      expect((file.branchesHit, file.branchesFound), (44, 44));
      expect(file.uncovered, isEmpty);
      expect(file.untakenBranchLines, isEmpty);
    });

    test('reports whether the tracefile has branch data', () {
      expect(parseLcov(fixture('flutter_test_partial')).hasBranchData, isTrue);
      final without = parseLcov(fixture('flutter_test_partial_no_branch'));
      expect(without.hasBranchData, isFalse);
      expect(without.files[probe]!.branchesFound, 0);
      expect(without.files[probe]!.found, 42);
    });

    test('makes absolute paths under a root relative', () {
      final text = fixture('dart_test_partial');
      expect(parseLcov(text).files.keys, ['/abs/project/lib/probe.dart']);
      for (final root in ['/abs/project', '/abs/project/']) {
        expect(parseLcov(text, rootDirs: [root]).files.keys, [probe]);
      }
      expect(
        parseLcov(text, rootDirs: ['/abs/pro', '/abs/project']).files.keys,
        [probe],
        reason: 'a root is a directory, not a prefix of a name',
      );
    });

    test('normalizes ./ and backslashes', () {
      final report = parseLcov(
        'SF:./lib/a.dart\nDA:1,1\nend_of_record\n'
        'SF:C:\\app\\lib\\b.dart\nDA:1,1\nend_of_record\n',
        rootDirs: [r'C:\app'],
      );
      expect(report.files.keys, ['lib/a.dart', 'lib/b.dart']);
    });

    test('unites records of the same file: hit in any record counts', () {
      final report = parseLcov(
        'SF:lib/a.dart\nDA:1,1\nDA:2,0\nBRDA:1,0,0,1\nBRDA:2,0,0,0\nend_of_record\n'
        'SF:lib/a.dart\nDA:1,0\nDA:2,3\nDA:3,0\nBRDA:1,0,0,0\nBRDA:2,0,0,1\nBRDA:3,0,0,0\nend_of_record\n',
      );
      final file = report.files['lib/a.dart']!;
      expect((file.hit, file.found), (2, 3));
      expect(file.uncovered, [3]);
      expect((file.branchesHit, file.branchesFound), (2, 3));
      expect(file.untakenBranchLines, [3]);
    });

    test('keeps branches of one line apart by block and branch', () {
      // Not what Dart writes, but valid lcov (genhtml, other tools).
      final file = parseLcov(
        'SF:lib/a.dart\nDA:1,1\nBRDA:1,0,0,1\nBRDA:1,0,1,0\nBRDA:1,1,0,-\nend_of_record\n',
      ).files['lib/a.dart']!;
      expect((file.branchesHit, file.branchesFound), (1, 3));
      expect(file.untakenBranchLines, [1]);
    });

    test('reads "-" (block never reached) as not taken', () {
      final file = parseLcov(
        'SF:lib/a.dart\nDA:1,1\nBRDA:1,0,0,-\nend_of_record\n',
      ).files['lib/a.dart']!;
      expect((file.branchesHit, file.branchesFound), (0, 1));
    });

    test('does not trust LH / LF when DA entries exist', () {
      final file = parseLcov(
        'SF:lib/a.dart\nDA:1,1\nDA:2,0\nLF:2\nLH:2\nend_of_record\n',
      ).files['lib/a.dart']!;
      expect((file.hit, file.found), (1, 2));
    });

    test('uses LH / LF for a record without DA', () {
      final file = parseLcov(
        'SF:lib/a.dart\nLF:4\nLH:3\nend_of_record\n',
      ).files['lib/a.dart']!;
      expect((file.hit, file.found), (3, 4));
      expect(file.uncovered, isEmpty);
    });

    test('reads CRLF, skips lines outside a record, reports bad entries', () {
      final report = parseLcov(
        'DA:9,9\r\nSF:lib/a.dart\r\nDA:1,1\r\nDA:x,1\r\nDA:2\r\nDA:3,y\r\n'
        'BRDA:1,0,0\r\nBRDA:x,0,0,1\r\nBRDA:1,0,0,z\r\nBRDA:1,0,0,1\r\n'
        'LF:x\r\nend_of_record\r\nBRDA:5,0,0,1\r\n',
      );
      final file = report.files['lib/a.dart']!;
      expect((file.hit, file.found), (1, 1));
      expect((file.branchesHit, file.branchesFound), (1, 1));
      expect(report.files, hasLength(1));
      expect(report.problems, [
        'unreadable DA / BRDA entry at line 4, 5, 6, 7, 8, 9 of the '
            'tracefile. An entry that cannot be read cannot be counted',
      ]);
    });

    test('a well-formed tracefile has no problems', () {
      for (final name in ['flutter_test_partial', 'dart_test_full']) {
        expect(parseLcov(fixture(name)).problems, isEmpty);
      }
      expect(parseLcov('').problems, isEmpty);
      expect(
        parseLcov('SF:lib/a.dart\nDA:1,1\nend_of_record').problems,
        isEmpty,
        reason: 'no newline at the end',
      );
    });

    test('a truncated tracefile is reported', () {
      final cut = fixture('flutter_test_full').split('BRDA:4,').first;
      final report = parseLcov(cut);
      expect(report.problems, [
        'the last record is not closed with end_of_record. The tracefile '
            'looks truncated',
      ]);
      // Everything left is covered: without the report this would pass.
      final file = report.files[probe]!;
      expect(file.branchesHit, file.branchesFound);
      expect(file.hit, file.found);
    });

    test('an entry cut in the middle is reported as well', () {
      expect(
        parseLcov('SF:lib/a.dart\nDA:1,1\nBRDA:1,0,0,').problems,
        hasLength(2),
      );
    });

    test('a record that the next SF ends counts as well', () {
      final report = parseLcov(
        'SF:lib/a.dart\nLF:2\nLH:1\nSF:lib/b.dart\nLF:5\nLH:5\nend_of_record\n',
      );
      final a = report.files['lib/a.dart']!;
      expect((a.hit, a.found), (1, 2));
      final b = report.files['lib/b.dart']!;
      expect((b.hit, b.found), (5, 5));
      expect(report.problems, isEmpty);
    });

    test('a record that is not closed still counts', () {
      final report = parseLcov('SF:lib/a.dart\nLF:2\nLH:1');
      final file = report.files['lib/a.dart']!;
      expect((file.hit, file.found), (1, 2));
      expect(report.problems, hasLength(1));
    });
  });

  group('judgeLcov', () {
    LcovVerdict judge(String text, [List<String> gates = const [probe]]) =>
        judgeLcov(gates, parseLcov(text), tracefile: 'coverage/lcov.info');

    List<String> messages(LcovVerdict verdict) => [
      for (final violation in verdict.violations) violation.toString(),
    ];

    test('passes a gate at 100% lines and 100% branches', () {
      final verdict = judge(fixture('flutter_test_full'));
      expect(verdict.violations, isEmpty);
      final result = verdict.results.single;
      expect(result.ok, isTrue);
      expect((result.hit, result.found), (42, 42));
      expect((result.branchesHit, result.branchesFound), (44, 44));
    });

    test('reports lines and branches separately', () {
      final verdict = judge(fixture('flutter_test_partial'));
      expect(messages(verdict), [
        'lib/probe.dart:45: 29/42 lines covered (uncovered: 45, 48, 51, 58, '
            '68, 76, 84, 85, 93, 100, 111, 125, 135)',
        'lib/probe.dart:4: 28/44 branches taken (not taken, at lines: 4, 18, '
            '48, 58, 60, 68, 69, 75, 83, 92, 100, 102, 111, 112, 125, 135)',
      ]);
      expect(verdict.results.single.ok, isFalse);
    });

    test('fails on branches alone when every line is covered', () {
      final verdict = judge(
        'SF:lib/probe.dart\nDA:1,1\nBRDA:1,0,0,1\nBRDA:3,0,0,0\nend_of_record\n',
      );
      expect(messages(verdict), [
        'lib/probe.dart:3: 1/2 branches taken (not taken, at lines: 3)',
      ]);
      expect(verdict.results.single.ok, isFalse);
    });

    test('fails on lines alone when every branch is taken', () {
      final verdict = judge(
        'SF:lib/probe.dart\nDA:1,1\nDA:2,0\nBRDA:1,0,0,1\nend_of_record\n',
      );
      expect(messages(verdict), [
        'lib/probe.dart:2: 1/2 lines covered (uncovered: 2)',
      ]);
    });

    test('a tracefile without branch data fails once, with the remedy', () {
      final verdict = judge(
        fixture('flutter_test_full').replaceAll(RegExp(r'BRDA:.*\n'), ''),
        [probe, probe],
      );
      expect(messages(verdict), [
        allOf(
          startsWith('coverage/lcov.info: no branch data (no BRDA entry).'),
          contains('flutter test --coverage --branch-coverage'),
          contains('dart test --coverage-path=<file> --branch-coverage'),
        ),
      ]);
      expect(verdict.results.map((result) => result.ok), [false, false]);
      expect(verdict.results.first.found, 42);
    });

    test('the real tracefile without --branch-coverage fails', () {
      final verdict = judge(fixture('flutter_test_partial_no_branch'));
      expect(messages(verdict), hasLength(2));
      expect(messages(verdict).first, contains('no branch data'));
      expect(messages(verdict).last, contains('29/42 lines covered'));
    });

    test('a gate without BRDA in a tracefile that has them fails', () {
      final verdict = judge(
        'SF:lib/probe.dart\nDA:1,1\nend_of_record\n'
        'SF:lib/other.dart\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n',
      );
      expect(messages(verdict), [
        'lib/probe.dart: no branch data (no BRDA entry) in the lcov record',
      ]);
      expect(verdict.results.single.ok, isFalse);
    });

    test('a tracefile with problems fails even if every gate is at 100%', () {
      final verdict = judge(
        'SF:lib/probe.dart\nDA:1,1\nDA:2,\nBRDA:1,0,0,1\nBRDA:3,0,0\n',
      );
      expect(messages(verdict), [
        'coverage/lcov.info: unreadable DA / BRDA entry at line 3, 5 of the '
            'tracefile. An entry that cannot be read cannot be counted',
        'coverage/lcov.info: the last record is not closed with '
            'end_of_record. The tracefile looks truncated',
      ]);
    });

    test('a gate without a record fails', () {
      final verdict = judge(fixture('flutter_test_full'), [
        'lib/unloaded.dart',
        './lib/probe.dart',
      ]);
      expect(messages(verdict), [
        'lib/unloaded.dart: no record in the lcov file',
      ]);
      expect(verdict.results.map((result) => result.ok), [false, true]);
      expect(verdict.results.first.found, 0);
    });

    test('a gate without an instrumented line fails', () {
      final verdict = judge(
        'SF:lib/probe.dart\nend_of_record\n'
        'SF:lib/other.dart\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n',
      );
      expect(messages(verdict), [
        'lib/probe.dart: no instrumented lines in the lcov record',
      ]);
      final result = verdict.results.single;
      expect(result.path, probe);
      expect(result.ok, isFalse);
    });

    test('a record with only LF / LH below 100% names no line', () {
      final verdict = judge(
        'SF:lib/probe.dart\nLF:4\nLH:3\nBRDA:1,0,0,1\nend_of_record\n',
      );
      expect(messages(verdict), ['lib/probe.dart: 3/4 lines covered']);
      expect(verdict.violations.single.line, isNull);
    });

    test('lists at most 20 lines', () {
      final lines = [for (var line = 1; line <= 21; line++) line];
      final verdict = judge(
        'SF:lib/probe.dart\n'
        '${lines.map((line) => 'DA:$line,0\nBRDA:$line,0,0,0\n').join()}'
        'end_of_record\n',
      );
      final listed = lines.take(20).join(', ');
      expect(messages(verdict), [
        'lib/probe.dart:1: 0/21 lines covered (uncovered: $listed, …)',
        'lib/probe.dart:1: 0/21 branches taken (not taken, at lines: $listed, …)',
      ]);
    });

    test('exactly 20 lines are listed without an ellipsis', () {
      final verdict = judge(
        'SF:lib/probe.dart\n'
        '${[for (var line = 1; line <= 20; line++) 'DA:$line,0\n'].join()}'
        'BRDA:1,0,0,1\nend_of_record\n',
      );
      expect(messages(verdict).single, isNot(contains('…')));
    });
  });

  group('summarizeLcov', () {
    final report = parseLcov(
      'SF:lib/a.dart\nDA:1,1\nDA:2,0\nend_of_record\n'
      'SF:lib/a.g.dart\nDA:1,0\nend_of_record\n'
      'SF:lib/l10n/x.dart\nDA:1,0\nend_of_record\n',
    );

    test('adds up every record', () {
      expect(summarizeLcov(report, []), (found: 4, hit: 1));
    });

    test('leaves out the excluded paths', () {
      expect(
        summarizeLcov(report, [RegExp(r'\.g\.dart$'), RegExp('lib/l10n/')]),
        (found: 2, hit: 1),
      );
    });
  });
}
