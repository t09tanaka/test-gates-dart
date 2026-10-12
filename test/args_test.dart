import 'package:test/test.dart';
import 'package:test_gates/src/args.dart';

Matcher usageError(String message) => throwsA(
  isA<UsageError>().having((error) => error.toString(), 'message', message),
);

void main() {
  test('no arguments', () {
    final args = parseArgs([]);
    expect(args.command, isNull);
    expect(
      (args.help, args.version, args.dir, args.file),
      (false, false, '.', null),
    );
  });

  test('lcov with its options, both spellings', () {
    for (final argv in [
      ['lcov', '--dir', 'app', '--file', 'a.info'],
      ['lcov', '--dir=app', '--file=a.info'],
      ['lcov', '--file', 'a.info', '--dir=app'],
    ]) {
      final args = parseArgs(argv);
      expect((args.command, args.dir, args.file), ('lcov', 'app', 'a.info'));
    }
  });

  test('a value may contain "="', () {
    expect(parseArgs(['lcov', '--file=a=b.info']).file, 'a=b.info');
  });

  test('the last value wins', () {
    expect(parseArgs(['lcov', '--file', 'a', '--file', 'b']).file, 'b');
  });

  test('help and version, with or without a command', () {
    expect(parseArgs(['--help']).help, isTrue);
    expect(parseArgs(['-h']).help, isTrue);
    expect(parseArgs(['--version']).version, isTrue);
    expect(parseArgs(['-v']).version, isTrue);
    final args = parseArgs(['lcov', '-h', '-v']);
    expect((args.command, args.help, args.version), ('lcov', true, true));
  });

  test('test and selfcheck take --dir and --file', () {
    for (final command in ['test', 'selfcheck']) {
      final args = parseArgs([command, '--dir=app', '--file', 'a.info']);
      expect((args.command, args.dir, args.file), (command, 'app', 'a.info'));
      expect(args.mode, isNull);
      expect(args.rest, isEmpty);
    }
  });

  test('selfcheck: --all and --first', () {
    expect(parseArgs(['selfcheck', '--all']).mode, 'all');
    expect(parseArgs(['selfcheck', '--first', '--first']).mode, 'first');
    expect(
      () => parseArgs(['selfcheck', '--all', '--first']),
      usageError('--all and --first cannot be combined'),
    );
    expect(
      () => parseArgs(['selfcheck', '--first=1']),
      usageError('--first does not take a value'),
    );
  });

  test('what follows "--" is the command, untouched', () {
    for (final command in ['test', 'selfcheck']) {
      final args = parseArgs([
        command,
        '--dir',
        'app',
        '--',
        'flutter',
        'test',
        '--dir',
        '-h',
        '--',
      ]);
      expect(args.dir, 'app');
      expect(args.help, isFalse);
      expect(args.rest, ['flutter', 'test', '--dir', '-h', '--']);
      expect(
        () => parseArgs([command, '--']),
        usageError('"--" must be followed by the command to run'),
      );
    }
  });

  test('unknown command', () {
    expect(() => parseArgs(['cover']), usageError('unknown command: cover'));
  });

  test('mutation with its options, and what follows "--" for dart_mutant '
      'run, untouched', () {
    final args = parseArgs([
      'mutation',
      '--dir=app',
      '--force',
      '--report',
      'r.json',
      '--',
      '--jobs',
      '3',
      '--',
      'fvm',
      'flutter',
      'test',
    ]);
    expect(
      (args.command, args.dir, args.force, args.report),
      ('mutation', 'app', true, 'r.json'),
    );
    expect(args.rest, ['--jobs', '3', '--', 'fvm', 'flutter', 'test']);
    expect(
      () => parseArgs(['mutation', '--force', '--']),
      usageError('"--" must be followed by the options for dart_mutant run'),
    );
    final plain = parseArgs(['mutation']);
    expect((plain.force, plain.report), (false, null));
    expect(plain.rest, isEmpty);
    expect(
      () => parseArgs(['mutation', '--force=1']),
      usageError('--force does not take a value'),
    );
    expect(
      () => parseArgs(['mutation', '--file', 'x']),
      usageError('unknown argument for mutation: --file'),
    );
  });

  test('--gate: once per gate, for mutation and mutation-result', () {
    expect(parseArgs(['mutation']).gates, isEmpty);
    expect(parseArgs(['mutation', '--gate', 'lib/a.dart']).gates, [
      'lib/a.dart',
    ]);
    final args = parseArgs([
      'mutation',
      '--gate=lib/b.dart',
      '--force',
      '--gate',
      'lib/a.dart',
    ]);
    expect(args.gates, ['lib/b.dart', 'lib/a.dart']);
    expect(args.force, isTrue);
    // Not the report, the directory or the tracefile.
    expect((args.report, args.dir, args.file), (null, '.', null));
    expect(parseArgs(['mutation-result', '--gate', 'lib/a.dart']).gates, [
      'lib/a.dart',
    ]);
    expect(
      () => parseArgs(['mutation', '--gate']),
      usageError('--gate needs a value'),
    );
    for (final command in ['lcov', 'check', 'test', 'selfcheck']) {
      expect(
        () => parseArgs([command, '--gate', 'lib/a.dart']),
        usageError('unknown argument for $command: --gate'),
      );
    }
  });

  test('--not-evaluable, for mutation and mutation-result', () {
    for (final command in ['mutation', 'mutation-result']) {
      expect(parseArgs([command]).notEvaluable, isFalse);
      final args = parseArgs([command, '--not-evaluable', '--dir', 'app']);
      expect((args.notEvaluable, args.dir, args.force), (true, 'app', false));
      expect(args.mode, isNull);
      expect(
        () => parseArgs([command, '--not-evaluable=1']),
        usageError('--not-evaluable does not take a value'),
      );
    }
    expect(parseArgs(['mutation', '--force']).notEvaluable, isFalse);
    expect(
      () => parseArgs(['selfcheck', '--not-evaluable']),
      usageError('unknown argument for selfcheck: --not-evaluable'),
    );
  });

  test('timezones: --zone once per zone, --all, and a command after '
      '"--"', () {
    final plain = parseArgs(['timezones']);
    expect((plain.command, plain.mode), ('timezones', null));
    expect(plain.zones, isEmpty);
    final args = parseArgs([
      'timezones',
      '--zone',
      'UTC',
      '--all',
      '--zone=Asia/Tokyo',
      '--dir',
      'app',
      '--',
      'fvm',
      'flutter',
      'test',
    ]);
    expect(args.zones, ['UTC', 'Asia/Tokyo']);
    expect((args.mode, args.dir), ('all', 'app'));
    expect(args.rest, ['fvm', 'flutter', 'test']);
    expect(args.gates, isEmpty);
    expect(
      () => parseArgs(['timezones', '--zone']),
      usageError('--zone needs a value'),
    );
    expect(
      () => parseArgs(['timezones', '--first']),
      usageError('unknown argument for timezones: --first'),
    );
    expect(
      () => parseArgs(['timezones', '--']),
      usageError('"--" must be followed by the command to run'),
    );
    expect(
      () => parseArgs(['test', '--zone', 'UTC']),
      usageError('unknown argument for test: --zone'),
    );
    expect(parseArgs(['mutation', '--gate', 'a']).zones, isEmpty);
  });

  test('--selfcheck, for test only', () {
    expect(parseArgs(['test']).selfcheck, isFalse);
    final args = parseArgs(['test', '--selfcheck', '--file', 'x.info']);
    expect(
      (args.selfcheck, args.file, args.notEvaluable),
      (true, 'x.info', false),
    );
    expect(args.mode, isNull);
    expect(parseArgs(['mutation', '--not-evaluable']).selfcheck, isFalse);
    expect(
      () => parseArgs(['test', '--selfcheck=1']),
      usageError('--selfcheck does not take a value'),
    );
    expect(
      () => parseArgs(['selfcheck', '--selfcheck']),
      usageError('unknown argument for selfcheck: --selfcheck'),
    );
  });

  test('mutation-result takes --dir and --report', () {
    final args = parseArgs(['mutation-result', '--report=r.json']);
    expect((args.command, args.report), ('mutation-result', 'r.json'));
    expect(parseArgs(['mutation-result', '--dir', 'app']).dir, 'app');
    expect(
      () => parseArgs(['mutation-result', '--force']),
      usageError('unknown argument for mutation-result: --force'),
    );
    expect(
      () => parseArgs(['mutation-result', '--', 'dart', 'test']),
      usageError(
        '"--" is only accepted by the test, selfcheck, timezones and mutation '
        'commands',
      ),
    );
    expect(
      () => parseArgs(['mutation-result', '--report']),
      usageError('--report needs a value'),
    );
  });

  test('a value option needs a value', () {
    expect(
      () => parseArgs(['lcov', '--file']),
      usageError('--file needs a value'),
    );
    expect(
      () => parseArgs(['lcov', '--file=']),
      usageError('--file needs a value'),
    );
    expect(
      () => parseArgs(['lcov', '--dir']),
      usageError('--dir needs a value'),
    );
    expect(
      () => parseArgs(['lcov', '--dir', '']),
      usageError('--dir needs a value'),
    );
  });

  test('unknown arguments', () {
    expect(
      () => parseArgs(['lcov', '--report', 'x']),
      usageError('unknown argument for lcov: --report'),
    );
    expect(
      () => parseArgs(['lcov', 'extra']),
      usageError('unknown argument for lcov: extra'),
    );
    expect(
      () => parseArgs(['lcov', '--', 'dart', 'test']),
      usageError(
        '"--" is only accepted by the test, selfcheck, timezones and mutation '
        'commands',
      ),
    );
    expect(
      () => parseArgs(['test', '--all']),
      usageError('unknown argument for test: --all'),
    );
    expect(
      () => parseArgs(['lcov', '--files=x']),
      usageError('unknown argument for lcov: --files=x'),
    );
  });

  test('options are not accepted without a command', () {
    expect(
      () => parseArgs(['--dir', 'app']),
      usageError('unknown argument: --dir'),
    );
    expect(
      () => parseArgs(['--file=x', 'lcov']),
      usageError('unknown argument: --file=x'),
    );
  });

  test('check takes --dir only', () {
    final args = parseArgs(['check', '--dir', 'app']);
    expect((args.command, args.dir, args.file), ('check', 'app', null));
    expect(
      () => parseArgs(['check', '--file', 'x']),
      usageError('unknown argument for check: --file'),
    );
  });
}
