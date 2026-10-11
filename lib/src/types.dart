/// One allowed mutant. Matched by mutator + original + replacement, never by
/// line number. Used by `equivalentMutants` and `expectedTimeouts`.
class EquivalentMutant {
  const EquivalentMutant({
    required this.mutator,
    required this.original,
    required this.replacement,
    required this.reason,
    this.occurrence,
    this.index,
  });

  final String mutator;
  final String original;
  final String replacement;
  final String reason;

  /// 1-based index among the mutants of the file that share the key.
  final int? occurrence;

  /// Position of the entry in its list in test-gates.json, for messages.
  /// Entries that cannot be used are left out of the list, so this is not
  /// the position in the list the gate holds. `null`: that position.
  final int? index;
}

/// A file that holds an important decision.
class Gate {
  const Gate({
    required this.path,
    required this.decides,
    required this.impact,
    this.equivalentMutants = const [],
    this.expectedTimeouts = const [],
  });

  final String path;

  /// Empty when missing in the manifest (reported as a violation).
  final String decides;

  /// Empty when missing in the manifest (reported as a violation).
  final String impact;

  /// Only the entries that are usable for matching.
  final List<EquivalentMutant> equivalentMutants;

  /// Only the entries that are usable for matching.
  final List<EquivalentMutant> expectedTimeouts;
}

/// Important logic that cannot be a gate yet.
class Candidate {
  const Candidate({
    required this.path,
    required this.decides,
    required this.blocker,
  });

  final String path;
  final String decides;
  final String blocker;
}

/// `settings.spec.rewrite[]`, compiled.
class SpecRewrite {
  const SpecRewrite(this.regex, this.to);

  final RegExp regex;
  final String to;
}

/// A rule of `impureImports`, `impurePaths` or `forbiddenSource`, compiled.
class CompiledRule {
  const CompiledRule(this.regex, this.reason);

  final RegExp regex;
  final String reason;
}

/// `settings.impureNamedImports.add[]`: names banned from a library that is
/// otherwise fine.
class NamedImportRule {
  const NamedImportRule({
    required this.module,
    required this.names,
    required this.reason,
  });

  /// The URI as it is written in the import (`package:x/x.dart`).
  final String module;
  final List<String> names;
  final String reason;
}

/// `settings.importAliases[]`: a URI prefix that points into the package.
class ImportAlias {
  const ImportAlias(this.prefix, this.target);

  final String prefix;
  final String target;
}

/// One entry of `settings.imports.allow`, compiled.
class ImportAllowRule {
  /// Exactly one of [module] and [regex] is given.
  const ImportAllowRule({this.module, this.regex, this.names})
    : assert((module == null) != (regex == null));

  /// Matches the URI itself and what is below it (`package:decimal` covers
  /// `package:decimal/decimal.dart`).
  final String? module;

  /// Pattern tested against the whole URI.
  final RegExp? regex;

  /// When given, only these names may be imported, and only with `show`.
  final List<String>? names;
}

/// `settings.imports.mode`.
enum ImportMode { blocklist, allowlist }

/// Settings with defaults applied and every pattern compiled.
///
/// Only the settings this version acts on are resolved. The other keys of
/// upstream (`stryker.configFile`, `selfcheck.failurePattern`) are validated
/// and then ignored.
class ResolvedSettings {
  const ResolvedSettings({
    required this.gateExtensions,
    required this.specSuffixes,
    required this.specRewrite,
    required this.impureImports,
    required this.allowedImports,
    required this.impureNamedImports,
    required this.impurePaths,
    required this.forbiddenSource,
    required this.forbiddenSourceDefaults,
    required this.importAliases,
    required this.importMode,
    required this.importAllow,
    required this.lcovFile,
    required this.lcovSummaryExclude,
    required this.maxTimeouts,
    required this.reportFile,
    this.gateCommand,
    this.selfcheckMode = 'all',
  });

  final List<String> gateExtensions;

  /// `null` means "not configured": `_test<ext>` of the gate. An empty list
  /// means "no spec convention" (the spec checks are skipped).
  final List<String>? specSuffixes;

  /// `null` means "not configured": the test is looked for next to the gate
  /// and under `test/`. A list, even an empty one, is applied as upstream does.
  final List<SpecRewrite>? specRewrite;

  /// URIs a gate must not import, export or have as a part.
  final List<CompiledRule> impureImports;

  /// `settings.impureImports.allow`: URIs exempt from every rule of
  /// [impureImports], and parts that may be there although not generated.
  final List<RegExp> allowedImports;
  final List<NamedImportRule> impureNamedImports;

  /// Paths that cannot be gates.
  final List<CompiledRule> impurePaths;

  /// `settings.forbiddenSource.add`, tested one line at a time.
  final List<CompiledRule> forbiddenSource;

  /// False when `settings.forbiddenSource.defaults` is `false`: the built-in
  /// rules (reads of the environment) are then off.
  final bool forbiddenSourceDefaults;
  final List<ImportAlias> importAliases;
  final ImportMode importMode;
  final List<ImportAllowRule> importAllow;

  final String? lcovFile;
  final List<RegExp> lcovSummaryExclude;

  /// Timeouts tolerated outside `expectedTimeouts`.
  final int maxTimeouts;

  /// `settings.stryker.reportFile`: where the mutation report is written
  /// (`mutation`) and read (`mutation-result`). The key is the one of
  /// upstream, so that one test-gates.json is accepted by both tools.
  final String reportFile;

  /// The command that runs the tests and writes the tracefile, program first.
  /// Started without a shell. `null` when not set.
  final List<String>? gateCommand;

  /// `all` or `first`: which gates `selfcheck` puts a probe in.
  final String selfcheckMode;
}

/// One finding. Printed as `file:line: message`.
class Violation {
  const Violation({required this.file, this.line, required this.message});

  final String file;
  final int? line;
  final String message;

  @override
  String toString() =>
      line == null ? '$file: $message' : '$file:$line: $message';
}
