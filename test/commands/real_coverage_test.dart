@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';

import '../package_root.dart';

/// `selfcheck` and `test` against the real thing: a small package whose
/// coverage is collected by `dart test`. The source is kept as .txt
/// (test/fixtures/selfcheck/package) so that it is not analyzed or run with
/// this package, and is copied into a temporary directory.
void main() {
  late Directory dir;
  late List<String> out;
  late List<String> err;

  const sources = [
    'pubspec.yaml',
    'lib/price.dart',
    'lib/price.g.dart',
    'lib/unloaded.dart',
    'test/price_test.dart',
  ];
  final command = [
    Platform.resolvedExecutable,
    'test',
    '--coverage-path=coverage/lcov.info',
    '--branch-coverage',
  ];

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('test_gates_real_');
    for (final source in sources) {
      File('${dir.path}/$source')
        ..createSync(recursive: true)
        ..writeAsBytesSync(
          File(
            inPackage('test/fixtures/selfcheck/package/$source.txt'),
          ).readAsBytesSync(),
        );
    }
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  setUp(() {
    out = [];
    err = [];
  });

  void manifest(List<String> gates) =>
      File('${dir.path}/test-gates.json').writeAsStringSync(
        jsonEncode({
          'gates': [
            for (final path in gates)
              {'path': path, 'decides': 'd', 'impact': 'i'},
          ],
          'settings': {
            'lcov': {'file': 'coverage/lcov.info'},
            'gateCommand': command,
          },
        }),
      );

  List<int> bytes(String source) =>
      File('${dir.path}/$source').readAsBytesSync();

  test('selfcheck: a library with a part, the part itself, and a file no '
      'test loads', () async {
    manifest(['lib/price.dart', 'lib/price.g.dart', 'lib/unloaded.dart']);
    final before = [for (final source in sources) bytes(source)];

    final code = await runAsync([
      'selfcheck',
      '--dir',
      dir.path,
    ], Io(out: out.add, err: err.add));

    expect(out.sublist(1), [
      '  ✓ lib/price.dart: with unexecuted code at line 11 the gate fails',
      '  ✓ lib/price.g.dart: with unexecuted code at line 5 the gate fails',
    ]);
    expect(err, [
      '  ✗ lib/unloaded.dart: no record in the tracefile, so the probe was '
          'not measured. No test loads this file',
      'test_gates selfcheck: FAILED (1 of 3 negative control(s))',
    ]);
    expect(code, 1);
    expect([for (final source in sources) bytes(source)], before);
  });

  /// The records of the tracefile, sorted: the order of the records is not
  /// the same from run to run.
  List<String> records() =>
      (File('${dir.path}/coverage/lcov.info')
          .readAsStringSync()
          .split('end_of_record')
          .map((record) => record.trim())
          .where((record) => record.isNotEmpty)
          .toList()
        ..sort());

  for (final (name, gates, code) in [
    ('every gate at 100%', ['lib/price.dart', 'lib/price.g.dart'], 0),
    ('a gate that no test loads', ['lib/price.dart', 'lib/unloaded.dart'], 1),
  ]) {
    test('test --selfcheck leaves the tracefile of test and says the same '
        'about the coverage: $name', () async {
      manifest(gates);
      final before = [for (final source in sources) bytes(source)];
      expect(
        await runAsync([
          'test',
          '--dir',
          dir.path,
        ], Io(out: out.add, err: err.add)),
        code,
      );
      final plainRecords = records();
      final plainOut = [...out];
      final plainErr = [...err];
      out.clear();
      err.clear();

      expect(
        await runAsync([
          'test',
          '--selfcheck',
          '--dir',
          dir.path,
        ], Io(out: out.add, err: err.add)),
        code,
      );
      expect(records(), plainRecords);
      // What is said about the coverage comes last, and is what test says.
      expect(out.sublist(out.length - plainOut.length), plainOut);
      expect(err.sublist(err.length - plainErr.length), plainErr);
      expect([for (final source in sources) bytes(source)], before);
    });
  }

  test('test: the same command, without probes, passes the gates', () async {
    manifest(['lib/price.dart', 'lib/price.g.dart']);
    final code = await runAsync([
      'test',
      '--dir',
      dir.path,
    ], Io(out: out.add, err: err.add));
    expect(err, isEmpty);
    // How many lines and blocks carry an entry is up to the SDK.
    expect(out.sublist(1), [
      startsWith('  ✓ lib/price.dart: '),
      startsWith('  ✓ lib/price.g.dart: '),
      'test_gates lcov: OK (2 gate(s) at 100% line and branch coverage)',
    ]);
    expect(code, 0);
  });
}
