/// A time zone the tests of the gates are run in: the name the `TZ`
/// environment variable takes, and how it is shown.
typedef Zone = ({String name, String label});

/// The zones `timezones` runs the tests in when none is named.
///
/// The two ends of the world's clocks. At every moment the calendar date of
/// at least one of them is another one than the date in UTC: fourteen hours
/// ahead it is tomorrow from 10:00 UTC on, twelve hours behind it is
/// yesterday until 12:00 UTC. A test whose result depends on which day, month
/// or year a moment falls in therefore fails in one of the two, whatever
/// moment it uses and whatever zone it was written in. The zone of the
/// machine itself is the one every other run of the tests uses.
const defaultZones = <Zone>[
  (name: 'Pacific/Kiritimati', label: 'UTC+14'),
  (name: 'Etc/GMT+12', label: 'UTC-12'),
];

/// The names of the time zone database: `Area/Location`, `Etc/GMT+12`,
/// `UTC`. Not a path that leaves the database, and not a POSIX rule
/// (`UTC-14`), which names no entry of it.
final _zoneName = RegExp(r'^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$');

/// The zones of a run: [defaultZones], or the ones [requested] with `--zone`
/// (each once, in the order given). `null` when a name of [requested] is not
/// one the time zone database can have; [problem] then names it.
({List<Zone>? zones, String? problem}) zonesFor(List<String> requested) {
  if (requested.isEmpty) {
    return (zones: defaultZones, problem: null);
  }
  final labels = {for (final zone in defaultZones) zone.name: zone.label};
  final zones = <Zone>[];
  for (final name in requested) {
    if (!_zoneName.hasMatch(name)) {
      return (
        zones: null,
        problem:
            '--zone: "$name" is not the name of a time zone '
            '(Area/Location, as in Asia/Tokyo; or UTC)',
      );
    }
    if (!zones.any((zone) => zone.name == name)) {
      zones.add((name: name, label: labels[name] ?? name));
    }
  }
  return (zones: zones, problem: null);
}

/// The file of the time zone database that says what [zone] is, below
/// [database] (`/usr/share/zoneinfo` on macOS and Linux). A zone without it
/// is not known to the system, and a process that is started with it runs
/// in UTC without saying so.
String zoneFile(String database, String zone) => '$database/$zone';

final _flutterSdk = RegExp(r'^\s+sdk:\s*flutter\s*(#.*)?$', multiLine: true);

/// The command that runs test files, program first: [override] when given,
/// else `flutter test --no-pub` when the pubspec has a dependency from the
/// Flutter SDK, and `dart test` for any other package. ([pubspec] is `null`
/// when there is none.) It is the command `dart_mutant` chooses for the
/// mutation test.
List<String> zoneTestCommand(String? pubspec, List<String> override) =>
    override.isNotEmpty
    ? override
    : pubspec is String &&
          _flutterSdk.hasMatch(pubspec.replaceAll('\r\n', '\n'))
    ? const ['flutter', 'test', '--no-pub']
    : const ['dart', 'test'];

/// True when one of the files a gate is made of and tested with names
/// `DateTime` ([identifiers]: the identifiers of the gate, of every file of
/// the package it reaches, and of its test). Only such a gate can decide
/// something by the time zone: a local date or time is a `DateTime`, and
/// who makes or reads one names the class, or reaches a file that does.
bool usesDateTime(Iterable<Set<String>> identifiers) =>
    identifiers.any((names) => names.contains('DateTime'));
