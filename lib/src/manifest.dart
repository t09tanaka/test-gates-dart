import 'dart:convert';

import 'json.dart';
import 'types.dart';

const manifestFile = 'test-gates.json';

/// The manifest cannot be used at all (exit code 2), as opposed to a violation
/// inside it (exit code 1).
class ManifestError implements Exception {
  ManifestError(this.message);

  final String message;

  @override
  String toString() => message;
}

class ParsedManifest {
  const ParsedManifest({
    required this.gates,
    required this.candidates,
    required this.settings,
    required this.violations,
  });

  /// Entries whose `path` is usable. Other problems of an entry are reported
  /// in [violations].
  final List<Gate> gates;
  final List<Candidate> candidates;

  /// The raw `settings` value, to be handed to `resolveSettings`. An empty
  /// object when the manifest has no `settings` key.
  final Object? settings;
  final List<Violation> violations;
}

/// What is wrong with one allowance. Empty when it can be used for matching.
List<String> _allowanceProblems(Object? entry) {
  final object = asObject(entry);
  if (object == null) {
    return [' must be an object'];
  }
  return [
    if (!isFilled(object['mutator'])) ': "mutator" is missing',
    if (!isFilled(object['original'])) ': "original" is missing',
    // An empty replacement is real: a string literal can be mutated to "".
    if (object['replacement'] is! String) ': "replacement" is missing',
    if (!isFilled(object['reason']))
      ': "reason" is missing (say why the mutant cannot be observed)',
    if (object.containsKey('occurrence') &&
        (asInteger(object['occurrence']) ?? 0) < 1)
      ': "occurrence" must be an integer >= 1',
  ];
}

/// Checks one allow list of one gate, when the gate has that key. `reason` is
/// mandatory: an allowance nobody can justify is a mutant nobody checked.
List<Violation> validateEquivalentMutants(
  JsonObject gate,
  String gatePath, [
  String field = 'equivalentMutants',
]) {
  if (!gate.containsKey(field)) {
    return [];
  }
  final value = gate[field];
  if (value is! List) {
    return [
      Violation(
        file: manifestFile,
        message: '$gatePath: $field must be an array',
      ),
    ];
  }
  return [
    for (final (index, entry) in value.indexed)
      for (final problem in _allowanceProblems(entry))
        Violation(
          file: manifestFile,
          message: '$gatePath: $field[$index]$problem',
        ),
  ];
}

List<EquivalentMutant> _usableAllowances(Object? value) {
  if (value is! List) {
    return const [];
  }
  return [
    for (final (index, entry) in value.indexed)
      if (_allowanceProblems(entry).isEmpty)
        EquivalentMutant(
          index: index,
          mutator: (entry as JsonObject)['mutator']! as String,
          original: entry['original']! as String,
          replacement: entry['replacement']! as String,
          reason: entry['reason']! as String,
          occurrence: asInteger(entry['occurrence']),
        ),
  ];
}

/// The entries of `gates` or `candidates` that have a usable, unique `path`.
List<JsonObject> _usableEntries(
  String kind,
  List<Object?> entries,
  List<String> fields,
  List<Violation> violations,
) {
  final usable = <JsonObject>[];
  final seen = <String>{};
  for (final (index, entry) in entries.indexed) {
    final at = '$kind[$index]';
    final object = asObject(entry);
    if (object == null) {
      violations.add(
        Violation(file: manifestFile, message: '$at must be an object'),
      );
      continue;
    }
    final path = object['path'];
    if (path is! String || !isFilled(path)) {
      violations.add(
        Violation(file: manifestFile, message: '$at: "path" is missing'),
      );
      continue;
    }
    for (final field in fields) {
      if (!isFilled(object[field])) {
        violations.add(
          Violation(
            file: manifestFile,
            message: '$path: "$field" is missing in $kind',
          ),
        );
      }
    }
    if (!seen.add(path)) {
      violations.add(
        Violation(file: manifestFile, message: '$path: listed twice in $kind'),
      );
      continue;
    }
    usable.add(object);
  }
  return usable;
}

String _text(Object? value) => value is String ? value : '';

/// Parses test-gates.json. Throws [ManifestError] when the file is not usable
/// at all; returns per-entry problems as violations.
///
/// The rules are those of upstream `@t09tanaka/test-gates`: the same file is
/// accepted and rejected by both.
ParsedManifest parseManifest(String text) {
  final Object? raw;
  try {
    raw = jsonDecode(text);
  } on FormatException catch (error) {
    throw ManifestError('$manifestFile is not valid JSON: ${error.message}');
  }
  final root = asObject(raw);
  if (root == null) {
    throw ManifestError('$manifestFile must be a JSON object');
  }
  final rawGates = root['gates'];
  if (rawGates is! List) {
    throw ManifestError('$manifestFile: "gates" must be an array');
  }
  // `candidates` may be omitted (a coverage-only manifest); when present it
  // must be an array.
  final rawCandidates = root['candidates'];
  if (root.containsKey('candidates') && rawCandidates is! List) {
    throw ManifestError('$manifestFile: "candidates" must be an array');
  }
  for (final key in root.keys) {
    if (!const {r'$schema', 'gates', 'candidates', 'settings'}.contains(key)) {
      throw ManifestError('$manifestFile: unknown top-level key ${quote(key)}');
    }
  }

  final violations = <Violation>[];
  if (rawGates.isEmpty) {
    violations.add(
      const Violation(
        file: manifestFile,
        message:
            'gates is empty. A project with nothing to gate should not have this file',
      ),
    );
  }
  final gateEntries = _usableEntries('gates', rawGates, const [
    'decides',
    'impact',
  ], violations);
  final candidateEntries = _usableEntries(
    'candidates',
    rawCandidates is List ? rawCandidates : const [],
    const ['decides', 'blocker'],
    violations,
  );

  final gatePaths = {for (final gate in gateEntries) gate['path']};
  for (final candidate in candidateEntries) {
    if (gatePaths.contains(candidate['path'])) {
      violations.add(
        Violation(
          file: manifestFile,
          message: '${candidate['path']}: listed in both gates and candidates',
        ),
      );
    }
  }
  final gates = <Gate>[];
  for (final entry in gateEntries) {
    final path = entry['path']! as String;
    violations
      ..addAll(validateEquivalentMutants(entry, path))
      ..addAll(validateEquivalentMutants(entry, path, 'expectedTimeouts'));
    gates.add(
      Gate(
        path: path,
        decides: _text(entry['decides']),
        impact: _text(entry['impact']),
        equivalentMutants: _usableAllowances(entry['equivalentMutants']),
        expectedTimeouts: _usableAllowances(entry['expectedTimeouts']),
      ),
    );
  }

  return ParsedManifest(
    gates: gates,
    candidates: [
      for (final entry in candidateEntries)
        Candidate(
          path: entry['path']! as String,
          decides: _text(entry['decides']),
          blocker: _text(entry['blocker']),
        ),
    ],
    settings: root.containsKey('settings')
        ? root['settings']
        : const <String, Object?>{},
    violations: violations,
  );
}
