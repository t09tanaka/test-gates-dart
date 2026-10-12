// TZ is not how a process is given a time zone on Windows.
@TestOn('!windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:test_gates/src/cli.dart';
import 'package:test_gates/src/commands/output.dart';
import 'package:test_gates/src/zones.dart';

/// `timezones` against the real thing: `dart test` on a small package
/// (test/fixtures/zones/package, kept as .txt and copied into a temporary
/// directory) whose tests pass on a machine in UTC and decide by the zone of
/// the machine.
///
/// This is also where it is checked that the `TZ` environment variable
/// moves the local time of a Dart program on the system the tests run on.
void main() {
  late Directory dir;
  final out = <String>[];
  final err = <String>[];
  final io = Io(out: out.add, err: err.add);

  setUpAll(() {
    dir = Directory.systemTemp.createTempSync('test_gates_real_timezones_');
    for (final (from, to) in [
      ('selfcheck/package/pubspec.yaml', 'pubspec.yaml'),
      ('zones/package/lib/day.dart', 'lib/day.dart'),
      ('zones/package/test/day_test.dart', 'test/day_test.dart'),
    ]) {
      File('${dir.path}/$to')
        ..createSync(recursive: true)
        ..writeAsBytesSync(File('test/fixtures/$from.txt').readAsBytesSync());
    }
    File('${dir.path}/test-gates.json').writeAsStringSync(
      jsonEncode({
        'gates': [
          {'path': 'lib/day.dart', 'decides': 'd', 'impact': 'i'},
        ],
      }),
    );
    final pubGet = Process.runSync(Platform.resolvedExecutable, [
      'pub',
      'get',
      '--offline',
    ], workingDirectory: dir.path);
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}${pubGet.stderr}');
  });

  tearDownAll(() => dir.deleteSync(recursive: true));

  /// The names of the tests of the package that fail with TZ set to [zone].
  List<String> failingIn(String zone) {
    final result = Process.runSync(
      Platform.resolvedExecutable,
      ['test', '--reporter', 'json', 'test/day_test.dart'],
      workingDirectory: dir.path,
      environment: {'TZ': zone},
    );
    final names = <int, String>{};
    final failed = <String>[];
    for (final line in (result.stdout as String).split('\n')) {
      if (!line.startsWith('{')) {
        continue;
      }
      final event = jsonDecode(line) as Map<String, Object?>;
      if (event['type'] == 'testStart') {
        final test = event['test']! as Map<String, Object?>;
        names[test['id']! as int] = test['name']! as String;
      } else if (event['type'] == 'testDone' && event['result'] != 'success') {
        failed.add(names[event['testID']]!);
      }
    }
    return failed;
  }

  test('what each zone finds: UTC nothing, and each end of the clocks the '
      'day the other one misses', () {
    expect(failingIn('UTC'), isEmpty);
    expect(failingIn(defaultZones[0].name), [
      'late in the UTC day',
      'the zone it was written in',
    ]);
    expect(failingIn(defaultZones[1].name), [
      'early in the UTC day',
      'the zone it was written in',
    ]);
  });

  test('timezones fails the package in both zones, and passes it in '
      'UTC', () async {
    expect(await runAsync(['timezones', '--dir', dir.path], io), 1);
    expect(out, [
      'running "dart test test/day_test.dart" for 1 gate(s) in 2 time '
          'zone(s)',
    ]);
    expect(err.where((line) => line.startsWith('  ✗ ')), [
      '  ✗ TZ=Pacific/Kiritimati (UTC+14): the tests fail (exit 1)',
      '  ✗ TZ=Etc/GMT+12 (UTC-12): the tests fail (exit 1)',
    ]);
    out.clear();
    err.clear();
    expect(
      await runAsync(['timezones', '--dir', dir.path, '--zone', 'UTC'], io),
      0,
    );
    expect(out.last, startsWith('test_gates timezones: OK (the tests of 1 '));
    expect(err, isEmpty);
  });

  test('the locale: LANG moves it on Linux and not on macOS, which is why '
      'timezones does not vary it', () {
    File('${dir.path}/locale.dart').writeAsStringSync(
      "import 'dart:io';\n\nvoid main() => print(Platform.localeName);\n",
    );
    String localeWith(Map<String, String> environment) =>
        (Process.runSync(
                  Platform.resolvedExecutable,
                  ['locale.dart'],
                  workingDirectory: dir.path,
                  environment: environment,
                ).stdout
                as String)
            .trim();
    final german = localeWith({'LANG': 'de_DE.UTF-8', 'LC_ALL': ''});
    final french = localeWith({'LANG': 'fr_FR.UTF-8', 'LC_ALL': ''});
    if (Platform.isMacOS) {
      expect(german, french);
    } else {
      expect((german, french), ('de_DE.UTF-8', 'fr_FR.UTF-8'));
    }
  });

  test('a zone that the machine does not know is refused', () async {
    out.clear();
    err.clear();
    expect(
      await runAsync([
        'timezones',
        '--dir',
        dir.path,
        '--zone',
        'Nowhere/No_Such_Zone',
      ], io),
      1,
    );
    expect(
      err.single,
      startsWith(
        'test_gates timezones: Nowhere/No_Such_Zone: not in the time zone '
        'database of this machine (/usr/share/zoneinfo).',
      ),
    );
  });
}
