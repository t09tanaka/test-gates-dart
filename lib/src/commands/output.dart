import '../types.dart';

/// Where a command writes. Injected, so that commands can be tested.
///
/// The output of the commands that `test` and `mutation` start (the test
/// runner, `dart_mutant`) does not go through here: it is written to the
/// standard output and error of the process as it comes.
class Io {
  /// Writes results with [out] and violations and errors with [err], one
  /// call per line. The command line passes `stdout.writeln` and
  /// `stderr.writeln`.
  const Io({required this.out, required this.err});

  /// Receives the lines of the result: what passed, and the summary.
  final void Function(String line) out;

  /// Receives the lines that say what is wrong: violations, wrong usage, an
  /// unusable `test-gates.json`.
  final void Function(String line) err;
}

/// The name users type. Upstream prints `test-gates`.
const executable = 'test_gates';

void printViolations(Io io, String title, List<Violation> violations) {
  io.err('$executable $title: ${violations.length} violation(s)');
  for (final violation in violations) {
    io.err('  - $violation');
  }
}

/// The last lines of what a command printed, indented, for showing why it
/// failed.
String tailOf(String output) {
  final lines = output.trimRight().split('\n');
  return lines
      .skip(lines.length > 25 ? lines.length - 25 : 0)
      .map((line) => '      $line')
      .join('\n');
}
