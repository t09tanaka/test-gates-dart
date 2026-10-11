import 'package:test/test.dart';
import 'package:test_gates/src/gate_path.dart';
import 'package:test_gates/src/pubspec.dart';

void main() {
  group('isPlainRelativePath', () {
    test('relative, with "/"', () {
      expect(isPlainRelativePath('lib/models/shipping_fee.dart'), isTrue);
      expect(isPlainRelativePath('shipping_fee.dart'), isTrue);
      expect(isPlainRelativePath('lib/..a/b.dart'), isTrue);
    });

    test('everything else', () {
      for (final path in [
        '/abs/shipping_fee.dart',
        r'C:\app\shipping_fee.dart',
        'c:/app/shipping_fee.dart',
        r'lib\shipping_fee.dart',
        '../other/lib/shipping_fee.dart',
        'lib/../shipping_fee.dart',
        './lib/shipping_fee.dart',
        'lib/./shipping_fee.dart',
        'lib//shipping_fee.dart',
        'lib/',
      ]) {
        expect(isPlainRelativePath(path), isFalse, reason: path);
      }
    });
  });

  group('packageNameOf', () {
    test('the top-level name', () {
      expect(packageNameOf('name: app\nversion: 1.0.0\n'), 'app');
      expect(
        packageNameOf('# c\ndescription: x\nname:   my_app  # the app\n'),
        'my_app',
      );
      expect(packageNameOf('name: "app"\r\nversion: 1.0.0\r\n'), 'app');
      expect(packageNameOf("name: 'app'"), 'app');
      expect(packageNameOf('\uFEFFname: app\n'), 'app');
    });

    test('no name', () {
      expect(packageNameOf(''), isNull);
      expect(packageNameOf('dependencies:\n  name: x\n'), isNull);
      expect(packageNameOf('names: app\n'), isNull);
      expect(packageNameOf('name: 1app\n'), isNull);
      expect(packageNameOf('name: "app\n'), isNull);
    });
  });
}
