import 'package:test/test.dart';
import 'package:test_gates/src/pubspec.dart';

void main() {
  test('the name of a pubspec', () {
    expect(packageNameOf('name: app\nversion: 1.0.0\n'), 'app');
    expect(packageNameOf('description: x\nname: my_app2\n'), 'my_app2');
    expect(packageNameOf('name: _private'), '_private');
  });

  test('quoted, with spaces and with a comment', () {
    expect(packageNameOf("name: 'app'\n"), 'app');
    expect(packageNameOf('name: "app"\n'), 'app');
    expect(packageNameOf('name:\tapp \t# the app\n'), 'app');
    expect(packageNameOf('name:app\n'), 'app');
  });

  test('CRLF line ends and a byte order mark', () {
    expect(packageNameOf('name: app\r\nversion: 1.0.0\r\n'), 'app');
    expect(packageNameOf('﻿name: app\n'), 'app');
  });

  test('null when there is no top-level name', () {
    expect(packageNameOf(''), isNull);
    expect(packageNameOf('version: 1.0.0\n'), isNull);
    expect(packageNameOf('dependencies:\n  name: app\n'), isNull);
    expect(packageNameOf('name: \'app"\n'), isNull);
    expect(packageNameOf('name: 2app\n'), isNull);
    expect(packageNameOf('name: my-app\n'), isNull);
    expect(packageNameOf('name: app extra\n'), isNull);
    expect(packageNameOf('# name: app\n'), isNull);
  });
}
