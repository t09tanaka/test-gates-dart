@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';
import 'package:test_gates/src/mutation_run.dart';

/// `mutation` against the real thing: `dart_mutant` as it is installed on
/// this machine, on a small package whose tests are run by `dart test`. The
/// source is kept as .txt (test/fixtures/mutation/package) so that it is not
/// analyzed or run with this package, and is copied into a temporary
/// directory.
///
/// Where the tool is not installed the test is skipped: it needs a newer
/// Dart than this package does. With TEST_GATES_REQUIRE_DART_MUTANT=1 (the
/// workflow of this package sets it where the tool is installed) a missing
/// tool fails the test instead.
void main() {
  late Directory dir;
  final out = <String>[];
  final err = <String>[];
  final io = Io(out: out.add, err: err.add);

  bool installed() {
    for (final command in dartMutantCommands(Platform.resolvedExecutable)) {
      try {
        final result = Process.runSync(command.first, [
          ...command.sublist(1),
          '--version',
        ]);
        final version = dartMutantVersionOf(
          result.exitCode,
          result.stdout as String,
        );
        if (version != null) {
          return true;
        }
      } on ProcessException {
        // The next one.
      }
    }
    return false;
  }

  const required = 'TEST_GATES_REQUIRE_DART_MUTANT';
  const gate = 'lib/steps.dart';

  void manifest([List<Object?> equivalentMutants = const []]) =>
      File('${dir.path}/test-gates.json').writeAsStringSync(
        jsonEncode({
          'gates': [
            {
              'path': gate,
              'decides': 'd',
              'impact': 'i',
              'equivalentMutants': equivalentMutants,
            },
          ],
        }),
      );

  Future<int> cli(List<String> arguments) {
    out.clear();
    err.clear();
    return runAsync([
      arguments.first,
      '--dir',
      dir.path,
      ...arguments.skip(1),
    ], io);
  }

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('test_gates_real_mutation_');
    for (final (from, to) in [
      ('selfcheck/package/pubspec.yaml', 'pubspec.yaml'),
      ('mutation/package/lib/steps.dart', gate),
      ('mutation/package/test/steps_test.dart', 'test/steps_test.dart'),
    ]) {
      File('${dir.path}/$to')
        ..createSync(recursive: true)
        ..writeAsBytesSync(File('test/fixtures/$from.txt').readAsBytesSync());
    }
    manifest();
    // The packages are in the cache: this package depends on `test` too.
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  test('the tool is started, its report is judged, and the entries that are '
      'printed for the survivors allow them when they are pasted', () async {
    if (!installed()) {
      if (Platform.environment[required] == '1') {
        fail('$required is set, and dart_mutant is not installed');
      }
      markTestSkipped('dart_mutant is not installed ($dartMutantInstall)');
      return;
    }
    final source = File('${dir.path}/$gate').readAsBytesSync();

    // The tool ends with exit code 1 here: mutants survive.
    expect(await cli(['mutation', '--force']), 1);
    expect(
      err.first,
      'test_gates mutation: 9 surviving mutant(s) not in the allow list',
    );
    expect(
      err.last,
      'test_gates mutation: FAILED (mutants 14 / detected 5 (timeout 0) / '
      'allowed equivalent 0 / not evaluable 0 / unallowed survivors 9)',
    );
    expect(
      err,
      contains(
        '  - lib/steps.dart:6:24 / MethodExpression / .abs() →  (Survived)',
      ),
    );
    expect(
      err,
      contains(
        '  - lib/steps.dart:5:25 / NumberLiteral / 0 → 1 / occurrence 4 of 4 '
        '(Survived)',
      ),
    );
    expect(File('${dir.path}/$gate').readAsBytesSync(), source);
    expect(
      File('${dir.path}/.dart_tool/test_gates/mutation-plan.json').existsSync(),
      isTrue,
    );

    // What is printed below the path of the gate, with a reason filled in.
    final printed = [
      for (final line in err.skip(err.indexOf('  $gate') + 1))
        if (line.startsWith('    {'))
          (jsonDecode(line.replaceFirst(RegExp(r',$'), ''))
                as Map<String, Object?>)
            ..['reason'] = 'for the test',
    ];
    expect(printed, hasLength(9));
    manifest(printed);

    // Nothing changed for the tool: it takes its results from the last run,
    // and still ends with exit code 1. The verdict is that of the report.
    expect(await cli(['mutation']), 0);
    expect(out, [
      'test_gates mutation: OK (mutants 14 / detected 5 (timeout 0) / '
          'allowed equivalent 9 / not evaluable 0 / unallowed survivors 0)',
    ]);
    expect(err, isEmpty);
    expect(run(['mutation-result', '--dir', dir.path], io), 0);

    // One entry less: that mutant is back.
    manifest(printed.sublist(1));
    expect(await cli(['mutation', '--gate', gate, '--', '--jobs', '1']), 1);
    expect(
      err[1],
      '  - lib/steps.dart:4:17 / ConditionalExpression / from < 0 → false '
      '(Survived)',
    );
    expect(File('${dir.path}/$gate').readAsBytesSync(), source);

    // A part of the run is written and not judged, and is no result.
    manifest(printed);
    expect(
      await cli(['mutation', '--report', 'part.json', '--', '--shard', '1/2']),
      0,
    );
    expect(out.single, contains('a part of a run (--shard) was written'));
    expect(
      run(['mutation-result', '--dir', dir.path, '--report', 'part.json'], io),
      1,
    );
    expect(err, contains(startsWith('  - mutation report: is part 1/2 of')));
  });
}
