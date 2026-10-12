import 'package:test/test.dart';
import 'package:test_gates/src/scan.dart';
import 'package:test_gates/src/settings.dart';
import 'package:test_gates/src/types.dart';

const gate = 'lib/models/shipping_fee.dart';

/// The start of a coverage ignore comment. Written in two parts: the test of
/// a gate must not have such a comment, and `check` finds it in the text of a
/// line, test data included.
const ignore =
    'coverage:'
    'ignore';

List<String> scan(
  String source, {
  Map<String, Object?> settings = const {},
  String? packageName = 'app',
}) => [
  for (final violation in scanGateSource(
    gate,
    source,
    resolveSettings(settings),
    packageName: packageName,
  ))
    violation.toString().substring(gate.length + 1),
];

/// The gate with the files of [files] (path → content) around it: the
/// imports are followed.
List<String> reach(
  String source,
  Map<String, String> files, {
  Map<String, Object?> settings = const {},
  List<String>? read,
}) => [
  for (final violation in scanGateSource(
    gate,
    source,
    resolveSettings(settings),
    packageName: 'app',
    readSource: (path) {
      read?.add(path);
      return files[path];
    },
  ))
    violation.toString().substring(gate.length + 1),
];

const allowlist = {
  'imports': {'mode': 'allowlist'},
};

