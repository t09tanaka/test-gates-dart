import 'dart_source.dart';
import 'import_policy.dart';
import 'types.dart';

/// What the coverage tools honour (`package:coverage`, which `dart test` and
/// `flutter test` use, matches these comments with a pattern, line by line).
/// The same is done here, so nothing the tool would obey is missed.
final _coverageIgnore = RegExp(r'//\s*coverage:ignore-(line|start|end|file)');

/// The lines of a file, without their line terminators: a pattern that ends
/// in `$` must match in a file with CRLF as well.
List<String> _lines(String source) => source.split(RegExp(r'\r?\n'));

String _directive(DirectiveKind kind) => switch (kind) {
  DirectiveKind.import => 'import',
  DirectiveKind.export => 'export',
  DirectiveKind.part => 'part',
};

List<Violation> _sorted(List<Violation> violations) {
  // Every finding of a source scan has a line. The sort is stable.
  final indexed = violations.indexed.toList()
    ..sort((a, b) {
      final byLine = a.$2.line!.compareTo(b.$2.line!);
      return byLine != 0 ? byLine : a.$1.compareTo(b.$1);
    });
  return [for (final (_, violation) in indexed) violation];
}

List<Violation> _coverageIgnores(String path, String source) => [
  for (final (index, line) in _lines(source).indexed)
    if (_coverageIgnore.hasMatch(line))
      Violation(
        file: path,
        line: index + 1,
        message: 'coverage ignore comment',
      ),
];

List<Violation> _syntaxErrors(String path, DartSource parsed) => [
  for (final error in parsed.syntaxErrors)
    Violation(
      file: path,
      line: error.line,
      message: 'cannot be parsed as Dart (${error.what})',
    ),
];

/// Checks the text of a gate: it must be a pure module with no way to opt out
/// of measurement.
///
/// [packageName] is `name` of pubspec.yaml: `package:<name>/…` is then an
/// import of the package's own `lib/`.
List<Violation> scanGateSource(
  String gatePath,
  String source,
  ResolvedSettings settings, {
  String? packageName,
}) {
  final parsed = parseDartSource(source);
  final aliases = aliasesFor(packageName, settings.importAliases);
  final violations = [
    ..._syntaxErrors(gatePath, parsed),
    ..._coverageIgnores(gatePath, source),
  ];
  void report(int line, String message) =>
      violations.add(Violation(file: gatePath, line: line, message: message));

  if (parsed.partOfLine case final line?) {
    report(
      line,
      'a part of another library (its imports are in that library and '
      'cannot be checked). Make it a library of its own',
    );
  }
  if (settings.forbiddenSourceDefaults) {
    for (final read in parsed.environmentReads) {
      report(
        read.line,
        'reads ${read.what} (not a pure module). Take the value as an argument',
      );
    }
  }
  for (final (index, line) in _lines(source).indexed) {
    for (final rule in settings.forbiddenSource) {
      if (rule.regex.hasMatch(line)) {
        report(index + 1, rule.reason);
      }
    }
  }
  for (final shared in parsed.sharedBlockLines) {
    report(
      shared.line,
      '${shared.what} blocks start on this line and share one branch entry '
      'in lcov, so an untested one is not reported. Run dart format, and '
      'give nested control flow braces',
    );
  }
  for (final line in parsed.uncheckableUris) {
    report(line, 'a URI that is not a plain string cannot be checked');
  }

  for (final imported in parsed.imports) {
    final what = _directive(imported.kind);
    final exempt = settings.allowedImports.any(
      (regex) => regex.hasMatch(imported.uri),
    );
    final before = violations.length;
    if (!exempt) {
      for (final rule in settings.impureImports) {
        if (rule.regex.hasMatch(imported.uri)) {
          report(imported.line, '$what of "${imported.uri}" (${rule.reason})');
        }
      }
    }
    if (imported.kind == DirectiveKind.part) {
      // A part is the gate's own code in another file: it is not scanned
      // here, and its coverage is recorded under its own path.
      if (!exempt &&
          violations.length == before &&
          !isGeneratedPart(imported.uri)) {
        report(
          imported.line,
          'part "${imported.uri}" is code of the gate in a file that is not '
          'checked or measured (only generated *.g.dart / *.freezed.dart parts are allowed). '
          'Make it a library and list it as a gate',
        );
      }
      continue;
    }
    for (final rule in settings.impureNamedImports) {
      if (imported.uri != rule.module) {
        continue;
      }
      final shown = imported.shown;
      final hit = [
        for (final name in rule.names)
          if (shown?.contains(name) ?? parsed.identifiers.contains(name)) name,
      ];
      if (hit.isNotEmpty) {
        report(
          imported.line,
          'use of ${hit.join(', ')} from "${rule.module}" (${rule.reason})',
        );
      }
    }
    // Allowlist mode adds to the rules above; an import they already reject
    // is reported once.
    if (settings.importMode == ImportMode.allowlist &&
        violations.length == before) {
      final target = resolveUri(imported.uri, gatePath, aliases);
      if (target == null) {
        if (judgePackageImport(imported, settings.importAllow)
            case final reason?) {
          report(imported.line, reason);
        }
      } else if (judgeProjectImport(target, settings.impurePaths)
          case final reason?) {
        report(imported.line, '$what of "${imported.uri}" ($reason)');
      }
    }
  }

  return _sorted(violations);
}

/// Checks the text of a gate's test: nothing skipped, nothing focused, no
/// coverage ignore comment.
List<Violation> scanSpecSource(String specPath, String source) {
  final parsed = parseDartSource(source);
  return _sorted([
    ..._syntaxErrors(specPath, parsed),
    ..._coverageIgnores(specPath, source),
    for (final disabled in parsed.disabledTests)
      Violation(
        file: specPath,
        line: disabled.line,
        message: '${disabled.what} (a skipped or focused test)',
      ),
  ]);
}
