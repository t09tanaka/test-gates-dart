@Timeout(Duration(minutes: 2))
library;

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';

import 'package_fixture.dart';

const gates = ['lib/a.dart', 'lib/b.dart'];

/// `all`: the checks in one start. What it prints, leaves and ends with is
/// compared with the same checks started one by one, on the same package.
/// (The mutation test is left out here; test/commands/real_mutation_test.dart
/// runs `all` with it, where `dart_mutant` is installed.)
void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    package.write('lib/a.dart', 'int a() => 1;\n');
    package.write('lib/a_test.dart', '');
    package.write('lib/b.dart', 'int b() => 2;\n');
    package.write('lib/b_test.dart', '');
  });

  tearDown(() => package.delete());

  void manifest([String mode = 'honest']) => package.manifest(
    gates,
    settings: {'gateCommand': package.fake(mode, gates)},
  );

  Future<int> run(List<String> arguments) => runAsync([
    arguments.first,
    '--dir',
    package.dir.path,
    ...arguments.skip(1),
  ], package.io);

  String? tracefile() => package.file('coverage/lcov.info').existsSync()
      ? package.read('coverage/lcov.info')
      : null;

  /// The checks of [commands] one by one, until the first that fails, as a
  /// hook with `set -e` runs them.
  Future<({int code, List<String> out, List<String> err, String? tracefile})>
  oneByOne(List<List<String>> commands) async {
    var code = 0;
    for (final command in commands) {
      code = await run(command);
      if (code != 0) {
        break;
      }
    }
    final result = (
      code: code,
      out: [...package.out],
      err: [...package.err],
      tracefile: tracefile(),
    );
    package.out.clear();
    package.err.clear();
    if (package.file('coverage/lcov.info').existsSync()) {
      package.file('coverage/lcov.info').deleteSync();
    }
    return result;
  }

  const three = [
    ['check'],
    ['test'],
    ['timezones'],
  ];

  test('every check passes: the output of each, in order, then one line; '
      'the tracefile is the one test leaves', () async {
    manifest();
    final expected = await oneByOne(three);
    expect(expected.code, 0);

    expect(await run(['all', '--no-mutation']), 0);
    expect(package.out, [
      ...expected.out,
      'test_gates all: OK (check, test, timezones)',
    ]);
    expect(package.err, expected.err);
    expect(tracefile(), expected.tracefile);
  });

  test('--selfcheck: the same as check, test --selfcheck and '
      'timezones', () async {
    manifest();
    final expected = await oneByOne([
      ['check'],
      ['test', '--selfcheck'],
      ['timezones'],
    ]);
    expect(expected.code, 0);

    expect(await run(['all', '--no-mutation', '--selfcheck']), 0);
    expect(package.out, [
      ...expected.out,
      'test_gates all: OK (check, test --selfcheck, timezones)',
    ]);
    expect(tracefile(), expected.tracefile);
    expect(package.read('lib/a.dart'), 'int a() => 1;\n');
  });

  test('check fails: its output and exit code, and the tests are not '
      'run', () async {
    package.write('lib/a.dart', "import 'dart:io';\n\nint a() => 1;\n");
    manifest();
    final expected = await oneByOne(three);
    expect(expected.code, 1);
    expect(expected.tracefile, isNull);

    expect(await run(['all', '--no-mutation']), 1);
    expect(package.out, expected.out);
    expect(package.err, [
      ...expected.err,
      'test_gates all: stopped at "check" (exit code 1). Not run: test, '
          'timezones',
    ]);
    // The coverage command was not started.
    expect(tracefile(), isNull);
  });

  test('test fails: check was run, timezones is not', () async {
    package.write('lib/b.dart', 'int b() => 2;\nint untested() => 3;\n');
    manifest();
    final expected = await oneByOne(three);
    expect(expected.code, 1);
    expect(
      expected.out.first,
      'test_gates check: OK (2 gate(s), 0 candidate(s))',
    );

    expect(await run(['all', '--no-mutation']), 1);
    expect(package.out, expected.out);
    expect(package.err, [
      ...expected.err,
      'test_gates all: stopped at "test" (exit code 1). Not run: timezones',
    ]);
    expect(tracefile(), expected.tracefile);
    expect(
      [
        ...package.out,
        ...package.err,
      ].where((line) => line.contains('timezones:')),
      isEmpty,
    );
  });

  test('the last check fails: nothing is left to run', () async {
    manifest();
    // A gate without a test fails check as well, so the test is taken away
    // from timezones only: the convention that finds it.
    package.manifest(
      gates,
      settings: {
        'gateCommand': package.fake('honest', gates),
        'spec': {'suffixes': <String>[]},
      },
    );
    final expected = await oneByOne(three);
    expect(expected.code, 1);

    expect(await run(['all', '--no-mutation']), 1);
    expect(package.err, [
      ...expected.err,
      'test_gates all: stopped at "timezones" (exit code 1)',
    ]);
  });

  test('an unusable test-gates.json: exit code 2, from the first '
      'check', () async {
    package.write('test-gates.json', '{"gates": [], "sttings": {}}');
    expect(await run(['all']), 2);
    expect(package.err, [
      'test_gates: test-gates.json: unknown top-level key "sttings"',
      'test_gates all: stopped at "check" (exit code 2). Not run: test, '
          'timezones, mutation',
    ]);
  });

  test('wrong usage of all itself: nothing is run', () async {
    manifest();
    expect(await run(['all', '--gate', 'lib/a.dart']), 2);
    expect(package.err.first, 'test_gates: unknown argument for all: --gate\n');
    expect(package.out, isEmpty);
    expect(tracefile(), isNull);
  });
}
