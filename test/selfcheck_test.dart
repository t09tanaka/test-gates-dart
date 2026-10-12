import 'dart:convert';

import 'package:test/test.dart';
import 'package:test_gates/src/lcov.dart';
import 'package:test_gates/src/selfcheck.dart';

List<int> withProbe(List<int> original, [String path = 'lib/a.dart']) => [
  ...original,
  ...buildProbe(original, path).suffix,
];

void main() {
  group('buildProbe', () {
    test('appends a comment and a function after the last line', () {
      final probe = buildProbe(utf8.encode('int a() => 1;\n'), 'lib/a.dart');
      final lines = ascii.decode(probe.suffix).split('\n');
      expect(lines, hasLength(3));
      expect(lines[0], startsWith('// test_gates selfcheck probe 0. '));
      expect(
        lines[1],
        matches(RegExp(r'^int testGatesSelfcheckProbe[0-9a-f]{8}\(\) => 0;$')),
      );
      expect(lines[2], isEmpty);
      // Line 1 is the source, 2 the comment, 3 the function.
      expect(probe.line, 3);
    });

    test('the text of the probe says what it is and what to do with it', () {
      expect(
        ascii.decode(buildProbe(utf8.encode('a\n'), 'lib/a.dart').suffix),
        '// test_gates selfcheck probe 0. Never executed. Removed when the '
        'run ends; delete these two lines if they are left behind.\n'
        'int ${probeFunctionName('lib/a.dart')}() => 0;\n',
      );
    });

    test('the name always has eight hexadecimal digits', () {
      // FNV-1a of these paths, worked out by hand: the second starts with 0.
      expect(
        probeFunctionName('lib/models/shipping_fee.dart'),
        'testGatesSelfcheckProbe7ab929ac',
      );
      expect(
        probeFunctionName('lib/models/zone37.dart'),
        'testGatesSelfcheckProbe0971a727',
      );
    });

    test('a file without a final line break gets one first', () {
      final probe = buildProbe(utf8.encode('a\nb'), 'lib/a.dart');
      expect(
        ascii.decode(probe.suffix),
        startsWith('\n// test_gates selfcheck probe 1. '),
      );
      expect(probe.line, 4);
    });

    test('an empty file', () {
      final probe = buildProbe(const [], 'lib/a.dart');
      expect(ascii.decode(probe.suffix), startsWith('// test_gates'));
      expect(probe.line, 2);
    });

    test('CRLF line ends count as one line each', () {
      expect(buildProbe(utf8.encode('a\r\nb\r\n'), 'lib/a.dart').line, 4);
    });

    test('the function is named after the path, so two parts of one '
        'library do not collide', () {
      expect(
        probeFunctionName('lib/a.dart'),
        isNot(probeFunctionName('lib/a.g.dart')),
      );
      expect(probeFunctionName('lib/a.dart'), probeFunctionName('lib/a.dart'));
      expect(
        ascii.decode(buildProbe(const [], 'lib/a.dart').suffix),
        contains('int ${probeFunctionName('lib/a.dart')}() => 0;'),
      );
    });
  });

  group('lengthWithoutProbe', () {
    test('gives back the file byte for byte', () {
      for (final original in [
        utf8.encode('int a() => 1;\n'),
        utf8.encode('int a() => 1;'),
        utf8.encode('int a() => 1;\n\n\n'),
        utf8.encode('a\r\nb\r\n'),
        utf8.encode('// 金額\nint a() => 1;'),
        // A byte order mark, and bytes that are not UTF-8.
        [0xEF, 0xBB, 0xBF, 0x61, 0x0A],
        [0xFF, 0xFE, 0x0A, 0xC3],
        <int>[],
        List.filled(5000, 0x61),
      ]) {
        final probed = withProbe(original);
        expect(lengthWithoutProbe(probed), original.length);
        expect(probed.sublist(0, original.length), original);
      }
    });

    test('null without a probe at the very end', () {
      expect(lengthWithoutProbe(utf8.encode('int a() => 1;\n')), isNull);
      expect(lengthWithoutProbe(const []), isNull);
      final probed = withProbe(utf8.encode('a\n'));
      // Something was written after the probe.
      expect(lengthWithoutProbe([...probed, ...utf8.encode('b\n')]), isNull);
      // The probe is cut short.
      expect(lengthWithoutProbe(probed.sublist(0, probed.length - 1)), isNull);
      // The marker alone, in a comment of the source.
      expect(
        lengthWithoutProbe(utf8.encode('$probeMarker\nint a() => 0;\n')),
        isNull,
      );
    });

    test('only the last of two probes is removed', () {
      final original = utf8.encode('a\n');
      final once = withProbe(original);
      expect(lengthWithoutProbe(withProbe(once)), once.length);
    });
  });

  group('judgeCoverageRun', () {
    String? judge({int? exitCode, String? startError, bool read = true}) =>
        judgeCoverageRun(
          command: 'flutter test',
          exitCode: exitCode,
          startError: startError,
          tracefileRead: read,
          tracefile: 'coverage/lcov.info',
        );

    test('a passing command that wrote the tracefile is a measurement', () {
      expect(judge(exitCode: 0), isNull);
    });

    test('a command that cannot be started', () {
      expect(
        judge(startError: 'No such file or directory'),
        'cannot start "flutter test" (No such file or directory)',
      );
      expect(judge(), 'cannot start "flutter test"');
    });

    test('a failing command proves nothing, whatever the tracefile says', () {
      expect(
        judge(exitCode: 1),
        startsWith('"flutter test" failed (exit 1) with the probes in place.'),
      );
    });

    test('no tracefile', () {
      expect(
        judge(exitCode: 0, read: false),
        startsWith(
          '"flutter test" passed but did not write coverage/lcov.info',
        ),
      );
    });
  });

  group('judgeProbe', () {
    const gate = ProbedGate(path: 'lib/a.dart', line: 9);

    String? judge(String record, {String path = 'lib/a.dart'}) {
      final report = parseLcov(
        'SF:$path\n${record}end_of_record\n'
        'SF:lib/other.dart\nDA:1,1\nBRDA:1,0,0,1\nend_of_record\n',
      );
      return judgeProbe(
        gate,
        report,
        judgeLcov([gate.path], report, tracefile: 'lcov.info'),
      );
    }

    test('holds when the probe is the unexecuted line and the untaken '
        'branch', () {
      expect(judge('DA:1,1\nDA:9,0\nBRDA:1,0,0,1\nBRDA:9,0,0,0\n'), isNull);
    });

    test('holds for a path written with ./', () {
      const dotted = ProbedGate(path: './lib/a.dart', line: 9);
      final report = parseLcov(
        'SF:lib/a.dart\nDA:9,0\nBRDA:9,0,0,0\nend_of_record\n',
      );
      expect(
        judgeProbe(
          dotted,
          report,
          judgeLcov([dotted.path], report, tracefile: 'lcov.info'),
        ),
        isNull,
      );
    });

    test('a gate that is red on another line proves nothing', () {
      expect(
        judge('DA:1,0\nDA:2,1\nBRDA:1,0,0,0\nBRDA:2,0,0,1\n'),
        'the probe at line 9 is not reported as a line that was not '
        'executed. The tracefile does not measure this file as it is on disk',
      );
    });

    test('a probe that is reported as executed', () {
      expect(
        judge('DA:9,1\nBRDA:9,0,0,1\n'),
        startsWith('the probe at line 9 is not reported as a line'),
      );
    });

    test('no record for the gate', () {
      expect(
        judge('DA:9,0\nBRDA:9,0,0,0\n', path: 'lib/b.dart'),
        'no record in the tracefile, so the probe was not measured. '
        'No test loads this file',
      );
    });

    test('lines without branches: the branch gate is not proven', () {
      expect(
        judge('DA:1,1\nDA:9,0\nBRDA:1,0,0,1\n'),
        'the probe at line 9 is not reported as a branch that was not '
        'taken. Collect the coverage with --branch-coverage',
      );
    });

    test('the result of the gate is the one that counts, wherever it is '
        'among the results', () {
      final report = parseLcov(
        'SF:lib/a.dart\nDA:9,0\nBRDA:9,0,0,0\nend_of_record\n',
      );
      const failed = LcovGateResult(path: 'lib/a.dart', ok: false);
      const passed = LcovGateResult(path: 'lib/a.dart', ok: true);
      const otherPassed = LcovGateResult(path: 'lib/b.dart', ok: true);
      const otherFailed = LcovGateResult(path: 'lib/c.dart', ok: false);
      String? judged(List<LcovGateResult> results) => judgeProbe(
        gate,
        report,
        LcovVerdict(violations: const [], results: results),
      );
      expect(judged([failed, otherPassed]), isNull);
      expect(judged([otherPassed, failed, otherPassed]), isNull);
      expect(judged([otherFailed, failed]), isNull);
      const message =
          'the probe at line 9 was not executed, and the gate passed';
      expect(judged([passed, otherFailed]), message);
      expect(judged([otherFailed, passed]), message);
      expect(judged([otherFailed]), message);
    });

    test('a verdict that passes the gate', () {
      final report = parseLcov(
        'SF:lib/a.dart\nDA:9,0\nBRDA:9,0,0,0\nend_of_record\n',
      );
      const passing = LcovVerdict(
        violations: [],
        results: [LcovGateResult(path: 'lib/a.dart', ok: true)],
      );
      expect(
        judgeProbe(gate, report, passing),
        'the probe at line 9 was not executed, and the gate passed',
      );
      expect(
        judgeProbe(
          gate,
          report,
          const LcovVerdict(violations: [], results: []),
        ),
        'the probe at line 9 was not executed, and the gate passed',
      );
    });
  });
}
