@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/timezones.dart';

import 'package_fixture.dart';

void main() {
  late PackageFixture package;

  setUp(() {
    package = PackageFixture();
    File(
      'test/fixtures/zones/fake_zone_test.dart.txt',
    ).copySync('${package.dir.path}/fake_zone_test.dart');
    // The time zone database of the tests: these zones are known.
    for (final zone in ['Pacific/Kiritimati', 'Etc/GMT+12', 'UTC']) {
      package.write('zoneinfo/$zone', '');
    }
    package.write(
      'lib/due.dart',
      'bool isDue(DateTime now, DateTime due) => now.isAfter(due);\n',
    );
    package.write('lib/due_test.dart', '');
    package.write('lib/fee.dart', 'int fee(int grams) => grams * 2;\n');
    package.write('test/fee_test.dart', '');
    package.manifest(['lib/due.dart', 'lib/fee.dart']);
  });

  tearDown(() => package.delete());

  final fake = [Platform.resolvedExecutable, 'fake_zone_test.dart'];

  Future<int> timezones({
    List<String> zones = const [],
    bool all = false,
    List<String>? command,
  }) => runTimezones(
    package.dir.path,
    zones,
    command ?? fake,
    package.io,
    all: all,
    database: '${package.dir.path}/zoneinfo',
  );

  List<String> runs() => package.file('zones.log').existsSync()
      ? package.file('zones.log').readAsLinesSync()
      : [];

  final shown = '"${fake.join(' ')} lib/due_test.dart"';

  group('exit code 0', () {
    test('the tests of the gates that name DateTime are run once in each of '
        'the two built-in zones; the other gates are left out', () async {
      expect(await timezones(), 0);
      expect(runs(), [
        'TZ=Pacific/Kiritimati lib/due_test.dart',
        'TZ=Etc/GMT+12 lib/due_test.dart',
      ]);
      expect(package.out, [
        'running $shown for 1 gate(s) in 2 time zone(s); 1 gate(s) that do '
            'not name DateTime were left out',
        '  ✓ TZ=Pacific/Kiritimati (UTC+14): the tests pass',
        '  ✓ TZ=Etc/GMT+12 (UTC-12): the tests pass',
        'test_gates timezones: OK (the tests of 1 gate(s) pass in '
            'Pacific/Kiritimati, Etc/GMT+12; 1 gate(s) that do not name '
            'DateTime were left out)',
      ]);
      expect(package.err, isEmpty);
    });

    test('--all: every gate, in one run per zone', () async {
      expect(await timezones(all: true), 0);
      expect(runs(), [
        'TZ=Pacific/Kiritimati lib/due_test.dart test/fee_test.dart',
        'TZ=Etc/GMT+12 lib/due_test.dart test/fee_test.dart',
      ]);
      expect(
        package.out.last,
        'test_gates timezones: OK (the tests of 2 gate(s) pass in '
        'Pacific/Kiritimati, Etc/GMT+12)',
      );
    });

    test('--zone: the zones that are named, in place of the built-in '
        'ones', () async {
      expect(await timezones(zones: ['UTC', 'Etc/GMT+12', 'UTC']), 0);
      expect(runs(), [
        'TZ=UTC lib/due_test.dart',
        'TZ=Etc/GMT+12 lib/due_test.dart',
      ]);
      expect(package.out.sublist(1, 3), [
        '  ✓ TZ=UTC: the tests pass',
        '  ✓ TZ=Etc/GMT+12 (UTC-12): the tests pass',
      ]);
    });

    test('no gate names DateTime: nothing is run', () async {
      package.manifest(['lib/fee.dart']);
      expect(await timezones(), 0);
      expect(runs(), isEmpty);
      expect(package.out, [
        'test_gates timezones: OK (no gate names DateTime, so no test was '
            'run: 1 gate(s))',
      ]);
    });

    test('DateTime in the test of a gate, in a file the gate imports, and '
        'in a generated part of it counts; in a comment it does not', () async {
      package.write('pubspec.yaml', 'name: app\n');
      package.write('lib/a.dart', '// DateTime\nint a() => 1;\n');
      package.write('lib/a_test.dart', '');
      package.write('lib/b.dart', 'int b() => 1;\n');
      package.write('lib/b_test.dart', 'final now = DateTime(2026);\n');
      package.write('lib/c.dart', "import 'package:app/src/d.dart';\n");
      package.write('lib/c_test.dart', '');
      package.write('lib/src/d.dart', "export 'e.dart';\n");
      package.write('lib/src/e.dart', 'int day(DateTime at) => at.day;\n');
      package.write('lib/f.dart', "part 'f.g.dart';\n");
      package.write('lib/f_test.dart', '');
      package.write('lib/f.g.dart', "part of 'f.dart';\nDateTime? at;\n");
      package.manifest([
        'lib/a.dart',
        'lib/b.dart',
        'lib/c.dart',
        'lib/f.dart',
      ]);
      expect(await timezones(), 0);
      expect(
        runs().first,
        [
          'TZ=Pacific/Kiritimati',
          'lib/b_test.dart',
          'lib/c_test.dart',
          'lib/f_test.dart',
        ].join(' '),
      );
    });
  });

  group('exit code 1', () {
    test('the tests fail in one zone: the zone, the end of the output, and '
        'how to run it by hand', () async {
      package.write('fail-in', 'Etc/GMT+12\n');
      expect(await timezones(), 1);
      expect(package.out, [
        'running $shown for 1 gate(s) in 2 time zone(s); 1 gate(s) that do '
            'not name DateTime were left out',
        '  ✓ TZ=Pacific/Kiritimati (UTC+14): the tests pass',
      ]);
      expect(package.err, [
        '  ✗ TZ=Etc/GMT+12 (UTC-12): the tests fail (exit 1)',
        '      Expected: <31>\n        Actual: <1> in Etc/GMT+12',
        'test_gates timezones: FAILED (the tests of the gates do not pass '
            'in Etc/GMT+12). A gate decides something by the time zone of '
            'the machine, or a test expects the zone it was written in. Run '
            'them yourself with: TZ=Etc/GMT+12 ${fake.join(' ')} '
            'lib/due_test.dart',
      ]);
    });

    test('the other zones are still run after a failure', () async {
      package.write('fail-in', 'Pacific/Kiritimati\nEtc/GMT+12\n');
      expect(await timezones(), 1);
      expect(runs(), hasLength(2));
      expect(
        package.err.last,
        startsWith(
          'test_gates timezones: FAILED (the tests of the gates do not pass '
          'in Pacific/Kiritimati, Etc/GMT+12). ',
        ),
      );
    });

    test('a zone that the time zone database of the machine does not have: '
        'nothing is run', () async {
      expect(await timezones(zones: ['UTC', 'Mars/Olympus', 'Etc/GMT+1']), 1);
      expect(runs(), isEmpty);
      expect(package.err, [
        'test_gates timezones: Mars/Olympus, Etc/GMT+1: not in the time '
            'zone database of this machine (${package.dir.path}/zoneinfo). '
            'A process that is started with an unknown zone runs in UTC '
            'without saying so',
      ]);
    });

    test('no time zone database: nothing is run', () async {
      expect(
        await runTimezones(
          package.dir.path,
          const [],
          fake,
          package.io,
          database: '${package.dir.path}/no-such-directory',
        ),
        1,
      );
      expect(runs(), isEmpty);
      expect(
        package.err.single,
        startsWith(
          'test_gates timezones: cannot run the tests in another time zone '
          'here. ',
        ),
      );
    });

    test('a gate without a test, and a gate that is gone', () async {
      package.write('lib/c.dart', 'int c() => 1;\n');
      package.manifest(['lib/due.dart', 'lib/c.dart', 'lib/gone.dart']);
      expect(await timezones(), 1);
      expect(runs(), isEmpty);
      expect(package.err, [
        'test_gates timezones: 2 violation(s)',
        '  - lib/c.dart: no test found (looked for lib/c_test.dart, '
            'test/c_test.dart)',
        '  - lib/gone.dart: file not found (the check is case-sensitive). '
            'Update test-gates.json if it moved',
      ]);
    });

    test('settings.spec.suffixes: [] leaves no test to run', () async {
      package.manifest(
        ['lib/due.dart'],
        settings: {
          'spec': {'suffixes': <String>[]},
        },
      );
      expect(await timezones(), 1);
      expect(
        package.err.last,
        '  - lib/due.dart: no test is known for this gate: '
        'settings.spec.suffixes is empty',
      );
    });

    test('a wrong entry of test-gates.json: nothing is run', () async {
      package.write('test-gates.json', '{"gates": [{"path": "lib/due.dart"}]}');
      expect(await timezones(), 1);
      expect(package.err.first, 'test_gates timezones: 2 violation(s)');
      expect(runs(), isEmpty);
    });

    test('the command cannot be started', () async {
      expect(await timezones(command: ['test_gates_no_such_program']), 1);
      expect(
        package.err.single,
        startsWith(
          'test_gates timezones: cannot start "test_gates_no_such_program" (',
        ),
      );
    });
  });

  group('exit code 2', () {
    test('a --zone that is no name of a zone', () async {
      expect(
        await runAsync([
          'timezones',
          '--dir',
          package.dir.path,
          '--zone',
          '../etc',
        ], package.io),
        2,
      );
      expect(
        package.err.first,
        'test_gates: --zone: "../etc" is not the name of a time zone '
        '(Area/Location, as in Asia/Tokyo; or UTC)\n',
      );
    });

    test('no test-gates.json', () async {
      package.file('test-gates.json').deleteSync();
      expect(
        await runAsync(['timezones', '--dir', package.dir.path], package.io),
        2,
      );
    });
  });
}
