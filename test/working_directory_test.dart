import 'dart:io';

import 'package:test/test.dart';

import 'package_root.dart';

/// `dart test` runs the test files side by side in one process, and the
/// working directory belongs to the whole process: a test that changed it
/// would move it under the feet of every other test that is running.
void main() {
  test('no test, and nothing in lib/ or bin/, sets the working directory', () {
    final setting = RegExp(r'Directory\.current\s*=(?!=)');
    final found = [
      for (final dir in ['bin', 'lib', 'test'])
        for (final file in Directory(
          inPackage(dir),
        ).listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart') &&
              setting.hasMatch(file.readAsStringSync()))
            file.path.substring(packageRoot.length + 1),
    ];
    expect(found, isEmpty);
  });
}
