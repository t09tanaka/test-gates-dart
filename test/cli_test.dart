import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';
import 'package:test_gates/src/settings.dart';
import 'package:test_gates/src/version.dart';

void main() {
  late List<String> out;
  late List<String> err;

  setUp(() {
    out = [];
    err = [];
  });

  int cli(List<String> argv) => run(argv, Io(out: out.add, err: err.add));

  test('--version prints the version of pubspec.yaml', () {
    expect(cli(['--version']), 0);
    expect(out, [packageVersion]);
    expect(
      File('pubspec.yaml').readAsLinesSync(),
      contains('version: $packageVersion'),
    );
  });

  test('--help prints the usage on stdout', () {
    expect(cli(['--help']), 0);
    expect(out, [help]);
    expect(err, isEmpty);
    expect(cli(['lcov', '-h']), 0);
  });

  test('wrong usage: exit code 2, message and usage on stderr', () {
    expect(cli([]), 2);
    expect(err, ['test_gates: no command given\n', help]);
    err.clear();
    expect(cli(['mutate']), 2);
    expect(err.first, 'test_gates: unknown command: mutate\n');
    expect(out, isEmpty);
  });

  test('the executable sets the exit code', () {
    final result = Process.runSync(Platform.resolvedExecutable, [
      'run',
      'bin/test_gates.dart',
      'lcov',
      '--dir',
      'test/fixtures/manifest',
    ]);
    expect(result.exitCode, 2);
    expect(result.stdout, isEmpty);
    expect(
      result.stderr,
      contains('test_gates: test-gates.json not found in '),
    );

    final version = Process.runSync(Platform.resolvedExecutable, [
      'run',
      'bin/test_gates.dart',
      '-v',
    ]);
    expect(version.exitCode, 0);
    expect(version.stdout, '$packageVersion\n');
  });

  group('the bundled schema', () {
    final schema =
        jsonDecode(File('schema/test-gates.schema.json').readAsStringSync())
            as Map<String, Object?>;
    final definitions = schema['definitions']! as Map<String, Object?>;
    final settings = definitions['settings']! as Map<String, Object?>;
    final properties = settings['properties']! as Map<String, Object?>;

    test('lists exactly the settings the reader accepts', () {
      expect(properties.keys, unorderedEquals(settingsKeys));
    });

    test('documents the default of gateExtensions', () {
      final gateExtensions =
          properties['gateExtensions']! as Map<String, Object?>;
      expect(gateExtensions['default'], defaultGateExtensions);
    });

    test('has the same top-level keys as the reader', () {
      expect((schema['properties']! as Map<String, Object?>).keys, [
        r'$schema',
        'gates',
        'candidates',
        'settings',
      ]);
    });
  });

  group('runAll', () {
    const steps = [
      ['check', '--dir', 'app'],
      ['test', '--selfcheck', '--dir', 'app'],
      ['timezones', '--dir', 'app'],
      ['mutation', '--force', '--dir', 'app'],
    ];
    final io = Io(out: (line) => out.add(line), err: (line) => err.add(line));

    test('every step in order, each once, and a last line that names '
        'them', () async {
      final ran = <List<String>>[];
      expect(
        await runAll(steps, io, (step) async {
          ran.add(step);
          return 0;
        }),
        0,
      );
      expect(ran, steps);
      expect(out, [
        'test_gates all: OK (check, test --selfcheck, timezones, mutation '
            '--force)',
      ]);
      expect(err, isEmpty);
    });

    for (final (failing, code, behind) in [
      (0, 1, '. Not run: test --selfcheck, timezones, mutation --force'),
      (1, 2, '. Not run: timezones, mutation --force'),
      (2, 130, '. Not run: mutation --force'),
      (3, 137, ''),
    ]) {
      test('step ${failing + 1} ends with $code: that is the exit code, and '
          'no step behind it is run', () async {
        final ran = <String>[];
        expect(
          await runAll(steps, io, (step) async {
            ran.add(step.first);
            return ran.length == failing + 1 ? code : 0;
          }),
          code,
        );
        expect(ran, [for (final step in steps.take(failing + 1)) step.first]);
        expect(out, isEmpty);
        final shown = steps[failing]
            .takeWhile((argument) => argument != '--dir')
            .join(' ');
        expect(err, [
          'test_gates all: stopped at "$shown" (exit code $code)$behind',
        ]);
      });
    }

    test('no step: nothing to run', () async {
      expect(await runAll(const [], io, (_) async => 1), 0);
      expect(out, ['test_gates all: OK ()']);
    });

    test('all waits for processes: run alone does not take it', () {
      expect(() => cli(['all']), throwsStateError);
    });
  });
}
