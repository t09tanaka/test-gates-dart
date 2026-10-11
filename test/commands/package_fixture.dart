import 'dart:convert';
import 'dart:io';

import 'package:test_gates/src/commands/output.dart';

/// A package in a temporary directory, with what the commands print.
class PackageFixture {
  PackageFixture() : dir = Directory.systemTemp.createTempSync('test_gates_') {
    File(
      'test/fixtures/selfcheck/fake_coverage.dart.txt',
    ).copySync('${dir.path}/fake_coverage.dart');
  }

  final Directory dir;
  final out = <String>[];
  final err = <String>[];

  Io get io => Io(out: out.add, err: err.add);

  void delete() => dir.deleteSync(recursive: true);

  File file(String path) => File('${dir.path}/$path');

  void write(String path, String content) => file(path)
    ..createSync(recursive: true)
    ..writeAsStringSync(content);

  String read(String path) => file(path).readAsStringSync();

  /// Writes test-gates.json with one gate per path.
  void manifest(List<String> gates, {Map<String, Object?>? settings}) => write(
    'test-gates.json',
    jsonEncode({
      'gates': [
        for (final path in gates) {'path': path, 'decides': 'd', 'impact': 'i'},
      ],
      'settings': {
        'lcov': {'file': 'coverage/lcov.info'},
        ...?settings,
      },
    }),
  );

  /// The stand-in for `flutter test --coverage --branch-coverage`, see
  /// test/fixtures/selfcheck/fake_coverage.dart.txt.
  List<String> fake(String mode, List<String> sources) => [
    Platform.resolvedExecutable,
    'fake_coverage.dart',
    mode,
    'coverage/lcov.info',
    ...sources,
  ];
}
