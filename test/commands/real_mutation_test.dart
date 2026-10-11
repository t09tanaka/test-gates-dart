@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';
import 'package:test_gates/src/mutation_result.dart';

/// `mutation` against the real thing: a small package whose tests are run by
/// `dart test`. The source is kept as .txt (test/fixtures/selfcheck/package)
/// so that it is not analyzed or run with this package, and is copied into a
/// temporary directory.
void main() {
  late Directory dir;
  final out = <String>[];
  final err = <String>[];

  const sources = [
    'pubspec.yaml',
    'lib/price.dart',
    'lib/price.g.dart',
    'test/price_test.dart',
  ];

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('test_gates_real_mutation_');
    for (final source in sources) {
      File('${dir.path}/$source')
        ..createSync(recursive: true)
        ..writeAsBytesSync(
          File('test/fixtures/selfcheck/package/$source.txt').readAsBytesSync(),
        );
    }
    // A mutant that only compiles when the type promotion is kept.
    File('${dir.path}/lib/label.dart').writeAsStringSync('''
String label(String? name) {
  if (name == null) {
    return 'nobody';
  }
  return name.trim();
}
''');
    File('${dir.path}/test/label_test.dart').writeAsStringSync('''
import 'package:selfcheck_fixture/label.dart';
import 'package:test/test.dart';

void main() {
  test('label', () {
    expect(label(null), 'nobody');
    expect(label(' a '), 'a');
  });
}
''');
    File('${dir.path}/test-gates.json').writeAsStringSync(
      jsonEncode({
        'gates': [
          for (final path in ['lib/price.dart', 'lib/label.dart'])
            {'path': path, 'decides': 'd', 'impact': 'i'},
        ],
      }),
    );
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('dart test on every mutant of a library with a part: killed, '
      'survived and compile error are told apart', () async {
    final before = [
      for (final source in sources)
        File('${dir.path}/$source').readAsBytesSync(),
    ];
    final code = await runAsync([
      'mutation',
      '--dir',
      dir.path,
      '--',
      Platform.resolvedExecutable,
      'test',
    ], Io(out: out.add, err: err.add));

    final report = parseMutationReport(
      File('${dir.path}/reports/mutation/mutation.json').readAsStringSync(),
    );
    List<String> statuses(String path) {
      final file = report.files[path]!;
      return [
        for (final mutant in file.mutants)
          '${mutant.mutatorName} '
              '${sliceByLocation(file.source!, mutant.start, mutant.end)!.replaceAll(RegExp(r'\s+'), ' ')} → '
              '${mutant.replacement}: ${mutant.status}',
      ];
    }

    expect(statuses('lib/price.dart'), [
      'ConditionalExpression percent == 0 → true: Killed',
      // 0% tax is 0: the early return is a shortcut, not a decision.
      'ConditionalExpression percent == 0 → false: Survived',
      'EqualityOperator == → !=: Killed',
      'BlockStatement { return cents; } → {}: Survived',
      'ArithmeticOperator + → -: Killed',
    ]);
    expect(statuses('lib/label.dart'), [
      // After `if (... || true) return`, and without the test, `name.trim()`
      // is a call on a nullable value: the compiler holds this decision.
      'ConditionalExpression name == null → (name == null) || true: '
          'CompileError',
      'ConditionalExpression name == null → (name == null) && false: '
          'CompileError',
      'EqualityOperator == → !=: CompileError',
      'BlockStatement { return \'nobody\'; } → {}: CompileError',
      "StringLiteral 'nobody' → '': Killed",
    ]);
    expect(code, 1);
    expect(
      err.last,
      'test_gates mutation: FAILED (mutants 10 / detected 4 (timeout 0) / '
      'allowed equivalent 0 / not evaluable 4 / unallowed survivors 2)',
    );
    expect([
      for (final source in sources)
        File('${dir.path}/$source').readAsBytesSync(),
    ], before);
  });
}
