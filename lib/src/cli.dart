import 'dart:io';

import 'args.dart';
import 'commands/check.dart';
import 'commands/lcov.dart';
import 'commands/mutation.dart';
import 'commands/mutation_result.dart';
import 'commands/output.dart';
import 'commands/selfcheck.dart';
import 'commands/test.dart';
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
  mutation [-- <command>]     Mutation test of the gates (or of --gate <path>), then mutation-result
  mutation-result             Judge an existing mutation report (Stryker JSON schema)

Options:
  --dir <package>             Directory that holds test-gates.json (default: .)
  --file <path>               lcov, test, selfcheck: tracefile (default: settings.lcov.file)
  --all | --first             selfcheck: every gate (default) or only the first
  --report <path>             mutation, mutation-result: the report (default: settings.stryker.reportFile)
  --force                     mutation: run every mutant again, also of a gate unchanged since the last run
  --gate <path>               mutation, mutation-result: only this gate (may be given more than once)
  -h, --help                  Show this help
  -v, --version               Show the version

Exit codes: 0 passed, 1 violations found, 2 wrong usage or unusable test-gates.json,
130 / 143 / 129 interrupted by SIGINT / SIGTERM / SIGHUP (test, selfcheck, mutation)
''';

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
          return await runTest(args.dir, args.file, args.rest, io);
        case 'selfcheck':
          return await runSelfcheck(
            args.dir,
            args.file,
            args.mode,
            args.rest,
            io,
          );
        case 'mutation':
          return await runMutation(
            args.dir,
            args.report,
            args.rest,
            io,
            force: args.force,
            only: args.gates,
          );
      }
    }
  } on UsageError catch (error) {
    return _usage(error, io);
  } on ManifestError catch (error) {
    return _unusable(error, io);
  } on FileSystemException catch (error) {
    // A tracefile or a report that cannot be deleted, read or written. The
    // gates have been put back by then.
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
      ),
      'test' || 'selfcheck' || 'mutation' => throw StateError(
        '${args.command} waits for a process: call runAsync',
      ),
      _ => throw UsageError('no command given'),
    };
  } on UsageError catch (error) {
    return _usage(error, io);
  } on ManifestError catch (error) {
    return _unusable(error, io);
  }
}
