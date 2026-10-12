import 'dart:io';

import '../args.dart';
import '../dart_source.dart';
import '../gate_path.dart';
import '../import_policy.dart';
import '../io/files.dart';
import '../io/process.dart';
import '../pubspec.dart';
import '../scan.dart';
import '../spec_path.dart';
import '../types.dart';
import '../zones.dart';
import 'output.dart';

/// True when [file] is an entry of the time zone database, see
/// [isZoneData].
bool _isZone(File file) {
  if (!FileSystemEntity.isFileSync(file.path)) {
    return false;
  }
  try {
    final handle = file.openSync();
    try {
      return isZoneData(handle.readSync(4));
    } finally {
      handle.closeSync();
    }
  } on FileSystemException {
    return false;
  }
}

String _inPackage(String dir, String relativePath) =>
    '$dir${Platform.pathSeparator}'
    '${relativePath.replaceAll('/', Platform.pathSeparator)}';

/// Runs the tests of the gates once more in other time zones (the `TZ`
/// environment variable): a decision about a day, a month or an hour must
/// not depend on where the machine is that runs the tests.
///
/// Only the gates that name `DateTime` (in the gate, in a file of the
/// package it reaches, or in its test) are run, unless [all] is set. Their
/// tests are run together, once per zone: the zones of [requested]
/// (`--zone`), or the built-in two. [commandOverride] (what follows `--`)
/// replaces the command that runs test files.
///
/// [database] is where the time zone database is. It is a parameter for
/// the tests of this package only; the command line uses
/// [zoneDatabaseFor].
///
/// Returns the exit code: 0 when the tests pass in every zone, 1 otherwise,
/// 130 / 143 / 129 when interrupted.
Future<int> runTimezones(
  String dir,
  List<String> requested,
  List<String> commandOverride,
  Io io, {
  bool all = false,
  String? database,
}) async {
  final zoneinfo =
      database ??
      zoneDatabaseFor(
        linux: Platform.isLinux,
        tzdir: Platform.environment['TZDIR'],
      );
  final manifest = readManifest(dir);
  final (:zones, :problem) = zonesFor(requested);
  if (zones == null) {
    throw UsageError(problem!);
  }
  if (manifest.violations.isNotEmpty) {
    printViolations(io, 'timezones', manifest.violations);
    return 1;
  }
  String? read(String path) {
    if (!isPlainRelativePath(path) || !existsExact(manifest.dir, path)) {
      return null;
    }
    try {
      return readText(_inPackage(manifest.dir, path));
    } on FileSystemException {
      return null;
    }
  }

  final pubspec = read('pubspec.yaml');
  final packageName = pubspec == null ? null : packageNameOf(pubspec);

  final violations = <Violation>[];
  final specs = <String>[];
  var chosen = 0;
  var leftOut = 0;
  for (final gate in manifest.gates) {
    final path = gate.path;
    final source = read(path);
    if (source == null) {
      violations.add(
        Violation(
          file: path,
          message:
              'file not found (the check is case-sensitive). '
              'Update test-gates.json if it moved',
        ),
      );
      continue;
    }
    final places = specCandidatesFor(path, manifest.settings);
    final tests = [
      for (final place in places)
        if (existsExact(manifest.dir, place)) place,
    ];
    if (tests.isEmpty) {
      violations.add(
        Violation(
          file: path,
          message: places.isEmpty
              ? 'no test is known for this gate: settings.spec.suffixes is '
                    'empty'
              : 'no test found (looked for ${places.join(', ')})',
        ),
      );
      continue;
    }
    // The gate, its tests, and the files of the package they reach: a test
    // can get its dates from a helper.
    final texts = <String, String>{
      for (final start in [path, ...tests])
        ...gateSources(
          start,
          start == path ? source : read(start) ?? '',
          manifest.settings,
          packageName: packageName,
          readSource: read,
        ),
    };
    final parsed = {
      for (final MapEntry(key: file, value: text) in texts.entries)
        file: parseDartSource(text),
    };
    // Without the name of the package, `package:` may be the package.
    final unfollowed =
        packageName == null &&
        parsed.entries.any(
          (entry) => entry.value.imports.any(
            (imported) =>
                imported.uri.startsWith('package:') &&
                resolveUri(
                      imported.uri,
                      entry.key,
                      manifest.settings.importAliases,
                    ) ==
                    null,
          ),
        );
    if (all ||
        usesDateTime(
          parsed.values.map((source) => source.identifiers),
          unfollowed: unfollowed,
        )) {
      chosen++;
      specs.addAll(tests.where((test) => !specs.contains(test)));
    } else {
      leftOut++;
    }
  }
  final skipped = leftOut == 0
      ? ''
      : '; $leftOut gate(s) that do not name DateTime were left out';

  if (violations.isNotEmpty) {
    printViolations(io, 'timezones', violations);
    return 1;
  }
  // Also when there is nothing to run: a zone that is misspelt today is
  // still misspelt when a gate names DateTime.
  final usable = !Platform.isWindows && Directory(zoneinfo).existsSync();
  final unknown = [
    if (usable)
      for (final zone in zones)
        if (!_isZone(File(zoneFile(zoneinfo, zone.name)))) zone.name,
  ];
  if (unknown.isNotEmpty) {
    io.err(
      '$executable timezones: ${unknown.join(', ')}: not a zone of the time '
      'zone database of this machine ($zoneinfo). A process that is started '
      'with an unknown zone runs in UTC without saying so',
    );
    return 1;
  }
  if (specs.isEmpty) {
    io.out(
      '$executable timezones: OK (no gate names DateTime, so no test was '
      'run: $leftOut gate(s))',
    );
    return 0;
  }

  if (!usable) {
    io.err(
      '$executable timezones: cannot run the tests in another time zone '
      'here. It is done with the TZ environment variable and the time zone '
      'database in $zoneinfo, as macOS and Linux have them',
    );
    return 1;
  }

  final command = [...zoneTestCommand(pubspec, commandOverride), ...specs];
  io.out(
    'running "${command.join(' ')}" for $chosen gate(s) in '
    '${zones.length} time zone(s)$skipped',
  );
  final failed = <String>[];
  final signals = SignalWatch();
  try {
    for (final zone in zones) {
      final shown = zone.label == zone.name
          ? 'TZ=${zone.name}'
          : 'TZ=${zone.name} (${zone.label})';
      final result = await runCommand(
        command,
        workingDirectory: manifest.dir,
        capture: true,
        signals: signals,
        environment: {'TZ': zone.name},
      );
      final signal = result.signal ?? signals.signal;
      if (signal != null) {
        io.err('$executable timezones: interrupted');
        return signalExitCode(signal);
      }
      if (result.exitCode == null) {
        io.err(
          '$executable timezones: cannot start "${command.first}" '
          '(${result.startError})',
        );
        return 1;
      }
      if (result.exitCode == 0) {
        io.out('  ✓ $shown: the tests pass');
        continue;
      }
      failed.add(zone.name);
      io.err('  ✗ $shown: the tests fail (exit ${result.exitCode})');
      final tail = tailOf(result.output);
      if (tail.trim().isNotEmpty) {
        io.err(tail);
      }
    }
  } finally {
    await signals.cancel();
  }

  if (failed.isNotEmpty) {
    io.err(
      '$executable timezones: FAILED (the tests of the gates do not pass in '
      '${failed.join(', ')}). A gate decides something by the time zone of '
      'the machine, or a test expects the zone it was written in. Run them '
      'yourself with: TZ=${failed.first} ${command.join(' ')}',
    );
    return 1;
  }
  io.out(
    '$executable timezones: OK (the tests of $chosen gate(s) pass in '
    '${zones.map((zone) => zone.name).join(', ')}$skipped)',
  );
  return 0;
}
