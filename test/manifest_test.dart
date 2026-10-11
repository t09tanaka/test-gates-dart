import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/manifest.dart';

const gate = {'path': 'lib/a.dart', 'decides': 'd', 'impact': 'i'};

ParsedManifest parse(Object? json) => parseManifest(jsonEncode(json));

List<String> messages(Object? json) => [
  for (final violation in parse(json).violations) violation.toString(),
];

Matcher manifestError(String message) => throwsA(
  isA<ManifestError>().having((error) => error.message, 'message', message),
);

void main() {
  group('a manifest that cannot be used at all', () {
    test('invalid JSON', () {
      expect(
        () => parseManifest('{'),
        throwsA(
          isA<ManifestError>().having(
            (error) => error.toString(),
            'message',
            startsWith('test-gates.json is not valid JSON: '),
          ),
        ),
      );
    });

    test('not an object', () {
      for (final json in [<Object>[], 'x', 1, null]) {
        expect(
          () => parse(json),
          manifestError('test-gates.json must be a JSON object'),
        );
      }
    });

    test('gates missing or not an array', () {
      for (final json in [
        <String, Object?>{},
        {'gates': null},
        {'gates': <String, Object?>{}},
      ]) {
        expect(
          () => parse(json),
          manifestError('test-gates.json: "gates" must be an array'),
        );
      }
    });

    test('candidates present but not an array', () {
      for (final candidates in [null, 'x', <String, Object?>{}]) {
        expect(
          () => parse({
            'gates': [gate],
            'candidates': candidates,
          }),
          manifestError('test-gates.json: "candidates" must be an array'),
        );
      }
    });

    test('unknown top-level key', () {
      expect(
        () => parse({
          'gates': [gate],
          'gate"s': <Object>[],
        }),
        manifestError(r'test-gates.json: unknown top-level key "gate\"s"'),
      );
    });
  });

  group('a usable manifest', () {
    test('reads gates, candidates and the raw settings', () {
      final manifest = parse({
        r'$schema': './schema.json',
        'gates': [gate],
        'candidates': [
          {'path': 'lib/b.dart', 'decides': 'd', 'blocker': 'b'},
        ],
        'settings': {'lcov': <String, Object?>{}},
      });
      expect(manifest.violations, isEmpty);
      final read = manifest.gates.single;
      expect((read.path, read.decides, read.impact), ('lib/a.dart', 'd', 'i'));
      expect(read.equivalentMutants, isEmpty);
      expect(read.expectedTimeouts, isEmpty);
      final candidate = manifest.candidates.single;
      expect(
        (candidate.path, candidate.decides, candidate.blocker),
        ('lib/b.dart', 'd', 'b'),
      );
      expect(manifest.settings, {'lcov': <String, Object?>{}});
    });

    test('candidates and settings may be omitted', () {
      final manifest = parse({
        'gates': [gate],
      });
      expect(manifest.violations, isEmpty);
      expect(manifest.candidates, isEmpty);
      expect(manifest.settings, <String, Object?>{});
    });

    test('settings: null is kept, for resolveSettings to reject', () {
      expect(
        parse({
          'gates': [gate],
          'settings': null,
        }).settings,
        isNull,
      );
    });

    test('accepts unknown keys inside a gate and a candidate', () {
      // Upstream does not reject them (schema: additionalProperties true).
      expect(
        messages({
          'gates': [
            {...gate, 'note': 'x'},
          ],
          'candidates': [
            {'path': 'b', 'decides': 'd', 'blocker': 'b', 'note': 'x'},
          ],
        }),
        isEmpty,
      );
    });

    test('reads a manifest written for a Flutter app as it is', () {
      final manifest = parseManifest(
        File(
          'test/fixtures/manifest/flutter-coverage-only.test-gates.json',
        ).readAsStringSync(),
      );
      expect(manifest.violations, isEmpty);
      expect(manifest.gates.map((gate) => gate.path), [
        'lib/models/shipping_fee.dart',
        'lib/utils/weight_units.dart',
      ]);
      expect(manifest.gates.first.decides, '送料の計算');
    });
  });

  group('violations inside the manifest', () {
    test('empty gates', () {
      expect(messages({'gates': <Object>[]}), [
        'test-gates.json: gates is empty. A project with nothing to gate '
            'should not have this file',
      ]);
    });

    test('an entry that is not an object, or has no path', () {
      final manifest = parse({
        'gates': [
          'lib/a.dart',
          {'decides': 'd', 'impact': 'i'},
          {'path': ' ', 'decides': 'd', 'impact': 'i'},
          {'path': 1},
          gate,
        ],
        'candidates': [null],
      });
      expect(manifest.violations.map((violation) => '$violation'), [
        'test-gates.json: gates[0] must be an object',
        'test-gates.json: gates[1]: "path" is missing',
        'test-gates.json: gates[2]: "path" is missing',
        'test-gates.json: gates[3]: "path" is missing',
        'test-gates.json: candidates[0] must be an object',
      ]);
      expect(manifest.gates.single.path, 'lib/a.dart');
    });

    test('missing fields keep the entry usable', () {
      final manifest = parse({
        'gates': [
          {'path': 'lib/a.dart', 'decides': '  ', 'impact': 3},
        ],
        'candidates': [
          {'path': 'lib/b.dart'},
        ],
      });
      expect(manifest.violations.map((violation) => '$violation'), [
        'test-gates.json: lib/a.dart: "decides" is missing in gates',
        'test-gates.json: lib/a.dart: "impact" is missing in gates',
        'test-gates.json: lib/b.dart: "decides" is missing in candidates',
        'test-gates.json: lib/b.dart: "blocker" is missing in candidates',
      ]);
      expect(manifest.gates.single.decides, '  ');
      expect(manifest.gates.single.impact, '');
      expect(manifest.candidates.single.blocker, '');
    });

    test('a path listed twice is used once', () {
      final manifest = parse({
        'gates': [gate, gate],
        'candidates': [
          {'path': 'b', 'decides': 'd', 'blocker': 'b'},
          {'path': 'b', 'decides': 'd', 'blocker': 'b'},
        ],
      });
      expect(manifest.violations.map((violation) => '$violation'), [
        'test-gates.json: lib/a.dart: listed twice in gates',
        'test-gates.json: b: listed twice in candidates',
      ]);
      expect(manifest.gates, hasLength(1));
      expect(manifest.candidates, hasLength(1));
    });

    test('a path in both gates and candidates', () {
      expect(
        messages({
          'gates': [gate],
          'candidates': [
            {'path': 'lib/a.dart', 'decides': 'd', 'blocker': 'b'},
          ],
        }),
        ['test-gates.json: lib/a.dart: listed in both gates and candidates'],
      );
    });
  });

  group('equivalentMutants and expectedTimeouts', () {
    const allowance = {
      'mutator': 'ConditionalExpression',
      'original': 'a > b',
      'replacement': '',
      'reason': 'because',
    };

    Map<String, Object?> withGate(String field, Object? value) => {
      'gates': [
        {...gate, field: value},
      ],
    };

    test('usable entries are read, an empty replacement included', () {
      final read = parse({
        'gates': [
          {
            ...gate,
            'equivalentMutants': [
              allowance,
              {...allowance, 'occurrence': 2},
            ],
            'expectedTimeouts': [
              {...allowance, 'occurrence': 1.0},
            ],
          },
        ],
      });
      expect(read.violations, isEmpty);
      final mutants = read.gates.single.equivalentMutants;
      expect(mutants, hasLength(2));
      expect(
        (
          mutants[0].mutator,
          mutants[0].original,
          mutants[0].replacement,
          mutants[0].reason,
          mutants[0].occurrence,
        ),
        ('ConditionalExpression', 'a > b', '', 'because', null),
      );
      expect(mutants[1].occurrence, 2);
      expect(read.gates.single.expectedTimeouts.single.occurrence, 1);
    });

    for (final field in ['equivalentMutants', 'expectedTimeouts']) {
      test('$field must be an array', () {
        for (final value in [null, 'x', <String, Object?>{}]) {
          final manifest = parse(withGate(field, value));
          expect(manifest.violations.map((violation) => '$violation'), [
            'test-gates.json: lib/a.dart: $field must be an array',
          ]);
          expect(manifest.gates.single.equivalentMutants, isEmpty);
          expect(manifest.gates.single.expectedTimeouts, isEmpty);
        }
      });

      test('$field: every problem of an entry is reported', () {
        final manifest = parse(
          withGate(field, [
            'x',
            {'mutator': ' ', 'original': '', 'replacement': 1, 'reason': null},
            {...allowance, 'occurrence': 0},
            {...allowance, 'occurrence': 1.5},
            {...allowance, 'occurrence': null},
            {...allowance, 'occurrence': '1'},
            allowance,
          ]),
        );
        expect(manifest.violations.map((violation) => '$violation'), [
          'test-gates.json: lib/a.dart: $field[0] must be an object',
          'test-gates.json: lib/a.dart: $field[1]: "mutator" is missing',
          'test-gates.json: lib/a.dart: $field[1]: "original" is missing',
          'test-gates.json: lib/a.dart: $field[1]: "replacement" is missing',
          'test-gates.json: lib/a.dart: $field[1]: "reason" is missing '
              '(say why the mutant cannot be observed)',
          for (final index in [2, 3, 4, 5])
            'test-gates.json: lib/a.dart: $field[$index]: "occurrence" must '
                'be an integer >= 1',
        ]);
        final gate = manifest.gates.single;
        expect(
          gate.equivalentMutants.length + gate.expectedTimeouts.length,
          1,
          reason: 'only the usable entry is kept',
        );
      });
    }
  });
}
