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

    // The tool ends with exit code 1 here: mutants survive. How many, and
    // which, is the tool's to decide and may change with its version: what
    // is checked is that the two tools agree, not the numbers. The mutants
    // of the syntax tree are the same in every version, so one of those is
    // looked for by name.
    expect(await cli(['mutation', '--force']), 1);
    final count = RegExp(
      r'^test_gates mutation: (\d+) surviving mutant\(s\) not in the allow '
      r'list$',
    ).firstMatch(err.first);
    expect(count, isNotNull, reason: err.first);
    final survivors = int.parse(count![1]!);
    expect(survivors, greaterThan(0));
    final listed = err.sublist(1, 1 + survivors);
    expect(listed, everyElement(startsWith('  - lib/steps.dart:')));
    expect(
      listed,
      contains(
        '  - lib/steps.dart:4:17 / ConditionalExpression / from < 0 → false '
        '(Survived)',
      ),
    );
    final total = RegExp(
      r'^test_gates mutation: FAILED \(mutants (\d+) / detected (\d+) '
      r'\(timeout 0\) / allowed equivalent 0 / not evaluable (\d+) / '
      r'unallowed survivors (\d+)\)$',
    ).firstMatch(err.last);
    expect(total, isNotNull, reason: err.last);
    final [mutants, detected, notEvaluable, unallowed] = [
      for (var group = 1; group <= 4; group++) int.parse(total![group]!),
    ];
    expect(unallowed, survivors);
    expect(detected + notEvaluable + unallowed, mutants);
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
    expect(printed, hasLength(survivors));
    manifest(printed);

    // Nothing changed for the tool: it takes its results from the last run,
    // and still ends with exit code 1. The verdict is that of the report.
    expect(await cli(['mutation']), 0);
    expect(out, [
      'test_gates mutation: OK (mutants $mutants / detected $detected '
          '(timeout 0) / allowed equivalent $survivors / not evaluable '
          '$notEvaluable / unallowed survivors 0)',
    ]);
    expect(err, isEmpty);
    expect(run(['mutation-result', '--dir', dir.path], io), 0);

    // One entry less: that mutant is back, and no other.
    manifest(printed.sublist(1));
    expect(await cli(['mutation', '--gate', gate, '--', '--jobs', '1']), 1);
    expect(
      err.first,
      'test_gates mutation: 1 surviving mutant(s) not in the allow list',
    );
    expect(err[1], listed.first);
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
