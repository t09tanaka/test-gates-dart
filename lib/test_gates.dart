/// Test gates for the Dart and Flutter code that must not be wrong.
///
/// The package is a command-line tool, and the command line is the supported
/// interface:
///
/// ```bash
/// dart run test_gates check
/// dart run test_gates test
/// dart run test_gates selfcheck
/// dart run test_gates mutation
/// ```
///
/// This library is that command line as a function, for a Dart script (a
/// `tool/` script, a git hook written in Dart) that wants to run it without
/// starting another process:
///
/// ```dart
/// import 'dart:io';
///
/// import 'package:test_gates/test_gates.dart';
///
/// Future<void> main() async {
///   exitCode = await runAsync([
///     'check',
///   ], Io(out: stdout.writeln, err: stderr.writeln));
/// }
/// ```
///
/// What the commands are built from (`package:test_gates/src/...`) is not
/// part of the interface and changes without notice.
library;

export 'src/cli.dart' show runAsync;
export 'src/commands/output.dart' show Io;
export 'src/version.dart' show packageVersion;
