# test_gates example

A package with two gates. `lib/bulk_discount.dart` and `lib/shipping_fee.dart` decide what a customer pays, so they are listed in [`test-gates.json`](test-gates.json). `bin/estimate.dart` uses them and prints; it is listed as a candidate, with what keeps it from being a gate.

```bash
dart pub get
dart pub global activate dart_mutant '^0.2.0'   # once per machine: the tool that `mutation` starts
dart run test_gates check       # the gates exist, have their tests, and are pure modules
dart run test_gates test        # dart test with coverage: 100% lines and branches of the gates
dart run test_gates selfcheck   # with unexecuted code in it, a gate fails
dart run test_gates timezones   # the tests in other time zones (nothing to run here: no gate names DateTime)
dart run test_gates mutation    # every small change to a gate is noticed by a test
```

```
test_gates check: OK (2 gate(s), 1 candidate(s))
```

Things to try:

- Remove the test `never charges more than the maximum` from [`test/shipping_fee_test.dart`](test/shipping_fee_test.dart). `test` fails: the block that limits the fee is never executed (`2/3 branches taken`).
- Remove the expectation for 50 items from [`test/bulk_discount_test.dart`](test/bulk_discount_test.dart). `test` still passes, at 100%: every line and block is executed by the other cases. `mutation` fails and names the changes that nothing notices any more (`>=` → `>` and `50` → `51` in `quantity >= 50`).
- Add `import 'dart:io';` to [`lib/shipping_fee.dart`](lib/shipping_fee.dart). `check` rejects it: a gate is a pure module.
- Remove both `equivalentMutants` from `test-gates.json`. `mutation` fails with the two mutants that no test can notice (`>` → `>=` where the fee is limited to the maximum, and `50` → `51` where the discount is rounded), and prints the entries to put back.

All of them in one start: `dart run test_gates all`. [`tool/test_gates.dart`](tool/test_gates.dart) is the entry point for compiling the tool into an executable (`dart compile exe tool/test_gates.dart -o build/test_gates`), which starts faster still; the README of the package says when that is worth it.

In a package of your own, `test_gates` is a development dependency from pub.dev (`dart pub add --dev test_gates`), not a path.
