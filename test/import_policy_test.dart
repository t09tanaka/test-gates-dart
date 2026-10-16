import 'package:test/test.dart';
import 'package:test_gates/src/dart_source.dart';
import 'package:test_gates/src/import_policy.dart';
import 'package:test_gates/src/settings.dart';
import 'package:test_gates/src/types.dart';

ImportRef ref(String uri, [List<String>? shown]) => ImportRef(
  kind: DirectiveKind.import,
  uri: uri,
  line: 1,
  conditional: false,
  shown: shown,
);

void main() {
  final own = aliasesFor('app', const []);

  group('aliasesFor', () {
    test('the package itself comes first', () {
      final aliases = aliasesFor('app', const [ImportAlias('@/', 'lib/src/')]);
      expect(aliases.map((alias) => '${alias.prefix} -> ${alias.target}'), [
        'package:app/ -> lib/',
        '@/ -> lib/src/',
      ]);
    });

    test('without a pubspec only the configured aliases', () {
      expect(aliasesFor(null, const []), isEmpty);
    });
  });

  group('isProjectImport', () {
    test('relative URIs and the package itself', () {
      expect(isProjectImport('shipping_fee.dart', own), isTrue);
      expect(isProjectImport('../utils/number.dart', own), isTrue);
      expect(isProjectImport('./a.dart', own), isTrue);
      expect(
        isProjectImport('package:app/models/shipping_fee.dart', own),
        isTrue,
      );
    });

    test('other packages and the SDK', () {
      expect(isProjectImport('package:apple/a.dart', own), isFalse);
      expect(isProjectImport('package:dio/dio.dart', own), isFalse);
      expect(isProjectImport('dart:math', own), isFalse);
      expect(isProjectImport('package:app/a.dart', const []), isFalse);
    });
  });

  group('resolveUri', () {
    test('relative to the importing file', () {
      expect(resolveUri('b.dart', 'lib/a/a.dart', own), 'lib/a/b.dart');
      expect(resolveUri('./b.dart', 'lib/a/a.dart', own), 'lib/a/b.dart');
      expect(resolveUri('../b.dart', 'lib/a/a.dart', own), 'lib/b.dart');
      expect(resolveUri('x/../b.dart', 'a.dart', own), 'b.dart');
      // Above the package: the path keeps its "..", and is no file of it.
      expect(resolveUri('../../b.dart', 'lib/a.dart', own), '../b.dart');
      expect(resolveUri('../../../b.dart', 'lib/a.dart', own), '../../b.dart');
      expect(resolveUri('../b.dart', 'a.dart', own), '../b.dart');
      expect(resolveUri('../x/../../b.dart', 'lib/a.dart', own), '../b.dart');
      expect(resolveUri('../x/../b.dart', 'lib/a.dart', own), 'b.dart');
      expect(resolveUri('../x/../b.dart', 'a.dart', own), '../b.dart');
      expect(resolveUri('../x/y/../b.dart', 'a.dart', own), '../x/b.dart');
    });

    test('through the package and through an alias', () {
      expect(
        resolveUri('package:app/m/c.dart', 'lib/a.dart', own),
        'lib/m/c.dart',
      );
      expect(
        resolveUri('@/c.dart', 'lib/a.dart', const [
          ImportAlias('@/', 'lib/src/'),
        ]),
        'lib/src/c.dart',
      );
    });

    test('another package or the SDK: null', () {
      expect(resolveUri('package:dio/dio.dart', 'lib/a.dart', own), isNull);
      expect(resolveUri('dart:io', 'lib/a.dart', own), isNull);
    });
  });

  group('judgePackageImport', () {
    test('what is built in needs no entry', () {
      for (final uri in [
        'dart:core',
        'dart:async',
        'dart:collection',
        'dart:convert',
        'dart:math',
        'dart:typed_data',
        'package:collection/collection.dart',
        'package:json_annotation/json_annotation.dart',
        'package:meta/meta.dart',
      ]) {
        expect(judgePackageImport(ref(uri), const []), isNull, reason: uri);
      }
    });

    test('everything else has to be listed, the rest of the SDK too', () {
      for (final uri in [
        'dart:io',
        'dart:developer',
        'dart:mathx',
        'package:collection_x/a.dart',
        'package:decimal/decimal.dart',
      ]) {
        expect(
          judgePackageImport(ref(uri), const []),
          'import of "$uri" is not in settings.imports.allow (allowlist mode '
          'allows the package\'s own files and listed libraries only)',
        );
      }
    });

    test('a string covers the library and what is below it', () {
      const allow = [ImportAllowRule(module: 'package:decimal')];
      expect(
        judgePackageImport(ref('package:decimal/decimal.dart'), allow),
        isNull,
      );
      expect(judgePackageImport(ref('package:decimal'), allow), isNull);
      expect(
        judgePackageImport(ref('package:decimal_x/a.dart'), allow),
        isNotNull,
      );
      expect(
        judgePackageImport(ref('dart:developer'), const [
          ImportAllowRule(module: 'dart:developer'),
        ]),
        isNull,
      );
    });

    test('a pattern is tested against the whole URI', () {
      final allow = [ImportAllowRule(regex: RegExp('^package:acme_'))];
      expect(
        judgePackageImport(ref('package:acme_money/a.dart'), allow),
        isNull,
      );
      expect(judgePackageImport(ref('package:x/acme_.dart'), allow), isNotNull);
    });

    test('names: only those, and only with show', () {
      const allow = [
        ImportAllowRule(
          module: 'package:intl/intl.dart',
          names: ['NumberFormat'],
        ),
        ImportAllowRule(module: 'package:intl', names: ['DateFormat']),
      ];
      const uri = 'package:intl/intl.dart';
      expect(judgePackageImport(ref(uri, ['NumberFormat']), allow), isNull);
      expect(
        judgePackageImport(ref(uri, ['DateFormat', 'NumberFormat']), allow),
        isNull,
      );
      expect(
        judgePackageImport(ref(uri), allow),
        'only NumberFormat, DateFormat may be imported from '
        '"package:intl/intl.dart", with show (settings.imports.allow)',
      );
      expect(
        judgePackageImport(ref(uri, ['NumberFormat', 'Intl', 'Bidi']), allow),
        'import of Intl, Bidi from "package:intl/intl.dart" is not in '
        'settings.imports.allow (allowed: NumberFormat, DateFormat)',
      );
    });

    test('an entry of the project narrows what is built in', () {
      const allow = [
        ImportAllowRule(module: 'dart:math', names: ['max']),
      ];
      expect(judgePackageImport(ref('dart:math', ['max']), allow), isNull);
      expect(judgePackageImport(ref('dart:math'), allow), isNotNull);
      expect(
        judgePackageImport(ref('dart:math', ['Random']), allow),
        isNotNull,
      );
      expect(judgePackageImport(ref('dart:convert'), allow), isNull);
    });

    test('an entry without names opens the whole library', () {
      const allow = [
        ImportAllowRule(module: 'package:intl', names: ['DateFormat']),
        ImportAllowRule(module: 'package:intl'),
      ];
      expect(judgePackageImport(ref('package:intl/intl.dart'), allow), isNull);
    });
  });

  group('judgeProjectImport', () {
    final impurePaths = resolveSettings({
      'impurePaths': {
        'add': [
          {'pattern': '^lib/blocs/', 'reason': 'bloc'},
        ],
      },
    }).impurePaths;

    test('a file that could not be a gate', () {
      expect(judgeProjectImport('lib/blocs/basket.dart', impurePaths), 'bloc');
      expect(judgeProjectImport('lib/a.g.dart', impurePaths), 'generated file');
    });

    test('a file that could', () {
      expect(judgeProjectImport('lib/models/basket.dart', impurePaths), isNull);
    });
  });

  test('isGeneratedPart', () {
    expect(isGeneratedPart('shipping_fee.g.dart'), isTrue);
    expect(isGeneratedPart('src/shipping_fee.g.dart'), isTrue);
    expect(isGeneratedPart('shipping_fee.freezed.dart'), isTrue);
    expect(isGeneratedPart('shipping_fee.gr.dart'), isFalse);
    expect(isGeneratedPart('shipping_fee_g.dart'), isFalse);
    expect(isGeneratedPart('shipping_fee.g.dart.txt'), isFalse);
  });
}
