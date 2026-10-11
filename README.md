# test_gates

[![CI](https://github.com/t09tanaka/test-gates-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/t09tanaka/test-gates-dart/actions/workflows/ci.yml)

Test gates for the Dart and Flutter code that must not be wrong.

A handful of files decide things where a mistake costs money or trust: amounts and rounding, the states of a payment, who may do what, when something expires. This package keeps the list of those files in one place, `test-gates.json`, and requires more of them than of the rest of the code. Each listed file is a _gate_.

It is the Dart port of [`@t09tanaka/test-gates`](https://github.com/t09tanaka/test-gates) (npm). The file name, the keys and the rules for reading it are the same (the built-in defaults are those of Dart, see [Relation to `@t09tanaka/test-gates`](#relation-to-t09tanakatest-gates)), so a repository with a TypeScript backend and a Flutter app uses one format.

| Command                      | What it does                                                                |
| ---------------------------- | --------------------------------------------------------------------------- |
| `test_gates check`           | Static checks: a gate exists, has its test, and is a pure module (analyzer) |
| `test_gates lcov`            | Every gate at 100% line coverage and 100% branch coverage                   |
| `test_gates test`            | Runs the tests with coverage, then `lcov`. One command for a pre-push hook  |
| `test_gates selfcheck`       | Negative control: with unexecuted code in it, a gate must fail              |
| `test_gates mutation`        | Mutation test of the gates, with a per-mutant allow list                    |
| `test_gates mutation-result` | Judges an existing mutation report (Stryker JSON schema)                    |

100% coverage is only the floor. It proves that a test runs the code, not that the test checks the decision, and Dart's coverage is thin: an `if` without `else`, `a ? b : c`, `&&`, `||` and `??` tested on one side only are all 100% (see [Limitations](#limitations)). `mutation` closes that gap: it changes the gate, one small change at a time, and requires that a test notices.

There is no overall threshold. The requirement is per gate, and it is 100%.

## Install

Requires Dart 3.9 or later. The package is pure Dart and does not depend on the Flutter SDK; it works in Flutter apps and in plain Dart packages.

As a development dependency of the package that has the gates:

```bash
dart pub add --dev test_gates     # or: flutter pub add --dev test_gates
dart run test_gates --help
```

```yaml
dev_dependencies:
  test_gates: ^0.1.1
```

Or once per machine, outside of any package:

```bash
dart pub global activate test_gates
test_gates --help                 # needs ~/.pub-cache/bin on PATH
```

The development dependency is the one to prefer: the version is in `pubspec.lock`, so everybody and CI run the same one. `test_gates` depends on `package:analyzer` with a wide range (`>=8.2.0 <15.0.0`) so that it resolves next to the code generators of an app. When it does not, the global activation is the way out: it has dependencies of its own.

## Quick start

1. Write `test-gates.json` next to `pubspec.yaml`, with the one or two files that must not be wrong.

   For a Flutter app:

   ```json
   {
     "gates": [
       {
         "path": "lib/shipping_fee.dart",
         "decides": "The fee for sending a parcel, by weight, and its maximum",
         "impact": "A heavy parcel is sent for too little, or the customer pays more than the advertised maximum"
       }
     ],
     "settings": {
       "lcov": { "file": "coverage/lcov.info" },
       "gateCommand": ["flutter", "test", "--coverage", "--branch-coverage"]
     }
   }
   ```

   For a package without Flutter, the same file with another command:

   ```json
   "gateCommand": ["dart", "test", "--coverage-path=coverage/lcov.info", "--branch-coverage"]
   ```

   (`dart test` has these two options from `package:test` 1.27.0 on.)

2. Run the four checks. Each one says what is missing, as `file:line: reason`.

   ```bash
   dart run test_gates check       # the list, the test of each gate, pure modules
   dart run test_gates test        # the tests with coverage: 100% lines and branches per gate
   dart run test_gates selfcheck   # can the gate fail at all?
   dart run test_gates mutation    # do the tests check the decisions?
   ```

   The test of `lib/shipping_fee.dart` is expected at `lib/shipping_fee_test.dart` or `test/shipping_fee_test.dart` ([`check`](#test_gates-check)). The first `mutation` usually finds survivors; see [Allowing an equivalent mutant](#allowing-an-equivalent-mutant) before allowing any.

3. Keep it that way. Before a push (`.git/hooks/pre-push`, or the hook manager of the project):

   ```sh
   #!/bin/sh
   set -e
   dart run test_gates check
   dart run test_gates test
   dart run test_gates mutation
   ```

   `mutation` runs nothing for a gate that did not change. In CI, where the full run counts:

   ```bash
   dart run test_gates check
   dart run test_gates test
   dart run test_gates selfcheck
   dart run test_gates mutation --force
   ```

## `test-gates.json`

One file per package, next to `pubspec.yaml`:

```json
{
  "gates": [
    {
      "path": "lib/shipping_fee.dart",
      "decides": "The fee for sending a parcel, by weight, and its maximum",
      "impact": "A heavy parcel is sent for too little, or the customer pays more than the advertised maximum"
    }
  ],
  "candidates": [
    {
      "path": "lib/pages/order_page.dart",
      "decides": "When an order may be sent",
      "blocker": "Mixed with navigation. The decision has to be extracted first"
    }
  ],
  "settings": {
    "lcov": {
      "file": "coverage/lcov.info",
      "summaryExclude": ["\\.g\\.dart$", "lib/l10n/"]
    },
    "gateCommand": ["flutter", "test", "--coverage", "--branch-coverage"]
  }
}
```

- `gates`: the files that hold an important decision. `path`, `decides` (what the file decides) and `impact` (what goes wrong for users when it is wrong) are required.
- `candidates`: important logic that cannot be a gate yet, with what blocks it. `path`, `decides` and `blocker` are required and the path has to exist; nothing is required of the code.
- `settings`: optional, see below.

Problems are reported in two ways, as upstream does:

- The file cannot be used at all: not JSON, `gates` missing, **an unknown top-level key, or an unknown key anywhere in `settings`**. Exit code 2. A typo in a setting must not silently fall back to a default.
- An entry is wrong: a missing `decides`, a path listed twice, a path in both lists, a malformed `equivalentMutants` entry. Reported as a violation, exit code 1.

### Settings

| Setting                 | Default     | Purpose                                                                      |
| ----------------------- | ----------- | ---------------------------------------------------------------------------- |
| `lcov.file`             | none        | Tracefile for `test_gates lcov` when `--file` is not given                   |
| `lcov.summaryExclude`   | none        | Regular expressions; matching paths are left out of the reference total      |
| `gateCommand`           | none        | The command that runs the tests and writes the tracefile, as an array. Used by `test` and `selfcheck` |
| `selfcheck.mode`        | `all`       | `all`: `selfcheck` puts a probe in every gate. `first`: only in the first    |
| `gateExtensions`        | `[".dart"]` | Extensions a gate may have                                                   |
| `spec.suffixes`         | `_test<ext>` of the gate | Replaces the gate's extension to form the path of its test. `[]` means no spec convention (the test checks are skipped) |
| `spec.rewrite`          | not set     | `[{ "from", "to" }]` applied to the gate path first. Not set: the test may be next to the gate or under `test/`, see [`check`](#test_gates-check) |
| `impureImports.defaults` | `true`     | Built-in list, see [What a gate must not import](#what-a-gate-must-not-import) |
| `impureImports.add`     | none        | More URI patterns a gate must not import, export or have as a part           |
| `impureImports.allow`   | none        | URI patterns exempt from every `impureImports` rule and from the part rule (`^package:flutter/foundation\\.dart$`) |
| `impureNamedImports`    | none        | `{ "add": [{ "module", "names", "reason" }] }`: names banned from a library that is otherwise fine (`Random` from `dart:math`) |
| `impurePaths`           | `*.g.dart`, `*.freezed.dart` | `{ "defaults", "add" }`: gate paths that are rejected (`^lib/pages/`) |
| `forbiddenSource`       | reads of the environment | `{ "defaults", "add" }`: `add` lists patterns tested against one line at a time; `defaults: false` turns the built-in rules off |
| `importAliases`         | `package:<name>/` → `lib/` | `[{ "prefix", "target" }]`: more URI prefixes that point into the package (allowlist mode) |
| `imports.mode`          | `blocklist` | `allowlist` turns the import check around, see [Allowlist mode](#allowlist-mode) |
| `imports.allow`         | none        | Libraries a gate may import in allowlist mode: `"package:decimal"`, `{ "pattern": "^package:acme_" }`, `{ "module": "package:intl/intl.dart", "names": ["NumberFormat"] }` |
| `mutation.maxTimeouts`  | `0`         | Timeouts tolerated outside `expectedTimeouts`, see [Timeouts](#timeouts)     |
| `stryker.reportFile`    | `reports/mutation/mutation.json` | Where `mutation` writes its report and `mutation-result` reads it. The key is upstream's, so that both tools accept the same file |

`gateCommand` is started without a shell, so nothing in it is expanded or split: one array item is one argument. (Windows is the exception: `flutter` and `dart` are batch files there, so a shell starts them.) For a package without Flutter it is `["dart", "test", "--coverage-path=coverage/lcov.info", "--branch-coverage"]`. Upstream uses the same key for the command whose exit code is the verdict (`jest --config jest.gates.config.js`). Here the command only has to pass and write the tracefile named by `lcov.file`; the verdict comes from the tracefile. It must not call `test_gates lcov` itself.

Every other key of upstream (`selfcheck.failurePattern`, `stryker.configFile`) is accepted and validated with upstream's rules, and has no effect. A `test-gates.json` written for `npx test-gates lcov` is read as it is.

Regular expressions are Dart's, which follow the JavaScript syntax. Where a rule has `flags`, `i`, `m`, `s`, `u` are honoured, `g` is accepted, and any other flag is an error.

### JSON Schema

The schema is in the package, `schema/test-gates.schema.json`, because a Flutter repository has no `node_modules` to point at. The tool never reads `$schema`; the key is for editors. Any string is accepted, including a path to upstream's schema.

## `test_gates check`

```bash
dart run test_gates check
```

Static checks, before the tests run. Every violation is reported as `file:line: reason`. Nothing of the project is executed or resolved: the files are parsed with [`package:analyzer`](https://pub.dev/packages/analyzer), so a comment, a string or an annotation such as `@JsonSerializable()` is not mistaken for something else.

The list:

- Every gate exists. **The check is case-sensitive** even on macOS and Windows, because CI on Linux is.
- A gate has one of `settings.gateExtensions`, is written relative to the package with `/` and without `..`, is not itself a test, and is not matched by `settings.impurePaths` (built in: `*.g.dart` and `*.freezed.dart`; other generated files go into `add`).
- No path is listed twice, or in both `gates` and `candidates`. Candidates exist (a candidate may be a directory).
- `equivalentMutants` / `expectedTimeouts` entries are well formed and each has a `reason`.

The test of a gate:

- Every gate has its test. For `lib/a/b.dart` that is `lib/a/b_test.dart` (next to the gate) or `test/a/b_test.dart` (the mirror under `test/`). **Exactly one must exist**: the cases that check a gate belong in one file, the one `mutation` runs.
- `settings.spec.suffixes` replaces `_test.dart`. `settings.spec.rewrite` replaces the two directories with the one it rewrites to: `[{ "from": "^lib/", "to": "test/" }]` accepts the mirror only, `[]` accepts only the test next to the gate.
- `"spec": { "suffixes": [] }` says the project has no convention; the checks of this group are skipped.
- The test has no `skip:` or `solo:` argument (other than `false` / `null`), no `@Skip`, no `markTestSkipped()`, and no coverage ignore comment.

A gate is a pure module:

- It does not import, export or have as a part anything in [What a gate must not import](#what-a-gate-must-not-import). The URIs of a conditional import are all checked.
- `part 'x.g.dart'` and `part 'x.freezed.dart'` are allowed (the output of json_serializable, freezed and other generators; the same files that cannot be gates themselves). Any other part is rejected: it is code of the gate in a file that is neither checked nor measured under the gate's path. A gate that is itself `part of` another library is rejected too, because its imports are in that library.
- It does not read the environment: `Platform.environment`, `String.fromEnvironment`, `bool.fromEnvironment`, `int.fromEnvironment`, `bool.hasEnvironment`. What comes from the environment is an input: take it as an argument.
- It has no coverage ignore comment (`// coverage:ignore-line`, `ignore-start`, `ignore-end`, `ignore-file`).
- It can be parsed. A syntax error is a violation, not a reason to skip the file.
- **No two blocks start on the same line.** Dart keys a branch entry by the line a block starts on, so `if (a) { return 1; } else { return 2; }` on one line is a single entry that is taken as soon as one side runs ([Limitations](#limitations)). `dart format` puts blocks on lines of their own; what it leaves on one line is nested control flow without braces (`if (a) if (b) return 1;`, `for (final x in xs) if (x > 0) n += x;`), and that needs braces.

Annotations are not checked. Upstream rejects decorators because of what they do to branch coverage under Jest; `@JsonSerializable()`, `@immutable` and `@override` have no such effect in Dart.

The outputs on this page are those of the package in [`example/`](example), which has two gates. This is `check` after three changes to it (`import 'dart:io';` in one gate, a constant read with `String.fromEnvironment` in the other, and the test of that one renamed):

```
test_gates check: 3 violation(s)
  - lib/bulk_discount.dart:23: reads String.fromEnvironment (not a pure module). Take the value as an argument
  - lib/bulk_discount.dart: test not found (looked for lib/bulk_discount_test.dart, test/bulk_discount_test.dart; the check is case-sensitive)
  - lib/shipping_fee.dart:1: import of "dart:io" (file system / network / process access)
```

Violations go to stderr. When nothing is wrong: `test_gates check: OK (2 gate(s), 1 candidate(s))`.

| Exit code | Meaning                                                             |
| --------- | ------------------------------------------------------------------- |
| 0         | Nothing to report                                                   |
| 1         | Violations found                                                    |
| 2         | Wrong usage, or `test-gates.json` is missing, broken or has an unknown key |

### What a gate must not import

Built in (`settings.impureImports.defaults`). The patterns are tested against the URI as it is written in the gate.

| What                         | URIs                                                                                              |
| ---------------------------- | ------------------------------------------------------------------------------------------------- |
| Flutter framework and engine | `package:flutter/*`, `dart:ui`, `dart:ui_web`                                                      |
| Flutter plugins and UI packages | every `package:flutter_*` (`flutter_bloc`, `flutter_riverpod`, `flutter_secure_storage`, `flutter_stripe`, `flutter_svg`, `flutter_test`, …) and every `package:*_flutter` (`hive_flutter`, `sentry_flutter`, …) |
| File system, network, process | `dart:io`, `dart:ffi`, `dart:isolate`, `dart:mirrors`                                             |
| Browser                      | `dart:html`, `dart:indexed_db`, `dart:svg`, `dart:web_audio`, `dart:web_gl`, `dart:js`, `dart:js_*` (`js_interop`, `js_util`, …), `package:web`, `package:js` |
| HTTP clients                 | `package:http`, `dio`, `retrofit`, `chopper`, `graphql`, `grpc`, `web_socket_channel`              |
| Persistence                  | `package:shared_preferences`, `sqflite`, `hive`, `hive_ce`, `isar`, `drift`, `sembast`, `objectbox`, `path_provider` |
| Database clients             | `package:sqlite3`, `postgres`, `mysql1`, `mysql_client`, `mongo_dart`, `redis`                     |
| State management             | `package:bloc`, `provider`, `riverpod`, `hooks_riverpod`, `riverpod_annotation`, `get`, `get_it`, `mobx`, `redux`, `rxdart` |
| External service SDKs        | `package:firebase_*`, `cloud_firestore`, `cloud_functions`, `sentry`                               |

Not on the list, on purpose: `package:json_annotation`, `package:meta` and `package:collection` (annotations and pure data structures), and the rest of the SDK (`dart:core`, `dart:async`, `dart:collection`, `dart:convert`, `dart:math`, `dart:typed_data`, `dart:developer`).

The files of the project are not judged by where they are: `import 'package:shop/state/basket.dart'` passes unless a rule says otherwise. Project-specific layers go into `add`, and a library that is on the list but harmless for one project into `allow` (which exempts from these patterns only, not from `impureNamedImports` or allowlist mode):

```json
{
  "settings": {
    "impureImports": {
      "add": [
        { "pattern": "^package:shop/(state|pages)/", "reason": "state or UI layer" },
        { "pattern": "_repository\\.dart$", "reason": "talks to the API" }
      ],
      "allow": ["^package:flutter/foundation\\.dart$"]
    },
    "impurePaths": {
      "add": [{ "pattern": "^lib/(pages|widgets)/", "reason": "UI" }]
    },
    "forbiddenSource": {
      "add": [{ "pattern": "\\bDateTime\\.now\\(", "reason": "reads the clock. Take the time as an argument" }]
    }
  }
}
```

A pattern of `add` sees the URI, not the file it resolves to: `^package:shop/state/` does not match `../state/basket.dart`. Write the pattern for the spelling the project uses, or use allowlist mode, which resolves the URI.

Dart has no `import type`. An import that is only used for a type (`Dio` as a parameter type) is reported like any other; a file that names `Dio` is not a pure module in the sense of this check, and `allow` is there for the exception.

### Allowlist mode

The default import check is a blocklist: it knows the libraries listed above, and a new SDK passes until somebody adds it. `settings.imports.mode: "allowlist"` turns it around. A gate may then import only

- the files of its own package: a relative URI, `package:<name>/…` (`name` of `pubspec.yaml`), or a prefix of `settings.importAliases`,
- `dart:core`, `dart:async`, `dart:collection`, `dart:convert`, `dart:math`, `dart:typed_data`, `package:collection`, `package:json_annotation`, `package:meta`,
- what `settings.imports.allow` lists.

```json
{
  "settings": {
    "imports": {
      "mode": "allowlist",
      "allow": ["package:decimal", { "module": "package:intl/intl.dart", "names": ["NumberFormat"] }]
    }
  }
}
```

- A string is a library and what is below it: `"package:decimal"` covers `package:decimal/decimal.dart`; `"dart:developer"` is that library.
- `{ "pattern" }` is a regular expression tested against the whole URI.
- `{ "module", "names" }` allows only those names, and only with `show`: `import 'package:intl/intl.dart' show NumberFormat;` passes, the same import without `show` does not. An entry with `names` for a built-in library (`dart:math`) narrows it.

The blocklist stays in force underneath, and a file of the package is not safe just because it is in the package: in allowlist mode an import is also rejected when the file it points at matches `settings.impurePaths` (a generated file, or what the project added: a page, a widget).

What it does not do: follow the imports. Only the gate's own directives are read. If `zones.dart` is imported and itself imports `dart:io`, that is not noticed unless `zones.dart` is a gate too.

## `test_gates lcov [--file <lcov.info>]`

```bash
flutter test --coverage --branch-coverage
dart run test_gates lcov
```

For a package without Flutter:

```bash
dart test --coverage-path=coverage/lcov.info --branch-coverage
dart run test_gates lcov
```

`--dir <package>` names the directory that holds `test-gates.json` (default: the current directory). `--file` is relative to it and wins over `settings.lcov.file`.

For every gate:

- **Lines:** every `DA:` entry of the gate has been executed.
- **Branches:** every `BRDA:` entry of the gate has been taken.
- A gate **without a record** in the tracefile fails. Dart writes no record for a file that no test loads.
- A gate **without an instrumented line** fails.
- A gate whose file does not exist fails. The check is case-sensitive on every platform, because CI on Linux is.
- **A tracefile without any `BRDA:` entry fails.** Dart writes one for the entry of every function, so their absence means the coverage was collected without `--branch-coverage`. Requiring 100% of nothing would pass every gate.

Lines are counted from the `DA:` entries and branches from the `BRDA:` entries, not from the totals, which can be edited out of step. `LF:` / `LH:` are only used for a record that has no `DA:` entry at all; Dart writes no `BRF:` / `BRH:`. A `DA:` / `BRDA:` entry that cannot be read, or a last record without `end_of_record` (a truncated file), fails the run: the entry that is missing could be the one that was not covered. When a file has several records (merged tracefiles), a line or a branch counts if any record hit it.

`flutter test` writes paths relative to the package (`SF:lib/shipping_fee.dart`); `dart test` writes absolute paths. Both are matched against the `path` of the gate.

With the test of the maximum fee taken out of the example, the block that sets it is never executed:

```
reference: overall line coverage 100.00% (16/16, not gated)
  ✓ lib/bulk_discount.dart: 10/10 lines, 5/5 branches
  ✗ lib/shipping_fee.dart: 6/6 lines, 2/3 branches
test_gates lcov: 1 violation(s)
  - lib/shipping_fee.dart:14: 2/3 branches taken (not taken, at lines: 14)
```

The first line is for reference only: the line coverage of everything in the tracefile, gate or not. Violations go to stderr as `file:line: message`.

| Exit code | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| 0         | Every gate passed                                                          |
| 1         | Violations found, or the tracefile cannot be read                          |
| 2         | Wrong usage, no tracefile named, or `test-gates.json` is missing, broken or has an unknown key |

## `test_gates test [-- <command>]`

Runs `settings.gateCommand` and then judges the tracefile exactly as `lcov` does. This is the one command to call from a pre-push hook or from CI:

```bash
dart run test_gates test
```

- The tracefile of an earlier run is deleted first. A command that writes none is not judged on old numbers.
- The output of the command goes to the terminal as it is.
- When the command fails (a failing test), the exit code is 1 and the coverage is not judged.
- A command after `--` replaces `settings.gateCommand` for this run: `dart run test_gates test -- flutter test --coverage --branch-coverage test/pricing`. `--file` works as for `lcov`.

| Exit code | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| 0         | The command passed and every gate is at 100%                               |
| 1         | The command failed or could not be started, or `lcov` found violations     |
| 2         | Wrong usage, no command or no tracefile named, or an unusable `test-gates.json` |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the command was ended       |

## `test_gates selfcheck [--all | --first] [-- <command>]`

Negative control: is the gate able to fail? A gate can be green for the wrong reason: the tracefile is one of another build, the coverage command leaves the directory of the gate out, `--branch-coverage` was dropped, or the path in `test-gates.json` no longer matches what the tracefile calls the file. `selfcheck` finds out by making every gate wrong on purpose.

```bash
dart run test_gates selfcheck
```

```
running "dart test --coverage-path=coverage/lcov.info --branch-coverage" with a probe in 2 gate(s)
  ✓ lib/bulk_discount.dart: with unexecuted code at line 23 the gate fails
  ✓ lib/shipping_fee.dart: with unexecuted code at line 20 the gate fails
test_gates selfcheck: OK (2 negative control(s) failed as they should)
```

What it does:

1. Appends a **probe** to every gate: a comment and one top-level function that nothing calls.

   ```dart
   // test_gates selfcheck probe 0. Never executed. Removed when the run ends; delete these two lines if they are left behind.
   int testGatesSelfcheckProbe5f0c9a1e() => 0;
   ```

2. Runs `settings.gateCommand` **once**, with all probes in place. The time is that of one test run, whatever the number of gates (on a Flutter app with about 550 tests and 8 gates it took about as long as the tests on their own, a little over half a minute).
3. Requires for each gate that the tracefile reports **the line of the probe** as a line that was not executed and as a branch that was not taken, and that the `lcov` judgement fails the gate. A gate that is red for another reason proves nothing, so "the gate failed" alone is not accepted.
4. Takes the probes out again and puts back the tracefile that was there before the run (or deletes the one of the run): it counts the probes and would fail the next `test_gates lcov`.

A control does not hold, and the exit code is 1, when:

- the gate has no record in the tracefile (no test loads the file),
- the probe is not reported as unexecuted (the tracefile does not measure the file as it is on disk),
- the probe is reported as a line but not as a branch (no `--branch-coverage`),
- the command fails with the probes in place, cannot be started, or writes no tracefile. Nothing was measured then, and the last lines of the output are printed.

`--all` (default) checks every gate, `--first` only the first; `settings.selfcheck.mode` sets the default. With one run for all gates `--first` saves no time; it exists because upstream has it. A command after `--` replaces `settings.gateCommand`, and `--file` names the tracefile.

| Exit code | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| 0         | Every negative control held                                                |
| 1         | A control did not hold, nothing was measured, a probe could not be removed, or an entry of `test-gates.json` is wrong |
| 2         | Wrong usage, no command or no tracefile named, or an unusable `test-gates.json` |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the gates were put back     |

### Your files during the run

`selfcheck` changes the gates **in place** and for the length of one test run. Do not edit a gate, commit, or switch branches while it runs.

- The probe is only ever **appended**. The bytes of the file are not written again, so there is no moment at which the original content is not on disk. Removing the probe cuts the file back to its old length: the file is the same byte for byte, line ends and a missing final line break included.
- The probes are removed when the run ends, when the command fails, when the tool itself throws, and on **Ctrl-C (SIGINT), SIGTERM and SIGHUP** (the terminal was closed): the command is ended first, then the gates and the tracefile are put back, then the tool exits with 130 / 143 / 129. The command is ended together with the processes that descend from it (found with `ps`; on Windows, and where there is no `ps`, only the command itself).
- A run that is killed outright (SIGKILL, power loss) cannot clean up. The next `selfcheck` removes what is left from the gates listed in `test-gates.json` before it does anything else, and until then the leftover makes the gate **fail** on the next coverage run, never pass: the probe is unexecuted code in a gate. It is also two lines at the end of the file that `git diff` shows.
- When a gate is saved by somebody else during the run, the change is kept and only the probe at its end is removed; the run fails and says so.

A copy of the package in a temporary directory would leave the working tree alone, and was tried on a Flutter app. It was not chosen: `flutter test` in the copy resolved the dependencies again (`pub get`, which needs the network or a complete cache), relative `path:` dependencies and pub workspaces point outside the copy, and what to leave out of the copy is different in every project (`build/` and `.dart_tool/` of that app alone were more than 2 GB). A control that fails for such a reason says nothing about the gates.

The end of the file is a valid place in every Dart file: after all directives, so a library with `part 'shipping_fee.g.dart';` is fine, and inside a `part of` file. The function is named after the path of the gate, so two gates that are parts of one library do not collide.

### What it does not show

Upstream's `selfcheck` leaves out the test of one gate and runs the gate again, once per gate. That also catches a gate whose coverage is held up by the test of another file. This `selfcheck` does not: it shows that the measurement reaches every gate and that the judgement reads it, not which test does the covering. That each gate has a test of its own is checked by [`check`](#test_gates-check), and that this test checks the decisions of the gate by [`mutation`](#test_gates-mutation---force---report-path----command), which runs only that test.

## `test_gates mutation [--force] [--report <path>] [-- <command>]`

Mutation test of the gates. For each gate the tool makes **mutants** (the gate with one small change: `+` → `-`, a condition → `true`, a block emptied) and runs the test of the gate on each. A mutant that the tests notice is _killed_. One that passes them _survived_: the gate decides something there that no test checks.

```bash
dart run test_gates mutation
```

```
  lib/bulk_discount.dart: 29 of 29 mutant(s) with "dart test --fail-fast --timeout 10s test/bulk_discount_test.dart"
  lib/bulk_discount.dart: 29 mutants / killed 28 / survived 0 / timeout 0 / compile error 1 (26.6s)
  lib/shipping_fee.dart: 15 of 15 mutant(s) with "dart test --fail-fast --timeout 10s test/shipping_fee_test.dart"
  lib/shipping_fee.dart: 15 mutants / killed 13 / survived 1 / timeout 0 / compile error 1 (12.7s)
test_gates mutation: OK (mutants 44 / detected 41 (timeout 0) / allowed equivalent 1 / not evaluable 2 / unallowed survivors 0)
```

What it does, gate by gate:

1. Finds the test of the gate the way [`check`](#test_gates-check) does: `lib/a/b.dart` → `lib/a/b_test.dart` and `test/a/b_test.dart` (`settings.spec`). Every one that exists is run. A gate without a test fails; with `"suffixes": []` there is nothing to run, so every gate fails.
2. Parses the gate with `package:analyzer` and makes the mutants from the syntax tree (see [Mutators](#mutators)). A comment or a string that holds an operator is never changed, and no mutant is a syntax error.
3. Runs the tests once without a mutant. They must pass, within 10 minutes; otherwise nothing is measured for this gate and it fails.
4. Puts each mutant in the file, runs the tests, and takes it out again. Only the tests of the gate are run, so the time for one mutant is that of starting the test runner on one file.
5. Writes the report (`settings.stryker.reportFile`, default `reports/mutation/mutation.json`; `--report <path>` for another place) and judges it as [`mutation-result`](#test_gates-mutation-result---report-path) does. A report of an earlier run is deleted first, so a run that writes none cannot pass on old results.

The test command is `flutter test --no-pub` when the pubspec has a dependency from the Flutter SDK (run `flutter pub get` first), and `dart test` otherwise. A command after `--` replaces it (`-- fvm flutter test --no-pub`); `--fail-fast --timeout 10s` and the test files are appended to it, so it has to be a `dart test` / `flutter test` of some kind. It is started without a shell, like `gateCommand`.

| Status of a mutant | When                                                                    |
| ------------------ | ----------------------------------------------------------------------- |
| `Killed`           | The test run failed                                                     |
| `Survived`         | The test run passed                                                     |
| `Timeout`          | The test run did not end within its limit, see [Timeouts](#timeouts)    |
| `CompileError`     | The mutant does not compile (the output has the compiler's `file.dart:12:3: Error:` or `Compilation failed`). Nothing was evaluated |

| Exit code | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| 0         | Every mutant is detected, allowed as equivalent, or does not compile       |
| 1         | A survivor without an allowance, a timeout nobody explained, a stale allowance, a gate that could not be mutation tested, a wrong entry of `test-gates.json`, or the run had to stop |
| 2         | Wrong usage, or an unusable `test-gates.json`                              |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the gates were put back     |

### Mutators

The names are Stryker's where Stryker has the same mutator. They are part of the key of an allowance.

| Mutator                 | Change                                                                                  |
| ----------------------- | --------------------------------------------------------------------------------------- |
| `ArithmeticOperator`    | `+` ↔ `-`, `*` ↔ `/`, `%` → `*`, `~/` → `*`                                              |
| `EqualityOperator`      | `<` → `<=`, `>=`; `<=` → `<`, `>`; `>` → `>=`, `<=`; `>=` → `>`, `<`; `==` ↔ `!=`        |
| `LogicalOperator`       | `&&` ↔ `\|\|`; `a ?? b` → `b`                                                            |
| `ConditionalExpression` | The condition of `if`, `? :` and a collection `if` → `true` and `false`; of `while`, `do` and `for` → `false` only |
| `BooleanLiteral`        | `true` ↔ `false`; `!a` → `a`                                                             |
| `UnaryOperator`         | `-a` → `a`                                                                               |
| `UpdateOperator`        | `++` ↔ `--`                                                                              |
| `AssignmentOperator`    | `+=` ↔ `-=`, `*=` ↔ `/=`, `%=` → `*=`, `~/=` → `*=`, `??=` → `=`                         |
| `BlockStatement`        | `{ … }` → `{}`                                                                           |
| `RemoveCall`            | A call whose result is not used (`save(x);`, `await sync();`) → `;`. Not in Stryker      |
| `StringLiteral`         | `'text'` → `''`, `''` → `'mutated'`, a string with `${…}` → `''`                         |
| `ArrayDeclaration`      | `[a, b]` → `[]`                                                                          |

Left alone: annotations, `import` / `export` / `part` / `library` directives, `assert`, and a block that holds assertions only. `if (x case …)` is not given a condition mutant.

There is no way to switch a mutator off, and no comment that hides a mutant (upstream rejects Stryker's `excludedMutations` and `// Stryker disable` for the same reason). A mutant that cannot be observed is allowed one by one, with a reason, in `test-gates.json`.

**Mutants that cannot compile.** Dart is null-safe and statically typed, so many textbook mutants are not programs. The ones the syntax gives away are not made:

- The emptied body of a function that has to return a value (`int f() { return 1; }` → `{}`), and the emptied last block on one of its paths (`if (a) { return 1; } else { return 2; }` as its last statement). A function without a declared return type counts as returning a value when it has a `return <value>`.
- An arithmetic operator next to a string literal (`'a' + b`, `s += 'x'`). Between two `String` variables nothing in the syntax says so: `s += t` gets `-=`, a compile error.
- The same change twice: a condition that is a literal (`while (true)`) is left to `BooleanLiteral`, and a call that is the only statement of a block to `BlockStatement`.
- The one mutant that is equivalent by construction: an emptied block that only says `return;` or `return null;` at the end of a function.
- A condition that tests for `null` or with `is` is not replaced by `true` / `false` but by `(c) || true` / `(c) && false`: `if (x != null) { x.y }` → `if (true) { x.y }` loses the type promotion, `if ((x != null) && false) { x.y }` keeps it.

What is left is found by compiling: nothing is resolved here, so `*` → `/` on two `int`s (the result is a `double`), a flipped null test before code that relies on it, or `if ((x == null) || true) return;` before a use of `x` are made, fail to compile in about a second, and are counted as `CompileError`. They do not fail the run and they are not a detection either: the summary shows them as `not evaluable`, so that a gate whose mutants mostly do not compile is visible. Measured: about one mutant in ten in two Flutter apps, and 279 of 2284 on the 15 gates of this package. Nearly all of them are null tests.

### Timeouts

Two limits, both fixed:

- **A test gets 10 seconds** (`--timeout 10s`, where the test runner's default is 30). A mutant that makes a test wait for something that never comes (a stream that no longer emits) fails that test: `Killed`. With `--fail-fast` the run ends at the first failing test.
- **The test run of one mutant gets three times the duration of the run without a mutant, plus 20 seconds.** Only a mutant that keeps the process from ending gets this far: a loop that never yields, so that no timer can fire. It is ended together with the processes it started (found with `ps`; on Windows, and where there is no `ps`, only the test runner itself is ended), and is a `Timeout`.

They are not settings. A limit that depends on the machine is what makes a timeout appear on one run and not on the next, and upstream changed its default once on a guess and had to take it back (0.3.1 → 0.3.2). A test of a gate that needs more than 10 seconds fails the run without a mutant; a gate is a pure module, and its test should not.

A `Timeout` counts as detected, but an unexplained one fails the run. The rules are upstream's:

- `expectedTimeouts` (per gate): mutants that can never finish. Same key as `equivalentMutants` (`mutator` + `original` + `replacement`, `occurrence` when ambiguous, `reason` required). An entry whose mutant survived, or does not exist, fails the run. Any other status is accepted, `Killed` included: which of the two limits fires first can depend on the load.
- `settings.mutation.maxTimeouts`: how many timeouts outside `expectedTimeouts` are tolerated, default `0`.

A `Timeout` is never taken from the last run: it is measured again every time.

### Results of the last run, and `--force`

The first run tests every mutant. After that a gate is run again only when something that decides its result changed:

- the gate,
- its test files (which ones, and their content),
- the test command,
- the version of this package, or of its mutators.

The results are kept in `.dart_tool/test_gates/mutation/incremental.json` (`.dart_tool` is ignored by git in every Dart project; `flutter clean` removes it, and the next run is a full one). The judgement is always made again, on the current `test-gates.json`, so removing an allowance fails the next run without anything being tested.

**A file that the gate imports is not part of this.** When `lib/order_total.dart` is unchanged and `lib/shipping_fee.dart`, which it calls, changed, the results of `order_total.dart` are reused as they are. The same goes for a helper that the test imports, for `pubspec.lock`, and for the SDK. `--force` tests everything:

- **pre-push: `test_gates mutation`.** Nothing is run when no gate changed, apart from the mutants that timed out.
- **CI, and before a release: `test_gates mutation --force`.** CI has no results to start from anyway, and the full run is the one that counts.

### One gate at a time: `--gate`

`--gate <path>` limits the run to one gate: only its mutants are made and run, and only that gate is judged. The option may be given more than once, and goes together with `--force`.

```bash
dart run test_gates mutation --gate lib/shipping_fee.dart
dart run test_gates mutation --force --gate lib/shipping_fee.dart --gate lib/bulk_discount.dart
```

```
test_gates mutation: OK for 1 of 2 gate(s) (--gate) (mutants 15 / detected 13 (timeout 0) / allowed equivalent 1 / not evaluable 1 / unallowed survivors 0)
```

- The path is the one in `test-gates.json`, as it is written there. A path that is not a gate is wrong usage (exit code 2): a typo must not become a run that tests nothing.
- For the gates it names, the run fails for the same reasons as a full run: a survivor, a stale allowance, a timeout nobody explained, a gate without a test. Nothing is said about the mutants, the tests or the allowances of the other gates. (A wrong entry of `test-gates.json` still stops every run, whichever gate it is in: the file is one, and it is checked before anything is run.) **The last line says how many gates were judged**; `OK for 1 of 2 gate(s)` is not a pass of the project.
- `settings.mutation.maxTimeouts` is counted within the run, so with a value above `0` several runs can each stay below a limit that the full run would exceed.
- The report keeps what it says about the other gates, and gets the new result of the named ones. After a full run and a `--gate` run it is still a report of all gates. Before the first mutant is tried, the old result of the named gates is taken out of it, so a run that is stopped does not leave it behind.
- The results of the last run of the other gates stay where they are, with `--force` as well: `--force --gate a` runs every mutant of `a` again and forgets nothing about `b`.
- `mutation-result --gate <path>` judges the same gates of an existing report.

It is for two things: working on one gate (the survivors of that gate, without the minutes of the others), and CI, where each gate can be a job of its own. A matrix made from `test-gates.json` cannot forget a gate that is added later:

```yaml
jobs:
  gates:
    runs-on: ubuntu-latest
    outputs:
      paths: ${{ steps.list.outputs.paths }}
    steps:
      - uses: actions/checkout@v4
      - id: list
        run: echo "paths=$(jq -c '[.gates[].path]' test-gates.json)" >> "$GITHUB_OUTPUT"

  mutation-gate:
    needs: gates
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        gate: ${{ fromJSON(needs.gates.outputs.paths) }}
    steps:
      - uses: actions/checkout@v4
      - uses: dart-lang/setup-dart@v1
      - run: dart pub get
      - run: dart run test_gates mutation --force --gate "$GATE"
        env:
          GATE: ${{ matrix.gate }}

  mutation:
    # The one check to require: green only when every gate was.
    needs: mutation-gate
    if: always()
    runs-on: ubuntu-latest
    steps:
      - run: test "$RESULT" = success
        env:
          RESULT: ${{ needs.mutation-gate.result }}
```

(For a Flutter package: the Flutter setup action and `flutter pub get` in place of the two Dart steps.)

**Before a push, and before a release, run without `--gate`.** Only the full run says that every gate passes, and only it notices a gate that no job was started for.

### Your files during the run

`mutation` changes the gates **in place**, one mutant at a time, one gate at a time. Do not edit a gate, commit, or switch branches while it runs.

- Before the first mutant goes into a gate, the gate is copied to `.dart_tool/test_gates/mutation/backup/<path>`. Every mutant, and the original after it, is put in place by writing a file next to the backups and renaming it over the gate, so the gate is never half-written. The bytes are put back as they were (line ends, a byte order mark).
- The mutant is taken out after every test run, when the tool itself throws, and on **Ctrl-C (SIGINT), SIGTERM and SIGHUP** (Windows delivers only the first): the test run is ended first, with the processes it started, then the gate is put back, then the tool exits with 130 / 143 / 129 and writes no report.
- A run that is killed outright (SIGKILL, power loss) leaves one mutant in one gate. The next `mutation` puts the gate back from the backup before it does anything else, and says so. Until then `git diff` shows the mutant, and the tests of the gate most likely fail.
- A file is only put back when it is exactly what the run left: the original with one of its mutants. When a gate is saved by somebody else during the run, or edited after a run was killed, it is left as it is, the run stops with exit code 1, and the message names the backup.
- Putting a file in place by renaming keeps its bytes, not its mode or its hard links. A gate that is a symbolic link is changed where it points to, which has to be on the same file system as the package. A gate that is not valid UTF-8 is not touched.
- Run one `mutation` at a time in a package. A second one takes the mutant of the first for a leftover and puts the gate back.

There is no copy of the package in a temporary directory, for the reasons given for [`selfcheck`](#your-files-during-the-run), and the mutants are run one after the other: two test runs on one working tree would each see the other's mutant.

### How long it takes

Measured with Flutter 3.47.2 / Dart 3.13.2 on a Mac Studio, one run at a time:

| Package                                          | Gates | Mutants   | Full run (`--force`) | Run again, nothing changed |
| ------------------------------------------------ | ----- | --------- | -------------------- | -------------------------- |
| A Flutter app with about 550 tests               | 8     | about 330 | about 12 minutes     | about 1 minute (the timeouts are measured again) |
| Two utility files of another Flutter app         | 2     | about 120 | about 4 minutes      | not measured               |
| This package (`dart test`), its own gates        | 15    | 2284      | 38 min (62 min on a GitHub-hosted runner; 14 min as one job per gate) | 1 min 52 s (the 4 timeouts are measured again) |

The two apps were run twice with `--force`; the statuses of every mutant were the same both times. Neither had been mutation tested before, so many of their mutants survived. This package is its own gate ([Development](#the-gates-of-this-package)): of its 2284 mutants 2001 are killed, 4 time out and 279 do not compile; nothing survives, and the four timeouts are in `expectedTimeouts`. In the first app the gates take between a few seconds and more than four minutes; half of the mutants take less than two seconds, and a few take about ten (a test that waits, or a timeout).

The time is the number of mutants times the time to start the test runner on the test of the gate (between one and two and a half seconds for `flutter test` on one file, with the build of an earlier run in place), plus what the slow mutants add: a test that waits (10 seconds each) and a timeout. Mutants that do not compile cost about one second.

## `test_gates mutation-result [--report <path>]`

Judges an existing report without running anything: the report of the last `mutation`, or one of another tool in the mutation-testing-elements (Stryker) JSON schema. `--gate <path>` (may be given more than once) judges only those gates of it, see [`--gate`](#one-gate-at-a-time---gate). The rules are those of upstream's `mutation-result`, ported with its test cases.

| Status in the report                | Treated as                                                          |
| ----------------------------------- | ------------------------------------------------------------------- |
| `Killed`, `Timeout`                 | Detected                                                            |
| `Survived`, `NoCoverage`            | Survivor. Must match exactly one allowance, otherwise the run fails |
| `CompileError`, `RuntimeError`      | Not evaluable. Counted and shown, does not fail the run             |
| `Ignored`, `Pending`, anything else | Failure. A mutant that was not evaluated proves nothing             |

The run also fails when

- an allowance matches no surviving mutant of this run (stale: the mutant is now killed, or the code changed),
- an allowance matches several mutants and has no `occurrence`,
- two allowances point at the same mutant, or an allowance has no `reason`,
- a gate is missing from the report or has no mutants, or no mutant was evaluated at all,
- the report was made from a different version of a gate than the one on disk,
- a mutant timed out outside `expectedTimeouts`, and there are more of them than `settings.mutation.maxTimeouts` allows.

On failure every unallowed survivor is listed as `file:line:column / mutator / original → replacement / occurrence`, followed by a JSON fragment that can be pasted into `equivalentMutants`. The last line gives the real numbers, never a percentage. The example, without the allowance it has for this mutant:

```
test_gates mutation: 1 surviving mutant(s) not in the allow list
  - lib/shipping_fee.dart:14:11 / EqualityOperator / > → >= (Survived)

Fix the test so that it detects the mutant. Only when the mutant cannot be observed from
outside (same return value, exception and side effects for every input), add it to
"equivalentMutants" of the gate in test-gates.json and fill in "reason":

  lib/shipping_fee.dart
    {"mutator":"EqualityOperator","original":">","replacement":">=","reason":""}

test_gates mutation: FAILED (mutants 44 / detected 41 (timeout 0) / allowed equivalent 0 / not evaluable 2 / unallowed survivors 1)
```

### Allowing an equivalent mutant

An equivalent mutant changes the code without changing anything observable: same return value, same exception, same side effects, for every input. Only those may be allowed, in `test-gates.json`, with the reason.

The example has one. `lib/shipping_fee.dart` limits the fee:

```dart
  if (fee > maxFeeCents) {
    fee = maxFeeCents;
  }
```

With `>=` the only input that is treated differently is a fee equal to the maximum, and that fee is set to the value it already has. No test can tell the two apart, so the gate lists the mutant:

```json
{
  "path": "lib/shipping_fee.dart",
  "decides": "…",
  "impact": "…",
  "equivalentMutants": [
    {
      "mutator": "EqualityOperator",
      "original": ">",
      "replacement": ">=",
      "reason": "A fee that is equal to the maximum is set to the maximum, which is the value it has"
    }
  ]
}
```

- The key is `mutator` + `original` + `replacement`. `original` is the source text at the location in the report. Whitespace differences are ignored. **Line numbers are not part of the key**, so moving code does not break an allowance, and an allowance never covers a different mutant on the same line.
- When the same key occurs more than once in a file, `occurrence` (1-based, in source order) is required.
- A comment inside the mutated text is part of `original`; the fragment the tool prints has it.
- An error message or a label is not equivalent just because no test reads it. If it matters, assert it.
- If in doubt, write the test.

## Limitations

What Dart reports as a "branch" is not what Istanbul or gcov report. It is a **block**: `BRDA:<line>,0,0,<hits>`, one entry per line on which a block starts. The rules above are defined on the real output, measured with Flutter 3.47.2 / Dart 3.13.2 on one file with one function per construct, each called with one input only. The source and the tracefiles are in [`test/fixtures/lcov`](test/fixtures/lcov) and the findings are tests in [`test/lcov_test.dart`](test/lcov_test.dart).

Recorded, so an untested side fails the gate:

| Construct                                | What is recorded                                                |
| ---------------------------------------- | --------------------------------------------------------------- |
| Function, method, getter, constructor    | Its entry. `0` when never called                                |
| `if` / `else`                            | The then-block and the else-block, each with its own entry (for `else if`, see below) |
| `if (x) return y;` (no braces)           | The statement after the condition                               |
| `switch` statement and `switch` expression | Every `case` / arm, `default` / `_` included                  |
| `for`, `while`, `for … in`               | The body. `0` when the loop never ran                           |
| `try` / `catch`                          | Both blocks                                                     |

A block that was not executed is written with hits `0`, not left out.

**Not recorded, so the gate passes at 100% although one side was never tested:**

- **An `if` without `else` that is never skipped.** Only the then-block has an entry. `if (a) { x = 1; }` tested with `a == true` only is 100%. The same for an early return that is always taken, and for a loop whose body always runs: "the condition was false" has no entry.
- **`a ? b : c`, `a && b`, `a || b`, `a ?? b`, `a?.b`.** None of them is a block. The line they are on has a `DA:` entry only when it contains a call, and that entry is `0` only when no call on the line ran (`a ?? fallback()` with `a` never null). `a ? 1 : 2` tested on one side is 100%.
- **Default parameter values.** Never passing or always passing the argument makes no difference.
- **Several blocks on one line share one entry.** `if (a) { return 1; } else { return 2; }` written on one line is a single `BRDA:` whose hits are those of its blocks added up, so it is taken as soon as one of them runs. When the function is written on that line too, calling it is enough. `dart format` puts blocks on lines of their own, and `test_gates check` rejects a gate that has two on one line. Three cases stay on one line in formatted code and are **not** rejected:
  - **`else if`.** `} else if (b) {` starts two blocks, the `else` and the `then` inside it. Once `a` has been false, the entry is taken, whether or not `b` was ever true. Measured with Dart 3.13.2: `if (a) {…} else if (b) {…} else {…}` called with both false gives hits `1` on the `else if` line although its block never ran. The lines inside the block still have their own `DA:` entries when they contain a call.
  - **`if` / `else` inside a collection literal** (`[if (a) 1 else 2]`).
  - **A closure** (`xs.map((x) => x * 2)` on the line of an `if`, or of its function).

**Line coverage is thinner than it looks.** Dart instruments a line only when it contains a call (operators such as `+` and `==` are calls) or starts a function. `return 1;`, `x = 1;`, `const` and field declarations have no `DA:` entry. That is why a gate needs the branch entries as well, and why the two together are still only a floor.

Limits of `mutation`:

- **Only the test of the gate is run.** A decision that is checked in another test file survives. Measured on one model class whose cases are spread over two test files: about five times as many survivors with its own test alone as with both. Move the cases into the test of the gate; `check` asks for exactly one test per gate for the same reason.
- **The mutants are made from the syntax, without types.** Mutants that do not compile are made and counted (see [Mutators](#mutators)), and one kind that could compile is not made: the body of a function without a declared return type is not emptied when it has a `return <value>`.
- **A mutant that does not compile is not a detection and not a failure.** A gate whose mutants all fail to compile passes; the `not evaluable` number in the summary is where to look.
- **Results of the last run do not see what the gate imports** (see [Results of the last run](#results-of-the-last-run-and---force)). Use `--force` where it counts.
- **One mutant at a time.** There is no parallel run and no copy of the working tree. What can be split is the list of gates, over several machines: [`--gate`](#one-gate-at-a-time---gate).
- **`flutter test` and `dart test` only.** The options `--fail-fast` and `--timeout` are theirs.
- **Logging is mutated like everything else.** A removed `log('fee capped');` survives unless a test reads the log; allow it with a reason.
- **Stryker has mutators this tool does not**: `OptionalChaining` (`a?.b` → `a.b` does not compile under null safety), `ObjectLiteral`, `MethodExpression`, `Regex`, `ArrowFunction`. The body of `=> expression` functions is mutated through the expression only.

Other limits:

- **`dart test --coverage=<dir>` followed by `format_coverage --lcov`** gives the same records as `--coverage-path` (compared byte for byte once, on the same source as the fixtures; that output is not kept as a fixture). Both need `--branch-coverage` on the `dart test` side; `format_coverage` has no such option of its own.
- **Only Flutter 3.47.2 / Dart 3.13.2 were measured.** Which lines carry a block is decided by the Dart VM and may change between SDK versions. A gate that passes on one SDK and fails on another points at such a change.
- **The clock and random numbers are not checked** (`DateTime.now()`, `Random()`), by `lcov` or by `check`: a default argument such as `now ?? DateTime.now()` is a legitimate way to pass them in, and the syntax cannot tell it from a direct read. Add a `forbiddenSource` rule, or `impureNamedImports` for `Random`, if the project wants one.
- **`check` reads the syntax, not the meaning.** Nothing is resolved, so the environment is found by name: `Platform.environment` and `String.fromEnvironment` are reported, a class of the project called `Platform` with an `environment` member is reported too, and a read through another name (`final env = Platform.environment` in another file) is not. A record field named `skip` in a test is taken for the argument.
- **`check` does not follow imports**, and `impureImports` patterns see the URI as written (see [What a gate must not import](#what-a-gate-must-not-import)).
- **A pattern of `forbiddenSource.add` is tested against the text of a line**, as upstream does, so it matches in a comment too. The built-in rules do not. Coverage ignore comments are found in the text of the line as well, because that is how the coverage tool finds them: one inside a string literal is honoured by the tool, and reported here.
- **`check` parses with the newest language version its `analyzer` knows.** The range is wide (`>=8.2.0 <15.0.0`) so that it resolves next to the code generators of an app; an app that pins an old `analyzer` and uses newer syntax in a gate gets a syntax error from `check`.
- **Tests are not checked for mocking the gate.** Upstream rejects `jest.mock` of the module under test; Dart has no module mock.
- **The tool does not judge what belongs in `gates`.** Whether every important decision has been extracted and listed is for people to review; `candidates` is where the known gaps are written down.

## Relation to `@t09tanaka/test-gates`

| | npm `@t09tanaka/test-gates` | Dart `test_gates` |
| --- | --- | --- |
| File | `test-gates.json` | the same file, the same keys |
| Unknown keys | rejected (exit code 2) | rejected in the same places |
| Default `gateExtensions` | `.ts .mts .cts .js .mjs .cjs` | `.dart` |
| `lcov` | lines only (`LH == LF` from `DA:`) | lines **and branches** |
| `lcov` output | passing gates listed with `✓` | the same, plus `✗` lines with the numbers of failing gates |
| `check` | text and regular expressions; rejects decorators | syntax tree (`package:analyzer`); annotations are fine, blocks sharing a line are rejected |
| Where the test of a gate is | `.spec<ext>` / `.test<ext>` next to the gate | `_test<ext>` next to the gate or under `test/` |
| Built-in impure imports | Node.js, NestJS, React, Vue, database clients, SDKs | Flutter, `dart:io` / `dart:ui` / browser, HTTP, persistence, state management |
| `forbiddenSource` defaults | `'use client'` / `'use server'`, `process.env` | reads of the environment, found in the syntax |
| Tests + coverage in one command | `npm run test:gates` (a script the project writes) | `test_gates test` |
| `gateCommand` | the gate: its exit code is the verdict | runs the tests and writes the tracefile; the verdict comes from the tracefile |
| Negative control (`selfcheck`) | leaves out the test of a gate; one run per gate | appends unexecuted code to the gates; one run for all |
| Mutation testing | `mutation` runs Stryker, `mutation-result` judges its JSON report | `mutation` makes the mutants itself (syntax tree) and runs the tests of each gate; the same report schema, the same judgement and allow list |
| Report file | `settings.stryker.reportFile` | the same key |
| Results of the last run | Stryker's incremental file | `.dart_tool/test_gates/mutation/incremental.json`; `--force` runs everything |
| Safe defaults | 0.3.2 (`mutation.maxTimeouts: 0`, no overall threshold) | the same |

`npx test-gates lcov` works on a Dart package too, and checks lines only. Use this package when the repository has no Node.js, or when branches should count.

## Development

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The decisions live in `lib/src/` as pure functions (text in, verdict out): `manifest.dart`, `settings.dart`, `lcov.dart`, `selfcheck.dart`, `args.dart`, for `check` `dart_source.dart`, `scan.dart`, `import_policy.dart`, `spec_path.dart`, `gate_path.dart`, `pubspec.dart`, `json.dart`, and for `mutation` `mutators.dart` (source in, mutants out), `mutation_run.dart` (the status of a run, the report, what may be reused) and `mutation_result.dart` (the judgement, a port of upstream's `mutation-result.ts` with its test cases). `dart_source.dart` and `mutators.dart` are the only files that touch `package:analyzer`. Reading and writing files, starting processes and printing are in `lib/src/io/` and `lib/src/commands/`.

The tests of `test`, `selfcheck` and `mutation` start processes: stand-ins for the coverage command and for the test runner (`test/fixtures/selfcheck/fake_coverage.dart.txt`, `test/fixtures/mutation/fake_test.dart.txt`) and, in `test/commands/real_coverage_test.dart` and `real_mutation_test.dart`, `dart test` on a small package that is copied to a temporary directory and resolved with `dart pub get --offline`.

### The gates of this package

The pure files above are the gates of this package: [`test-gates.json`](test-gates.json) lists them, with what each decides, and the files that are not gates as `candidates`, with the reason. The tool is run on itself, as upstream is:

```bash
dart run test_gates check             # under a second
dart run test_gates test              # the whole test suite with coverage
dart run test_gates selfcheck         # the same suite once more, with a probe in every gate
dart run test_gates mutation          # only the gates that changed since the last run
dart run test_gates mutation --gate lib/src/lcov.dart   # one gate, while working on it
dart run test_gates mutation --force  # everything, before a release
```

- The test of `lib/src/x.dart` is `test/x_test.dart` (`settings.spec.rewrite`), and `mutation` runs only that file. A case that kills a mutant of `x.dart` belongs there, not in `test/commands/`.
- The import check is in allowlist mode: a gate imports `dart:` libraries of the built-in list, other files of `lib/src/`, and `package:analyzer`. Nothing else.
- A survivor is fixed with a test. `equivalentMutants` is for a mutant that no input can tell apart from the original, with the reason, and is empty at present; code that cannot be reached is deleted, not allowed. `expectedTimeouts` has the mutants that make a loop endless.
- `mutation` changes the gates in place, and the gates are the code that is running. The tool is compiled before the first mutant goes in, so this works; do not start a second `dart run` in the package while it runs.

CI runs `check`, `test` and `selfcheck` on Dart 3.9.0 and on stable (which lines carry a branch entry is decided by the SDK), and `mutation --force` on stable only: the verdict on a mutant does not depend on the SDK, and the run is the long one (about an hour as one job on a GitHub-hosted runner). It is split into one job per gate with [`--gate`](#one-gate-at-a-time---gate); the jobs are made from `test-gates.json`, and the job `Mutation test of the gates` is green when all of them are. Split that way the whole workflow takes 14 minutes, the longest gate (`mutators.dart`) included.

## License

MIT
