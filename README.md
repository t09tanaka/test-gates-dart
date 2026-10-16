# test_gates

[![CI](https://github.com/t09tanaka/test-gates-dart/actions/workflows/ci.yml/badge.svg)](https://github.com/t09tanaka/test-gates-dart/actions/workflows/ci.yml)

Test gates for the Dart and Flutter code that must not be wrong.

A handful of files decide things where a mistake costs money or trust: amounts and rounding, the states of a payment, who may do what, when something expires. This package keeps the list of those files in one place, `test-gates.json`, and requires more of them than of the rest of the code. Each listed file is a _gate_.

It is the Dart port of [`@t09tanaka/test-gates`](https://github.com/t09tanaka/test-gates) (npm). The file name, the keys and the rules for reading it are the same (the built-in defaults are those of Dart, see [Relation to `@t09tanaka/test-gates`](#relation-to-t09tanakatest-gates)), so a repository with a TypeScript backend and a Flutter app uses one format.

| Command                      | What it does                                                                |
| ---------------------------- | --------------------------------------------------------------------------- |
| `test_gates check`           | Static checks: a gate exists, has its test, and is a pure module (analyzer) |
| `test_gates lcov`            | Every gate at 100% line coverage and 100% branch coverage                   |
| `test_gates test`            | Runs the tests with coverage, then `lcov`. With `--selfcheck`, the negative control in the same run |
| `test_gates selfcheck`       | Negative control: with unexecuted code in it, a gate must fail              |
| `test_gates timezones`       | Runs the tests of the gates that name `DateTime` in other time zones        |
| `test_gates mutation`        | Mutation test of the gates: runs `dart_mutant` and judges its report, with a per-mutant allow list |
| `test_gates mutation-result` | Judges an existing mutation report (mutation-testing-elements JSON schema)  |
| `test_gates all`             | `check`, `test`, `timezones` and `mutation` in one start, until the first that fails |

100% coverage is only the floor. It proves that a test runs the code, not that the test checks the decision, and Dart's coverage is thin: an `if` without `else`, `a ? b : c`, `&&`, `||` and `??` tested on one side only are all 100% (see [Limitations](#limitations)). `mutation` closes that gap: the gate is changed, one small change at a time, and a test has to notice each one.

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
  test_gates: ^0.3.0
```

Or once per machine, outside of any package:

```bash
dart pub global activate test_gates
test_gates --help                 # needs ~/.pub-cache/bin on PATH
```

The development dependency is the one to prefer: the version is in `pubspec.lock`, so everybody and CI run the same one. `test_gates` depends on `package:analyzer` with a wide range (`>=8.2.0 <15.0.0`) so that it resolves next to the code generators of an app. When it does not, the global activation is the way out: it has dependencies of its own.

`test_gates mutation` starts [`dart_mutant`](https://pub.dev/packages/dart_mutant). There is nothing to install for it: the first run in a package fetches it from pub.dev (see [Where `dart_mutant` comes from](#where-dart_mutant-comes-from)). It needs Dart 3.11 or later.

Coming from 0.1: [Upgrading from 0.1](#upgrading-from-01).

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

2. Run the checks. Each one says what is missing, as `file:line: reason`.

   ```bash
   dart run test_gates check       # the list, the test of each gate, pure modules
   dart run test_gates test        # the tests with coverage: 100% lines and branches per gate
   dart run test_gates selfcheck   # can the gate fail at all?
   dart run test_gates timezones   # do the tests pass in another time zone?
   dart run test_gates mutation    # do the tests check the decisions?
   ```

   The test of `lib/shipping_fee.dart` is expected at `lib/shipping_fee_test.dart` or `test/shipping_fee_test.dart` ([`check`](#test_gates-check)). `mutation` fetches the tool that runs the mutants by itself, the first time. The first `mutation` usually finds survivors; see [Allowing an equivalent mutant](#allowing-an-equivalent-mutant) before allowing any.

3. Keep it that way. Before a push (`.git/hooks/pre-push`, or the hook manager of the project):

   ```sh
   #!/bin/sh
   exec dart run test_gates all
   ```

   That is `check`, `test`, `timezones` and `mutation`, one after the other in one start of the tool, until the first that fails ([`all`](#test_gates-all---selfcheck---force---no-mutation)). `mutation` runs nothing again for a gate when nothing it depends on changed ([Results of the last run](#results-of-the-last-run-and---force)). In CI, where the full run counts:

   ```bash
   dart run test_gates all --selfcheck --force
   ```

   which is the same as

   ```bash
   dart run test_gates check
   dart run test_gates test --selfcheck   # the coverage and the negative control, in one run of the tests
   dart run test_gates timezones
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
- An entry is wrong: a missing `decides`, a path listed twice, a path in both lists, a malformed `equivalentMutants` entry, **or a key such an entry does not have** (`"occurence"`: without its `occurrence` the entry would point at another mutant). Reported as a violation, exit code 1.

An entry of `gates` or `candidates` may have keys of its own (`"owner"`), as upstream's schema allows; they are not read.

### Settings

| Setting                 | Default     | Purpose                                                                      |
| ----------------------- | ----------- | ---------------------------------------------------------------------------- |
| `lcov.file`             | none        | Tracefile for `test_gates lcov` when `--file` is not given                   |
| `lcov.summaryExclude`   | none        | Regular expressions; matching paths are left out of the reference total      |
| `gateCommand`           | none        | The command that runs the tests and writes the tracefile, as an array. Used by `test` and `selfcheck` |
| `selfcheck.mode`        | `all`       | `all`: `selfcheck` and `test --selfcheck` put a probe in every gate. `first`: only in the first |
| `gateExtensions`        | `[".dart"]` | Extensions a gate may have                                                   |
| `spec.suffixes`         | `_test<ext>` of the gate | Replaces the gate's extension to form the path of its test. `[]` means no spec convention (the test checks are skipped) |
| `spec.rewrite`          | not set     | `[{ "from", "to" }]` applied to the gate path first. Not set: the test may be next to the gate or under `test/`, see [`check`](#test_gates-check) |
| `impureImports.defaults` | `true`     | Built-in list, see [What a gate must not import](#what-a-gate-must-not-import) |
| `impureImports.add`     | none        | More URI patterns a gate must not import, export or have as a part           |
| `impureImports.allow`   | none        | URI patterns exempt from every `impureImports` rule and from the part rule (`^package:flutter/foundation\\.dart$`). A file of the package that one matches is not followed either, see [What a gate reaches](#what-a-gate-reaches) |
| `impureNamedImports`    | none        | `{ "add": [{ "module", "names", "reason" }] }`: names banned from a library that is otherwise fine (`Random` from `dart:math`) |
| `impurePaths`           | `*.g.dart`, `*.freezed.dart` | `{ "defaults", "add" }`: gate paths that are rejected (`^lib/pages/`) |
| `forbiddenSource`       | reads of the environment | `{ "defaults", "add" }`: `add` lists patterns tested against the code of one line at a time (not its comments); `defaults: false` turns the built-in rules off |
| `importAliases`         | `package:<name>/` → `lib/` | `[{ "prefix", "target" }]`: more URI prefixes that point into the package. `check` follows them, and allowlist mode takes them for the package's own files |
| `imports.mode`          | `blocklist` | `allowlist` turns the import check around, see [Allowlist mode](#allowlist-mode) |
| `imports.allow`         | none        | Libraries a gate may import in allowlist mode: `"package:decimal"`, `{ "pattern": "^package:acme_" }`, `{ "module": "package:intl/intl.dart", "names": ["NumberFormat"] }` |
| `mutation.maxTimeouts`  | `0`         | Timeouts tolerated outside `expectedTimeouts`, see [Timeouts](#timeouts)     |
| `stryker.reportFile`    | `reports/mutation/mutation.json` | Where `mutation` has the report written and `mutation-result` reads it. The key is upstream's, so that both tools accept the same file |

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
- **Neither does a file it reaches.** The imports and exports of the gate that point into the package are followed, file by file, and every file on the way is held to the rules of this list that are about what a file brings in and reads: its imports, its reads of the environment, `settings.forbiddenSource`, `settings.impureNamedImports`, and allowlist mode. See [What a gate reaches](#what-a-gate-reaches).
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
| 1         | Violations found, or a file of the package cannot be read           |
| 2         | Wrong usage, or `test-gates.json` is missing, broken or has an unknown key |

### What a gate must not import

Built in (`settings.impureImports.defaults`). The patterns are tested against the URI as it is written in the gate.

| What                         | URIs                                                                                              |
| ---------------------------- | ------------------------------------------------------------------------------------------------- |
| Flutter framework and engine | `package:flutter/*`, `dart:ui`, `dart:ui_web`                                                      |
| Flutter plugins and UI packages | every `package:flutter_*` (`flutter_bloc`, `flutter_riverpod`, `flutter_secure_storage`, `flutter_stripe`, `flutter_svg`, `flutter_test`, …) and every `package:*_flutter` (`hive_flutter`, `sentry_flutter`, …); `go_router`, `auto_route`, `cached_network_image`, `google_fonts` |
| File system, network, process | `dart:io`, `dart:ffi`, `dart:isolate`, `dart:mirrors`; `package:file`, `process`, `platform` |
| Device and platform          | `package:connectivity_plus`, `device_info_plus`, `package_info_plus`, `share_plus`, `battery_plus`, `sensors_plus`, `network_info_plus`, `url_launcher`, `permission_handler`, `geolocator`, `image_picker`, `file_picker`, `local_auth` |
| Browser                      | `dart:html`, `dart:indexed_db`, `dart:svg`, `dart:web_audio`, `dart:web_gl`, `dart:js`, `dart:js_*` (`js_interop`, `js_util`, …), `package:web`, `package:js` |
| HTTP clients                 | `package:http`, `dio`, `retrofit`, `chopper`, `graphql`, `grpc`, `web_socket_channel`, `socket_io_client`, `mqtt_client` |
| Persistence                  | `package:shared_preferences`, `sqflite`, `hive`, `hive_ce`, `isar`, `drift`, `sembast`, `objectbox`, `path_provider`, `get_storage`, `realm`, `floor` |
| Database clients             | `package:sqlite3`, `postgres`, `mysql1`, `mysql_client`, `mongo_dart`, `redis`                     |
| State management             | `package:bloc`, `provider`, `riverpod`, `hooks_riverpod`, `riverpod_annotation`, `get`, `get_it`, `mobx`, `redux`, `rxdart`, `hydrated_bloc`, `replay_bloc`, `state_notifier`, `signals`, `async_redux`, `watch_it`, `stacked` |
| External service SDKs        | `package:firebase_*`, `cloud_firestore`, `cloud_functions`, `sentry`, `supabase`, `appwrite`, `googleapis`, `google_sign_in`, `in_app_purchase` |
| Dart-only packages of the above | `package:realm_dart`, `dart_appwrite`, `googleapis_auth`, `signals_core` |

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

### What a gate reaches

A gate that imports nothing impure itself can still do I/O through a file it imports. So `check` follows the imports:

- **What is followed:** `import` and `export` with a relative URI, `package:<name>/…` (`name` of `pubspec.yaml`) or a prefix of `settings.importAliases`, and in the files on the way also a `part` that no generator wrote. Every URI of a conditional import is followed. Each file is read once, so imports that form a circle end.
- **What is not followed:** another package and the SDK (they are judged by their names, as in the tables above), a generated part (`*.g.dart`, `*.freezed.dart`), an import that is a finding already, and a URI that `settings.impureImports.allow` exempts. That last one is the way to say "this file is fine, and so is what is behind it": `"allow": ["^legacy/clock\\.dart$"]`.
- **What is checked in a file on the way:** what it imports, exports and has as a part, its reads of the environment, the patterns of `settings.forbiddenSource.add`, the names of `settings.impureNamedImports`, and in allowlist mode what it may import. Coverage ignore comments and blocks that share a line are rules about how a gate is measured, and are checked in gates only.
- **The package is the directory of `test-gates.json`.** `package:<name>/` is followed with the `name` of the `pubspec.yaml` next to it (a pubspec whose name is not found is a violation). Without a `pubspec.yaml` no `package:` import can be told from an import of another package: `check` still runs, and says in a note which gates have such imports, or reach a file that has one, that were not followed. A gate in a package below it (`packages/shop/lib/…`, imported as `package:shop/…`) is only followed with an entry in `settings.importAliases`. An import that leaves the package (`../../outside.dart`) is reported as a file that cannot be read.
- **A URI has to be written plainly.** Dart reads `DART:io` as `dart:io` and `package:%68ttp/…` as `package:http/…`, and the rules compare the text. A URI with an upper-case scheme, with `%`, or with `file:` is reported as one that cannot be checked.
- A file that cannot be read (it is not there, or its name is spelt in another case) is a violation: what it brings in cannot be checked. A file a generator writes has to be there when `check` runs, and the message says so: `… reaches lib/rates.g.dart, which cannot be read, so what it brings in cannot be checked. When a generator writes that file, run it before check (lib/fee.dart → lib/rates.g.dart)`.

The finding is reported at the line of the gate's own directive, with the file and line it is in, and the files in between. The example with `import 'limits.dart';` added to a gate, where `lib/limits.dart` says `export 'freight.dart';` and `lib/freight.dart` reads an environment variable through `dart:io`:

```
test_gates check: 2 violation(s)
  - lib/shipping_fee.dart:1: import of "limits.dart" reaches lib/freight.dart:1: import of "dart:io" (file system / network / process access) (lib/shipping_fee.dart → lib/limits.dart → lib/freight.dart)
  - lib/shipping_fee.dart:1: import of "limits.dart" reaches lib/freight.dart:4: reads Platform.environment (not a pure module). Take the value as an argument (lib/shipping_fee.dart → lib/limits.dart → lib/freight.dart)
```

When several ways lead to a file, the shortest is the one that is shown, and a finding is reported once per gate.

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

The files a gate reaches are held to the same list: a file of the package that the gate imports may itself import only what a gate may ([What a gate reaches](#what-a-gate-reaches)).

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

## `test_gates test [--selfcheck] [-- <command>]`

Runs `settings.gateCommand` and then judges the tracefile exactly as `lcov` does:

```bash
dart run test_gates test
```

- The tracefile of an earlier run is deleted first. A command that writes none is not judged on old numbers.
- The output of the command goes to the terminal as it is.
- When the command fails (a failing test), the exit code is 1 and the coverage is not judged.
- A command after `--` replaces `settings.gateCommand` for this run: `dart run test_gates test -- flutter test --coverage --branch-coverage test/pricing`. `--file` works as for `lcov`.

### One run for the coverage and the negative control: `--selfcheck`

`test` and [`selfcheck`](#test_gates-selfcheck---all----first----command) each run the whole test suite with coverage. `test --selfcheck` runs it once and gives both verdicts:

```bash
dart run test_gates test --selfcheck
```

```
running "dart test --coverage-path=coverage/lcov.info --branch-coverage" with a probe in 2 gate(s)
  ✓ lib/bulk_discount.dart: with unexecuted code at line 23 the gate fails
  ✓ lib/shipping_fee.dart: with unexecuted code at line 20 the gate fails
test_gates selfcheck: OK (2 negative control(s) failed as they should)
reference: overall line coverage 100.00% (16/16, not gated)
  ✓ lib/bulk_discount.dart: 10/10 lines, 5/5 branches
  ✓ lib/shipping_fee.dart: 6/6 lines, 3/3 branches
test_gates lcov: OK (2 gate(s) at 100% line and branch coverage)
```

1. The probes of `selfcheck` are appended to the gates, and `settings.gateCommand` is run once.
2. The negative controls are judged on the tracefile of that run, as `selfcheck` judges them.
3. The entries of the probes are taken out of the tracefile: for each gate the line entry and the branch entry at the line of its probe, and one off its `LF:` total (with function coverage also the `FN:` / `FNDA:` entries of the probe, and one off `FNF:`). A probe is a function at the end of the file that nothing calls, so that is all it adds; what is left is the tracefile the command writes without probes. `test/commands/real_coverage_test.dart` runs `dart test` both ways and requires the same records. The entries are only taken out when all of them say "not executed"; otherwise they stay, and the gate fails.
4. That tracefile is left behind and judged as `lcov` judges it. (When the command fails, no tracefile is left: the one it wrote counts the probes.)

The exit code is 0 when every control held and every gate is at 100%. Each of the two verdicts is the one its own command gives; nothing is decided differently. What differs from `test`: the output of the test command is not shown as it comes (it is captured, and its last lines are printed when it fails), and the gates are changed in place for the length of the run, with everything [`selfcheck` says about that](#your-files-during-the-run). `settings.selfcheck.mode: "first"` puts a probe in the first gate only.

What it saves is one of two runs of the tests with coverage: about half the time of `test` followed by `selfcheck`, in [`example/`](example) and for this package.

| Exit code | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| 0         | The command passed and every gate is at 100% (with `--selfcheck`: and every negative control held) |
| 1         | The command failed or could not be started, or `lcov` found violations (with `--selfcheck`: or a control did not hold) |
| 2         | Wrong usage, no command or no tracefile named, or an unusable `test-gates.json` |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the command was ended (with `--selfcheck`: and the gates were put back) |

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

2. Runs `settings.gateCommand` **once**, with all probes in place. The time is that of one test run, whatever the number of gates.
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
- A run that is killed outright (SIGKILL, power loss) cannot clean up. The next `selfcheck` (or `test --selfcheck`) removes what is left from the gates listed in `test-gates.json` before it does anything else, and until then the leftover makes the gate **fail** on the next coverage run, never pass: the probe is unexecuted code in a gate. It is also two lines at the end of the file that `git diff` shows.
- When a gate is saved by somebody else during the run, the change is kept and only the probe at its end is removed; the run fails and says so.

A copy of the package in a temporary directory would leave the working tree alone. It was not chosen, because a copy is not the package: a relative `path:` dependency (the one [`example/`](example) has on this package, `path: ..`) and a pub workspace point outside the copy, and the coverage command of the project would have to be run somewhere it was not written for. A control that fails for such a reason says nothing about the gates.

The end of the file is a valid place in every Dart file: after all directives, so a library with `part 'shipping_fee.g.dart';` is fine, and inside a `part of` file. The function is named after the path of the gate, so two gates that are parts of one library do not collide.

### What it does not show

Upstream's `selfcheck` leaves out the test of one gate and runs the gate again, once per gate. That also catches a gate whose coverage is held up by the test of another file. This `selfcheck` does not: it shows that the measurement reaches every gate and that the judgement reads it, not which test does the covering. That each gate has a test of its own is checked by [`check`](#test_gates-check), and that this test checks the decisions of the gate by [`mutation`](#test_gates-mutation---force---gate-path---report-path----options), which runs only that test.

## `test_gates timezones [--zone <name>] [--all] [-- <command>]`

Runs the tests of the gates once more in other time zones. A gate that decides which day, month or hour a moment falls in must give the same answer wherever the tests run. A test of such a gate can pass because of where the machine is: on a CI runner in UTC, on the laptop it was written on. `timezones` starts the tests with the `TZ` environment variable set, and requires that they pass.

```bash
dart run test_gates timezones
```

The two gates of [`example/`](example) compute with integers, so there is nothing to run:

```
test_gates timezones: OK (no gate names DateTime, so no test was run: 2 gate(s))
```

With `--all` they are run all the same:

```
running "dart test test/bulk_discount_test.dart test/shipping_fee_test.dart" for 2 gate(s) in 2 time zone(s)
  ✓ TZ=Pacific/Kiritimati (UTC+14): the tests pass
  ✓ TZ=Etc/GMT+12 (UTC-12): the tests pass
test_gates timezones: OK (the tests of 2 gate(s) pass in Pacific/Kiritimati, Etc/GMT+12)
```

What it does:

1. **Picks the gates that can depend on the zone: the ones that name `DateTime`**, in the gate itself, in its test, or in a file of the package that one of the two reaches through its imports, exports and parts (generated parts included, and the helpers a test imports). A local date or time is a `DateTime`, and who makes or reads one names the class or reaches a file that does. A comment or a string that says `DateTime` does not count. The other gates are left out, and the first line says how many; `--all` runs every gate.
2. Finds the test of every gate the way [`check`](#test_gates-check) does, before the gates are picked. A gate without a test, or whose file is gone, fails, whether or not it names `DateTime`; with `"suffixes": []` that is every gate.
3. **Runs those tests together, once per zone**, with `TZ` set to the zone: `flutter test --no-pub <tests>` when the pubspec has a dependency from the Flutter SDK, `dart test <tests>` otherwise (the command `dart_mutant` chooses for the mutation test). A command after `--` replaces it; the test files are appended to it. Nothing of the package is changed, and no coverage is collected.
4. Requires that every run passes. For a run that fails, the last lines of its output are printed, and the last line of `timezones` has the command to run it by hand.

The zone of the machine itself is not one of the runs: that is what every other run of the tests uses.

### Which zones, and why two

By default the two ends of the world's clocks:

| Zone                 | Offset | Where the date differs from UTC |
| -------------------- | ------ | ------------------------------- |
| `Pacific/Kiritimati` | UTC+14 | It is tomorrow from 10:00 UTC on |
| `Etc/GMT+12`         | UTC-12 | It is yesterday until 12:00 UTC  |

Between them there is no moment of the UTC day at which both have the date of UTC. A test that reads the day of a moment on the calendar of the machine fails in one of the two, whatever moment it uses.

The tests of this package have a small package for exactly this ([`test/fixtures/zones/package`](test/fixtures/zones/package)): a function that reads the day of a moment on the calendar of the machine, with three tests that pass on a machine in UTC, and one function that takes the offset as an argument. `test/commands/real_timezones_test.dart` runs its tests with `dart test` in each zone and expects this:

| Test of the package                              | `UTC`  | `Pacific/Kiritimati` | `Etc/GMT+12` |
| ------------------------------------------------ | ------ | -------------------- | ------------ |
| `late in the UTC day` (23:30 UTC is the 31st)    | passes | **fails**            | passes       |
| `early in the UTC day` (00:30 UTC is the 1st)    | passes | passes               | **fails**    |
| `the zone it was written in` (noon is hour 12)   | passes | **fails**            | **fails**    |
| `the offset is an argument`                      | passes | passes               | passes       |

A run in UTC finds none of the three, one end finds two, and the two ends together find all three. In this package a third zone finds nothing the two do not, and it costs one more run, so the default is two. `--zone <name>` (may be given more than once) names the zones to use in their place: `--zone UTC --zone Asia/Tokyo`, or a zone with daylight saving time, which the default two do not have.

This is `timezones` on that package:

```
running "dart test test/day_test.dart" for 1 gate(s) in 2 time zone(s)
  ✗ TZ=Pacific/Kiritimati (UTC+14): the tests fail (exit 1)
      00:00 +0 -1: late in the UTC day [E]
        Expected: <31>
          Actual: <1>
      …
  ✗ TZ=Etc/GMT+12 (UTC-12): the tests fail (exit 1)
      00:00 +1: early in the UTC day
      00:00 +1 -1: early in the UTC day [E]
        Expected: <1>
          Actual: <31>
      …
test_gates timezones: FAILED (the tests of the gates do not pass in Pacific/Kiritimati, Etc/GMT+12). A gate decides something by the time zone of the machine, or a test expects the zone it was written in. Run them yourself with: TZ=Pacific/Kiritimati dart test test/day_test.dart
```

(`…` stands for the other lines of the test runner; up to 25 are printed per zone.)

### What it costs

One start of the test runner per zone, on the tests of the gates that name `DateTime`, and nothing when no gate does: then the command ends as soon as it has read the gates.

In [`example/`](example) (two gates, two test files, run with `timezones --all`), every zone added about as much time as one `dart test` of those two files takes by itself, in runs with one, two and three zones. So the default costs two such runs, and a third zone would cost half as much again.

### Where it works

`TZ` and the time zone database (`/usr/share/zoneinfo`) are how macOS and Linux give a process its zone, and `timezones` works there. `test/commands/real_timezones_test.dart` checks on the machine that runs the tests of this package that `dart test` started with `TZ` runs in that zone; the workflow runs it on Linux and on macOS. `flutter test` is started the same way.

- **A zone the machine does not know is refused** before anything is run, also when there is nothing to run. A process that is started with an unknown `TZ` runs in UTC without saying so, and its run would pass for the wrong reason. Known means: a file of the database that starts as its entries do (`TZif`); the database also has files that are no zones. On Linux the database is where `TZDIR` says, when that is set. A container image without the time zone database (`tzdata`) fails, with exit code 1, when a gate names `DateTime`.
- **Windows is not supported**: `TZ` is not how a process gets its zone there. The command fails with exit code 1 when a gate names `DateTime`.
- **The locale is not varied.** On Linux a Dart program takes it from `LANG`; on macOS `LANG` does not change it (the same test file checks both). A check that worked on one of the two would say "passed" on the other without having checked anything.
- **Daylight saving time is not covered** by the default zones: neither has it. A gate that decides something around the hour that is skipped or repeated needs a zone that has it (`--zone Europe/Berlin`), and a test at such a moment.
- **What the two zones are sure to find is a decision about the day.** A month or a year changes with the day only near its end: a test with a moment in the middle of a month passes in both. A decision about an hour of the day or a day of the week can come out the same in both zones and differ in one between them, and neither of the two has an offset of half an hour. For those, use a moment near the boundary in the test, and name the zones the gate is for: `--zone Asia/Tokyo --zone Asia/Kolkata`.
- **A gate that reads the zone without naming `DateTime`** is left out: one that gets a date from another package and never names the class, in the gate, in its test, and in the files of the package the two reach. `--all` runs every gate. (Without a `pubspec.yaml` a `package:` import cannot be followed, and a gate that has one, or reaches a file that has one, is run.)

| Exit code | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| 0         | The tests pass in every zone, or no gate names `DateTime` (and every gate has its test) |
| 1         | The tests fail in a zone, a gate has no test, a zone is not known to the machine, the command cannot be started, or an entry of `test-gates.json` is wrong |
| 2         | Wrong usage (a `--zone` that is no name of a zone), or an unusable `test-gates.json` |
| 130 / 143 / 129 | Interrupted (SIGINT / SIGTERM / SIGHUP); the command was ended       |

## `test_gates mutation [--force] [--gate <path>] [--report <path>] [-- <options>]`

Mutation test of the gates. A **mutant** is a gate with one small change (`+` → `-`, a condition → `true`, `round()` → `floor()`). A mutant that the test of the gate notices is _killed_. One that passes it _survived_: the gate decides something there that no test checks.

Two tools share the work, the way upstream's `mutation` and Stryker do:

- [`dart_mutant`](https://pub.dev/packages/dart_mutant) makes the mutants and runs the tests on them. It is given files and their tests, and writes a report. It knows no list of gates and no allowance.
- `test_gates` keeps the list and gives the verdict. `mutation` tells `dart_mutant` which files and which tests (the gates of `test-gates.json`), and judges its report as [`mutation-result`](#test_gates-mutation-result---report-path) does: which survivors are allowed, each with a reason, and that no gate and no mutant was left out.

```bash
dart run test_gates mutation
```

```
test_gates mutation: running every mutant of the gates (--force): there is no record of a run to reuse
dart_mutant run: the dependency "test_gates" is at a path relative to the package (../../), so it cannot be run from working copies. The mutants are run one at a time, in place (--jobs 1), each with a start of the test runner of its own
  lib/bulk_discount.dart: 44 of 45 mutant(s) with "dart test --fail-fast --timeout 10s test/bulk_discount_test.dart" (1 do not compile)
  lib/bulk_discount.dart: 45 mutants / killed 43 / survived 1 / timeout 0 / compile error 1 (1 found before the run) (36.3s)
  lib/shipping_fee.dart: 23 of 24 mutant(s) with "dart test --fail-fast --timeout 10s test/shipping_fee_test.dart" (1 do not compile)
  lib/shipping_fee.dart: 24 mutants / killed 22 / survived 1 / timeout 0 / compile error 1 (1 found before the run) (19.0s)
dart_mutant run: 2 surviving mutant(s)
  - lib/bulk_discount.dart:19:39 / NumberLiteral / 50 → 51 (Survived)
  - lib/shipping_fee.dart:14:11 / EqualityOperator / > → >= (Survived)
dart_mutant run: FAILED (69 mutants / killed 65 / survived 2 / timeout 0 / compile error 2 (2 found before the run))
test_gates mutation: OK (mutants 69 / detected 65 (timeout 0) / allowed equivalent 2 / not evaluable 2 / unallowed survivors 0)
```

(The outputs on this page are those of [`example/`](example). It has `test_gates` as a `path:` dependency, which is what the first line is about; a package of your own gets it from pub.dev.)

The lines of `dart_mutant` come first, as it prints them. To that tool a survivor is a failure, so it ends with `FAILED`; the last line is the verdict of `test_gates`, which knows that the gates allow these two (see [Allowing an equivalent mutant](#allowing-an-equivalent-mutant)).

### Where `dart_mutant` comes from

`mutation` fetches it. The first run in a package says so, and takes a few seconds longer:

```
test_gates mutation: fetching dart_mutant ^0.2.1 from pub.dev into .dart_tool/test_gates/dart_mutant/0.2/dart_mutant.snapshot (once per package)
```

- It runs `dart pub global activate dart_mutant '^0.2.1'` with `PUB_CACHE` set to a temporary directory, keeps the compiled program (one file, the path above, below the package) and deletes the rest. Your pub cache, your globally activated packages and your `PATH` are not read and not changed.
- Later runs start that file with the `dart` that runs `test_gates` (the `dart` on `PATH` when `test_gates` was [compiled into an executable](#starting-it-faster-still)), and do not go to the network. A file that no longer answers (the SDK was upgraded, the file is damaged) or is not a supported version is fetched again. So is one that was deleted: to get a later 0.2.x, delete the directory.
- `.dart_tool/` is ignored by git in a Dart project, so the file is not committed. In CI every job that starts on a fresh checkout fetches it.
- When it cannot be fetched (no network, or a Dart older than 3.11), the exit code is 2, and the message has what the command printed and how the tool is installed by hand.

`dart_mutant` is a program of its own, not a dependency of your package: it needs a narrow range of `package:analyzer`, which would have to resolve next to the code generators of an app, and a package has one set of dependencies. It runs on Dart 3.11 or later (`test_gates` itself on 3.9), and the package has to be resolved (`dart pub get` / `flutter pub get`).

**This version works with `dart_mutant` 0.2.1 and every later 0.2.x.** (Not 0.1.x: `test_gates` 0.2.0 is the version for that one.) The version is asked for before every run, and any other is refused with exit code 2 before anything is run or changed: another version may make other mutants of the same source, and then the allowances of `test-gates.json` no longer mean what they meant.

#### A `dart_mutant` you installed yourself

To use another build of the tool, or one that is already on the machine, name its executable with the environment variable `TEST_GATES_DART_MUTANT`. Then nothing is fetched:

```bash
dart pub global activate dart_mutant '^0.2.1'
TEST_GATES_DART_MUTANT="$HOME/.pub-cache/bin/dart_mutant" dart run test_gates mutation
```

Its version is checked in the same way. Give the range when you install it: without it, a later 0.3 would be installed, which this version refuses. A `dart_mutant` on `PATH` is not used unless the variable names it, so that an older one that happens to be there is not picked up. (There is no setting for it in `test-gates.json`: that is the file upstream reads as well, and upstream refuses a key it does not know.)

### What it does

1. Finds the test of each gate the way [`check`](#test_gates-check) does: `lib/a/b.dart` → `lib/a/b_test.dart` and `test/a/b_test.dart` (`settings.spec`). Every one that exists is run on the mutants of the gate. A gate without a test, and a gate whose file is gone, fails, and is not given to the tool; with `"suffixes": []` that is every gate.
2. Writes the gates and their tests as a plan file for the tool, `.dart_tool/test_gates/mutation-plan.json` (`.dart_tool` is ignored by git in every Dart project).
3. Decides which gates keep the results of the last run, and says so in its first line (see [Results of the last run](#results-of-the-last-run-and---force)). Takes what the report of an earlier run says about the gates that are run out of it (`settings.stryker.reportFile`, default `reports/mutation/mutation.json`; `--report <path>` for another place, relative to the package), and deletes the report when nothing is left. (A file there that is not a mutation report is left as it is; `dart_mutant` refuses to replace it, with exit code 2.) Whatever is judged in step 5 was then written by this run, also when the tool ends without writing anything.
4. Starts `dart_mutant run --dir <package> --plan <the plan> --report <the report>` in the package, with `--force --only <path>` for every gate that is run again (with `--force` alone when every gate is), with `--only <path>` for every `--gate <path>` when nothing is run again, and with what follows `--`. What the tool prints goes to the terminal as it is.
5. Judges the report, see below.

### What follows `--` is for `dart_mutant`

It is handed to `dart_mutant run` as it is, like upstream hands what it does not know to Stryker. The options are described in [the README of `dart_mutant`](https://pub.dev/packages/dart_mutant):

```bash
dart run test_gates mutation -- --jobs 3                 # test runs at a time, in working copies of the package (not in example/, see above)
dart run test_gates mutation -- --html reports/mutation/mutation.html
dart run test_gates mutation -- --shard 1/4              # a part of the run, see below
dart run test_gates mutation -- --one-by-one             # a start of the test runner for every mutant, as dart_mutant 0.1 ran them
dart run test_gates mutation --force -- --jobs 2 -- fvm flutter test --no-pub
```

- **The command that runs test files** is the tool's to choose: `flutter test --no-pub` when the pubspec has a dependency from the Flutter SDK, and `dart test` otherwise. Another one goes behind a second `--`, as in the last line. `settings.gateCommand` is not used for it: that command collects coverage, which a test run on a mutant has no use for. So there is nothing to set twice.
- The tool is started in the package, so a path behind `--` (`--html`) is relative to the package, like `--report` and `--file` of `test_gates`.
- `--dir`, `--plan`, `--report` and `--only` are refused behind `--` (exit code 2): `mutation` sets them from `test-gates.json`, and with another value the tool would mutate other files than the gates, or write a report that is not the one that is judged. Give `--dir`, `--report` and `--gate` in front of `--`.
- `--help` and `--version` are refused as well: the tool would run nothing.
- Anything else that the tool does not know, it refuses itself, with exit code 2.

### Who decides whether the run passes

The exit code of `dart_mutant` is not the verdict. It ends with 1 for a survivor that the gate allows, and with 0 when a gate was never part of the run.

| `dart_mutant` ends with | `mutation` does |
| ----------------------- | --------------- |
| 0 or 1                  | Judges the report with the rules of [`mutation-result`](#test_gates-mutation-result---report-path). A gate that is not in the report fails (the tool leaves out a file it could not mutation test: its tests fail without a mutant, say, and it has printed why). So does exit code 1 with a report in which no mutant of these gates survived and none is missing: the tool failed at something the report does not show |
| 2                       | Exit code 2. The tool refused its command line and ran nothing |
| 130 / 143 / 129         | The same exit code. The tool was interrupted, and has put back what it changed |
| anything else           | The same exit code; for a process that a signal ended, 128 + the number of the signal (137 when the system killed it for its memory). Nothing is judged |

| Exit code of `mutation` | Meaning                                                              |
| ----------------------- | -------------------------------------------------------------------- |
| 0                       | Every mutant is detected, allowed as equivalent, or does not compile |
| 1                       | A survivor without an allowance, a timeout nobody explained, a stale allowance, a gate that could not be mutation tested or is missing from the report, a mutant that was not evaluated, or a wrong entry of `test-gates.json` |
| 2                       | Wrong usage, an unusable `test-gates.json`, `dart_mutant` could not be fetched or is not a supported version, or it refused its command line |
| 130 / 143 / 129         | Interrupted (SIGINT / SIGTERM / SIGHUP)                              |
| anything else           | `dart_mutant` ended with it, see above                               |

### Mutators

The mutants, their names and the statuses are those of `dart_mutant`; [its README](https://pub.dev/packages/dart_mutant) has the tables. The name of the mutator is part of the key of an allowance.

- **From the syntax tree:** `ArithmeticOperator`, `EqualityOperator`, `LogicalOperator`, `ConditionalExpression`, `BooleanLiteral`, `UnaryOperator`, `UpdateOperator`, `AssignmentOperator`, `BlockStatement`, `RemoveCall`, `StringLiteral`, `ArrayDeclaration`. These are the mutators `test_gates` 0.1 had itself, and for the same source they give the same mutants: an allowance written for 0.1 still matches.
- **From resolved types:** `MethodExpression` (`round` → `floor`, `first` → `last`, `x.abs()` → `x`, …), `NumberLiteral` and `ConstantNumberLiteral` (`n` → `n + 1`, `n - 1`), `GuardAlwaysTaken`, `GuardThrows`, `GuardResultSwapped`, `BranchCopied`, `ReturnValue`.

A mutant that does not compile is found by the analyzer before a test is run. It is a `CompileError`: not a detection and not a failure. The summary counts it as `not evaluable`, so that a gate whose mutants mostly do not compile is visible.

There is no way to switch a mutator off, and no comment that hides a mutant (upstream rejects Stryker's `excludedMutations` and `// Stryker disable` for the same reason). A mutant that cannot be observed is allowed one by one, with a reason, in `test-gates.json`.

### Timeouts

The limits are those of `dart_mutant`, and they are not settings: a test gets 10 seconds, and the test run of one mutant three times the run without a mutant plus 20 seconds. Only a mutant that keeps the process from ending gets that far (a loop that never yields), and is a `Timeout`; so is a test run that takes more memory than its limit.

A `Timeout` counts as detected, but an unexplained one fails the run. The rules are upstream's:

- `expectedTimeouts` (per gate): mutants that can never finish. Same key as `equivalentMutants` (`mutator` + `original` + `replacement`, `occurrence` when ambiguous, `reason` required). An entry whose mutant survived, or does not exist, fails the run. Any other status is accepted, `Killed` included: which limit is reached first can depend on the load.
- `settings.mutation.maxTimeouts`: how many timeouts outside `expectedTimeouts` are tolerated, default `0`.

### Results of the last run, and `--force`

`mutation` runs a gate again only when something its results can depend on changed, and then runs every mutant of it. What it can depend on is the gate, its tests, and every file of the package that one of them imports, exports or has as a part, however many imports away (a helper of a test, a file the gate calls). Each run writes down a fingerprint of each of these files, per gate, in `.dart_tool/test_gates/mutation-record.json`, and the next run compares them. The first line says what it found:

```
test_gates mutation: 1 of 2 gate(s) reused, 1 run again with every mutant
  lib/bulk_discount.dart: changed lib/bulk_discount.dart
```

(That is `example/` after a change of `lib/bulk_discount.dart`. A change of a file it imported, or of a helper of its test, would be named in the same way.)

- **A gate that runs again runs with every mutant.** It is given to `dart_mutant` with `--force --only <path>`: the results that tool keeps per file (`.dart_tool/dart_mutant/incremental.json`), which only look at the file, its tests, the test command and the tool, are not used for it. The other gates keep their results in the report.
- **When nothing changed, nothing is run again**, apart from the mutants that timed out: `dart_mutant` measures a `Timeout` again every time. When some gates run again, a gate with a mutant that timed out in the last run is one of them, so that its `Timeout` is measured again as well.
- **A file that no gate reaches changes nothing**, with one exception: a gate whose tests (or the files they import) import `dart:io`, `package:file` or `package:test_descriptor`, or name `matchesGoldenFile` or `rootBundle`, can read any file of the package (a fixture, a golden file). Such a gate runs again when any file of the package that git lists (tracked, or untracked and not ignored) changed. Outside a git work tree the files cannot be listed, and it runs again every time.
- A `flutter_test_config.dart` in the directory of a test or above it is run by `flutter test` around that test without an import, and counts as one of its files.
- **Every mutant of every gate is run** (`--force` is handed to `dart_mutant`) when the run is given `--force`, when the environment variable `CI` is set, for a part of a run (`--shard`), when there is no record or it cannot be read, when the report is not the one the last run left (deleted, or written by another run), when what a gate depends on cannot be told from its imports (a file it imports is missing, a URI that is not written out as Dart reads it, an import that leaves the package), and when one of these changed: `pubspec.yaml`, `pubspec.lock`, `pubspec_overrides.yaml`, `analysis_options.yaml`, `dart_test.yaml`, `build.yaml`, `test-gates.json`, the version of the Dart SDK, of `test_gates` or of `dart_mutant`, the options after `--`, or `--report`. The first line says which.

The judgement is always made again, on the current `test-gates.json`. Removing an allowance changes that file, so the next run runs every mutant and fails on the survivor.

- **pre-push: `test_gates mutation`.** Nothing is run when nothing a gate depends on changed, apart from the mutants that timed out.
- **CI, and before a release: `test_gates mutation --force`.** CI has no results to start from anyway, and `CI` is set there, which runs every mutant without the option as well.

The tests of a gate are its own tests only (see [What it does](#what-it-does)): `dart_mutant` runs no other test file on its mutants, so a change to another test that imports the gate does not make it run again.

### One gate at a time: `--gate`

`--gate <path>` limits the run to one gate: only that gate is in the plan, the tool is given `--only <path>`, and only that gate is judged. The option may be given more than once, and goes together with `--force`.

```bash
dart run test_gates mutation --gate lib/shipping_fee.dart
dart run test_gates mutation --force --gate lib/shipping_fee.dart --gate lib/bulk_discount.dart
```

After the full run above (the results of the gate are taken from it):

```
test_gates mutation: nothing that the 1 gate(s) depend on changed since the last run: their results are reused, and a Timeout is measured again
dart_mutant run: the dependency "test_gates" is at a path relative to the package (../../), so it cannot be run from working copies. The mutants are run one at a time, in place (--jobs 1), each with a start of the test runner of its own
  lib/shipping_fee.dart: 24 mutants / killed 22 / survived 1 / timeout 0 / compile error 1 (1 found before the run) (24 from the last run, 0.0s)
dart_mutant run: 1 surviving mutant(s)
  - lib/shipping_fee.dart:14:11 / EqualityOperator / > → >= (Survived)
dart_mutant run: FAILED (24 mutants / killed 22 / survived 1 / timeout 0 / compile error 1 (1 found before the run))
test_gates mutation: OK for 1 of 2 gate(s) (--gate) (mutants 24 / detected 22 (timeout 0) / allowed equivalent 1 / not evaluable 1 / unallowed survivors 0)
```

- The path is the one in `test-gates.json`, as it is written there. A path that is not a gate is wrong usage (exit code 2): a typo must not become a run that tests nothing.
- For the gates it names, the run fails for the same reasons as a full run: a survivor, a stale allowance, a timeout nobody explained, a gate without a test. Nothing is said about the mutants, the tests or the allowances of the other gates. (A wrong entry of `test-gates.json` still stops every run, whichever gate it is in: the file is one, and it is checked before anything is run.) **The last line says how many gates were judged**; `OK for 1 of 2 gate(s)` is not a pass of the project.
- `settings.mutation.maxTimeouts` is counted within the run, so with a value above `0` several runs can each stay below a limit that the full run would exceed.
- The report keeps what it says about the other gates, and gets the new result of the named ones. After a full run and a `--gate` run it is still a report of all gates.
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

### A run in several parts: `--shard`

One gate with many mutants, or with slow tests, can be divided over several machines: `-- --shard <i>/<n>` has `dart_mutant` run part `i` of `n` of the mutants of each gate.

```bash
dart run test_gates mutation --force --report part-1.json -- --shard 1/2
dart run test_gates mutation --force --report part-2.json -- --shard 2/2
dart pub global run dart_mutant merge part-1.json part-2.json --report reports/mutation/mutation.json
dart run test_gates mutation-result
```

The first of these lines prints:

```
test_gates mutation: running every mutant of the gates (--force): --force
dart_mutant run: the dependency "test_gates" is at a path relative to the package (../../), so it cannot be run from working copies. The mutants are run one at a time, in place (--jobs 1), each with a start of the test runner of its own
  lib/bulk_discount.dart: 22 of 45 mutant(s) with "dart test --fail-fast --timeout 10s test/bulk_discount_test.dart" (1 do not compile)
  lib/bulk_discount.dart: 23 of 45 mutants / killed 22 / survived 0 / timeout 0 / compile error 1 (1 found before the run) (18.5s)
  lib/shipping_fee.dart: 12 of 24 mutant(s) with "dart test --fail-fast --timeout 10s test/shipping_fee_test.dart"
  lib/shipping_fee.dart: 12 of 24 mutants / killed 11 / survived 1 / timeout 0 / compile error 0 (9.9s)
dart_mutant run: 1 surviving mutant(s)
  - lib/shipping_fee.dart:14:11 / EqualityOperator / > → >= (Survived)
dart_mutant run: FAILED (shard 1/2: 35 of 69 mutants / killed 33 / survived 1 / timeout 0 / compile error 1 (1 found before the run))
test_gates mutation: a part of a run (--shard) was written to part-1.json. It is not judged: put the parts together with "dart_mutant merge" and judge the result with "test_gates mutation-result"
```

- **A part runs every mutant of its gates** (`--force` is handed to `dart_mutant` whether it is given or not), and leaves no record of a run to reuse.
- **A part is not judged.** Its report lists every mutant, and the ones of the other parts were not evaluated. `mutation` ends with 0 when the part was written and has every gate of the run in it, and says that it judged nothing. A survivor in the part does not change that: whether it is allowed is decided when all parts are there.
- `dart_mutant merge` puts the parts together and refuses them when they are not all the parts of one run. Its exit code is 1 when a mutant survived; the verdict is that of `mutation-result` on the report it writes.
- `mutation-result` refuses the report of a part as a whole (and a mutant with the status `Pending` in any report), so a part that is given to it by mistake cannot pass.
- Two parts cannot run at the same time in one checkout: `dart_mutant` runs one at a time in a package. One after the other, as above, they can; side by side each needs a checkout of its own (the jobs of a CI workflow).

### Your files during the run

`test_gates` writes the plan file, and changes the report as described above. Everything else is done by `dart_mutant`, and [its README](https://pub.dev/packages/dart_mutant) says how:

- The mutants are put into working copies of the package below `.dart_tool/dart_mutant/`, and your files are not written.
- For a package that cannot be run from a copy (a `path:` dependency outside the package, a pub workspace), and with one job where every mutant gets a start of the test runner of its own (a Flutter package, `-- --one-by-one --jobs 1`), the gates are changed **in place**, one mutant at a time, and put back after every test run. Do not edit a gate, commit, or switch branches while that runs. For a package that cannot be run from a copy the tool says so in its first line.
- One run at a time in a package. A second one is turned away by the tool (exit code 1; the tool changes nothing, but `mutation` has already taken the earlier results of these gates out of the report), and `mutation` then fails: the gates have no result.

On **Ctrl-C (SIGINT), SIGTERM and SIGHUP** `mutation` hands the signal to the tool and to every process that descends from it (the executable on `PATH` is a script that starts the tool, and would not pass it on), and waits until they have ended: the tool ends its test runs, removes its copies or puts the gate back, and writes no report. `mutation` then exits with 130 / 143 / 129 and judges nothing. What is still there after 60 seconds is killed, and the message says so: the tool may then not have put back what it changed, and `git status` shows a gate with a mutant in it. Where there is no `ps`, only the process that was started gets the signal. On Windows no signal can be handed on: the process that was started is ended, and the tool behind it is not waited for.

A run that is killed outright (SIGKILL, power loss) while it changes the gates in place leaves one mutant in one gate. The next run of the tool puts the gate back before it does anything else. Until then `git diff` shows the mutant.

### How long it takes

A mutant that does not compile costs next to nothing. One that compiles costs one start of the test runner on the test of its gate in a Flutter package, with `-- --one-by-one`, and for a gate whose mutants `dart_mutant` does not build into it (a gate with few mutants, a package that cannot be run from a copy; the lines it prints per gate say which, and why). For the other gates of a pure Dart package the tests of the gate are compiled once for all its mutants, and a mutant costs the start of a process, which is a fraction of a start of the test runner; only a mutant that no test fails on there gets a start of the test runner as well. The time of a full run (`--force`) is what these test runs take, divided by the test runs `dart_mutant` makes at a time. A second run without `--force` and without a change runs nothing but the timeouts.

| Package                                    | Gates | Mutants                           | Test runs at a time (on a machine with 12 logical processors) |
| ------------------------------------------ | ----- | --------------------------------- | ------------------- |
| [`example/`](example)                      | 2     | 69, of which 2 do not compile     | 1, in place, a start of the test runner for each (it has a `path:` dependency) |
| This package, its own gates                | 15    | 2841, of which 274 do not compile | 3, in working copies (the default there) |

In `example/` a full run is 67 test runs, one at a time. For this package 2567 mutants are run, three at a time on that machine, most of them by a process of their own: the mutants are built into 13 of the 15 gates; in its workflow every gate is a job of its own ([`--gate`](#one-gate-at-a-time---gate)).

Of the 2841 mutants of this package 2559 are killed, 4 time out (they are in `expectedTimeouts`) and 4 survive and are allowed as equivalent ([Development](#the-gates-of-this-package)).

## `test_gates mutation-result [--report <path>]`

Judges an existing report without running anything: the report of the last `mutation`, of `dart_mutant` started by hand (`run`, or `merge` for a run in parts), or of another tool that writes the mutation-testing-elements JSON schema. `--gate <path>` (may be given more than once) judges only those gates of it, see [`--gate`](#one-gate-at-a-time---gate). The rules are those of upstream's `mutation-result`, ported with its test cases.

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
- the report is that of a part of a run (`dart_mutant run --shard`): it is refused as a whole,
- the report was made from a different version of a gate than the one on disk,
- a mutant timed out outside `expectedTimeouts`, and there are more of them than `settings.mutation.maxTimeouts` allows.

On failure every unallowed survivor is listed as `file:line:column / mutator / original → replacement / occurrence`, followed by a JSON fragment that can be pasted into `equivalentMutants`. The last line gives the real numbers, never a percentage. The example, without the two allowances it has:

```
test_gates mutation: 2 surviving mutant(s) not in the allow list
  - lib/bulk_discount.dart:19:39 / NumberLiteral / 50 → 51 / occurrence 2 of 2 (Survived)
  - lib/shipping_fee.dart:14:11 / EqualityOperator / > → >= (Survived)

Fix the test so that it detects the mutant. Only when the mutant cannot be observed from
outside (same return value, exception and side effects for every input), add it to
"equivalentMutants" of the gate in test-gates.json and fill in "reason":

  lib/bulk_discount.dart
    {"mutator":"NumberLiteral","original":"50","replacement":"51","occurrence":2,"reason":""}

  lib/shipping_fee.dart
    {"mutator":"EqualityOperator","original":">","replacement":">=","reason":""}

test_gates mutation: FAILED (mutants 69 / detected 65 (timeout 0) / allowed equivalent 0 / not evaluable 2 / unallowed survivors 2)
```

`--not-evaluable` (for `mutation` and for `mutation-result`) lists the mutants that could not be evaluated, with what the tool says about each. Without it they are only counted. The verdict is the same either way. (A part of a run, `-- --shard`, is not judged, so nothing is listed for it.)

```
test_gates mutation: 2 mutant(s) could not be evaluated (no test run says anything about them):
  ~ lib/bulk_discount.dart:12:27 / ArithmeticOperator / * → / / occurrence 1 of 2 (CompileError)
      A value of type 'double' can't be returned from the function 'lineTotalCents' because it has a return type of 'int'.
  ~ lib/shipping_fee.dart:13:19 / ArithmeticOperator / * → / (CompileError)
      A value of type 'int' can't be assigned to a variable of type 'double'.
test_gates mutation: OK (mutants 69 / detected 65 (timeout 0) / allowed equivalent 2 / not evaluable 2 / unallowed survivors 0)
```

The fragment is the key of the mutant, whatever its mutator: when the same change can be made in several places of the file (`0` → `1`), it has the `occurrence` that picks this one.

### Allowing an equivalent mutant

An equivalent mutant changes the code without changing anything observable: same return value, same exception, same side effects, for every input. Only those may be allowed, in `test-gates.json`, with the reason.

The example has two. `lib/shipping_fee.dart` limits the fee:

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

The other one is in `lib/bulk_discount.dart`, which rounds the discount half up with `(total * percent + 50) ~/ 100`. With `51` in place of `50` the result differs only when `total * percent` ends in 49, and the percentages are 0, 5 and 12: a multiple of 5 ends in 0 or 5, and a multiple of 12 is even. (`49` in place of `50` is not equivalent: half a cent is then rounded down, and a test notices.)

- The key is `mutator` + `original` + `replacement`. `original` is the source text at the location in the report. Whitespace differences are ignored. **Line numbers are not part of the key**, so moving code does not break an allowance, and an allowance never covers a different mutant on the same line.
- When the same key occurs more than once in a file, `occurrence` (1-based, in source order) is required.
- A comment inside the mutated text is part of `original`; the fragment the tool prints has it.
- An error message or a label is not equivalent just because no test reads it. If it matters, assert it.
- If in doubt, write the test.

## `test_gates all [--selfcheck] [--force] [--no-mutation]`

The checks that belong before a push, in one start of the tool:

```bash
dart run test_gates all
```

runs `check`, `test`, `timezones` and `mutation`, in this order, and stops at the first that does not pass. In [`example/`](example) it ends like this (the lines of the test runner and of `dart_mutant` left out):

```
test_gates check: OK (2 gate(s), 1 candidate(s))
reference: overall line coverage 100.00% (16/16, not gated)
  ✓ lib/bulk_discount.dart: 10/10 lines, 5/5 branches
  ✓ lib/shipping_fee.dart: 6/6 lines, 3/3 branches
test_gates lcov: OK (2 gate(s) at 100% line and branch coverage)
test_gates timezones: OK (no gate names DateTime, so no test was run: 2 gate(s))
test_gates mutation: nothing that the 2 gate(s) depend on changed since the last run: their results are reused, and a Timeout is measured again
test_gates mutation: OK (mutants 69 / detected 65 (timeout 0) / allowed equivalent 2 / not evaluable 2 / unallowed survivors 0)
test_gates all: OK (check, test, timezones, mutation)
```

- **Each check is the command of that name.** It prints what that command prints and decides what that command decides; `all` adds one line at the end. `test/commands/all_test.dart` compares `all` with the commands started one by one, each in a process of its own, and `real_mutation_test.dart` does it with the mutation test.
- **The first check that fails ends the run**, with its exit code, and the checks behind it are not started: `test_gates all: stopped at "test" (exit code 1). Not run: timezones, mutation`. A hook is over sooner that way, and a later check on a package that already failed says little.
- `--selfcheck` is handed to `test` ([one run for the coverage and the negative control](#one-run-for-the-coverage-and-the-negative-control---selfcheck)) and `--force` to `mutation`. `--no-mutation` leaves `mutation` out, where `dart_mutant` cannot run (a Dart older than 3.11). `--dir <package>` goes to all of them.
- The other options of the commands (`--file`, `--zone`, `--gate`, a command after `--`) are not taken: for those, call the command itself. What the checks need is in `test-gates.json`.
- Nothing is carried from one check to the next. Each reads `test-gates.json` and the files of the package when its turn comes, because `test --selfcheck` and `mutation` change files while they run.

**Why one start.** `dart run` looks at the dependencies of the package and starts the Dart VM on every call. For `check`, `lcov` and `mutation-result` that is most of their time. In [`example/`](example), with nothing to do for `mutation` (no gate changed), `all` took about half the time of the four commands one after the other. That is a small package: what `all` saves is three starts of the tool, whatever the tests take, so the share is smaller where the tests take longer.

### Starting it faster still

`all` still starts through `dart run` once. Where that matters (a hook that runs on every commit), compile the tool once into an executable of the package. A file of a few lines is the entry point; [`example/tool/test_gates.dart`](example/tool/test_gates.dart) is one:

```dart
// tool/test_gates.dart
import 'dart:io';

import 'package:test_gates/test_gates.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runAsync(
    arguments,
    Io(out: stdout.writeln, err: stderr.writeln),
  );
}
```

```sh
mkdir -p build
dart compile exe tool/test_gates.dart -o build/test_gates
build/test_gates all
```

The commands, their output and their exit codes are the same; only the start is shorter: the one start that `all` still pays through `dart run` (in `example/`, a quarter or more of what `all` took).

- **The executable is the version it was built from.** It is compiled from the dependencies as they are resolved at that moment (after `dart pub get`, the versions of `pubspec.lock`), not the ones after the next `dart pub upgrade`. Build it again whenever the lock file is newer, and resolve first, because `dart compile exe` does not: at the top of the hook, `test build/test_gates -nt pubspec.lock || { dart pub get && mkdir -p build && dart compile exe tool/test_gates.dart -o build/test_gates; }`. Without the `dart pub get`, a lock file that changed with a `git pull` gives an executable of the old versions that looks new. `build/test_gates --version` says what it is. The lock file changes with the version of a dependency from pub.dev or from git; with a `path` dependency it does not change when the source of the package does, so build again after changing that. Do not commit the executable: put `build/` into `.gitignore`.
- **In CI, stay with `dart run`.** A job calls `all` once; compiling takes longer than the start it saves.
- **`dart pub global activate test_gates` is not the same thing.** It installs a version of its own, outside the package, which is not the one in `pubspec.lock`. It is the way out when `test_gates` does not resolve next to the dependencies of an app ([Install](#install)), not a way to start faster.
- `mutation` fetches and starts `dart_mutant` as before, with the `dart` on `PATH`.

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

- **Only the test of the gate is run.** A decision that is checked in another test file survives. Move the cases into the test of the gate; `check` asks for exactly one test per gate for the same reason.
- **A mutant that does not compile is not a detection and not a failure.** A gate whose mutants all fail to compile passes; the `not evaluable` number in the summary is where to look.
- **Results of the last run see what the imports name, not more** (see [Results of the last run](#results-of-the-last-run-and---force)). A file that a test reads in another way than the ones listed there (through another package, an asset loaded by a widget), the files of a `path:` dependency or of another package of a workspace (only `pubspec.lock` is compared, which does not change when they do), the Flutter framework apart from the version of Dart, and a file that git ignores and a test reads are not seen. Use `--force` where it counts; CI runs every mutant anyway.
- **The mutators that use types often make a mutant that nothing can observe**: a number that only has to be large enough, `round` → `ceil` on a value that is whole anyway, `first` ↔ `last` on a list of one. Such a survivor is a question about the test first; when the answer is that no input can tell the two apart, it is allowed with that reason.
- **Logging is mutated like everything else.** A removed `log('fee capped');` survives unless a test reads the log; allow it with a reason.
- **`mutation` needs a newer Dart than the other commands**: `dart_mutant` runs on Dart 3.11 or later. `check`, `lcov`, `test`, `selfcheck`, `timezones` and `mutation-result` run on 3.9, and so does `all --no-mutation`.
- **What `dart_mutant` cannot do, `mutation` cannot do.** Its limits are in [its README](https://pub.dev/packages/dart_mutant): `flutter test` and `dart test` only, a package that cannot be run from a working copy is mutated in place and one mutant at a time, and on Windows a test run that is ended can leave a process behind.

Other limits:

- **`dart test --coverage=<dir>` followed by `format_coverage --lcov`** is another way to an lcov tracefile. The fixtures and tests of this package are made with `--coverage-path` only, so that way is not covered by them. Both need `--branch-coverage` on the `dart test` side; `format_coverage` has no such option of its own.
- **Only Flutter 3.47.2 / Dart 3.13.2 were measured.** Which lines carry a block is decided by the Dart VM and may change between SDK versions. A gate that passes on one SDK and fails on another points at such a change.
- **The clock and random numbers are not checked** (`DateTime.now()`, `Random()`), by `lcov` or by `check`: a default argument such as `now ?? DateTime.now()` is a legitimate way to pass them in, and the syntax cannot tell it from a direct read. Add a `forbiddenSource` rule, or `impureNamedImports` for `Random`, if the project wants one.
- **`check` reads the syntax, not the meaning.** Nothing is resolved, so the environment is found by name: `Platform.environment` and `String.fromEnvironment` are reported, a class of the project called `Platform` with an `environment` member is reported too, and a read through another name (`final env = Platform.environment` in another file) is not. A record field named `skip` in a test is taken for the argument.
- **A part named `*.g.dart` or `*.freezed.dart` is not read**, in a gate and in the files it reaches: it is taken for the output of a generator. A file with such a name that somebody wrote by hand is not checked.
- **`check` follows imports into the package, not into other packages.** What `package:decimal` imports is not read; a package is judged by its name. `impureImports` patterns see the URI as written (see [What a gate must not import](#what-a-gate-must-not-import)).
- **A pattern of `forbiddenSource.add` is tested against the code of a line.** A comment is not code (upstream tests the text of the line, comments included); a string literal is. Coverage ignore comments are found in the text of the line as well, because that is how the coverage tool finds them: one inside a string literal is honoured by the tool, and reported here.
- **`check` parses with the newest language version its `analyzer` knows.** The range is wide (`>=8.2.0 <15.0.0`) so that it resolves next to the code generators of an app; an app that pins an old `analyzer` and uses newer syntax in a gate gets a syntax error from `check`.
- **Tests are not checked for mocking the gate.** Upstream rejects `jest.mock` of the module under test; Dart has no module mock.
- **The tool does not judge what belongs in `gates`.** Whether every important decision has been extracted and listed is for people to review; `candidates` is where the known gaps are written down.

## Upgrading from 0.1

Until 0.1.1 `test_gates mutation` made the mutants and ran the tests itself. From 0.2.0 on it starts [`dart_mutant`](https://pub.dev/packages/dart_mutant) for that and judges its report. `test-gates.json` is read as before.

1. Nothing is installed for the tool: `mutation` fetches `dart_mutant` (0.2.1 or a later 0.2.x; it needs Dart 3.11 or later) the first time it runs in a package. See [Where `dart_mutant` comes from](#where-dart_mutant-comes-from).
2. A test command that was given behind `--` now goes behind a second one: `test_gates mutation -- fvm flutter test --no-pub` becomes `test_gates mutation -- -- fvm flutter test --no-pub`. What follows the first `--` are options of `dart_mutant run` (`--jobs`, `--shard`, `--html`). The old form is refused with exit code 2.
3. Run `test_gates mutation --force` once. The mutators of 0.1 make the same mutants as before, so every `equivalentMutants` and `expectedTimeouts` entry still matches. **New survivors are to be expected**: `dart_mutant` also changes members and numbers by their types (`MethodExpression`, `NumberLiteral`, the guard mutators, see [Mutators](#mutators)), which 0.1 did not. Each is a decision no test checked. Fix the test; allow only what no input can observe.
4. Run `test_gates check`. It is stricter than in 0.1: the imports of a gate are followed into the files of the package ([What a gate reaches](#what-a-gate-reaches)), more packages are impure by default ([What a gate must not import](#what-a-gate-must-not-import)), and a misspelt key in an `equivalentMutants` entry is a violation. One change goes the other way: a pattern of `settings.forbiddenSource.add` no longer sees comments, so a rule that was written to catch a comment matches nothing now, without a message. For a file that is fine although the check says otherwise, there is `settings.impureImports.allow`. Look at the patterns that are there already: one without `^` and `$` is tried on every import of every file on the way, and stops the following wherever it matches.
5. Delete `.dart_tool/test_gates/mutation/`. The results and backups that 0.1 kept there are no longer read. (When a run of 0.1 was killed, `git diff` shows the mutant it left in a gate: put the gate back first.)
6. Replace the list of commands in the hook and in CI by one: `dart run test_gates all` before a push, `dart run test_gates all --selfcheck --force` in CI ([`all`](#test_gates-all---selfcheck---force---no-mutation)). It runs `check`, `test`, `timezones` and `mutation` in one start and stops at the first that fails, so it is what a script with `set -e` did, with one difference: [`timezones`](#test_gates-timezones---zone-name---all----command) is new, and is part of it. Where `dart_mutant` cannot run (a Dart older than 3.11), `all --no-mutation`. With `"spec": { "suffixes": [] }` (no convention for where the tests are), `timezones` and `mutation` fail for every gate, and so does `all`: call `check` and `test` by themselves. The commands can still be called one by one.

What else changed: the lines per gate are printed by `dart_mutant`; the gates are no longer changed in place, where the package can be run from a copy; `mutation-result` refuses the report of a part of a run; exit code 2 also means that the tool could not be fetched; `check`, `lcov` and `mutation-result` end with a line and exit code 1, not with an unhandled error, when a file cannot be read. New and optional: `test --selfcheck` (the negative control in the run of the tests that `test` makes anyway), `--not-evaluable` for `mutation` and `mutation-result`.

## Relation to `@t09tanaka/test-gates`

| | npm `@t09tanaka/test-gates` | Dart `test_gates` |
| --- | --- | --- |
| File | `test-gates.json` | the same file, the same keys |
| Unknown keys | rejected (exit code 2) | rejected in the same places, and in an entry of `equivalentMutants` / `expectedTimeouts` (exit code 1) |
| Imports of a gate | the gate's own | followed into the files of the package ([What a gate reaches](#what-a-gate-reaches)) |
| `forbiddenSource.add` | tested against the text of a line | tested against the code of a line: a comment does not match |
| Default `gateExtensions` | `.ts .mts .cts .js .mjs .cjs` | `.dart` |
| `lcov` | lines only (`LH == LF` from `DA:`) | lines **and branches** |
| `lcov` output | passing gates listed with `✓` | the same, plus `✗` lines with the numbers of failing gates |
| `check` | text and regular expressions; rejects decorators | syntax tree (`package:analyzer`); annotations are fine, blocks sharing a line are rejected |
| Where the test of a gate is | `.spec<ext>` / `.test<ext>` next to the gate | `_test<ext>` next to the gate or under `test/` |
| Built-in impure imports | Node.js, NestJS, React, Vue, database clients, SDKs | Flutter, `dart:io` / `dart:ui` / browser, HTTP, persistence, state management |
| `forbiddenSource` defaults | `'use client'` / `'use server'`, `process.env` | reads of the environment, found in the syntax |
| Tests + coverage in one command | `npm run test:gates` (a script the project writes) | `test_gates test`; with `--selfcheck` the negative control in the same run |
| `gateCommand` | the gate: its exit code is the verdict | runs the tests and writes the tracefile; the verdict comes from the tracefile |
| Tests in other time zones | none | `timezones` |
| Several checks in one start | none (the scripts of `package.json` call the commands) | `all` |
| Negative control (`selfcheck`) | leaves out the test of a gate; one run per gate | appends unexecuted code to the gates; one run for all |
| Mutation testing | `mutation` runs Stryker, `mutation-result` judges its JSON report | `mutation` runs `dart_mutant`, `mutation-result` judges its JSON report; the same report schema, the same judgement and allow list |
| The mutation tool | a development dependency of the project (`@stryker-mutator/core`), with a configuration file (`stryker.gates.config.mjs`) | a program of its own, which `mutation` fetches from pub.dev, given a plan that `mutation` makes from `test-gates.json`; no configuration file |
| Arguments `mutation` does not know | handed to Stryker | what follows `--` is handed to `dart_mutant run` |
| Report file | `settings.stryker.reportFile` | the same key |
| Results of the last run | Stryker's incremental file; with `--affected`, per gate by what the gate and its specs import | per gate by what the gate and its tests import, always (`.dart_tool/test_gates/mutation-record.json`); `--force` and `CI` run everything |
| Safe defaults | 0.3.3 (`mutation.maxTimeouts: 0`, no overall threshold) | the same |

`npx test-gates lcov` works on a Dart package too, and checks lines only. Use this package when the repository has no Node.js, or when branches should count.

## Development

```bash
dart pub get
dart format --output=none --set-exit-if-changed .
dart analyze --fatal-infos
dart test
```

The decisions live in `lib/src/` as pure functions (text in, verdict out): `manifest.dart`, `settings.dart`, `lcov.dart`, `selfcheck.dart`, `zones.dart`, `args.dart`, for `check` `dart_source.dart`, `scan.dart`, `import_policy.dart`, `spec_path.dart`, `gate_path.dart`, `pubspec.dart`, `json.dart`, and for `mutation` `mutation_run.dart` (how `dart_mutant` is fetched and started, the supported versions, the plan, the arguments, and which of its exit codes leave the verdict to the report) and `mutation_result.dart` (the judgement, a port of upstream's `mutation-result.ts` with its test cases). `dart_source.dart` is the only file that touches `package:analyzer`. Reading and writing files, starting processes and printing are in `lib/src/io/` and `lib/src/commands/`.

The tests of `test`, `selfcheck`, `timezones`, `mutation` and `all` start processes: stand-ins for the coverage command, for the test runner, for `dart_mutant` and for the command that fetches it (`test/fixtures/selfcheck/fake_coverage.dart.txt`, `test/fixtures/zones/fake_zone_test.dart.txt`, `test/fixtures/mutation/fake_dart_mutant.dart.txt`, `fake_fetch.dart.txt`) and, in `test/commands/real_coverage_test.dart`, `real_timezones_test.dart` and `real_mutation_test.dart`, `dart test` and `dart_mutant` itself on a small package that is copied to a temporary directory and resolved with `dart pub get --offline`. The test with `dart_mutant` itself fetches the tool from pub.dev as `mutation` does; it runs only when `TEST_GATES_REQUIRE_DART_MUTANT=1` is set, as it is in the workflow, and is skipped otherwise.

### The gates of this package

The pure files above are the gates of this package: [`test-gates.json`](test-gates.json) lists them, with what each decides, and the files that are not gates as `candidates`, with the reason. The tool is run on itself, as upstream is:

```bash
dart run test_gates check             # no test is run
dart run test_gates test --selfcheck  # the whole test suite with coverage, once, with a probe in every gate
                                      # (or the two apart: test, then selfcheck)
dart run test_gates timezones         # the test of zones.dart, the one gate that names DateTime, in two zones
dart run test_gates mutation          # only the gates whose files changed since the last run
dart run test_gates mutation --gate lib/src/lcov.dart   # one gate, while working on it
dart run test_gates mutation --force  # everything, before a release
dart run test_gates all --selfcheck   # check, test --selfcheck, timezones and mutation in one start
```

- The test of `lib/src/x.dart` is `test/x_test.dart` (`settings.spec.rewrite`), and `mutation` runs only that file. A case that kills a mutant of `x.dart` belongs there, not in `test/commands/`.
- The import check is in allowlist mode: a gate imports `dart:` libraries of the built-in list, other files of `lib/src/`, and `package:analyzer`. Nothing else.
- A survivor is fixed with a test. `equivalentMutants` is for a mutant that no input can tell apart from the original, with the reason: at present two in `json.dart` and two in `selfcheck.dart`. Code that does nothing is deleted, not allowed. `expectedTimeouts` has the mutants that make a loop endless.
- Where `dart_mutant` changes the gates in place ([Your files during the run](#your-files-during-the-run)), the gates are the code that is running. `dart run` compiles the tool before the first mutant goes in, so this works; do not start a second `dart run` in the package while it runs.

CI runs `check`, `test --selfcheck` and `timezones --all` on Dart 3.9.0 and on stable (which lines carry a branch entry is decided by the SDK), and `mutation --force` on stable only: `dart_mutant` needs a newer Dart than 3.9, and the verdict on a mutant does not depend on the SDK. It is split into one job per gate with [`--gate`](#one-gate-at-a-time---gate); the jobs are made from `test-gates.json`, and the job `Mutation test of the gates` is green when all of them are. A job on macOS runs the tests of `timezones`, which depend on how the system gives a process its time zone.

## Related tools

- [test-gates](https://github.com/t09tanaka/test-gates) (npm `@t09tanaka/test-gates`): the same gates for JavaScript and TypeScript, with Stryker as the mutation tool.
- [dart_mutant](https://github.com/t09tanaka/dart_mutant) (pub.dev): mutation testing for Dart, the tool that runs the mutants these gates judge.
- [contract-fixtures](https://github.com/t09tanaka/contract-fixtures) (TypeScript and Dart): shared request and response fixtures that keep an API and its clients in step.

## License

MIT
