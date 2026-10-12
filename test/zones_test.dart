import 'package:test/test.dart';
import 'package:test_gates/src/zones.dart';

void main() {
  group('the built-in zones', () {
    test('the two ends of the clocks, fourteen hours ahead and twelve '
        'behind', () {
      expect(defaultZones, [
        (name: 'Pacific/Kiritimati', label: 'UTC+14'),
        (name: 'Etc/GMT+12', label: 'UTC-12'),
      ]);
    });

    test('at every hour of the UTC day, the date is another one in at least '
        'one of them', () {
      // What the two names mean, as the time zone database has them.
      const ahead = Duration(hours: 14);
      const behind = Duration(hours: -12);
      for (var minute = 0; minute < 24 * 60; minute++) {
        final moment = DateTime.utc(2026, 3, 10, 0, minute);
        final days = {moment.add(ahead).day, moment.add(behind).day};
        expect(days.any((day) => day != moment.day), isTrue, reason: '$moment');
      }
    });
  });

  group('zonesFor', () {
    test('no request: the built-in zones', () {
      final result = zonesFor([]);
      expect(result.zones, defaultZones);
      expect(result.problem, isNull);
    });

    test('the requested zones, each once, in the order given; a built-in '
        'one keeps its label', () {
      final result = zonesFor([
        'UTC',
        'Asia/Tokyo',
        'Etc/GMT+12',
        'UTC',
        'America/Argentina/Buenos_Aires',
        'Etc/GMT-14',
      ]);
      expect(result.problem, isNull);
      expect(result.zones, [
        (name: 'UTC', label: 'UTC'),
        (name: 'Asia/Tokyo', label: 'Asia/Tokyo'),
        (name: 'Etc/GMT+12', label: 'UTC-12'),
        (
          name: 'America/Argentina/Buenos_Aires',
          label: 'America/Argentina/Buenos_Aires',
        ),
        (name: 'Etc/GMT-14', label: 'Etc/GMT-14'),
      ]);
    });

    test('a name the time zone database cannot have is refused: a path, a '
        'rule with a colon, a blank', () {
      for (final name in [
        '../../etc/passwd',
        '/usr/share/zoneinfo/UTC',
        'Asia/',
        'Asia//Tokyo',
        '/Asia/Tokyo',
        'Asia/Tokyo ',
        ' UTC',
        '',
        '.',
        'Asia/../UTC',
        '9',
        '+9',
        'UTC-14:00',
        'Asia/To kyo',
        'Asia/Tokyo\nUTC',
      ]) {
        final result = zonesFor(['UTC', name]);
        expect(result.zones, isNull, reason: name);
        expect(
          result.problem,
          '--zone: "$name" is not the name of a time zone (Area/Location, '
          'as in Asia/Tokyo; or UTC)',
        );
      }
    });

    test('a name that could be an entry is taken; whether it is one is '
        'asked of the database', () {
      for (final name in ['UTC0', 'JST-9', 'EST5EDT', 'GB', 'Etc/GMT+0']) {
        expect(zonesFor([name]).zones, [(name: name, label: name)]);
      }
    });
  });

  test('zoneFile: the entry of a zone in the database', () {
    expect(
      zoneFile('/usr/share/zoneinfo', 'Etc/GMT+12'),
      '/usr/share/zoneinfo/Etc/GMT+12',
    );
  });

  group('zoneTestCommand', () {
    const flutter = 'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n';
    const plain = 'name: app\ndev_dependencies:\n  test: ^1.27.0\n';

    test('flutter test --no-pub for a package with a dependency from the '
        'Flutter SDK, dart test for any other', () {
      expect(zoneTestCommand(flutter, []), ['flutter', 'test', '--no-pub']);
      expect(zoneTestCommand(plain, []), ['dart', 'test']);
      expect(zoneTestCommand(null, []), ['dart', 'test']);
      expect(zoneTestCommand('', []), ['dart', 'test']);
    });

    test('the dependency is read with CRLF, with a comment, and under '
        'dev_dependencies', () {
      expect(zoneTestCommand(flutter.replaceAll('\n', '\r\n'), []), [
        'flutter',
        'test',
        '--no-pub',
      ]);
      expect(
        zoneTestCommand(
          'dev_dependencies:\n  flutter_test:\n    sdk:  flutter # sdk\n',
          [],
        ),
        ['flutter', 'test', '--no-pub'],
      );
    });

    test('what only looks like it is not it', () {
      for (final pubspec in [
        'sdk: flutter\n',
        '# sdk: flutter\n',
        'dependencies:\n  a:\n    sdk: flutter_x\n',
        'dependencies:\n  a:\n    sdk: dart\n',
        'dependencies:\n  a:\n    xsdk: flutter\n',
        'description: uses\n  the sdk: flutter and more\n',
      ]) {
        expect(zoneTestCommand(pubspec, []), ['dart', 'test'], reason: pubspec);
      }
    });

    test('a command that is given replaces both', () {
      expect(zoneTestCommand(flutter, ['fvm', 'flutter', 'test']), [
        'fvm',
        'flutter',
        'test',
      ]);
      expect(zoneTestCommand(null, ['tool/test.sh']), ['tool/test.sh']);
    });
  });

  group('usesDateTime', () {
    test('one of the files names DateTime', () {
      expect(
        usesDateTime([
          {'int', 'fee'},
          {'DateTime', 'now'},
        ]),
        isTrue,
      );
      expect(
        usesDateTime([
          {'DateTime'},
        ]),
        isTrue,
      );
    });

    test('none does', () {
      expect(usesDateTime([]), isFalse);
      expect(
        usesDateTime([
          {'int', 'Duration', 'dateTime', 'DateTimeRange', 'TZDateTime'},
          <String>{},
        ]),
        isFalse,
      );
    });
  });
}
