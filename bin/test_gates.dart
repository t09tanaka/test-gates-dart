import 'dart:io';

import 'package:test_gates/test_gates.dart';

Future<void> main(List<String> arguments) async {
  exitCode = await runAsync(
    arguments,
    Io(out: stdout.writeln, err: stderr.writeln),
  );
}