void main() {
  group('what a gate reaches through the files it imports', () {
    const io = 'import of "dart:io" (file system / network / process access)';

    test('pure files, however many: nothing', () {
      final read = <String>[];
      expect(
        reach(
          "import 'zone.dart';\nimport 'package:app/utils/units.dart';\n"
          "export '../money.dart';\n",
          {
            'lib/models/zone.dart': "import 'dart:math';\nconst a = 1;\n",
            'lib/utils/units.dart': "import '../money.dart';\n",
            'lib/money.dart': 'const cents = 100;\n',
          },
          read: read,
        ),
        isEmpty,
      );
      // Each file once, the nearest first.
      expect(read, [
        'lib/models/zone.dart',
        'lib/utils/units.dart',
        'lib/money.dart',
      ]);
    });

    test('an impure import two files away is reported at the import of the '
        'gate, with the file, the line and the way', () {
      expect(
        reach("\nimport 'zone.dart';\n", {
          'lib/models/zone.dart': "import 'dart:math';\nimport 'clock.dart';\n",
          'lib/models/clock.dart': "// the time\n\nimport 'dart:io';\n",
        }),
        [
          '2: import of "zone.dart" reaches lib/models/clock.dart:3: $io '
              '(lib/models/shipping_fee.dart → lib/models/zone.dart → '
              'lib/models/clock.dart)',
        ],
      );
    });

    test('an export is followed like an import, in the gate and on the '
        'way', () {
      expect(
        reach("export 'all.dart';\n", {
          'lib/models/all.dart': "export 'clock.dart';\n",
          'lib/models/clock.dart': "export 'dart:io';\n",
        }),
        [
          '1: export of "all.dart" reaches lib/models/clock.dart:1: export '
              'of "dart:io" (file system / network / process access) '
              '(lib/models/shipping_fee.dart → lib/models/all.dart → '
              'lib/models/clock.dart)',
        ],
      );
    });

    test('imports that form a circle end, and the gate itself is not read '
        'again', () {
      final read = <String>[];
      expect(
        reach("import 'a.dart';\n", {
          'lib/models/a.dart':
              "import 'b.dart';\nimport 'shipping_fee.dart';\n",
          'lib/models/b.dart': "import 'a.dart';\nimport 'dart:io';\n",
        }, read: read),
        [
          '1: import of "a.dart" reaches lib/models/b.dart:2: $io '
              '(lib/models/shipping_fee.dart → lib/models/a.dart → '
              'lib/models/b.dart)',
        ],
      );
      expect(read, ['lib/models/a.dart', 'lib/models/b.dart']);
    });

    test('a file that two imports lead to is reported once, by the shortest '
        'way', () {
      expect(
        reach("import 'far.dart';\nimport 'near.dart';\n", {
          'lib/models/far.dart': "import 'between.dart';\n",
          'lib/models/between.dart': "import 'clock.dart';\n",
          'lib/models/near.dart': "import 'clock.dart';\n",
          'lib/models/clock.dart': "import 'dart:io';\n",
        }),
        [
          '2: import of "near.dart" reaches lib/models/clock.dart:1: $io '
              '(lib/models/shipping_fee.dart → lib/models/near.dart → '
              'lib/models/clock.dart)',
        ],
      );
    });

    test('every finding of a file on the way, in the order of its lines: a '
        'read of the environment, an added pattern, an added name, a URI '
        'that is no plain string, a syntax error', () {
      expect(
        reach(
          "import 'env.dart';\n",
          {
            'lib/models/env.dart':
                "import 'dart:math';\n"
                "import 'a\${x}.dart';\n"
                "const a = String.fromEnvironment('A');\n"
                '// DateTime.now() in a comment\n'
                'final b = DateTime.now();\n'
                'final c = Random();\n'
                'final d = ;\n',
          },
          settings: {
            'forbiddenSource': {
              'add': [
                {'pattern': r'DateTime\.now\(', 'reason': 'reads the clock'},
              ],
            },
            'impureNamedImports': {
              'add': [
                {
                  'module': 'dart:math',
                  'names': ['Random'],
                  'reason': 'not repeatable',
                },
              ],
            },
          },
        ),
        [
          for (final finding in [
            '1: use of Random from "dart:math" (not repeatable)',
            '2: a URI that is not written plainly cannot be checked (a plain string, a lower-case scheme, no "%", not file:)',
            '3: reads String.fromEnvironment (not a pure module). Take the '
                'value as an argument',
            '5: reads the clock',
            '7: code that cannot be parsed as Dart (Expected an identifier.)',
          ])
            '1: import of "env.dart" reaches lib/models/env.dart:$finding '
                '(lib/models/shipping_fee.dart → lib/models/env.dart)',
        ],
      );
    });

    test('forbiddenSource.defaults: false holds on the way as well', () {
      expect(
        reach(
          "import 'env.dart';\n",
          {'lib/models/env.dart': "const a = bool.hasEnvironment('A');\n"},
          settings: {
            'forbiddenSource': {'defaults': false},
          },
        ),
        isEmpty,
      );
    });

    test('a file that cannot be read: what it brings in cannot be '
        'checked', () {
      expect(
        reach("import 'zone.dart';\nimport '../gone.dart';\n", {
          'lib/models/zone.dart': "import 'missing.dart';\n",
        }),
        [
          '1: import of "zone.dart" reaches lib/models/missing.dart, which '
              'cannot be read, so what it brings in cannot be checked. When a generator writes that file, run it '
              'before check (lib/models/shipping_fee.dart → lib/models/zone.dart → '
              'lib/models/missing.dart)',
          '2: import of "../gone.dart" reaches lib/gone.dart, which cannot be '
              'read, so what it brings in cannot be checked. When a generator writes that file, run it '
              'before check (lib/models/shipping_fee.dart → lib/gone.dart)',
        ],
      );
    });

    test('another package and the SDK are not followed: they are judged by '
        'their names', () {
      final read = <String>[];
      expect(
        reach(
          "import 'dart:math';\nimport 'package:decimal/decimal.dart';\n"
          "import 'zone.dart';\n",
          {'lib/models/zone.dart': "import 'package:intl/intl.dart';\n"},
          read: read,
        ),
        isEmpty,
      );
      expect(read, ['lib/models/zone.dart']);
    });

    test('an import that is a finding itself is not followed, in the gate '
        'and on the way', () {
      final read = <String>[];
      const settings = {
        'impureImports': {
          'add': [
            {'pattern': '_repository', 'reason': 'talks to the API'},
          ],
        },
      };
      expect(
        reach(
          "import 'fee_repository.dart';\nimport 'zone.dart';\n",
          {'lib/models/zone.dart': "import 'zone_repository.dart';\n"},
          settings: settings,
          read: read,
        ),
        [
          '1: import of "fee_repository.dart" (talks to the API)',
          '2: import of "zone.dart" reaches lib/models/zone.dart:1: import '
              'of "zone_repository.dart" (talks to the API) '
              '(lib/models/shipping_fee.dart → lib/models/zone.dart)',
        ],
      );
      expect(read, ['lib/models/zone.dart']);
    });

    test('settings.impureImports.allow: the URI is exempt, and is not '
        'followed', () {
      final read = <String>[];
      const files = {
        'lib/models/zone.dart':
            "import 'package:flutter/foundation.dart';\n"
            "import 'legacy/clock.dart';\n",
        'lib/models/legacy/clock.dart': "import 'dart:io';\n",
      };
      expect(
        reach(
          "import 'zone.dart';\n",
          files,
          settings: {
            'impureImports': {
              'allow': [r'^package:flutter/foundation\.dart$', '^legacy/'],
            },
          },
          read: read,
        ),
        isEmpty,
      );
      expect(read, ['lib/models/zone.dart']);
      expect(reach("import 'zone.dart';\n", files), hasLength(2));
    });

    test('parts: a generated part is not read; a part of a file on the way '
        'that no generator wrote is', () {
      final read = <String>[];
      expect(
        reach("import 'zone.dart';\npart 'shipping_fee.g.dart';\n", {
          'lib/models/zone.dart':
              "part 'zone.g.dart';\npart 'zone.freezed.dart';\n"
              "part 'zone_names.dart';\n",
          'lib/models/zone_names.dart':
              "part of 'zone.dart';\n"
              "final home = Platform.environment['HOME'];\n",
        }, read: read),
        [
          '1: import of "zone.dart" reaches lib/models/zone_names.dart:2: '
              'reads Platform.environment (not a pure module). Take the '
              'value as an argument (lib/models/shipping_fee.dart → '
              'lib/models/zone.dart → lib/models/zone_names.dart)',
        ],
      );
      expect(read, ['lib/models/zone.dart', 'lib/models/zone_names.dart']);
    });

    test('a part of the gate that no generator wrote is a finding of the '
        'gate, and is not read', () {
      final read = <String>[];
      expect(
        reach("part 'fee_rules.dart';\n", {
          'lib/models/fee_rules.dart': "import 'dart:io';\n",
        }, read: read),
        [startsWith('1: part "fee_rules.dart" is code of the gate')],
      );
      expect(read, isEmpty);
    });

    test('every URI of a conditional import is followed', () {
      expect(
        reach(
          "import 'clock_stub.dart'\n"
          "    if (dart.library.io) 'clock_io.dart';\n",
          {
            'lib/models/clock_stub.dart': 'int now() => 0;\n',
            'lib/models/clock_io.dart': "import 'zone.dart';\n",
            'lib/models/zone.dart': "import 'dart:ffi';\n",
          },
        ),
        [
          '2: import of "clock_io.dart" reaches lib/models/zone.dart:1: '
              'import of "dart:ffi" (file system / network / process '
              'access) (lib/models/shipping_fee.dart → '
              'lib/models/clock_io.dart → lib/models/zone.dart)',
        ],
      );
    });

    test('allowlist mode: the files on the way may import what the gate '
        'may, and no file that could not be a gate', () {
      expect(
        reach(
          "import 'zone.dart';\n",
          {
            'lib/models/zone.dart':
                "import 'dart:convert';\n"
                "import 'package:decimal/decimal.dart';\n"
                "import 'package:intl/intl.dart';\n"
                "import 'zone.g.dart';\n"
                "import 'package:app/pages/zone_page.dart';\n",
            'lib/models/zone.g.dart': '',
            'lib/pages/zone_page.dart': '',
          },
          settings: {
            'imports': {
              'mode': 'allowlist',
              'allow': ['package:decimal'],
            },
            'impurePaths': {
              'add': [
                {'pattern': '^lib/pages/', 'reason': 'UI'},
              ],
            },
          },
        ),
        [
          for (final finding in [
            '3: import of "package:intl/intl.dart" is not in '
                'settings.imports.allow (allowlist mode allows the '
                'package\'s own files and listed libraries only)',
            '4: import of "zone.g.dart" (generated file)',
            '5: import of "package:app/pages/zone_page.dart" (UI)',
          ])
            '1: import of "zone.dart" reaches lib/models/zone.dart:$finding '
                '(lib/models/shipping_fee.dart → lib/models/zone.dart)',
        ],
      );
    });

    test('settings.importAliases point into the package and are '
        'followed', () {
      expect(
        reach(
          "import 'shared:clock.dart';\n",
          {'packages/shared/lib/clock.dart': "import 'dart:io';\n"},
          settings: {
            'importAliases': [
              {'prefix': 'shared:', 'target': 'packages/shared/lib/'},
            ],
          },
        ),
        [
          '1: import of "shared:clock.dart" reaches '
              'packages/shared/lib/clock.dart:1: $io '
              '(lib/models/shipping_fee.dart → packages/shared/lib/clock.dart)',
        ],
      );
    });

    test('findings of the gate and of what it reaches are sorted by the '
        'line in the gate', () {
      expect(
        reach("import 'zone.dart';\nimport 'dart:io';\n", {
          'lib/models/zone.dart': "import 'dart:io';\n",
        }),
        [startsWith('1: import of "zone.dart" reaches '), '2: $io'],
      );
    });

    test('without a way to read files nothing is followed', () {
      expect(scan("import 'zone.dart';\n"), isEmpty);
    });
  });

  group('gateSources: the files a gate is made of', () {
    Map<String, String> sources(
      String source,
      Map<String, String> files, {
      Map<String, Object?> settings = const {},
      String? packageName = 'app',
    }) => gateSources(
      gate,
      source,
      resolveSettings(settings),
      packageName: packageName,
      readSource: (path) => files[path],
    );

    test('the gate alone', () {
      expect(sources('int a() => 1;\n', {}), {gate: 'int a() => 1;\n'});
    });

    test('the gate first, then what it imports, exports and has as a part, '
        'and what those bring in, each once', () {
      const files = {
        'lib/models/zone.dart': "import '../money.dart';\nexport 'a.dart';\n",
        'lib/money.dart': "import 'models/zone.dart';\n",
        'lib/models/a.dart': "part 'a.g.dart';\n",
        'lib/models/a.g.dart': "part of 'a.dart';\n",
        'lib/models/shipping_fee.g.dart': '// generated\n',
        'lib/unused.dart': '',
      };
      const source =
          "import 'zone.dart';\nimport 'package:app/money.dart';\n"
          "part 'shipping_fee.g.dart';\nimport 'shipping_fee.dart';\n";
      final found = sources(source, files);
      expect(found.keys, [
        gate,
        'lib/models/zone.dart',
        'lib/money.dart',
        'lib/models/shipping_fee.g.dart',
        'lib/models/a.dart',
        'lib/models/a.g.dart',
      ]);
      expect(found[gate], source);
      expect(found['lib/money.dart'], files['lib/money.dart']);
    });

    test('another package, the SDK and a file that cannot be read are left '
        'out, and so is what is behind them', () {
      expect(
        sources(
          "import 'dart:io';\nimport 'package:intl/intl.dart';\n"
          "import 'gone.dart';\nimport 'zone.dart';\n",
          {'lib/models/zone.dart': "import 'missing.dart';\n"},
        ).keys,
        [gate, 'lib/models/zone.dart'],
      );
    });

    test('an import that check rejects is followed all the same', () {
      expect(
        sources(
          "import 'fee_repository.dart';\n",
          {'lib/models/fee_repository.dart': "import 'dart:io';\n"},
          settings: {
            'impureImports': {
              'add': ['_repository'],
              'allow': ['_repository'],
            },
          },
        ).keys,
        [gate, 'lib/models/fee_repository.dart'],
      );
    });

    test('without the name of the package, package: is another '
        'package; settings.importAliases are followed', () {
      const files = {
        'lib/money.dart': '',
        'packages/shared/lib/clock.dart': '',
      };
      expect(
        sources(
          "import 'package:app/money.dart';\n",
          files,
          packageName: null,
        ).keys,
        [gate],
      );
      expect(
        sources(
          "import 'shared:clock.dart';\n",
          files,
          settings: {
            'importAliases': [
              {'prefix': 'shared:', 'target': 'packages/shared/lib/'},
            ],
          },
        ).keys,
        [gate, 'packages/shared/lib/clock.dart'],
      );
    });
  });

  group('a pure module passes', () {
    test('a model with json_serializable', () {
      expect(
        scan('''
import 'dart:math';

import 'package:app/utils/weight_units.dart';
import 'package:collection/collection.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:meta/meta.dart';

import 'zone.dart';

part 'shipping_fee.g.dart';

@JsonSerializable()
@immutable
class ShippingFee {
  const ShippingFee({this.flatCents, this.perKiloCents});

  factory ShippingFee.fromJson(Map<String, dynamic> json) => _\$ShippingFeeFromJson(json);

  @JsonKey(name: 'flat_cents')
  final int? flatCents;
  final double? perKiloCents;

  /// Mentions dart:io and Platform.environment in a comment.
  int feeFor(int amount, {DateTime? now}) {
    final at = now ?? DateTime.now();
    if (at.year < 2000) {
      return amount;
    }
    return max(0, amount - (flatCents ?? 0));
  }
}
'''),
        isEmpty,
      );
    });

    test('the same in allowlist mode', () {
      expect(
        scan('''
import 'dart:math';
import 'package:app/utils/weight_units.dart';
import 'package:json_annotation/json_annotation.dart';
import 'zone.dart';
part 'shipping_fee.g.dart';
''', settings: allowlist),
        isEmpty,
      );
    });
  });

  group('imports', () {
    test('built-in rules: import, export, conditional import', () {
      expect(
        scan('''
import 'dart:io';
import 'package:flutter/material.dart';
export 'package:dio/dio.dart' show Dio;
import 'stub.dart' if (dart.library.html) 'dart:html';
import 'package:flutter_bloc/flutter_bloc.dart' as bloc;
'''),
        [
          '1: import of "dart:io" (file system / network / process access)',
          '2: import of "package:flutter/material.dart" (Flutter framework)',
          '3: export of "package:dio/dio.dart" (HTTP client)',
          '4: import of "dart:html" (browser API)',
          '5: import of "package:flutter_bloc/flutter_bloc.dart" (Flutter plugin or UI package)',
        ],
      );
    });

    test('add: a layer of the project, by package URI', () {
      const settings = {
        'impureImports': {
          'add': [
            {'pattern': '^package:app/(blocs|stores)/', 'reason': 'state'},
            r'_repository\.dart$',
          ],
        },
      };
      expect(
        scan('''
import 'package:app/blocs/basket.dart';
import 'package:app/models/basket.dart';
import '../data/user_repository.dart';
''', settings: settings),
        [
          '1: import of "package:app/blocs/basket.dart" (state)',
          r'3: import of "../data/user_repository.dart" (matches _repository\.dart$)',
        ],
      );
    });

    test('allow exempts a URI from every pattern', () {
      expect(
        scan(
          "import 'package:flutter/foundation.dart';\n"
          "import 'package:flutter/material.dart';\n",
          settings: {
            'impureImports': {
              'allow': [r'^package:flutter/foundation\.dart$'],
            },
          },
        ),
        ['2: import of "package:flutter/material.dart" (Flutter framework)'],
      );
    });

    test('defaults: false', () {
      expect(
        scan(
          "import 'dart:io';\n",
          settings: {
            'impureImports': {'defaults': false},
          },
        ),
        isEmpty,
      );
    });

    test('two patterns on one URI are two findings', () {
      expect(
        scan(
          "import 'dart:io';\n",
          settings: {
            'impureImports': {
              'add': [
                {'pattern': '^dart:io', 'reason': 'again'},
              ],
            },
          },
        ),
        [
          '1: import of "dart:io" (file system / network / process access)',
          '1: import of "dart:io" (again)',
        ],
      );
    });
  });

  group('parts', () {
    test('a generated part is allowed, any other is not', () {
      expect(
        scan(
          "part 'shipping_fee.g.dart';\npart 'shipping_fee_rules.dart';\npart 'shipping_fee.freezed.dart';\n",
        ),
        [
          '2: part "shipping_fee_rules.dart" is code of the gate in a file that is '
              'not checked or measured (only generated *.g.dart / '
              '*.freezed.dart parts are allowed). Make it a library and list '
              'it as a gate',
        ],
      );
    });

    test('impureImports.allow lets another generator in', () {
      expect(
        scan(
          "part 'shipping_fee.mapper.dart';\npart 'shipping_fee_rules.dart';\n",
          settings: {
            'impureImports': {
              'allow': [r'\.mapper\.dart$'],
            },
          },
        ),
        [startsWith('2: part "shipping_fee_rules.dart"')],
      );
    });

    test('a part matched by a pattern is reported once', () {
      expect(
        scan(
          "part 'shipping_fee_io.dart';\n",
          settings: {
            'impureImports': {
              'add': [
                {'pattern': r'_io\.dart$', 'reason': 'I/O'},
              ],
            },
          },
        ),
        ['1: part of "shipping_fee_io.dart" (I/O)'],
      );
    });

    test('a gate that is a part of another library', () {
      expect(scan("part of 'models.dart';\n\nint f() => 1;\n"), [
        '1: a part of another library (its imports are in that library and '
            'cannot be checked). Make it a library of its own',
      ]);
    });
  });

  group('named imports', () {
    const settings = {
      'impureNamedImports': {
        'add': [
          {
            'module': 'dart:math',
            'names': ['Random', 'pi'],
            'reason': 'not deterministic',
          },
        ],
      },
    };

    test('with show, the names that are shown', () {
      expect(
        scan("import 'dart:math' show Random, max;\n", settings: settings),
        ['1: use of Random from "dart:math" (not deterministic)'],
      );
      expect(
        scan("import 'dart:math' show max;\n", settings: settings),
        isEmpty,
      );
    });

    test('with show, a name of the code that is not shown is another one', () {
      expect(
        scan(
          "import 'dart:math' show max;\n\nclass Random {}\n",
          settings: settings,
        ),
        isEmpty,
      );
    });

    test('several names are listed', () {
      expect(
        scan("import 'dart:math' show pi, Random;\n", settings: settings),
        ['1: use of Random, pi from "dart:math" (not deterministic)'],
      );
    });

    test('without show, the names the code uses', () {
      expect(
        scan(
          "import 'dart:math';\n\nint roll() => Random().nextInt(6);\n",
          settings: settings,
        ),
        ['1: use of Random from "dart:math" (not deterministic)'],
      );
      expect(
        scan(
          "import 'dart:math';\n\n// Random\nint twice(int x) => max(x, 2 * x);\n",
          settings: settings,
        ),
        isEmpty,
      );
    });

    test('another library is not concerned', () {
      expect(
        scan("import 'random.dart' show Random;\n", settings: settings),
        isEmpty,
      );
    });
  });

  group('allowlist mode', () {
    test('a package that is not listed, the SDK included', () {
      expect(
        scan(
          '''
import 'dart:developer';
import 'package:decimal/decimal.dart';
import 'package:intl/intl.dart';
''',
          settings: {
            'imports': {
              'mode': 'allowlist',
              'allow': ['package:decimal'],
            },
          },
        ),
        [
          startsWith(
            '1: import of "dart:developer" is not in settings.imports.allow',
          ),
          startsWith(
            '3: import of "package:intl/intl.dart" is not in settings.imports.allow',
          ),
        ],
      );
    });

    test('the blocklist stays in force and reports once', () {
      expect(scan("import 'dart:io';\n", settings: allowlist), [
        '1: import of "dart:io" (file system / network / process access)',
      ]);
    });

    test('a file of the package that could not be a gate', () {
      const settings = {
        'imports': {'mode': 'allowlist'},
        'impurePaths': {
          'add': [
            {'pattern': '^lib/blocs/', 'reason': 'bloc'},
          ],
        },
      };
      expect(
        scan('''
import 'package:app/blocs/basket.dart';
import '../blocs/basket.dart';
export 'package:app/models/basket.dart';
import 'basket.g.dart';
''', settings: settings),
        [
          '1: import of "package:app/blocs/basket.dart" (bloc)',
          '2: import of "../blocs/basket.dart" (bloc)',
          '4: import of "basket.g.dart" (generated file)',
        ],
      );
    });

    test('without a pubspec the package itself is another package', () {
      expect(
        scan(
          "import 'package:app/models/basket.dart';\n",
          settings: allowlist,
          packageName: null,
        ),
        [startsWith('1: import of "package:app/models/basket.dart" is not in')],
      );
    });

    test('names of an allowed library', () {
      expect(
        scan(
          "import 'package:intl/intl.dart' show NumberFormat, Intl;\n",
          settings: {
            'imports': {
              'mode': 'allowlist',
              'allow': [
                {
                  'module': 'package:intl/intl.dart',
                  'names': ['NumberFormat'],
                },
              ],
            },
          },
        ),
        [
          '1: import of Intl from "package:intl/intl.dart" is not in '
              'settings.imports.allow (allowed: NumberFormat)',
        ],
      );
    });
  });

  group('forbidden source', () {
    test('reads of the environment', () {
      expect(
        scan('''
const api = String.fromEnvironment('API');
const debug = bool.fromEnvironment('DEBUG');
const port = int.fromEnvironment('PORT');
final home = Platform.environment['HOME'];
'''),
        [
          '1: reads String.fromEnvironment (not a pure module). Take the value as an argument',
          '2: reads bool.fromEnvironment (not a pure module). Take the value as an argument',
          '3: reads int.fromEnvironment (not a pure module). Take the value as an argument',
          '4: reads Platform.environment (not a pure module). Take the value as an argument',
        ],
      );
    });

    test('the clock and random numbers are not checked', () {
      expect(
        scan('''
import 'dart:math';

DateTime stamp([DateTime? now]) => now ?? DateTime.now();
int roll([Random? random]) => (random ?? Random()).nextInt(6);
'''),
        isEmpty,
      );
    });

    test('add: a pattern per line of code; what a comment says is not '
        'code', () {
      expect(
        scan(
          'final a = DateTime.now();\n// DateTime.now()\nfinal b = 1;\n'
          '/// Uses [DateTime.now()] when no time is given.\n'
          'final c = 2; // not DateTime.now()\n'
          '/* DateTime.now()\n   final b */\n'
          "final d = 'DateTime.now()'; /* x */ final e = DateTime.now();\n",
          settings: {
            'forbiddenSource': {
              'add': [
                {'pattern': r'\bDateTime\.now\(', 'reason': 'reads the clock'},
                'final b',
              ],
            },
          },
        ),
        // Line 8: the text of a string is code, and so is what follows a
        // comment on the line.
        ['1: reads the clock', '3: matches final b', '8: reads the clock'],
      );
    });

    test('defaults: false turns the built-in rules off, not the added', () {
      expect(
        scan(
          "const a = String.fromEnvironment('A');\nfinal b = print;\n",
          settings: {
            'forbiddenSource': {
              'defaults': false,
              'add': [
                {'pattern': r'\bprint\b', 'reason': 'prints'},
              ],
            },
          },
        ),
        ['2: prints'],
      );
    });
  });

  group('coverage ignore comments', () {
    test('every form the coverage tool honours', () {
      expect(
        scan('''
// $ignore-file
int f(int x) {
  if (x > 0) return 1; // $ignore-line
  // $ignore-start
  return 2;
  //$ignore-end
}
const text = '// $ignore-line';
'''),
        [
          '1: coverage ignore comment',
          '3: coverage ignore comment',
          '4: coverage ignore comment',
          '6: coverage ignore comment',
          // The tool matches the text of the line, so a string counts too.
          '8: coverage ignore comment',
        ],
      );
    });

    test('other comments', () {
      expect(
        scan(
          '// ignore: avoid_print\n// ignore_for_file: x\n// coverage: 100%\n',
        ),
        isEmpty,
      );
    });
  });

  group('blocks on one line', () {
    test('are reported with what to do', () {
      expect(
        scan('int f(bool a) {\n  if (a) { return 1; } else { return 2; }\n}\n'),
        [
          '2: 2 blocks start on this line and share one branch entry in '
              'lcov, so an untested one is not reported. Run dart format, '
              'and give nested control flow braces',
        ],
      );
    });
  });

  group('line endings and a byte order mark', () {
    test('a BOM is not a syntax error, and moves no line', () {
      expect(scan("\uFEFFimport 'dart:io';\n"), [
        '1: import of "dart:io" (file system / network / process access)',
      ]);
    });

    test('CRLF: lines are the same, and a pattern ending in \$ matches', () {
      expect(
        scan(
          "import 'dart:io';\r\n\r\nvoid f() {\r\n  print('x');\r\n}\r\n",
          settings: {
            'forbiddenSource': {
              'add': [
                {'pattern': r'print\(.*\);$', 'reason': 'prints'},
              ],
            },
          },
        ),
        [
          '1: import of "dart:io" (file system / network / process access)',
          '4: prints',
        ],
      );
    });
  });

  test('a file that is not Dart', () {
    // The wording is the parser's and differs between analyzer versions.
    expect(scan('int f() {\n  return 1\n}\n'), [
      matches(RegExp(r'^[23]: cannot be parsed as Dart \(.+\)$')),
    ]);
  });

  test('a URI that is not a plain string', () {
    expect(
      scan("import 'a\${x}.dart';\n"),
      contains(
        '1: a URI that is not written plainly cannot be checked (a plain string, a lower-case scheme, no "%", not file:)',
      ),
    );
  });

  test('findings on one line keep the order of the checks', () {
    // More findings than a sort keeps in order by itself (Dart's is only
    // stable for short lists).
    const lines = 40;
    final messages = scan(
      [
        for (var line = 0; line < lines; line++)
          'final v$line = Platform.environment; // $ignore-line\n',
      ].join(),
    );
    expect(messages, [
      for (var line = 1; line <= lines; line++) ...[
        '$line: coverage ignore comment',
        '$line: reads Platform.environment (not a pure module). '
            'Take the value as an argument',
      ],
    ]);
  });

  test('findings are sorted by line, and carry the path of the gate', () {
    final violations = scanGateSource(
      gate,
      "import 'dart:io';\n\nfinal home = Platform.environment;\n// $ignore-file\n",
      resolveSettings(<String, Object?>{}),
    );
    expect(violations.map((violation) => violation.line), [1, 3, 4]);
    expect(violations.map((violation) => violation.file), everyElement(gate));
  });

  group('scanSpecSource', () {
    List<String> spec(String source) => [
      for (final Violation violation in scanSpecSource(
        'test/a_test.dart',
        source,
      ))
        violation.toString(),
    ];

    test('a plain test passes', () {
      expect(
        spec('''
import 'package:test/test.dart';

void main() {
  group('a', () {
    test('b', () {
      expect(1, 1);
    }, skip: false);
  });
}
'''),
        isEmpty,
      );
    });

    test('skipped, focused, ignored', () {
      expect(
        spec('''
@Skip()
library;

void main() {
  test('a', () {}, skip: 'later');
  test('b', () {}, solo: true); // $ignore-line
}
'''),
        [
          'test/a_test.dart:1: @Skip (a skipped or focused test)',
          'test/a_test.dart:5: skip: (a skipped or focused test)',
          'test/a_test.dart:6: coverage ignore comment',
          'test/a_test.dart:6: solo: (a skipped or focused test)',
        ],
      );
    });

    test('a test that cannot be parsed', () {
      expect(spec('void main() {\n'), [
        matches(
          RegExp(r'^test/a_test\.dart:[12]: cannot be parsed as Dart \(.+\)$'),
        ),
      ]);
    });
  });
}
