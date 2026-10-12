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

/// Something a file does that a pure module must not, at a line of it.
typedef _Finding = ({int line, String message});

/// What the code of a file does that a pure module must not, whatever its
/// directives are: reads of the environment, and what
/// `settings.forbiddenSource` adds. The patterns are tested against the code
/// of each line, not against what a comment on it says.
List<_Finding> _sourceFindings(
  DartSource parsed,
  ResolvedSettings settings,
) => [
  if (settings.forbiddenSourceDefaults)
    for (final read in parsed.environmentReads)
      (
        line: read.line,
        message:
            'reads ${read.what} (not a pure module). Take the value as '
            'an argument',
      ),
  for (final (index, line) in _lines(parsed.code).indexed)
    for (final rule in settings.forbiddenSource)
      if (rule.regex.hasMatch(line)) (line: index + 1, message: rule.reason),
  for (final line in parsed.uncheckableUris)
    (
      line: line,
      message:
          'a URI that is not written plainly cannot be checked (a plain '
          'string, a lower-case scheme, no "%", not file:)',
    ),
];

bool _exempt(ImportRef imported, ResolvedSettings settings) =>
    settings.allowedImports.any((regex) => regex.hasMatch(imported.uri));

/// What the directives of the file at [path] bring in that a pure module
/// must not. With [partRule] (the gate itself) a part that no generator
/// wrote is a finding as well: it is code of the gate in another file.
List<_Finding> _directiveFindings(
  String path,
  DartSource parsed,
  ResolvedSettings settings,
  List<ImportAlias> aliases, {
  required bool partRule,
}) {
  final findings = <_Finding>[];
  for (final imported in parsed.imports) {
    final what = _directive(imported.kind);
    void report(String message) =>
        findings.add((line: imported.line, message: message));
    final exempt = _exempt(imported, settings);
    final before = findings.length;
    if (!exempt) {
      for (final rule in settings.impureImports) {
        if (rule.regex.hasMatch(imported.uri)) {
          report('$what of "${imported.uri}" (${rule.reason})');
        }
      }
    }
    if (imported.kind == DirectiveKind.part) {
      // A part is the gate's own code in another file: it is not scanned
      // here, and its coverage is recorded under its own path.
      if (partRule &&
          !exempt &&
          findings.length == before &&
          !isGeneratedPart(imported.uri)) {
        report(
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
          'use of ${hit.join(', ')} from "${rule.module}" (${rule.reason})',
        );
      }
    }
    // Allowlist mode adds to the rules above; an import they already reject
    // is reported once.
    if (settings.importMode == ImportMode.allowlist &&
        findings.length == before) {
      final target = resolveUri(imported.uri, path, aliases);
      if (target == null) {
        if (judgePackageImport(imported, settings.importAllow)
            case final reason?) {
          report(reason);
        }
      } else if (judgeProjectImport(target, settings.impurePaths)
          case final reason?) {
        report('$what of "${imported.uri}" ($reason)');
      }
    }
  }
  return findings;
}

/// The files of the package that the file at [path] brings in: what it
/// imports and exports, and its parts that no generator wrote. (In the gate
/// itself such a part is a finding, so it is not followed.) A URI that
/// `settings.impureImports.allow` exempts is not followed, and neither is
/// another package or the SDK: those are judged by their names. A directive
/// that is a finding already ([rejected], by line) is not followed either:
/// it has to go, with whatever is behind it.
List<({ImportRef from, String target})> _projectFiles(
  String path,
  DartSource parsed,
  ResolvedSettings settings,
  List<ImportAlias> aliases,
  List<_Finding> rejected,
) => [
  for (final imported in parsed.imports)
    if (!rejected.any((finding) => finding.line == imported.line) &&
        !_exempt(imported, settings) &&
        (imported.kind != DirectiveKind.part || !isGeneratedPart(imported.uri)))
      if (resolveUri(imported.uri, path, aliases) case final target?)
        (from: imported, target: target),
];

