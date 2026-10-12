import 'dart:io';

import 'args.dart';
import 'commands/check.dart';
import 'commands/lcov.dart';
import 'commands/mutation.dart';
import 'commands/mutation_result.dart';
import 'commands/output.dart';
import 'commands/selfcheck.dart';
import 'commands/test.dart';
import 'commands/timezones.dart';
import 'manifest.dart';
import 'version.dart';

const help = '''
test_gates — test gates for the Dart and Flutter code that must not be wrong

Usage: test_gates <command> [options]

Commands:
  lcov [--file <lcov.info>]   Per-file 100% line and branch coverage from an lcov tracefile
  check                       Static checks: the list, the tests, and that every gate is a pure module
  test [-- <command>]         Run the tests with coverage (settings.gateCommand), then lcov
  selfcheck [-- <command>]    Negative control: with unexecuted code in it, a gate must fail
  timezones [-- <command>]    Run the tests of the gates that name DateTime in other time zones
  mutation [-- <options>]     Mutation test of the gates (or of --gate <path>): runs dart_mutant, then mutation-result
  mutation-result             Judge an existing mutation report (mutation-testing-elements JSON schema)
  all                         check, test, timezones and mutation in one start, until the first that fails

Options:
  --dir <package>             Directory that holds test-gates.json (default: .)
  --file <path>               lcov, test, selfcheck: tracefile (default: settings.lcov.file)
  --selfcheck, --force        all: handed to test and to mutation
  --no-mutation               all: leave the mutation test out
  --selfcheck                 test: the same run is also the negative control (selfcheck), with its
                              probes in the gates; one run of the tests in place of two
  --all | --first             selfcheck: every gate (default) or only the first
  --all                       timezones: every gate, also one that does not name DateTime
  --zone <name>               timezones: a time zone to run in (may be given more than once;
                              default: Pacific/Kiritimati and Etc/GMT+12, the two ends)
  --report <path>             mutation, mutation-result: the report (default: settings.stryker.reportFile)
  --force                     mutation: run every mutant again, also of a gate unchanged since the last run
  --gate <path>               mutation, mutation-result: only this gate (may be given more than once)
  --not-evaluable             mutation, mutation-result: list the mutants that could not be evaluated
                              (they do not compile, say), not only their number
  -- <options>                mutation: handed to "dart_mutant run" as they are (--jobs <n>, --shard <i>/<n>,
                              --html <file>, and behind a second "--" the command that runs test files)
  -h, --help                  Show this help
  -v, --version               Show the version

Exit codes: 0 passed, 1 violations found, 2 wrong usage or unusable test-gates.json
(mutation: or dart_mutant is missing or not a supported version),
130 / 143 / 129 interrupted by SIGINT / SIGTERM / SIGHUP (test, selfcheck, timezones, mutation)
''';

/// Runs the checks of `all` ([steps], see `stepsOfAll`) one after the other
/// with [runStep], and stops at the first that does not end with 0. Its
/// exit code is the one of `all`; the checks behind it are not run.
///
/// Nothing is kept from one check for the next: each reads test-gates.json
/// and the files of the package itself, as it does when it is started
/// alone. `test --selfcheck` and `mutation` change files while they run.
Future<int> runAll(
  List<List<String>> steps,
  Io io,
  Future<int> Function(List<String> step) runStep,
) async {
  String shown(List<String> step) =>
      step.takeWhile((argument) => argument != '--dir').join(' ');
  for (final (index, step) in steps.indexed) {
    final code = await runStep(step);
    if (code != 0) {
      final behind = steps.sublist(index + 1).map(shown).toList();
      io.err(
        '$executable all: stopped at "${shown(step)}" (exit code $code)'
        '${behind.isEmpty ? '' : '. Not run: ${behind.join(', ')}'}',
      );
      return code;
    }
  }
  io.out('$executable all: OK (${steps.map(shown).join(', ')})');
  return 0;
}

int _usage(UsageError error, Io io) {
  io.err('$executable: ${error.message}\n');
  io.err(help);
  return 2;
}

int _unusable(ManifestError error, Io io) {
  io.err('$executable: ${error.message}');
  return 2;
}

/// Runs the command line [argv] (without the executable: `['check']`,
/// `['lcov', '--file', 'coverage/lcov.info']`) and completes with the exit
/// code: 0 passed, 1 violations found, 2 wrong usage or an unusable
/// `test-gates.json`, 130 / 143 / 129 interrupted.
///
/// What the command reports is written to [io]. Nothing is thrown for a
/// problem of the project; the exit code and [io] say what is wrong.
///
/// `test`, `selfcheck` and `mutation` start a process and wait for it; the
/// other commands only read files.
Future<int> runAsync(List<String> argv, Io io) async {
  try {
    final args = parseArgs(argv);
    if (!args.version && !args.help) {
      switch (args.command) {
        case 'test':
          return args.selfcheck
              ? await runSelfcheck(
                  args.dir,
                  args.file,
                  null,
                  args.rest,
                  io,
                  coverage: true,
                )
              : await runTest(args.dir, args.file, args.rest, io);
        case 'selfcheck':
          return await runSelfcheck(
            args.dir,
            args.file,
            args.mode,
            args.rest,
            io,
          );
        case 'all':
          return await runAll(
            stepsOfAll(args),
            io,
            (step) => runAsync(step, io),
          );
        case 'timezones':
          return await runTimezones(
            args.dir,
            args.zones,
            args.rest,
            io,
            all: args.mode == 'all',
          );
        case 'mutation':
          return await runMutation(
            args.dir,
            args.report,
            args.rest,
            io,
            force: args.force,
            only: args.gates,
            listNotEvaluable: args.notEvaluable,
          );
      }
    }
  } on UsageError catch (error) {
    return _usage(error, io);
  } on ManifestError catch (error) {
    return _unusable(error, io);
  } on FileSystemException catch (error) {
    // A tracefile, a report or a plan that cannot be deleted, read or
    // written.
    io.err(
      '$executable: ${error.osError?.message ?? error.message}'
      '${error.path == null ? '' : ' (${error.path})'}',
    );
    return 1;
  }
  return run(argv, io);
}

/// Runs the command line and returns the exit code. The commands that wait
/// for a process (`test`, `selfcheck`, `mutation`) are only reachable through
/// [runAsync].
int run(List<String> argv, Io io) {
  try {
    final args = parseArgs(argv);
    if (args.version) {
      io.out(packageVersion);
      return 0;
    }
    if (args.help) {
      io.out(help);
      return 0;
    }
    return switch (args.command) {
      'lcov' => runLcov(args.dir, args.file, io),
      'check' => runCheck(args.dir, io),
      'mutation-result' => runMutationResult(
        args.dir,
        args.report,
        io,
        only: args.gates,
        listNotEvaluable: args.notEvaluable,
      ),
      'test' || 'selfcheck' || 'timezones' || 'mutation' || 'all' =>
        throw StateError('${args.command} waits for a process: call runAsync'),
      _ => throw UsageError('no command given'),
    };
  } on UsageError catch (error) {
    return _usage(error, io);
  } on ManifestError catch (error) {
    return _unusable(error, io);
  }
}
