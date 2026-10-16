import 'dart:convert';

import 'package:test/test.dart';
import 'package:test_gates/src/mutation_reuse.dart';
import 'package:test_gates/src/types.dart';

const aliases = [ImportAlias('package:app/', 'lib/')];

/// Other packages as a package_config.json and a lock file give them: one
/// at a path next to the package, the others from the pub cache.
const PackageRoots roots = (
  roots: {'other': '../other/lib/', 'test': null, 'hosted': null},
  problem: null,
);

Reach reach(
  List<String> starts,
  Map<String, String> files, {
  PackageRoots packages = roots,
}) => reachOf(starts, aliases, (path) => files[path], packages: packages);

/// A package: two gates, their tests, a helper of one test, a file one gate
/// imports, and a file that nothing imports.
Map<String, String> package() => {
  'lib/total.dart':
      "import 'package:app/fee.dart';\nint total(int x) => x + fee(x);\n",
  'lib/fee.dart': 'int fee(int x) => x > 10 ? 0 : 5;\n',
  'lib/tax.dart': 'int tax(int x) => x ~/ 10;\n',
  'lib/unused.dart': 'int unused() => 1;\n',
  'test/total_test.dart':
      "import 'package:test/test.dart';\nimport 'package:app/total.dart';\n",
  'test/tax_test.dart':
      "import 'package:test/test.dart';\nimport 'helpers.dart';\n"
      "import '../lib/tax.dart';\n",
  'test/helpers.dart': 'int one() => 1;\n',
  'pubspec.lock': 'packages: {}\n',
};

const gates = {
  'lib/total.dart': ['test/total_test.dart'],
  'lib/tax.dart': ['test/tax_test.dart'],
};

/// The gates as they are in [files]; the fingerprint of a file is its text.
List<GateState> statesOf(Map<String, String> files) => [
  for (final MapEntry(key: gate, value: tests) in gates.entries)
    GateState(gate, {
      for (final path in reach([gate, ...tests], files).files)
        path: files[path] ?? 'missing',
    }),
];

Map<String, String> contextOf(Map<String, String> files) => {
  'the Dart SDK': '3.13.2',
  for (final file in configFiles) file: files[file] ?? 'missing',
};

/// The record of a run of every gate on [files], with the report [report].
String recordOf(Map<String, String> files, {String report = 'r1'}) =>
    recordAfterRun(
      reportVerified: true,
      last: null,
      context: contextOf(files),
      report: report,
      ran: statesOf(files),
      written: gates.keys.toList(),
    );

ReusePlan plan(
  Map<String, String> files, {
  String? recordText,
  String? report = 'r1',
  String? forced,
  String? problem,
  List<String> timedOut = const [],
  List<GateState>? states,
}) => planReuse(
  forced: forced,
  problem: problem,
  recordText: recordText,
  context: contextOf(files),
  report: report,
  timedOut: timedOut,
  gates: states ?? statesOf(files),
);

List<String> rerunOf(ReusePlan plan) => [
  for (final (:gate, :why) in plan.rerun) '$gate: $why',
];

