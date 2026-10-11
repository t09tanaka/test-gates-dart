import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';

const fullRecord =
    'DA:1,1\nDA:2,3\nBRDA:1,0,0,1\nBRDA:2,0,0,1\nend_of_record\n';
const partialRecord =
    'DA:1,1\nDA:2,0\nBRDA:1,0,0,1\nBRDA:2,0,0,0\nend_of_record\n';

void main() {
  late Directory dir;
  late List<String> out;
  late List<String> err;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('test_gates_');
    out = [];
    err = [];
  });

  tearDown(() => dir.deleteSync(recursive: true));

  void write(String path, String content) {
    File('${dir.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync(content);
  }

  void manifest(Map<String, Object?> json) =>
      write('test-gates.json', jsonEncode(json));

  Map<String, Object?> gate(String path) => {
    'path': path,
    'decides': 'd',
    'impact': 'i',
  };

  int lcov([List<String> arguments = const []]) => run([
    'lcov',
    '--dir',
    dir.path,
    ...arguments,
  ], Io(out: out.add, err: err.add));

  group('exit code 0', () {
    test('every gate at 100% lines and branches', () {
      manifest({
        'gates': [gate('lib/a.dart'), gate('lib/b.dart')],
        'settings': {
          'lcov': {
            'file': 'coverage/lcov.info',
            'summaryExclude': [r'\.g\.dart$'],
          },
        },
      });
      write('lib/a.dart', '');
      write('lib/b.dart', '');
      write(
        'coverage/lcov.info',
        'SF:lib/a.dart\n$fullRecord'
            'SF:lib/b.dart\n$fullRecord'
            'SF:lib/other.dart\n$partialRecord'
            'SF:lib/x.g.dart\nDA:1,0\nend_of_record\n',
      );
      expect(lcov(), 0);
      expect(out, [
        'reference: overall line coverage 83.33% (5/6, not gated)',
        '  ✓ lib/a.dart: 2/2 lines, 2/2 branches',
        '  ✓ lib/b.dart: 2/2 lines, 2/2 branches',
        'test_gates lcov: OK (2 gate(s) at 100% line and branch coverage)',
      ]);
      expect(err, isEmpty);
    });

    test('--file wins over settings.lcov.file, relative to --dir', () {
      manifest({
        'gates': [gate('lib/a.dart')],
        'settings': {
          'lcov': {'file': 'coverage/missing.info'},
        },
      });
      write('lib/a.dart', '');
      write('other.info', 'SF:lib/a.dart\n$fullRecord');
      expect(lcov(['--file', 'other.info']), 0);
    });

    test('absolute --file, and absolute SF paths as dart test writes them', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      write('lib/a.dart', '');
      final resolved = dir.resolveSymbolicLinksSync();
      write('x.info', 'SF:$resolved/lib/a.dart\n$fullRecord');
      expect(lcov(['--file=$resolved/x.info']), 0);
      expect(out, contains('  ✓ lib/a.dart: 2/2 lines, 2/2 branches'));
    });
  });

  group('exit code 1', () {
    test('a gate below 100%, a gate without record, a gate that moved', () {
      manifest({
        'gates': [
          gate('lib/a.dart'),
          gate('lib/b.dart'),
          gate('lib/unloaded.dart'),
          gate('lib/moved.dart'),
          gate('lib/A.dart'),
        ],
      });
      write('lib/a.dart', '');
      write('lib/b.dart', '');
      write('lib/unloaded.dart', '');
      write(
        'cov.info',
        'SF:lib/a.dart\n$fullRecord'
            'SF:lib/b.dart\n$partialRecord'
            'SF:lib/moved.dart\n$fullRecord',
      );
      expect(lcov(['--file', 'cov.info']), 1);
      expect(out, [
        'reference: overall line coverage 83.33% (5/6, not gated)',
        '  ✓ lib/a.dart: 2/2 lines, 2/2 branches',
        '  ✗ lib/b.dart: 1/2 lines, 1/2 branches',
      ]);
      const notFound =
          'file not found (the check is case-sensitive). '
          'Update test-gates.json if it moved';
      expect(err, [
        'test_gates lcov: 5 violation(s)',
        '  - lib/moved.dart: $notFound',
        '  - lib/A.dart: $notFound',
        '  - lib/b.dart:2: 1/2 lines covered (uncovered: 2)',
        '  - lib/b.dart:2: 1/2 branches taken (not taken, at lines: 2)',
        '  - lib/unloaded.dart: no record in the lcov file',
      ]);
    });

    test('a tracefile collected without --branch-coverage', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      write('lib/a.dart', '');
      write('cov.info', 'SF:lib/a.dart\nDA:1,1\nend_of_record\n');
      expect(lcov(['--file', 'cov.info']), 1);
      expect(out, [
        'reference: overall line coverage 100.00% (1/1, not gated)',
        '  ✗ lib/a.dart: 1/1 lines, 0/0 branches',
      ]);
      expect(err, [
        'test_gates lcov: 1 violation(s)',
        allOf(
          startsWith('  - cov.info: no branch data (no BRDA entry).'),
          contains('--branch-coverage'),
        ),
      ]);
    });

    test('violations inside the manifest', () {
      manifest({
        'gates': [
          {'path': 'lib/a.dart', 'decides': 'd'},
        ],
      });
      write('lib/a.dart', '');
      write('cov.info', 'SF:lib/a.dart\n$fullRecord');
      expect(lcov(['--file', 'cov.info']), 1);
      expect(err, [
        'test_gates lcov: 1 violation(s)',
        '  - test-gates.json: lib/a.dart: "impact" is missing in gates',
      ]);
    });

    test('a truncated tracefile, although what is left is at 100%', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      write('lib/a.dart', '');
      write('cov.info', 'SF:lib/a.dart\nDA:1,1\nBRDA:1,0,0,1\nBRDA:2,0,');
      expect(lcov(['--file', 'cov.info']), 1);
      expect(err, [
        'test_gates lcov: 2 violation(s)',
        startsWith('  - cov.info: unreadable DA / BRDA entry at line 4 '),
        startsWith('  - cov.info: the last record is not closed'),
      ]);
    });

    test('bytes that are not UTF-8 do not stop the reading', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      write('lib/a.dart', '');
      File('${dir.path}/cov.info').writeAsBytesSync([
        ...utf8.encode('TN:'),
        0xFF,
        ...utf8.encode('\nSF:lib/a.dart\n$fullRecord'),
      ]);
      expect(lcov(['--file', 'cov.info']), 0);
    });

    test('an empty tracefile', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      write('lib/a.dart', '');
      write('cov.info', '');
      expect(lcov(['--file', 'cov.info']), 1);
      expect(out, ['reference: no instrumented lines in the lcov file']);
      expect(err, hasLength(3));
    });

    test('a tracefile that cannot be read', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      expect(lcov(['--file', 'coverage/lcov.info']), 1);
      expect(out, isEmpty);
      expect(
        err.single,
        startsWith('test_gates lcov: cannot read coverage/lcov.info ('),
      );
      expect(err.single, endsWith('). Run the tests with coverage first'));
    });
  });

  group('exit code 2', () {
    test('no test-gates.json', () {
      expect(lcov(['--file', 'x.info']), 2);
      expect(
        err.single,
        startsWith('test_gates: test-gates.json not found in '),
      );
    });

    test('broken JSON', () {
      write('test-gates.json', '{');
      expect(lcov(['--file', 'x.info']), 2);
      expect(
        err.single,
        startsWith('test_gates: test-gates.json is not valid JSON'),
      );
    });

    test('a byte order mark, which upstream does not accept either', () {
      File(
        '${dir.path}/test-gates.json',
      ).writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode('{"gates":[]}')]);
      expect(lcov(['--file', 'x.info']), 2);
      expect(
        err.single,
        startsWith('test_gates: test-gates.json is not valid JSON'),
      );
    });

    test('unknown top-level key', () {
      manifest({
        'gates': [gate('lib/a.dart')],
        'gate': <Object>[],
      });
      expect(lcov(['--file', 'x.info']), 2);
      expect(err, [
        'test_gates: test-gates.json: unknown top-level key "gate"',
      ]);
    });

    test('unknown setting', () {
      manifest({
        'gates': [gate('lib/a.dart')],
        'settings': {
          'lcov': {'path': 'x'},
        },
      });
      expect(lcov(['--file', 'x.info']), 2);
      expect(err, [
        'test_gates: test-gates.json: settings.lcov: unknown key "path"',
      ]);
    });

    test('no tracefile named anywhere', () {
      manifest({
        'gates': [gate('lib/a.dart')],
      });
      expect(lcov(), 2);
      expect(err, [
        'test_gates: no lcov file given. Pass --file <lcov.info> or set '
            'settings.lcov.file',
      ]);
    });
  });
}
