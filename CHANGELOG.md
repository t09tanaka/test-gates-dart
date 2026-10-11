# Changelog

## 0.1.1 (2026-10-11)

Documentation only; the commands behave as in 0.1.0.

- The outputs and paths shown in the README are those of the package in
  `example/`, which now has two gates, a candidate and an allowed equivalent
  mutant.

## 0.1.0 (2026-10-11)

First version. The Dart port of
[`@t09tanaka/test-gates`](https://github.com/t09tanaka/test-gates) 0.3.2: the
same `test-gates.json`, with the same keys and the same rules for reading it.
Unknown keys are rejected in the same places. The built-in defaults are those
of Dart (`settings.gateExtensions`: `[".dart"]`, the test of a gate, the
impure imports).

- The command line is the interface. The library
  (`package:test_gates/test_gates.dart`) has that command line as a function
  and nothing else: `runAsync`, `Io` and `packageVersion`. What is under
  `lib/src/` is not part of the interface.
- `test_gates lcov [--file <lcov.info>]`: every gate must be at 100% line
  coverage and 100% branch coverage. A gate without a record, a gate without
  an instrumented line, a tracefile collected without `--branch-coverage`, and
  a tracefile with an unreadable entry or an unclosed last record fail.
- The JSON Schema ships in the package (`schema/test-gates.schema.json`).
- `test_gates mutation [--force] [--report <path>] [-- <command>]`: mutation
  test of the gates. The mutants are made from the syntax tree
  (`package:analyzer`), each is put in the gate, and the test of the gate is
  run on it (`flutter test --no-pub` for a Flutter package, `dart test`
  otherwise, with `--fail-fast --timeout 10s`). The statuses are `Killed`,
  `Survived`, `Timeout` and `CompileError`.
  - Mutators, named as in Stryker where it has the same one:
    `ArithmeticOperator`, `EqualityOperator`, `LogicalOperator` (with `??`),
    `ConditionalExpression`, `BooleanLiteral`, `UnaryOperator`,
    `UpdateOperator`, `AssignmentOperator`, `BlockStatement`, `RemoveCall`,
    `StringLiteral`, `ArrayDeclaration`. No mutator can be switched off and no
    comment hides a mutant.
  - Mutants that the syntax shows cannot compile are not made. The others
    that do not compile are counted as `CompileError` and shown in the
    summary (`not evaluable`); they do not fail the run.
  - The limits are fixed: a test gets 10 seconds, the test run of a mutant
    three times the run without a mutant plus 20 seconds (only this one is a
    `Timeout`), the run without a mutant 10 minutes.
  - A gate whose source, tests, test command and tool version are those of
    the last run is not run again (`.dart_tool/test_gates/mutation/`), except
    for its timeouts. Files the gate imports are not looked at: `--force` runs
    everything, and is what CI should use.
  - The gates are changed in place, one mutant at a time, by renaming a
    complete file over the gate, and put back after every test run, on an
    error and on SIGINT / SIGTERM / SIGHUP. What a killed run leaves is put
    back by the next run from a backup; a file that was edited in between is
    never overwritten.
  - `--gate <path>` (may be given more than once) runs and judges only
    that gate, for working on one gate and for one CI job per gate. A path
    that is not a gate is wrong usage. The report keeps what it says about
    the other gates, and so do the results of the last run, with `--force`
    as well. The last line says how many gates were judged.
    `mutation-result --gate <path>` judges the same gates of a report.
- `test_gates mutation-result [--report <path>]`: judges a report in the
  mutation-testing-elements (Stryker) JSON schema with the rules of upstream's
  `mutation-result`: a survivor needs exactly one `equivalentMutants` entry
  (`mutator` + `original` + `replacement`, `occurrence` when ambiguous,
  `reason`), a stale allowance fails, a timeout outside `expectedTimeouts`
  fails above `settings.mutation.maxTimeouts` (default 0), a gate without
  mutants fails.
- `equivalentMutants`, `expectedTimeouts`, `settings.mutation.maxTimeouts` and
  `settings.stryker.reportFile` are those of upstream. The report is written where
  upstream's key says (default `reports/mutation/mutation.json`), so that one
  `test-gates.json` is accepted by both tools.
- A command that is ended (by a signal, or by the time limit of a mutant) is
  ended together with the processes that descend from it, found with `ps`.
  This also holds for `test` and `selfcheck`. On Windows, and where there is
  no `ps`, only the command itself is ended.
- `test_gates selfcheck [--all | --first] [-- <command>]`: negative control.
  Appends code that no test executes to every gate, runs the tests with
  coverage once, and requires the tracefile to report that very line as not
  executed and not taken for each gate. The gates are changed in place, only
  by appending, and put back when the run ends, on an error and on SIGINT /
  SIGTERM / SIGHUP; a leftover of a killed run fails `lcov` and is removed by
  the next `selfcheck`.
- `test_gates test [-- <command>]`: runs the tests with coverage and then
  judges the tracefile as `lcov` does. A tracefile of an earlier run is deleted
  first.
- `settings.gateCommand`: the command that runs the tests and
  writes the tracefile, as an array, started without a shell (on
  Windows with one, as `flutter` and `dart` are batch files there).
  `settings.selfcheck.mode` sets the default of `--all` / `--first`.
  `settings.selfcheck.failurePattern`
  is accepted and has no effect.
- `test_gates check`: the static checks of upstream, for Dart. The gates are
  parsed with `package:analyzer` (`>=8.2.0 <15.0.0`), not matched with
  patterns, so an annotation such as `@JsonSerializable()` is not a problem.
  - The list: a gate exists (case-sensitive), has a gate extension, is a
    plain relative path, is not a test or a generated file; candidates exist.
  - The test: `lib/a/b.dart` needs `lib/a/b_test.dart` or
    `test/a/b_test.dart`, exactly one. `settings.spec.suffixes` and
    `settings.spec.rewrite` change that; `"suffixes": []` turns the test
    checks off. The test has no `skip:` / `solo:` / `@Skip` /
    `markTestSkipped()`.
  - Imports, exports and parts: Flutter, `dart:io`, `dart:ui`, `dart:ffi`,
    `dart:isolate`, `dart:mirrors`, the browser libraries, HTTP clients,
    persistence, state management and service SDKs are rejected by default
    (`settings.impureImports`). `part 'x.g.dart'` and `part 'x.freezed.dart'`
    are allowed, any other part is not. `settings.imports.mode: "allowlist"`
    turns the check around.
  - Source: no read of the environment (`Platform.environment`,
    `String.fromEnvironment`, ...; `settings.forbiddenSource`), no coverage
    ignore comment, no syntax error.
  - Dart only: no two blocks start on the same line. They would share one
    branch entry in lcov, and the untested one would not be reported.
- `settings.impureImports`, `impureNamedImports`, `impurePaths`,
  `forbiddenSource`, `importAliases` and `imports` are read, with
  defaults for Dart. The keys are those of upstream.
  `settings.spec` has a default for Dart as well (see above).