/// What the gate at [gatePath] reaches through the files of the package it
/// imports: the same rules as for the gate's own imports and reads, applied
/// to every file on the way, however many imports away. Each finding is
/// reported once, at the directive of the gate that leads to it, with the
/// file and line it is in and the files in between.
///
/// A file is read once, so imports that form a circle end.
List<Violation> _reached(
  String gatePath,
  DartSource gate,
  ResolvedSettings settings,
  List<ImportAlias> aliases,
  List<_Finding> rejected,
  String? Function(String path) readSource,
) {
  final violations = <Violation>[];
  final seen = {gatePath};
  // Breadth first: the shortest way to a file is the one that is reported.
  final queue = [
    for (final step in _projectFiles(
      gatePath,
      gate,
      settings,
      aliases,
      rejected,
    ))
      (start: step.from, path: step.target, way: [gatePath, step.target]),
  ];
  for (var index = 0; index < queue.length; index++) {
    final (:start, :path, :way) = queue[index];
    if (!seen.add(path)) {
      continue;
    }
    void report(String what) => violations.add(
      Violation(
        file: gatePath,
        line: start.line,
        message:
            '${_directive(start.kind)} of "${start.uri}" reaches $what '
            '(${way.join(' → ')})',
      ),
    );
    final source = readSource(path);
    if (source == null) {
      report(
        '$path, which cannot be read, so what it brings in cannot be '
        'checked. When a generator writes that file, run it before check',
      );
      continue;
    }
    final parsed = parseDartSource(source);
    final directives = _directiveFindings(
      path,
      parsed,
      settings,
      aliases,
      partRule: false,
    );
    final findings = [
      for (final error in parsed.syntaxErrors)
        (
          line: error.line,
          message: 'code that cannot be parsed as Dart (${error.what})',
        ),
      ..._sourceFindings(parsed, settings),
      ...directives,
    ]..sort((a, b) => a.line.compareTo(b.line));
    for (final finding in findings) {
      report('$path:${finding.line}: ${finding.message}');
    }
    for (final step in _projectFiles(
      path,
      parsed,
      settings,
      aliases,
      directives,
    )) {
      queue.add((start: start, path: step.target, way: [...way, step.target]));
    }
  }
  return violations;
}

/// The files of the package that the gate at [gatePath] is made of: the gate
/// and every file it reaches through its imports, exports and parts, as far
/// as they can be read ([readSource] gives `null` for one that cannot). What
/// `check` would report on the way is not looked at; a generated part is
/// read here, because it is code of the gate all the same.
///
/// Path → content, the gate first.
Map<String, String> gateSources(
  String gatePath,
  String source,
  ResolvedSettings settings, {
  String? packageName,
  required String? Function(String path) readSource,
}) {
  final aliases = aliasesFor(packageName, settings.importAliases);
  final sources = {gatePath: source};
  // Every path once, whether it can be read or not.
  final asked = {gatePath};
  final queue = [gatePath];
  for (var index = 0; index < queue.length; index++) {
    final path = queue[index];
    for (final imported in parseDartSource(sources[path]!).imports) {
      final target = resolveUri(imported.uri, path, aliases);
      if (target is String && asked.add(target)) {
        final content = readSource(target);
        if (content is String) {
          sources[target] = content;
          queue.add(target);
        }
      }
    }
  }
  return sources;
}

/// Checks the text of a gate: it must be a pure module with no way to opt out
/// of measurement.
///
/// [packageName] is `name` of pubspec.yaml: `package:<name>/…` is then an
/// import of the package's own `lib/`.
///
/// [readSource] gives the content of a file of the package, or `null` when
/// it cannot be read. With it the imports are followed: what the gate
/// reaches through the files it imports is checked like the gate itself (see
/// [_reached]). Without it only the gate's own directives are read.
List<Violation> scanGateSource(
  String gatePath,
  String source,
  ResolvedSettings settings, {
  String? packageName,
  String? Function(String path)? readSource,
}) {
  final parsed = parseDartSource(source);
  final aliases = aliasesFor(packageName, settings.importAliases);
  Violation at(_Finding finding) =>
      Violation(file: gatePath, line: finding.line, message: finding.message);
  final directives = _directiveFindings(
    gatePath,
    parsed,
    settings,
    aliases,
    partRule: true,
  );
  return _sorted([
    ..._syntaxErrors(gatePath, parsed),
    ..._coverageIgnores(gatePath, source),
    if (parsed.partOfLine case final line?)
      Violation(
        file: gatePath,
        line: line,
        message:
            'a part of another library (its imports are in that library and '
            'cannot be checked). Make it a library of its own',
      ),
    ..._sourceFindings(parsed, settings).map(at),
    for (final shared in parsed.sharedBlockLines)
      Violation(
        file: gatePath,
        line: shared.line,
        message:
            '${shared.what} blocks start on this line and share one branch '
            'entry in lcov, so an untested one is not reported. Run dart '
            'format, and give nested control flow braces',
      ),
    ...directives.map(at),
    if (readSource != null)
      ..._reached(gatePath, parsed, settings, aliases, directives, readSource),
  ]);
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
