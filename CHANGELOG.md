# Changelog

## 0.2.0 (not yet published)

`test_gates mutation` no longer makes the mutants and runs the tests itself.
It starts [`dart_mutant`](https://pub.dev/packages/dart_mutant) for that, as
the npm package starts Stryker, and judges the report. The README has the
steps under "Upgrading from 0.1".

### Breaking

- `mutation` needs `dart_mutant` 0.1.x (`dart pub global activate
  dart_mutant`; Dart 3.11 or later). It is looked for on `PATH`, then as
  `dart pub global run dart_mutant`. When it is missing, or is not a 0.1.x,
  the exit code is 2 and nothing is run. The other commands run on Dart 3.9
  as before.
- What follows `--` on the command line of `mutation` is handed to
  `dart_mutant run` (`--jobs <n>`, `--shard <i>/<n>`, `--html <file>`). It used to be the command that runs test files; that
  command now goes behind a second `--` (`mutation -- -- fvm flutter test
  --no-pub`), and the old form is refused with exit code 2. `--dir`, `--plan`,
  `--report` and `--only` are refused behind `--`: `mutation` sets them.
  `--help` and `--version` are refused there as well.
- More mutants, so new survivors are to be expected. The twelve mutators of
  0.1 make the same mutants as before, and an `equivalentMutants` or
  `expectedTimeouts` entry written for 0.1 still matches. `dart_mutant` also
  has mutators that use resolved types (`MethodExpression`, `NumberLiteral`,
  `ConstantNumberLiteral`, `GuardAlwaysTaken`, `GuardThrows`,
  `GuardResultSwapped`, `BranchCopied`, `ReturnValue`). A survivor of those
  fails the run like any other until a test detects it or the gate allows it
  with a reason.
- The exit code of `mutation` can be one of `dart_mutant`: 2 when it refused
  its command line, and whatever else it ended with other than 0 and 1 (137
  when the system killed it). Nothing is judged then.
- `mutation-result` refuses the report of a part of a run (`dart_mutant run
  --shard`) as a whole. Such a report has `config.shard`.
- The results of the last run are those of `dart_mutant`
  (`.dart_tool/dart_mutant/`). `.dart_tool/test_gates/mutation/` of 0.1 is no
  longer read and can be deleted; a mutant that a killed run of 0.1 left in a
  gate is not put back by 0.2.0.
- The lines `mutation` printed per gate are now printed by `dart_mutant`, in
  its format, and the report names `dart_mutant` as its `framework`.

- `check` follows the imports of a gate. The imports and exports that point
  into the package are followed, file by file, and what a file on the way
  imports, reads from the environment or matches of
  `settings.forbiddenSource` is a violation of the gate, reported with the
  file, the line and the files in between. A gate that passed because the
  impure import was one file away now fails. A file that is to be left out,
  with what is behind it, goes into `settings.impureImports.allow`. A file
  on the way that cannot be read is a violation as well.
- More packages are impure by default: `go_router`, `auto_route`,
  `cached_network_image`, `google_fonts` (UI); `file`, `process`, `platform`
  (files, processes, the environment); `connectivity_plus`,
  `device_info_plus`, `package_info_plus`, `share_plus`, `battery_plus`,
  `sensors_plus`, `network_info_plus`, `url_launcher`, `permission_handler`,
  `geolocator`, `image_picker`, `file_picker`, `local_auth` (the device);
  `socket_io_client`, `mqtt_client` (network); `get_storage`, `realm`,
  `floor` (persistence); `hydrated_bloc`, `replay_bloc`, `state_notifier`,
  `signals`, `async_redux`, `watch_it`, `stacked` (state management);
  `supabase`, `appwrite`, `googleapis`, `google_sign_in`, `in_app_purchase`
  (services). `settings.impureImports.allow` exempts one.
- A key that an entry of `equivalentMutants` / `expectedTimeouts` does not
  have is a violation (exit code 1), and the entry is not used. A misspelt
  `occurrence` was read as an entry without one.

### Changed

- `mutation` writes the gates and their tests as a plan file
  (`.dart_tool/test_gates/mutation-plan.json`) and starts `dart_mutant run
  --dir <package> --plan <plan> --report <report>`, with `--force` for
  `--force` and `--only <path>` for each `--gate <path>`. The test command is
  the one `dart_mutant` chooses (`flutter test --no-pub` or `dart test`);
  `settings.gateCommand` is not used for it.
- The verdict is that of the report, not of the exit code of `dart_mutant`.
  With 0 or 1 the report is judged as `mutation-result` judges it. A gate
  that is not in the report fails, and so does exit code 1 with a report in
  which no mutant of the gates of the run survived and none is missing.
- Before the tool is started, what an earlier report says about the gates of
  the run is taken out of it, so that a run that writes nothing is not judged
  on old results. A file at that place that is not a mutation report is no
  longer deleted (0.1 deleted it); `dart_mutant` refuses to replace it.
- `mutation -- --shard <i>/<n>` runs a part and does not judge it: exit code
  0 when the part was written with every gate of the run in it. The parts are
  put together with `dart_mutant merge` and judged with `mutation-result`.
- A signal (SIGINT, SIGTERM, SIGHUP) is handed to `dart_mutant` and to every
  process that descends from it, and they are waited for (60 seconds at the
  most) while the tool puts back what it changed.
- With two jobs or more (`dart_mutant` decides; `-- --jobs <n>`), the gates
  are not changed in place: the mutants are put into working copies.
- `lcov`: the parser no longer trims the fields of a `DA:` / `BRDA:` / `LF:`
  / `LH:` entry before it reads them as numbers. Blanks around a number are
  read as before; the calls did nothing.

- A pattern of `settings.forbiddenSource.add` is tested against the code of
  a line. What a comment or a doc comment says no longer matches; the text
  of a string literal still does.
- `mutation --not-evaluable` and `mutation-result --not-evaluable` list the
  mutants that could not be evaluated, with the message of the compiler when
  the report has it. Without the option they are counted, as before.
- When `dart_mutant` is not found, the message says what each command that
  was tried did: that it could not be started, or its exit code and the
  first line it printed.
- When the tool does not end within 60 seconds of a signal and is killed,
  the message says so, and that a gate may still have a mutant in it.

### Removed

- The mutation engine of 0.1: making the mutants, changing the gates in
  place, the test runs, the time limits, the report writer, the file of
  results of the last run and the recovery of a killed run. They are
  `dart_mutant`'s now.

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
