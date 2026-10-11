import 'package:test/test.dart';
import 'package:test_gates/src/settings.dart';
import 'package:test_gates/src/spec_path.dart';

void main() {
  final defaults = resolveSettings(<String, Object?>{});

  group('gateExtensionOf', () {
    test('the longest configured extension wins', () {
      expect(gateExtensionOf('lib/a.dart', ['.dart']), '.dart');
      expect(gateExtensionOf('lib/a.g.dart', ['.dart', '.g.dart']), '.g.dart');
      expect(gateExtensionOf('lib/a.g.dart', ['.g.dart', '.dart']), '.g.dart');
      expect(gateExtensionOf('lib/a.ts', ['.dart']), isNull);
      // An empty string is not an extension, although every path ends
      // with it.
      expect(gateExtensionOf('lib/a.ts', ['']), isNull);
    });
  });

  group('specCandidatesFor', () {
    test('default: next to the gate, or the mirror under test/', () {
      expect(specCandidatesFor('lib/a/b.dart', defaults), [
        'lib/a/b_test.dart',
        'test/a/b_test.dart',
      ]);
    });

    test('a gate outside lib/ has no mirror', () {
      expect(specCandidatesFor('bin/tool.dart', defaults), [
        'bin/tool_test.dart',
      ]);
      expect(specCandidatesFor('packages/a/lib/b.dart', defaults), [
        'packages/a/lib/b_test.dart',
      ]);
    });

    test('not a gate extension: nothing', () {
      expect(specCandidatesFor('lib/a.ts', defaults), isEmpty);
    });

    test('suffixes: [] means no spec convention', () {
      final settings = resolveSettings({
        'gateExtensions': ['.dart'],
        'spec': {'suffixes': <String>[]},
      });
      expect(
        specCandidatesFor('lib/models/shipping_fee.dart', settings),
        isEmpty,
      );
    });

    test('suffixes replace the default, in both directories', () {
      final settings = resolveSettings({
        'spec': {
          'suffixes': ['_spec.dart', '.test.dart'],
        },
      });
      expect(specCandidatesFor('lib/a.dart', settings), [
        'lib/a_spec.dart',
        'lib/a.test.dart',
        'test/a_spec.dart',
        'test/a.test.dart',
      ]);
    });

    test('rewrite replaces the two default directories', () {
      final mirrorOnly = resolveSettings({
        'spec': {
          'rewrite': [
            {'from': '^lib/', 'to': 'test/'},
          ],
        },
      });
      expect(specCandidatesFor('lib/a/b.dart', mirrorOnly), [
        'test/a/b_test.dart',
      ]);
      final nextToTheGate = resolveSettings({
        'spec': {'rewrite': <Object>[]},
      });
      expect(specCandidatesFor('lib/a/b.dart', nextToTheGate), [
        'lib/a/b_test.dart',
      ]);
    });

    test('rewrites are applied one after the other, with groups', () {
      final settings = resolveSettings({
        'spec': {
          'suffixes': ['_test.dart'],
          'rewrite': [
            {'from': r'^lib/(\w+)/', 'to': r'test/unit/$1/'},
            {'from': 'unit/models', 'to': 'unit/model'},
          ],
        },
      });
      expect(specCandidatesFor('lib/models/shipping_fee.dart', settings), [
        'test/unit/model/shipping_fee_test.dart',
      ]);
    });
  });

  group('replaceFirstLikeJs', () {
    test('only the first match', () {
      expect(replaceFirstLikeJs('a/a/a', RegExp('a'), 'b'), 'b/a/a');
      expect(replaceFirstLikeJs('x', RegExp('a'), 'b'), 'x');
    });

    test(r'$1, $&, $$ and an index that is not a group', () {
      final regex = RegExp(r'(\w+)-(\w+)?');
      expect(replaceFirstLikeJs('ab-cd!', regex, r'$2-$1'), 'cd-ab!');
      expect(replaceFirstLikeJs('ab-!', regex, r'[$2|$1]'), '[|ab]!');
      expect(replaceFirstLikeJs('ab-cd', regex, r'<$&>'), '<ab-cd>');
      expect(replaceFirstLikeJs('ab-cd', regex, r'$$1'), r'$1');
      expect(replaceFirstLikeJs('ab-cd', regex, r'$3 $0'), r'$3 $0');
    });
  });

  group('looksLikeSpec', () {
    test('the default suffix', () {
      expect(looksLikeSpec('lib/a_test.dart', defaults), isTrue);
      expect(looksLikeSpec('test/a_test.dart', defaults), isTrue);
      expect(looksLikeSpec('lib/a.dart', defaults), isFalse);
      expect(looksLikeSpec('lib/latest.dart', defaults), isFalse);
      expect(looksLikeSpec('lib/a_test.ts', defaults), isFalse);
    });

    test('configured suffixes; none means nothing looks like a test', () {
      final spec = resolveSettings({
        'spec': {
          'suffixes': ['_spec.dart'],
        },
      });
      expect(looksLikeSpec('lib/a_spec.dart', spec), isTrue);
      expect(looksLikeSpec('lib/a_test.dart', spec), isFalse);
      final none = resolveSettings({
        'spec': {'suffixes': <String>[]},
      });
      expect(looksLikeSpec('lib/a_test.dart', none), isFalse);
    });
  });
}
