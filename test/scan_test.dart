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

const allowlist = {
  'imports': {'mode': 'allowlist'},
};

void main() {
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

    test('add: a pattern per line, comments included', () {
      expect(
        scan(
          'final a = DateTime.now();\n// DateTime.now()\nfinal b = 1;\n',
          settings: {
            'forbiddenSource': {
              'add': [
                {'pattern': r'\bDateTime\.now\(', 'reason': 'reads the clock'},
                'final b',
              ],
            },
          },
        ),
        ['1: reads the clock', '2: reads the clock', '3: matches final b'],
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
      contains('1: a URI that is not a plain string cannot be checked'),
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
