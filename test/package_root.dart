import 'dart:io';
import 'dart:isolate';

/// The root of this package, found from where `package:test_gates` is and
/// not from the working directory.
///
/// `dart test` runs every test file of the run in one process, and the
/// working directory belongs to the process: a test that read the files of
/// this package relative to it would read those of another directory as soon
/// as anything changed it. No test changes it (see
/// working_directory_test.dart), and none relies on it either.
final String packageRoot = File.fromUri(
  Isolate.resolvePackageUriSync(
    Uri.parse('package:test_gates/test_gates.dart'),
  )!,
).parent.parent.path;

/// [path], relative to the root of this package, as an absolute path.
String inPackage(String path) => '$packageRoot/$path';