void main() {
  test('where the record is, and the files that may affect every gate', () {
    expect(recordFile, '.dart_tool/test_gates/mutation-record.json');
    expect(configFiles, [
      'pubspec.yaml',
      'pubspec.lock',
      'pubspec_overrides.yaml',
      'analysis_options.yaml',
      'dart_test.yaml',
      'build.yaml',
      'test-gates.json',
    ]);
  });

  group('reachOf', () {
    test('follows imports, exports and parts inside the package, through '
        'relative URIs and package:<name>/, however many imports away', () {
      final files = {
        'lib/a.dart':
            "import 'b.dart';\nexport 'package:app/c.dart';\npart 'a.g.dart';\n",
        'lib/a.g.dart': "part of 'a.dart';\n",
        'lib/b.dart': "import 'd/e.dart';\n",
        'lib/c.dart': '',
        'lib/d/e.dart':
            "import '../b.dart';\nimport 'package:hosted/x.dart';\n",
      };
      final found = reach(['lib/a.dart'], files);
      expect(found.files, [
        'lib/a.dart',
        'lib/a.g.dart',
        'lib/b.dart',
        'lib/c.dart',
        'lib/d/e.dart',
      ]);
      expect(found.readsFiles, isFalse);
      expect(found.problem, isNull);
    });

    test('each start once, and the files sorted', () {
      final files = {'lib/b.dart': '', 'lib/a.dart': "import 'b.dart';\n"};
      expect(reach(['lib/b.dart', 'lib/a.dart', 'lib/b.dart'], files).files, [
        'lib/a.dart',
        'lib/b.dart',
      ]);
    });

    test('a file that can read files no import names: dart:io, package:file, '
        'package:test_descriptor, a golden file, an asset', () {
      for (final source in [
        "import 'dart:io';\n",
        "import 'package:file/file.dart';\n",
        "import 'package:test_descriptor/test_descriptor.dart';\n",
        'void f() => matchesGoldenFile;\n',
        'void f() => rootBundle;\n',
        'void f(c) => DefaultAssetBundle.of(c);\n',
        'void f() => AssetBundle;\n',
        'void f() => PlatformAssetBundle();\n',
        'void f() => CachingAssetBundle;\n',
        "void f() => AssetImage('a.png');\n",
        "void f() => ExactAssetImage('a.png');\n",
        "void f() => Image.asset('a.png');\n",
        "void f() => SvgPicture.asset('a.svg');\n",
        "void f(b) => b.loadString('a.json');\n",
        "void f(b) => b.loadStructuredData('a.json', p);\n",
        "void f(t) => screenMatchesGolden(t, 'a');\n",
        "void f(t) => multiScreenGolden(t, 'a');\n",
        "void f() => testGoldens('a', (t) async {});\n",
        'void f() => loadAppFonts();\n',
        "void f() => goldenTest('a', fileName: 'a', builder: b);\n",
      ]) {
        final files = {
          'test/a_test.dart': "import 'helper.dart';\n",
          'test/helper.dart': source,
        };
        expect(
          reach(['test/a_test.dart'], files).readsFiles,
          isTrue,
          reason: source,
        );
      }
    });

    test('a name like them does not', () {
      final files = {
        'test/a_test.dart':
            'final asset = 1;\nfinal b = x.assets;\nfinal c = asset.length;\n'
            "final d = Image.network('a');\nfinal e = loadStrings;\n",
      };
      expect(reach(['test/a_test.dart'], files).readsFiles, isFalse);
    });

    test('a file that names them in a string or a comment does not', () {
      final files = {
        'test/a_test.dart':
            "// import 'dart:io';\nconst a = 'matchesGoldenFile';\n"
            "import 'dart:convert';\n",
      };
      expect(reach(['test/a_test.dart'], files).readsFiles, isFalse);
    });

    test('a file that cannot be read is the problem', () {
      final found = reach(['lib/a.dart'], {'lib/a.dart': "import 'b.dart';\n"});
      expect(found.files, ['lib/a.dart', 'lib/b.dart']);
      expect(found.problem, 'lib/b.dart cannot be read');
    });

    test('a start that cannot be read is the problem', () {
      expect(reach(['lib/a.dart'], {}).problem, 'lib/a.dart cannot be read');
    });

    test('a URI of a conditional import that is not there is a file that is '
        'missing, not a problem: when it is added, it is a change', () {
      final found = reach(
        ['lib/a.dart'],
        {
          'lib/a.dart':
              "import 'h.dart' if (dart.library.html) 'h_web.dart';\n",
          'lib/h.dart': '',
        },
      );
      expect(found.files, ['lib/a.dart', 'lib/h.dart', 'lib/h_web.dart']);
      expect(found.problem, isNull);
    });

    test('a missing file that is also imported without a condition is the '
        'problem, wherever that import is', () {
      for (final files in [
        {
          'lib/a.dart':
              "import 'h.dart' if (dart.library.html) 'h_web.dart';\n"
              "import 'b.dart';\n",
          'lib/h.dart': '',
          'lib/b.dart': "import 'h_web.dart';\n",
        },
        {
          'lib/a.dart':
              "import 'h_web.dart';\n"
              "import 'h.dart' if (dart.library.html) 'h_web.dart';\n",
          'lib/h.dart': '',
        },
      ]) {
        expect(
          reach(['lib/a.dart'], files).problem,
          'lib/h_web.dart cannot be read',
        );
      }
    });

    test('another package at a path, or a member of the workspace: its files '
        'are followed like those of the package, outside it as well', () {
      final found = reach(
        ['lib/a.dart'],
        {
          'lib/a.dart': "import 'package:other/o.dart';\n",
          '../other/lib/o.dart':
              "import 'src/x.dart';\nexport 'package:other/y.dart';\n"
              "import 'package:test/test.dart';\n",
          '../other/lib/src/x.dart': "import '../../tool/z.dart';\n",
          '../other/lib/y.dart': '',
          '../other/tool/z.dart': "import 'dart:io';\n",
        },
      );
      expect(found.files, [
        '../other/lib/o.dart',
        '../other/lib/src/x.dart',
        '../other/lib/y.dart',
        '../other/tool/z.dart',
        'lib/a.dart',
      ]);
      expect(found.readsFiles, isTrue);
      expect(found.problem, isNull);
    });

    test('a package that the lock file pins is not followed', () {
      final found = reach(
        ['test/a_test.dart'],
        {
          'test/a_test.dart':
              "import 'package:test/test.dart';\nimport 'package:hosted/h.dart';\n",
        },
      );
      expect(found.files, ['test/a_test.dart']);
      expect(found.problem, isNull);
    });

    test('a package that package_config.json does not have is the '
        'problem', () {
      final found = reach(
        ['lib/a.dart'],
        {
          'lib/a.dart':
              "import 'dart:math';\n\nimport 'package:nope/n.dart';\n",
        },
      );
      expect(found.files, ['lib/a.dart']);
      expect(
        found.problem,
        'lib/a.dart:3: "package:nope/n.dart" is not a package of '
        '.dart_tool/package_config.json',
      );
    });

    test('when the packages cannot be told, an import of another package is '
        'the problem, and only then', () {
      const unknown = (roots: <String, String?>{}, problem: 'why');
      final files = {
        'lib/a.dart': "import 'package:app/b.dart';\nimport 'c.dart';\n",
        'lib/b.dart': "import 'dart:io';\nimport '../test/h.dart';\n",
        'test/h.dart': '',
        'lib/c.dart': "\nexport 'package:other/o.dart';\n",
      };
      expect(reach(['lib/b.dart'], files, packages: unknown).problem, isNull);
      expect(
        reach(['lib/a.dart'], files, packages: unknown).problem,
        'lib/c.dart:2: "package:other/o.dart" cannot be followed: why',
      );
    });

    test('a URI that is not written out as Dart reads it is the problem', () {
      final found = reach(
        ['lib/a.dart'],
        {'lib/a.dart': "import 'dart:core';\nimport 'DART:io';\n"},
      );
      expect(
        found.problem,
        'lib/a.dart:2: a URI that is not written out as it is read',
      );
    });

    test('a URI outside the package is followed, through an alias as '
        'well', () {
      final found = reachOf(
        ['test/a_test.dart'],
        [...aliases, const ImportAlias('package:shared/', '../shared/lib/')],
        (path) => {
          'test/a_test.dart':
              "import '../../shared/x.dart';\nimport 'package:shared/s.dart';\n",
          '../shared/x.dart': '',
          '../shared/lib/s.dart': '',
        }[path],
        packages: roots,
      );
      expect(found.files, [
        '../shared/lib/s.dart',
        '../shared/x.dart',
        'test/a_test.dart',
      ]);
      expect(found.problem, isNull);
    });

    test('of two URIs that are not written out, the first is given', () {
      final found = reach(
        ['lib/a.dart'],
        {'lib/a.dart': "import 'DART:io';\nimport 'DART:async';\n"},
      );
      expect(found.problem, startsWith('lib/a.dart:1: '));
    });

    test('the first problem is the one that is given', () {
      final found = reach(
        ['lib/a.dart'],
        {
          'lib/a.dart':
              "import 'DART:io';\nimport 'package:nope/n.dart';\n"
              "import 'b.dart';\n",
        },
      );
      expect(found.problem, startsWith('lib/a.dart:1: '));
    });
  });

  group('packageRootsOf', () {
    String config(List<Map<String, Object?>> packages) =>
        jsonEncode({'configVersion': 2, 'packages': packages});
    Map<String, Object?> entry(String name, String root, [String? lib]) => {
      'name': name,
      'rootUri': root,
      'packageUri': ?lib,
    };
    const lock = '''
# Generated by pub
packages:
  at_path:
    dependency: "direct main"
    description:
      path: "/elsewhere/at_path"
      relative: false
    source: path
    version: "1.0.0"
  flutter:
    dependency: "direct main"
    description: flutter
    source: sdk
    version: "0.0.0"
  from_git:
    dependency: "direct main"
    description:
      url: "https://example.com/g.git"
    source: git
    version: "1.0.0"
  next:
    dependency: "direct main"
    description:
      path: "../next"
      relative: true
    source: path
    version: "1.0.0"
  test:
    dependency: "direct dev"
    description:
      name: test
      url: "https://pub.dev"
    source: "hosted"
    version: "1.27.0"
sdks:
  dart: ">=3.9.0 <4.0.0"
''';
    final package = Uri.directory('/work/app/');
    final file = Uri.file('/work/app/.dart_tool/package_config.json');

    test('a package at a path, or not in the lock file (a member of the '
        'workspace): where its lib/ is, from the package; one that the lock '
        'file pins (hosted, git, sdk): null', () {
      final found = packageRootsOf(
        config: config([
          entry('app', '../', 'lib/'),
          entry('next', '../../next', 'lib/'),
          entry('at_path', 'file:///elsewhere/at_path/', 'lib/'),
          entry('member', '../packages/member', 'lib/'),
          entry('inside', '../tools/inside', 'src/'),
          entry('bare', '../../bare'),
          entry('above', '../../'),
          entry('test', 'file:///cache/hosted/pub.dev/test-1.27.0', 'lib/'),
          entry('from_git', 'file:///cache/git/g-abc/', 'lib/'),
          entry('flutter', 'file:///flutter/packages/flutter', 'lib/'),
        ]),
        lock: lock,
        configFile: file,
        package: package,
      );
      expect(found.problem, isNull);
      expect(found.roots, {
        'app': 'lib/',
        'next': '../next/lib/',
        'at_path': '../../elsewhere/at_path/lib/',
        'member': 'packages/member/lib/',
        'inside': 'tools/inside/src/',
        'bare': '../bare/',
        'above': '../',
        'test': null,
        'from_git': null,
        'flutter': null,
      });
    });

    test('the root of a workspace: from the member below it', () {
      final found = packageRootsOf(
        config: config([
          entry('app', '../packages/app', 'lib/'),
          entry('core', '../packages/core', 'lib/'),
        ]),
        lock: 'packages: {}\n',
        configFile: Uri.file('/ws/.dart_tool/package_config.json'),
        package: Uri.directory('/ws/packages/app/'),
      );
      expect(found.roots, {'app': 'lib/', 'core': '../core/lib/'});
    });

    test('what cannot be read is the problem, and no package is known', () {
      for (final (text, locked, why) in [
        (null, lock, 'there is no .dart_tool/package_config.json'),
        ('{', lock, 'the .dart_tool/package_config.json cannot be read'),
        (
          '{"packages": {}}',
          lock,
          'the .dart_tool/package_config.json cannot be read',
        ),
        (
          config([
            {'name': 'a'},
          ]),
          lock,
          'the .dart_tool/package_config.json cannot be read',
        ),
        (
          config([
            {'rootUri': '../'},
          ]),
          lock,
          'the .dart_tool/package_config.json cannot be read',
        ),
        (
          config([entry('a', '../', 'lib/'), entry('b', 'http://a/b/')]),
          lock,
          'b is not on the disk: http://a/b/',
        ),
        (config([entry('a', '../')]), null, 'there is no pubspec.lock'),
      ]) {
        final found = packageRootsOf(
          config: text,
          lock: locked,
          configFile: file,
          package: package,
        );
        expect(found.problem, '$why (run dart pub get)', reason: text);
        expect(found.roots, isEmpty, reason: text);
      }
    });
  });

  test('testConfigsFor: the directory of the test and every one above it', () {
    expect(testConfigsFor('test/a/b_test.dart'), [
      'test/a/flutter_test_config.dart',
      'test/flutter_test_config.dart',
      'flutter_test_config.dart',
    ]);
    expect(testConfigsFor('a_test.dart'), ['flutter_test_config.dart']);
  });

  group('the record', () {
    test('is written as JSON and read back', () {
      const record = MutationRecord(
        {'k': 'v'},
        'r',
        {
          'lib/a.dart': GateState(
            'lib/a.dart',
            {'lib/a.dart': '1'},
            readsFiles: true,
            everything: 'e',
          ),
          'lib/b.dart': GateState('lib/b.dart', {}),
        },
      );
      final text = encodeRecord(record);
      // Indented, for a person who looks at it.
      expect(text, startsWith('{\n  "version": 1,\n'));
      expect(jsonDecode(text), {
        'version': 1,
        'context': {'k': 'v'},
        'report': 'r',
        'gates': {
          'lib/a.dart': {
            'files': {'lib/a.dart': '1'},
            'readsFiles': true,
            'everything': 'e',
          },
          'lib/b.dart': {'files': <String, String>{}, 'readsFiles': false},
        },
      });
      final read = decodeRecord(text)!;
      expect(read.context, {'k': 'v'});
      expect(read.report, 'r');
      final a = read.gates['lib/a.dart']!;
      expect((a.path, a.readsFiles, a.everything), ('lib/a.dart', true, 'e'));
      expect(a.files, {'lib/a.dart': '1'});
      final b = read.gates['lib/b.dart']!;
      expect((b.path, b.readsFiles, b.everything), ('lib/b.dart', false, null));
    });

    test('anything else is no record', () {
      final good = {
        'version': 1,
        'context': {'k': 'v'},
        'report': 'r',
        'gates': {
          'lib/a.dart': {
            'files': {'lib/a.dart': '1'},
            'readsFiles': false,
          },
        },
      };
      expect(decodeRecord(jsonEncode(good)), isNotNull);
      Map<String, Object?> gate(Map<String, Object?> entry) => {
        ...good,
        'gates': {'lib/a.dart': entry},
      };
      for (final wrong in <Object?>[
        [],
        {...good, 'version': 2},
        {
          ...good,
          'context': {'k': 1},
        },
        {...good, 'context': <Object?>[]},
        {...good, 'report': 1},
        {...good, 'gates': <Object?>[]},
        gate({'readsFiles': false}),
        gate({
          'files': {'lib/a.dart': 1},
          'readsFiles': false,
        }),
        gate({'files': <String, String>{}}),
        gate({
          'files': <String, String>{},
          'readsFiles': false,
          'everything': 1,
        }),
        gate({}),
        {
          ...good,
          'gates': {'lib/a.dart': 1},
        },
      ]) {
        expect(decodeRecord(jsonEncode(wrong)), isNull, reason: '$wrong');
      }
      expect(decodeRecord('{'), isNull);
      expect(decodeRecord(''), isNull);
    });
  });

  group('planReuse: the negative controls', () {
    test('(a) a file the gate imports changed: that gate alone runs again', () {
      final before = package();
      final now = {...before, 'lib/fee.dart': 'int fee(int x) => 0;\n'};
      final result = plan(now, recordText: recordOf(before));
      expect(result.full, isNull);
      expect(rerunOf(result), ['lib/total.dart: changed lib/fee.dart']);
      expect(result.reused, ['lib/tax.dart']);
    });

    test(
      '(b) a helper of a test changed: the gate of that test runs again',
      () {
        final before = package();
        final now = {...before, 'test/helpers.dart': 'int one() => 2;\n'};
        final result = plan(now, recordText: recordOf(before));
        expect(rerunOf(result), ['lib/tax.dart: changed test/helpers.dart']);
        expect(result.reused, ['lib/total.dart']);
      },
    );

    test('(c) a file no gate reaches changed: nothing runs again', () {
      final before = package();
      final now = {...before, 'lib/unused.dart': 'int unused() => 2;\n'};
      final result = plan(now, recordText: recordOf(before));
      expect(result.full, isNull);
      expect(result.rerun, isEmpty);
      expect(result.reused, ['lib/total.dart', 'lib/tax.dart']);
    });

    test('(d) pubspec.lock changed: every mutant', () {
      final before = package();
      final now = {...before, 'pubspec.lock': 'packages: {a: 1}\n'};
      expect(
        plan(now, recordText: recordOf(before)).full,
        'changed since the last run: pubspec.lock',
      );
    });

    test('(e) no record: every mutant', () {
      expect(plan(package()).full, 'there is no record of a run to reuse');
    });
  });

  group('planReuse', () {
    test('--force, CI: every mutant, whatever else is the case', () {
      final files = package();
      expect(
        plan(
          files,
          recordText: recordOf(files),
          forced: '--force',
          problem: 'p',
        ).full,
        '--force',
      );
    });

    test('an import that cannot be told: every mutant, with why', () {
      final files = package();
      final result = plan(files, recordText: recordOf(files), problem: 'x');
      expect(
        result.full,
        'what a gate depends on cannot be told from the '
        'imports: x',
      );
      expect(result.rerun, isEmpty);
      expect(result.reused, isEmpty);
    });

    test('a record that cannot be read: every mutant', () {
      expect(
        plan(package(), recordText: '{').full,
        'the record of the last run cannot be read: $recordFile',
      );
    });

    test('a change of the context names what changed, at most three', () {
      final before = package();
      final now = {
        ...before,
        'pubspec.yaml': 'a',
        'pubspec.lock': 'b',
        'dart_test.yaml': 'c',
        'build.yaml': 'd',
        'test-gates.json': 'e',
      };
      expect(
        plan(now, recordText: recordOf(before)).full,
        'changed since the last run: build.yaml, dart_test.yaml, pubspec.lock, '
        'and 2 more',
      );
      // Three and four.
      final three = {
        ...before,
        'a': 'x',
        'pubspec.lock': 'b',
        'build.yaml': 'd',
      };
      expect(
        planReuse(
          forced: null,
          problem: null,
          recordText: recordOf(before),
          context: {...contextOf(three), 'a': 'x'},
          report: 'r1',
          timedOut: const [],
          gates: statesOf(three),
        ).full,
        'changed since the last run: a, build.yaml, pubspec.lock',
      );
      expect(
        planReuse(
          forced: null,
          problem: null,
          recordText: recordOf(before),
          context: {...contextOf(three), 'a': 'x', 'b': 'y'},
          report: 'r1',
          timedOut: const [],
          gates: statesOf(three),
        ).full,
        'changed since the last run: a, b, build.yaml, and 1 more',
      );
    });

    test('a key that only one side has is a change', () {
      final files = package();
      final result = planReuse(
        forced: null,
        problem: null,
        recordText: recordOf(files),
        context: {...contextOf(files), 'new': 'x'},
        report: 'r1',
        timedOut: const [],
        gates: statesOf(files),
      );
      expect(result.full, 'changed since the last run: new');
    });

    test('a report that is not the one the last run left: every mutant', () {
      final files = package();
      for (final report in ['r2', null]) {
        expect(
          plan(files, recordText: recordOf(files), report: report).full,
          'the report is not the one the last run left',
        );
      }
    });

    test('nothing changed: every gate reused', () {
      final files = package();
      final result = plan(
        files,
        recordText: recordOf(files),
        timedOut: ['lib/tax.dart'],
      );
      expect(result.full, isNull);
      expect(result.rerun, isEmpty);
      expect(result.reused, ['lib/total.dart', 'lib/tax.dart']);
    });

    test('a gate that is not in the record runs again', () {
      final files = package();
      final record = recordAfterRun(
        reportVerified: true,
        last: null,
        context: contextOf(files),
        report: 'r1',
        ran: statesOf(files),
        written: ['lib/tax.dart'],
      );
      expect(rerunOf(plan(files, recordText: record)), [
        'lib/total.dart: the last run left no result of it',
      ]);
    });

    test('a file that the gate reaches now and did not before, or the other '
        'way round, is a change', () {
      final before = package();
      final now = {
        ...before,
        'lib/tax.dart': "import 'unused.dart';\nint tax(int x) => x ~/ 10;\n",
        'test/total_test.dart': "import 'package:app/total.dart';\n",
      };
      expect(rerunOf(plan(now, recordText: recordOf(before))), [
        'lib/total.dart: changed test/total_test.dart',
        'lib/tax.dart: changed lib/tax.dart; not in the last record (new to '
            'the comparison): lib/unused.dart',
      ]);
    });

    test('files that the record does not have are named apart from the '
        'files that changed, at most three of each', () {
      final files = package();
      GateState without(GateState gate, List<String> paths) =>
          GateState(gate.path, {
            for (final MapEntry(:key, :value) in gate.files.entries)
              if (!paths.contains(key)) key: value,
          });
      final extra = {
        'lib/total.dart':
            "import 'package:app/fee.dart';\nimport 'a.dart';\n"
            "import 'b.dart';\nimport 'c.dart';\nimport 'd.dart';\n"
            'int total(int x) => x + fee(x);\n',
        'lib/a.dart': '',
        'lib/b.dart': '',
        'lib/c.dart': '',
        'lib/d.dart': '',
      };
      final more = {...files, ...extra};
      final states = statesOf(more);
      final fresh = ['lib/a.dart', 'lib/b.dart', 'lib/c.dart', 'lib/d.dart'];
      // The record of a version that compared fewer files.
      String record({String? fee}) => recordAfterRun(
        reportVerified: true,
        last: null,
        context: contextOf(more),
        report: 'r1',
        ran: [
          for (final gate in states)
            without(
              fee != null && gate.path == 'lib/total.dart'
                  ? GateState(gate.path, {...gate.files, 'lib/fee.dart': fee})
                  : gate,
              [...fresh, 'lib/total.dart'],
            ),
        ],
        written: gates.keys.toList(),
      );
      expect(rerunOf(plan(more, recordText: record(), states: states)), [
        'lib/total.dart: not in the last record (new to the comparison): '
            'lib/a.dart, lib/b.dart, lib/c.dart, and 2 more',
      ]);
      expect(
        rerunOf(
          plan(
            more,
            recordText: record(fee: 'old'),
            states: states,
          ),
        ),
        [
          'lib/total.dart: changed lib/fee.dart; not in the last record (new '
              'to the comparison): lib/a.dart, lib/b.dart, lib/c.dart, and 2 '
              'more',
        ],
      );
    });

    test('a gate whose tests can read files runs again when any file of the '
        'package changed, or when the files cannot be listed', () {
      final files = package();
      GateState reading(GateState gate, String? everything) => GateState(
        gate.path,
        gate.files,
        readsFiles: true,
        everything: everything,
      );
      final before = statesOf(files);
      final record = recordAfterRun(
        reportVerified: true,
        last: null,
        context: contextOf(files),
        report: 'r1',
        ran: [reading(before.first, 'all-1'), before.last],
        written: gates.keys.toList(),
      );
      ReusePlan with_(String? everything) => plan(
        files,
        recordText: record,
        states: [reading(before.first, everything), before.last],
      );
      expect(with_('all-1').rerun, isEmpty);
      expect(rerunOf(with_('all-2')), [
        'lib/total.dart: its tests can read any file, and a file of the '
            'package changed',
      ]);
      expect(rerunOf(with_(null)), [
        'lib/total.dart: its tests can read any file, and the files of the '
            'package cannot be listed',
      ]);
    });

    test('a gate that did not read files and does now runs again', () {
      final files = package();
      final now = statesOf(files);
      final result = plan(
        files,
        recordText: recordOf(files),
        states: [
          GateState(
            now.first.path,
            now.first.files,
            readsFiles: true,
            everything: 'all',
          ),
          now.last,
        ],
      );
      expect(rerunOf(result), [
        'lib/total.dart: its tests can read any file, and a file of the '
            'package changed',
      ]);
    });

    test('when a gate runs again, a reused gate with a mutant that timed out '
        'runs again as well', () {
      final before = package();
      final now = {...before, 'lib/fee.dart': 'int fee(int x) => 0;\n'};
      final result = plan(
        now,
        recordText: recordOf(before),
        timedOut: ['lib/tax.dart'],
      );
      expect(rerunOf(result), [
        'lib/total.dart: changed lib/fee.dart',
        'lib/tax.dart: a mutant of it timed out in the last run',
      ]);
      expect(result.reused, isEmpty);
    });
  });

  group('timedOutGates', () {
    String report(Map<String, List<String>> statuses) => jsonEncode({
      'files': {
        for (final MapEntry(key: path, value: list) in statuses.entries)
          path: {
            'mutants': [
              for (final status in list) {'status': status},
            ],
          },
      },
    });

    test('the gates with a Timeout, in the order given, whatever the '
        'spelling of the path in the report', () {
      expect(
        timedOutGates(
          report({
            './lib/b.dart': ['Killed', 'Timeout'],
            'lib/a.dart': ['Timeout'],
            'lib/c.dart': ['Killed', 'Survived'],
          }),
          ['lib/a.dart', 'lib/b.dart', 'lib/c.dart', 'lib/d.dart'],
        ),
        ['lib/a.dart', 'lib/b.dart'],
      );
    });

    test('no report, or one that cannot be read: none', () {
      expect(timedOutGates(null, ['lib/a.dart']), isEmpty);
      expect(timedOutGates('{', ['lib/a.dart']), isEmpty);
      expect(timedOutGates('[]', ['lib/a.dart']), isEmpty);
      expect(
        timedOutGates(
          jsonEncode({
            'files': {
              'lib/a.dart': {'mutants': 'Timeout'},
              'lib/b.dart': <Object?>[],
            },
          }),
          ['lib/a.dart', 'lib/b.dart'],
        ),
        isEmpty,
      );
    });
  });

  group('recordAfterRun', () {
    GateState gate(String path, String fingerprint) =>
        GateState(path, {path: fingerprint});

    Map<String, String> filesOf(String record) => {
      for (final entry in decodeRecord(record)!.gates.values)
        entry.path: entry.files[entry.path]!,
    };

    final last = recordAfterRun(
      reportVerified: true,
      last: null,
      context: {'k': 'v'},
      report: 'r1',
      ran: [gate('lib/a.dart', '1'), gate('lib/b.dart', '1')],
      written: ['lib/a.dart', 'lib/b.dart'],
    );

    test('the gates of the run that are in the report, and the others of the '
        'last record when the context is the same', () {
      final record = recordAfterRun(
        reportVerified: true,
        last: last,
        context: {'k': 'v'},
        report: 'r2',
        ran: [gate('lib/b.dart', '2'), gate('lib/c.dart', '2')],
        written: ['lib/b.dart'],
      );
      expect(filesOf(record), {'lib/a.dart': '1', 'lib/b.dart': '2'});
      expect(decodeRecord(record)!.report, 'r2');
      expect(decodeRecord(record)!.context, {'k': 'v'});
    });

    test('a gate of the run that is not in the report is dropped', () {
      final record = recordAfterRun(
        reportVerified: true,
        last: last,
        context: {'k': 'v'},
        report: 'r2',
        ran: [gate('lib/b.dart', '2')],
        written: [],
      );
      expect(filesOf(record), {'lib/a.dart': '1'});
    });

    test(
      'a report that was not checked against the record before the run '
      '(another report or context, no record): only the gates of the run',
      () {
        final record = recordAfterRun(
          reportVerified: false,
          last: last,
          context: {'k': 'v'},
          report: 'r2',
          ran: [gate('lib/b.dart', '2')],
          written: ['lib/b.dart'],
        );
        expect(filesOf(record), {'lib/b.dart': '2'});
      },
    );

    test('in another context, or after a record that cannot be read, only the '
        'gates of the run', () {
      for (final (before, context) in [
        (last, {'k': 'w'}),
        ('{', {'k': 'v'}),
        (null, {'k': 'v'}),
      ]) {
        final record = recordAfterRun(
          reportVerified: true,
          last: before,
          context: context,
          report: 'r2',
          ran: [gate('lib/b.dart', '2')],
          written: ['lib/b.dart'],
        );
        expect(filesOf(record), {'lib/b.dart': '2'});
      }
    });
  });

  group('reportVerified', () {
    final files = package();
    final record = recordOf(files);

    test('the record can be read, the context is the same and the report is '
        'the one it names', () {
      expect(
        reportVerified(
          recordText: record,
          context: contextOf(files),
          report: 'r1',
        ),
        isTrue,
      );
    });

    test('anything else is not', () {
      for (final (text, context, report) in [
        (null, contextOf(files), 'r1'),
        ('{', contextOf(files), 'r1'),
        (record, {...contextOf(files), 'pubspec.lock': 'x'}, 'r1'),
        (record, contextOf(files), 'r2'),
        (record, contextOf(files), null),
      ]) {
        expect(
          reportVerified(recordText: text, context: context, report: report),
          isFalse,
        );
      }
    });
  });

  group('the package', () {
    test('usesFlutter: a dependency from the Flutter SDK', () {
      expect(
        usesFlutter('name: a\ndependencies:\n  flutter:\n    sdk: flutter\n'),
        isTrue,
      );
      expect(
        usesFlutter(
          'name: a\ndev_dependencies:\n  flutter_test:\n    sdk:   flutter  \n',
        ),
        isTrue,
      );
      expect(usesFlutter('name: a\ndependencies:\n  path: ^1.0.0\n'), isFalse);
      expect(usesFlutter('name: a\n# sdk: flutter\n'), isFalse);
      expect(usesFlutter('name: a\n  sdk: flutterish\n'), isFalse);
    });

    test('inWorkspace: resolution: workspace', () {
      expect(inWorkspace('name: a\nresolution: workspace\n'), isTrue);
      expect(inWorkspace('name: a\nresolution:   workspace  \n'), isTrue);
      expect(inWorkspace('name: a\n'), isFalse);
      expect(inWorkspace('name: a\n# resolution: workspace\n'), isFalse);
      expect(inWorkspace('name: a\nresolution: workspaces\n'), isFalse);
      expect(inWorkspace('name: a\n  resolution: workspace\n'), isFalse);
    });

    test('isWorkspaceRoot: a top-level workspace key', () {
      expect(isWorkspaceRoot('name: r\nworkspace:\n  - packages/a\n'), isTrue);
      expect(isWorkspaceRoot('name: r\nworkspace: [packages/a]\n'), isTrue);
      expect(isWorkspaceRoot('name: r\n'), isFalse);
      expect(isWorkspaceRoot('name: r\n  workspace:\n'), isFalse);
      expect(isWorkspaceRoot('name: r\nworkspaces:\n'), isFalse);
    });

    test('workspaceFiles: the pubspec and the lock file of the root, from the '
        'package', () {
      expect(workspaceFiles(2), ['../../pubspec.yaml', '../../pubspec.lock']);
      expect(workspaceFiles(1), ['../pubspec.yaml', '../pubspec.lock']);
    });

    test(
      'flutterVersionOf: the versions and revisions of --version --machine',
      () {
        const machine =
            '{"frameworkVersion": "3.47.2", "channel": "stable", '
            '"frameworkRevision": "abc", "engineRevision": "def", '
            '"dartSdkVersion": "3.13.2", "flutterRoot": "/somewhere"}';
        expect(
          flutterVersionOf('Some banner\n$machine\n', null),
          'Flutter 3.47.2 (abc), engine def, Dart 3.13.2',
        );
        // An object in the object: the first brace is the start.
        expect(
          flutterVersionOf(
            '{"frameworkVersion": "3.47.2", "devTools": {"v": "2"}}',
            null,
          ),
          'Flutter 3.47.2 (?), engine ?, Dart ?',
        );
        expect(
          flutterVersionOf('{"frameworkVersion": "3.47.2"}', null),
          'Flutter 3.47.2 (?), engine ?, Dart ?',
        );
      },
    );

    test('flutterVersionOf: else what --version printed, else that it cannot '
        'be told', () {
      expect(
        flutterVersionOf('not json', ' Flutter 3.47.2 \n'),
        'Flutter 3.47.2',
      );
      expect(flutterVersionOf('{', 'Flutter 3.47.2'), 'Flutter 3.47.2');
      expect(flutterVersionOf('[]', null), 'cannot be told');
      expect(flutterVersionOf(null, '  '), 'cannot be told');
      expect(flutterVersionOf(null, null), 'cannot be told');
    });
  });

  group('describeReuse', () {
    test('every mutant', () {
      expect(describeReuse(const ReusePlan.full('why')), [
        'running every mutant of the gates (--force): why',
      ]);
    });

    test('nothing changed', () {
      expect(describeReuse(const ReusePlan.partly([], ['a', 'b'])), [
        'nothing that the 2 gate(s) depend on changed since the last run: '
            'their results are reused, and a Timeout is measured again',
      ]);
    });

    test('some gates run again, each with why, at most [shown]', () {
      final rerun = [
        for (final name in ['a', 'b', 'c']) (gate: name, why: 'w$name'),
      ];
      expect(describeReuse(ReusePlan.partly(rerun, ['d']), shown: 2), [
        '1 of 4 gate(s) reused, 3 run again with every mutant',
        '  a: wa',
        '  b: wb',
        '  and 1 more',
      ]);
      expect(describeReuse(ReusePlan.partly(rerun, const []), shown: 3), [
        '0 of 3 gate(s) reused, 3 run again with every mutant',
        '  a: wa',
        '  b: wb',
        '  c: wc',
      ]);
      // Five by default.
      final six = [
        for (final name in ['a', 'b', 'c', 'd', 'e', 'f'])
          (gate: name, why: 'w'),
      ];
      expect(describeReuse(ReusePlan.partly(six, const [])), [
        '0 of 6 gate(s) reused, 6 run again with every mutant',
        for (final name in ['a', 'b', 'c', 'd', 'e']) '  $name: w',
        '  and 1 more',
      ]);
    });
  });
}
