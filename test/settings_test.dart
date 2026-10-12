import 'package:test/test.dart';
import 'package:test_gates/src/settings.dart';
import 'package:test_gates/src/types.dart';

Matcher settingsError(Object message) => throwsA(
  isA<SettingsError>().having((error) => error.toString(), 'message', message),
);

void rejects(Map<String, Object?> settings, Object message) =>
    expect(() => resolveSettings(settings), settingsError(message));

void main() {
  group('defaults', () {
    final settings = resolveSettings(<String, Object?>{});

    test('gates are .dart files', () {
      expect(settings.gateExtensions, ['.dart']);
    });

    test('the safe side of upstream 0.3.2: no timeout is tolerated', () {
      expect(settings.maxTimeouts, 0);
    });

    test('where the tests live is not configured (check has a default)', () {
      expect(settings.specSuffixes, isNull);
      expect(settings.specRewrite, isNull);
    });

    test('the import check is a blocklist with the built-in rules', () {
      expect(settings.importMode, ImportMode.blocklist);
      expect(settings.importAllow, isEmpty);
      expect(settings.allowedImports, isEmpty);
      expect(settings.importAliases, isEmpty);
      expect(settings.impureNamedImports, isEmpty);
      expect(settings.impureImports, hasLength(defaultImpureImports.length));
      expect(settings.impurePaths.single.reason, 'generated file');
    });

    test('the built-in forbidden source is on, with no added pattern', () {
      expect(settings.forbiddenSourceDefaults, isTrue);
      expect(settings.forbiddenSource, isEmpty);
    });

    test('no command to run; selfcheck covers every gate', () {
      expect(settings.gateCommand, isNull);
      expect(settings.selfcheckMode, 'all');
    });

    test('no tracefile, nothing excluded', () {
      expect(settings.lcovFile, isNull);
      expect(settings.lcovSummaryExclude, isEmpty);
    });
  });

  group('the settings this version uses', () {
    test('a Flutter app with tests next to the sources', () {
      final settings = resolveSettings({
        'gateExtensions': ['.dart'],
        'spec': {'suffixes': <String>[]},
        'lcov': {
          'file': 'coverage/lcov.info',
          'summaryExclude': [r'\.g\.dart$', 'lib/l10n/'],
        },
      });
      expect(settings.specSuffixes, isEmpty);
      expect(settings.lcovFile, 'coverage/lcov.info');
      expect(settings.lcovSummaryExclude.map((regex) => regex.pattern), [
        r'\.g\.dart$',
        'lib/l10n/',
      ]);
      expect(
        settings.lcovSummaryExclude.first.hasMatch('lib/a.g.dart'),
        isTrue,
      );
      expect(settings.lcovSummaryExclude.first.hasMatch('lib/a.dart'), isFalse);
    });

    test('tests under test/: suffix and rewrite', () {
      final settings = resolveSettings({
        'spec': {
          'suffixes': ['_test.dart'],
          'rewrite': [
            {'from': '^lib/', 'to': 'test/'},
          ],
        },
      });
      expect(settings.specSuffixes, ['_test.dart']);
      final rewrite = settings.specRewrite!.single;
      expect(
        'lib/a.dart'.replaceFirst(rewrite.regex, rewrite.to),
        'test/a.dart',
      );
    });

    test('gateExtensions and maxTimeouts', () {
      final settings = resolveSettings({
        'gateExtensions': ['.dart', '.g.dart'],
        'mutation': {'maxTimeouts': 2.0},
      });
      expect(settings.gateExtensions, ['.dart', '.g.dart']);
      expect(settings.maxTimeouts, 2);
      expect(settings.reportFile, 'reports/mutation/mutation.json');
      expect(
        resolveSettings({
          'stryker': {'reportFile': 'build/mutation.json'},
        }).reportFile,
        'build/mutation.json',
      );
      expect(
        resolveSettings({
          'mutation': {'maxTimeouts': 0},
        }).maxTimeouts,
        0,
      );
    });
  });

  group('rejected, so that a typo cannot fall back to a default', () {
    test('settings that is not an object', () {
      for (final raw in [null, 'x', <Object>[]]) {
        expect(
          () => resolveSettings(raw),
          settingsError('settings: must be an object'),
        );
      }
    });

    test('unknown key', () {
      rejects({'lcovFile': 'x'}, 'settings: unknown key "lcovFile"');
      rejects({
        'lcov': {'files': 'x'},
      }, 'settings.lcov: unknown key "files"');
      rejects({
        'spec': {'suffix': <String>[]},
      }, 'settings.spec: unknown key "suffix"');
      rejects({
        'mutation': {'maxTimeout': 1},
      }, 'settings.mutation: unknown key "maxTimeout"');
    });

    test('a section that is not an object', () {
      for (final key in ['spec', 'lcov', 'mutation', 'stryker', 'selfcheck']) {
        rejects({key: null}, 'settings.$key: must be an object');
        rejects({key: <Object>[]}, 'settings.$key: must be an object');
      }
    });

    test('gateExtensions', () {
      const message =
          'settings.gateExtensions: must list at least one extension starting with "."';
      rejects({'gateExtensions': <String>[]}, message);
      rejects({
        'gateExtensions': ['dart'],
      }, message);
      // One of them is enough.
      rejects({
        'gateExtensions': ['.dart', 'g.dart'],
      }, message);
      rejects({
        'gateExtensions': ['g.dart', '.dart'],
      }, message);
      for (final value in [
        null,
        '.dart',
        [1],
        [''],
      ]) {
        rejects({
          'gateExtensions': value,
        }, 'settings.gateExtensions: must be an array of non-empty strings');
      }
    });

    test('spec', () {
      rejects({
        'spec': {'suffixes': '_test.dart'},
      }, 'settings.spec.suffixes: must be an array of non-empty strings');
      rejects({
        'spec': {'rewrite': 'x'},
      }, 'settings.spec.rewrite: must be an array');
      for (final item in [
        'x',
        {'from': 'a'},
        {'from': 1, 'to': 'b'},
      ]) {
        rejects({
          'spec': {
            'rewrite': [item],
          },
        }, 'settings.spec.rewrite[0]: must be { from, to }');
      }
      rejects({
        'spec': {
          'rewrite': [
            {'from': 'a', 'to': 'b', 'flags': 'i'},
          ],
        },
      }, 'settings.spec.rewrite[0]: unknown key "flags"');
      rejects(
        {
          'spec': {
            'rewrite': [
              {'from': '(', 'to': 'b'},
            ],
          },
        },
        startsWith('settings.spec.rewrite[0]: invalid regular expression "("'),
      );
    });

    test('lcov', () {
      for (final file in [null, '', 1]) {
        rejects({
          'lcov': {'file': file},
        }, 'settings.lcov.file: must be a non-empty string');
      }
      rejects({
        'lcov': {'summaryExclude': 'x'},
      }, 'settings.lcov.summaryExclude: must be an array of non-empty strings');
      rejects(
        {
          'lcov': {
            'summaryExclude': ['ok', '['],
          },
        },
        startsWith(
          'settings.lcov.summaryExclude[1]: invalid regular expression "["',
        ),
      );
    });

    test('mutation.maxTimeouts', () {
      for (final value in [-1, 1.5, '1', null]) {
        rejects({
          'mutation': {'maxTimeouts': value},
        }, 'settings.mutation.maxTimeouts: must be an integer >= 0');
      }
    });
  });

  group('sections of upstream that this version does not act on', () {
    test('a valid upstream manifest is accepted', () {
      final settings = resolveSettings({
        for (final key in settingsKeys)
          if (!const [
            'gateExtensions',
            'importAliases',
            'gateCommand',
          ].contains(key))
            key: <String, Object?>{},
        'importAliases': <Object>[],
      });
      expect(settings.gateExtensions, ['.dart']);

      resolveSettings({
        'impureImports': {
          'defaults': false,
          'add': [
            '^dio\$',
            {'pattern': 'repository', 'flags': 'gi', 'reason': 'DB layer'},
          ],
          'allow': ['^package:meta/'],
        },
        'impureNamedImports': {
          'defaults': true,
          'add': [
            {
              'module': 'dart:io',
              'names': ['File'],
              'reason': 'file system',
            },
          ],
        },
        'impurePaths': {
          'add': [r'_bloc\.dart$'],
        },
        'forbiddenSource': {
          'defaults': true,
          'add': [
            {'pattern': r'DateTime\.now\('},
          ],
        },
        'importAliases': [
          {'prefix': '@/', 'target': 'lib/'},
        ],
        'gateCommand': ['flutter', 'test'],
        'selfcheck': {'mode': 'first', 'failurePattern': r'{gate}.*\d+%'},
        'stryker': {'configFile': 'a.mjs', 'reportFile': 'b.json'},
        'imports': {
          'mode': 'allowlist',
          'allow': [
            'decimal',
            {'pattern': '^package:acme_', 'flags': 'i'},
            {
              'module': 'package:meta/meta.dart',
              'names': ['immutable'],
            },
          ],
        },
      });
    });

    test('null where upstream falls back to an empty list', () {
      resolveSettings({
        'spec': {'rewrite': null},
        'impureImports': {'add': null},
        'impurePaths': {'add': null},
        'forbiddenSource': {'add': null},
        'impureNamedImports': {'add': null},
        'importAliases': null,
        'imports': {'allow': null},
      });
    });

    test('a repeated flag is an error, as in JavaScript', () {
      rejects(
        {
          'impurePaths': {
            'add': [
              {'pattern': 'a', 'flags': 'ii'},
            ],
          },
        },
        'settings.impurePaths.add[0]: invalid regular expression flags "ii" '
        '(a flag is repeated)',
      );
    });

    test('rule lists', () {
      for (final key in ['impureImports', 'impurePaths', 'forbiddenSource']) {
        rejects({
          key: {'default': true},
        }, 'settings.$key: unknown key "default"');
        rejects({
          key: {'defaults': 'no'},
        }, 'settings.$key.defaults: must be a boolean');
        rejects({
          key: {'add': 'x'},
        }, 'settings.$key.add: must be an array');
        for (final item in [
          '',
          1,
          {'reason': 'x'},
          {'pattern': ''},
        ]) {
          rejects(
            {
              key: {
                'add': [item],
              },
            },
            'settings.$key.add[0]: must be a pattern string or '
            '{ pattern, flags?, reason? }',
          );
        }
        rejects({
          key: {
            'add': [
              {'pattern': 'a', 'because': 'x'},
            ],
          },
        }, 'settings.$key.add[0]: unknown key "because"');
        rejects({
          key: {
            'add': [
              {'pattern': 'a', 'flags': 1},
            ],
          },
        }, 'settings.$key.add[0].flags: must be a string');
        rejects({
          key: {
            'add': [
              {'pattern': 'a', 'reason': 1},
            ],
          },
        }, 'settings.$key.add[0].reason: must be a string');
        rejects({
          key: {
            'add': ['a', '('],
          },
        }, startsWith('settings.$key.add[1]: invalid regular expression "("'));
        rejects({
          key: {
            'add': [
              {'pattern': '(', 'flags': 'i'},
            ],
          },
        }, startsWith('settings.$key.add[0]: invalid regular expression "("'));
      }
      rejects({
        'impurePaths': {'allow': <String>[]},
      }, 'settings.impurePaths: unknown key "allow"');
    });

    test('a flag Dart cannot honour is an error, not dropped', () {
      rejects(
        {
          'impurePaths': {
            'add': [
              {'pattern': 'a', 'flags': 'iy'},
            ],
          },
        },
        'settings.impurePaths.add[0]: unsupported regular expression flags '
        '"y" (supported: g, i, m, s, u)',
      );
    });

    test('impureImports.allow', () {
      rejects({
        'impureImports': {'allow': 'x'},
      }, 'settings.impureImports.allow: must be an array of non-empty strings');
      rejects(
        {
          'impureImports': {
            'allow': ['('],
          },
        },
        startsWith(
          'settings.impureImports.allow[0]: invalid regular expression',
        ),
      );
    });

    test('impureNamedImports', () {
      const where = 'settings.impureNamedImports';
      rejects({
        'impureNamedImports': {'defaults': 1},
      }, '$where.defaults: must be a boolean');
      rejects({
        'impureNamedImports': {'add': <String, Object?>{}},
      }, '$where.add: must be an array');
      Map<String, Object?> add(Object? item) => {
        'impureNamedImports': {
          'add': [item],
        },
      };
      for (final item in [
        'x',
        {'names': <String>[]},
        {'module': ''},
      ]) {
        rejects(add(item), '$where.add[0]: must be { module, names, reason? }');
      }
      rejects(
        add({
          'module': 'a',
          'names': ['b'],
          'why': 'x',
        }),
        '$where.add[0]: unknown key "why"',
      );
      rejects(
        add({'module': 'a'}),
        '$where.add[0].names: must be an array of non-empty strings',
      );
      rejects(
        add({'module': 'a', 'names': <String>[]}),
        '$where.add[0].names: must list at least one name',
      );
      rejects(
        add({
          'module': 'a',
          'names': ['b'],
          'reason': 1,
        }),
        '$where.add[0].reason: must be a string',
      );
    });

    test('importAliases', () {
      rejects({
        'importAliases': <String, Object?>{},
      }, 'settings.importAliases: must be an array');
      for (final item in [
        'x',
        {'prefix': '', 'target': 'lib/'},
        {'prefix': '@/'},
        {'prefix': 1, 'target': 'lib/'},
      ]) {
        rejects({
          'importAliases': [item],
        }, 'settings.importAliases[0]: must be { prefix, target }');
      }
      rejects({
        'importAliases': [
          {'prefix': '@/', 'target': '', 'x': 1},
        ],
      }, 'settings.importAliases[0]: unknown key "x"');
    });

    test('gateCommand', () {
      rejects({
        'gateCommand': 'flutter test',
      }, 'settings.gateCommand: must be an array of non-empty strings');
      rejects({
        'gateCommand': <String>[],
      }, 'settings.gateCommand: must not be empty');
    });

    test('selfcheck', () {
      rejects({
        'selfcheck': {'mode': 'some'},
      }, 'settings.selfcheck.mode: must be "all" or "first"');
      rejects({
        'selfcheck': {'mode': null},
      }, 'settings.selfcheck.mode: must be "all" or "first"');
      rejects({
        'selfcheck': {'failurePattern': ''},
      }, 'settings.selfcheck.failurePattern: must be a non-empty string');
      rejects(
        {
          'selfcheck': {'failurePattern': '{gate}('},
        },
        startsWith(
          'settings.selfcheck.failurePattern: invalid regular expression "x("',
        ),
      );
      resolveSettings({
        'selfcheck': {'mode': 'all'},
      });
    });

    test('gateCommand and selfcheck.mode are resolved', () {
      final settings = resolveSettings({
        'gateCommand': ['flutter', 'test', '--coverage', '--branch-coverage'],
        'selfcheck': {'mode': 'first'},
      });
      expect(settings.gateCommand, [
        'flutter',
        'test',
        '--coverage',
        '--branch-coverage',
      ]);
      expect(settings.selfcheckMode, 'first');
    });

    test('imports', () {
      rejects({'imports': 'allowlist'}, 'settings.imports: must be an object');
      rejects({
        'imports': {'modes': 'allowlist'},
      }, 'settings.imports: unknown key "modes"');
      rejects({
        'imports': {'mode': 'strict'},
      }, 'settings.imports.mode: must be "blocklist" or "allowlist"');
      resolveSettings({
        'imports': {'mode': 'blocklist'},
      });
      rejects({
        'imports': {'allow': 'x'},
      }, 'settings.imports.allow: must be an array');
      Map<String, Object?> allow(Object? item) => {
        'imports': {
          'allow': [item],
        },
      };
      const where = 'settings.imports.allow[0]';
      for (final item in [
        '',
        1,
        <String, Object?>{},
        {'pattern': ''},
        {'module': ''},
      ]) {
        rejects(
          allow(item),
          '$where: must be a package name, { pattern, flags? } or '
          '{ module, names }',
        );
      }
      rejects(
        allow({'pattern': 'a', 'reason': 'x'}),
        '$where: unknown key "reason"',
      );
      rejects(
        allow({'pattern': 'a', 'flags': 1}),
        '$where.flags: must be a string',
      );
      rejects(
        allow({'pattern': '('}),
        startsWith('$where: invalid regular expression'),
      );
      rejects(
        allow({
          'module': 'a',
          'names': ['b'],
          'reason': 'x',
        }),
        '$where: unknown key "reason"',
      );
      rejects(
        allow({'module': 'a', 'names': <String>[]}),
        '$where.names: must list at least one name',
      );
      rejects(
        allow({'module': 'a'}),
        '$where.names: must be an array of non-empty strings',
      );
    });

    test('stryker', () {
      rejects({
        'stryker': {'configFile': ''},
      }, 'settings.stryker.configFile: must be a non-empty string');
      rejects({
        'stryker': {'reportFile': 1},
      }, 'settings.stryker.reportFile: must be a non-empty string');
      rejects({
        'stryker': {'config': 'x'},
      }, 'settings.stryker: unknown key "config"');
    });
  });

  group('the built-in impure imports', () {
    final rules = resolveSettings(<String, Object?>{}).impureImports;
    String? reasonFor(String uri) {
      for (final rule in rules) {
        if (rule.regex.hasMatch(uri)) {
          return rule.reason;
        }
      }
      return null;
    }

    test('what is rejected', () {
      expect({
        for (final uri in [
          'package:flutter/material.dart',
          'package:flutter/foundation.dart',
          'package:flutter_bloc/flutter_bloc.dart',
          'package:flutter_secure_storage/flutter_secure_storage.dart',
          'package:flutter_riverpod/flutter_riverpod.dart',
          'dart:ui',
          'dart:io',
          'dart:ffi',
          'dart:isolate',
          'dart:mirrors',
          'dart:html',
          'dart:js',
          'dart:js_interop',
          'dart:js_util',
          'package:web/web.dart',
          'package:http/http.dart',
          'package:dio/dio.dart',
          'package:shared_preferences/shared_preferences.dart',
          'package:bloc/bloc.dart',
          'package:provider/provider.dart',
          'package:riverpod/riverpod.dart',
          'package:hooks_riverpod/hooks_riverpod.dart',
          'package:rxdart/rxdart.dart',
          'package:firebase_core/firebase_core.dart',
          'package:hive_flutter/hive_flutter.dart',
          'package:sentry_flutter/sentry_flutter.dart',
          'package:sqlite3/sqlite3.dart',
          'package:postgres/postgres.dart',
        ])
          uri: reasonFor(uri),
      }, isNot(containsValue(isNull)));
      expect(reasonFor('package:flutter/widgets.dart'), 'Flutter framework');
      expect(reasonFor('dart:io'), 'file system / network / process access');
      expect(reasonFor('package:dio/dio.dart'), 'HTTP client');
      expect(reasonFor('package:provider/provider.dart'), 'state management');
    });

    test('what 0.2.0 added to the list, each with its reason', () {
      const added = {
        'package:go_router/go_router.dart': 'Flutter plugin or UI package',
        'package:auto_route/auto_route.dart': 'Flutter plugin or UI package',
        'package:cached_network_image/cached_network_image.dart':
            'Flutter plugin or UI package',
        'package:google_fonts/google_fonts.dart':
            'Flutter plugin or UI package',
        'package:connectivity_plus/connectivity_plus.dart':
            'device or platform access',
        'package:device_info_plus/device_info_plus.dart':
            'device or platform access',
        'package:package_info_plus/package_info_plus.dart':
            'device or platform access',
        'package:share_plus/share_plus.dart': 'device or platform access',
        'package:battery_plus/battery_plus.dart': 'device or platform access',
        'package:sensors_plus/sensors_plus.dart': 'device or platform access',
        'package:network_info_plus/network_info_plus.dart':
            'device or platform access',
        'package:url_launcher/url_launcher.dart': 'device or platform access',
        'package:permission_handler/permission_handler.dart':
            'device or platform access',
        'package:geolocator/geolocator.dart': 'device or platform access',
        'package:image_picker/image_picker.dart': 'device or platform access',
        'package:file_picker/file_picker.dart': 'device or platform access',
        'package:local_auth/local_auth.dart': 'device or platform access',
        'package:file/file.dart': 'file system / network / process access',
        'package:process/process.dart':
            'file system / network / process access',
        'package:platform/platform.dart':
            'file system / network / process access',
        'package:socket_io_client/socket_io_client.dart': 'HTTP client',
        'package:mqtt_client/mqtt_client.dart': 'HTTP client',
        'package:get_storage/get_storage.dart': 'persistence',
        'package:realm/realm.dart': 'persistence',
        'package:floor/floor.dart': 'persistence',
        'package:hydrated_bloc/hydrated_bloc.dart': 'state management',
        'package:replay_bloc/replay_bloc.dart': 'state management',
        'package:state_notifier/state_notifier.dart': 'state management',
        'package:signals/signals.dart': 'state management',
        'package:async_redux/async_redux.dart': 'state management',
        'package:watch_it/watch_it.dart': 'state management',
        'package:stacked/stacked.dart': 'state management',
        'package:supabase/supabase.dart': 'external service SDK',
        'package:appwrite/appwrite.dart': 'external service SDK',
        'package:googleapis/googleapis.dart': 'external service SDK',
        'package:google_sign_in/google_sign_in.dart': 'external service SDK',
        'package:in_app_purchase/in_app_purchase.dart': 'external service SDK',
      };
      expect({for (final uri in added.keys) uri: reasonFor(uri)}, added);
    });

    test('packages that compute and hold data are not on the list, also '
        'when their name starts like one that is', () {
      for (final name in [
        'decimal',
        'intl',
        'collection',
        'meta',
        'json_annotation',
        'equatable',
        'freezed_annotation',
        'path',
        'clock',
        'logging',
        'characters',
        'fixnum',
        'quiver',
        'tuple',
        'file_utils',
        'processing',
        'platforms',
        'signals_core',
        'realm_common',
        'http_parser',
      ]) {
        expect(reasonFor('package:$name/$name.dart'), isNull, reason: name);
      }
    });

    test('the reason of every rule', () {
      expect(
        {
          for (final uri in [
            'package:flutter/material.dart',
            'package:flutter_bloc/flutter_bloc.dart',
            'package:hive_flutter/hive_flutter.dart',
            'dart:ui',
            'dart:ui_web',
            'dart:isolate',
            'dart:html',
            'dart:js_interop',
            'package:web/web.dart',
            'package:js/js.dart',
            'package:http/http.dart',
            'package:sqflite/sqflite.dart',
            'package:postgres/postgres.dart',
            'package:get_it/get_it.dart',
            'package:firebase_auth/firebase_auth.dart',
            'package:sentry/sentry.dart',
          ])
            uri: reasonFor(uri),
        },
        {
          'package:flutter/material.dart': 'Flutter framework',
          'package:flutter_bloc/flutter_bloc.dart':
              'Flutter plugin or UI package',
          'package:hive_flutter/hive_flutter.dart':
              'Flutter plugin or UI package',
          'dart:ui': 'Flutter engine',
          'dart:ui_web': 'Flutter engine',
          'dart:isolate': 'file system / network / process access',
          'dart:html': 'browser API',
          'dart:js_interop': 'browser API',
          'package:web/web.dart': 'browser API',
          'package:js/js.dart': 'browser API',
          'package:http/http.dart': 'HTTP client',
          'package:sqflite/sqflite.dart': 'persistence',
          'package:postgres/postgres.dart': 'database client',
          'package:get_it/get_it.dart': 'state management',
          'package:firebase_auth/firebase_auth.dart': 'external service SDK',
          'package:sentry/sentry.dart': 'external service SDK',
        },
      );
    });

    test('what is not', () {
      for (final uri in [
        'dart:core',
        'dart:async',
        'dart:math',
        'dart:convert',
        'dart:collection',
        'dart:typed_data',
        'package:json_annotation/json_annotation.dart',
        'package:meta/meta.dart',
        'package:collection/collection.dart',
        'package:decimal/decimal.dart',
        'package:intl/intl.dart',
        'package:app/models/shipping_fee.dart',
        // Only the first segment is the package: these are other packages.
        'package:http_parser/http_parser.dart',
        'package:flutterx/flutterx.dart',
        'package:xflutter/x.dart',
        'package:a/b_flutter/c.dart',
        'package:provider_x/x.dart',
        'dart:iox',
        '../io.dart',
        'shipping_fee.g.dart',
      ]) {
        expect(reasonFor(uri), isNull, reason: uri);
      }
    });
  });

  group('the settings of check, resolved', () {
    test('defaults: false drops the built-in rules, add appends', () {
      final settings = resolveSettings({
        'impureImports': {
          'defaults': false,
          'add': [
            '^package:app/blocs/',
            {'pattern': 'SERVICE', 'flags': 'i', 'reason': 'service layer'},
          ],
          'allow': ['^package:dio/'],
        },
        'impurePaths': {
          'add': [
            {'pattern': '^lib/pages/', 'reason': 'page'},
          ],
        },
        'forbiddenSource': {
          'defaults': false,
          'add': [r'\bDateTime\.now\('],
        },
      });
      expect(settings.impureImports.map((rule) => rule.reason), [
        'matches ^package:app/blocs/',
        'service layer',
      ]);
      expect(
        settings.impureImports.last.regex.hasMatch('a/service.dart'),
        isTrue,
      );
      expect(
        settings.allowedImports.single.hasMatch('package:dio/dio.dart'),
        isTrue,
      );
      expect(settings.impurePaths.map((rule) => rule.reason), [
        'generated file',
        'page',
      ]);
      expect(settings.forbiddenSourceDefaults, isFalse);
      expect(
        settings.forbiddenSource.single.reason,
        r'matches \bDateTime\.now\(',
      );
    });

    test('a rule without a reason says which pattern matched', () {
      final settings = resolveSettings({
        'impurePaths': {
          'defaults': false,
          'add': [
            {'pattern': '^lib/pages/'},
          ],
        },
      });
      expect(settings.impurePaths.single.reason, 'matches ^lib/pages/');
    });

    test('flags: each one switches on its own option, and only that', () {
      RegExp compiled(String? flags) => resolveSettings({
        'impurePaths': {
          'defaults': false,
          'add': [
            {'pattern': 'a', 'flags': ?flags},
          ],
        },
      }).impurePaths.single.regex;
      List<bool> options(RegExp regex) => [
        regex.isCaseSensitive,
        regex.isMultiLine,
        regex.isDotAll,
        regex.isUnicode,
      ];
      expect(options(compiled(null)), [true, false, false, false]);
      expect(options(compiled('g')), [true, false, false, false]);
      expect(options(compiled('i')), [false, false, false, false]);
      expect(options(compiled('m')), [true, true, false, false]);
      expect(options(compiled('s')), [true, false, true, false]);
      expect(options(compiled('u')), [true, false, false, true]);
    });

    test('generated files cannot be gates', () {
      final rule = resolveSettings(<String, Object?>{}).impurePaths.single;
      expect(rule.regex.hasMatch('lib/models/shipping_fee.g.dart'), isTrue);
      expect(
        rule.regex.hasMatch('lib/models/shipping_fee.freezed.dart'),
        isTrue,
      );
      expect(rule.regex.hasMatch('lib/models/shipping_fee.dart'), isFalse);
      expect(rule.regex.hasMatch('lib/g.dart'), isFalse);
    });

    test('impureNamedImports, importAliases and imports', () {
      final settings = resolveSettings({
        'impureNamedImports': {
          'defaults': false,
          'add': [
            {
              'module': 'dart:math',
              'names': ['Random'],
            },
            {
              'module': 'dart:async',
              'names': ['Timer'],
              'reason': 'a timer',
            },
          ],
        },
        'importAliases': [
          {'prefix': 'package:shared/', 'target': '../shared/lib/'},
        ],
        'imports': {
          'mode': 'allowlist',
          'allow': [
            'package:decimal',
            {'pattern': '^PACKAGE:acme_', 'flags': 'i'},
            {
              'module': 'package:intl/intl.dart',
              'names': ['NumberFormat'],
            },
          ],
        },
      });
      expect(
        settings.impureNamedImports.map(
          (rule) => '${rule.module} ${rule.names} ${rule.reason}',
        ),
        [
          'dart:math [Random] not allowed in a pure module',
          'dart:async [Timer] a timer',
        ],
      );
      final alias = settings.importAliases.single;
      expect(
        (alias.prefix, alias.target),
        ('package:shared/', '../shared/lib/'),
      );
      expect(settings.importMode, ImportMode.allowlist);
      final [byName, byPattern, byNames] = settings.importAllow;
      expect(
        (byName.module, byName.regex, byName.names),
        ('package:decimal', null, null),
      );
      expect(byPattern.regex!.hasMatch('package:acme_money/a.dart'), isTrue);
      expect((byPattern.module, byPattern.names), (null, null));
      expect(byNames.module, 'package:intl/intl.dart');
      expect(byNames.names, ['NumberFormat']);
    });

    test('spec.rewrite: an empty list is a setting, null is not', () {
      expect(
        resolveSettings({
          'spec': {'rewrite': <Object>[]},
        }).specRewrite,
        isEmpty,
      );
      expect(
        resolveSettings({
          'spec': {'rewrite': null},
        }).specRewrite,
        isNull,
      );
    });
  });
}
