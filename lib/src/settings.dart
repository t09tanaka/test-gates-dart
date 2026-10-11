import 'json.dart';
import 'types.dart';

/// Extensions a gate may have when `settings.gateExtensions` is not set.
/// Upstream defaults to the TypeScript / JavaScript extensions.
const defaultGateExtensions = ['.dart'];

/// Timeouts tolerated outside `expectedTimeouts` when
/// `settings.mutation.maxTimeouts` is not set. Same as upstream 0.3.2.
const defaultMaxTimeouts = 0;

/// URIs a pure module must not import, export or have as a part: pattern and
/// reason. The patterns are tested against the URI as it is written.
///
/// `package:json_annotation`, `package:meta` and `package:collection` are
/// deliberately absent: annotations and pure data structures.
const defaultImpureImports = [
  (r'^package:flutter/', 'Flutter framework'),
  (r'^package:(flutter_[^/]*|[^/]*_flutter)/', 'Flutter plugin or UI package'),
  (r'^dart:(ui|ui_web)$', 'Flutter engine'),
  (
    r'^dart:(io|ffi|isolate|mirrors)$',
    'file system / network / process access',
  ),
  (
    r'^dart:(html|indexed_db|svg|web_audio|web_gl|js|js_[a-z_]+)$',
    'browser API',
  ),
  (r'^package:(web|js)/', 'browser API'),
  (
    r'^package:(http|dio|retrofit|chopper|graphql|grpc|web_socket_channel)/',
    'HTTP client',
  ),
  (
    r'^package:(shared_preferences|sqflite|hive|hive_ce|isar|drift|sembast|objectbox|path_provider)/',
    'persistence',
  ),
  (
    r'^package:(sqlite3|postgres|mysql1|mysql_client|mongo_dart|redis)/',
    'database client',
  ),
  (
    r'^package:(bloc|provider|riverpod|hooks_riverpod|riverpod_annotation|get|get_it|mobx|redux|rxdart)/',
    'state management',
  ),
  (
    r'^package:(firebase_[^/]*|cloud_firestore|cloud_functions|sentry)/',
    'external service SDK',
  ),
];

/// Paths that cannot be gates: pattern and reason.
const defaultImpurePaths = [(r'\.(g|freezed)\.dart$', 'generated file')];

/// Where the mutation report is written and read when
/// `settings.stryker.reportFile` is not set. Same as upstream.
const defaultReportFile = 'reports/mutation/mutation.json';

/// Which gates `selfcheck` checks when `settings.selfcheck.mode` is not set.
const defaultSelfcheckMode = 'all';

/// The keys upstream accepts directly under `settings`. All of them are
/// accepted here too, so that one test-gates.json can be read by both tools.
const settingsKeys = [
  'gateExtensions',
  'spec',
  'impureImports',
  'impureNamedImports',
  'impurePaths',
  'forbiddenSource',
  'importAliases',
  'gateCommand',
  'selfcheck',
  'stryker',
  'lcov',
  'imports',
  'mutation',
];

class SettingsError implements Exception {
  SettingsError(this.message);

  final String message;

  @override
  String toString() => message;
}

RegExp _compile(String pattern, String where, [String? flags]) {
  // Dart has no flag string. The flags of JavaScript that Dart supports are
  // mapped, `g` changes nothing for a yes/no match, and anything else is an
  // error instead of being silently dropped.
  final unknown = (flags ?? '').replaceAll(RegExp('[gimsu]'), '');
  if (unknown.isNotEmpty) {
    throw SettingsError(
      '$where: unsupported regular expression flags ${quote(unknown)} '
      '(supported: g, i, m, s, u)',
    );
  }
  final set = flags ?? '';
  // JavaScript rejects a flag given twice.
  if (set.split('').toSet().length != set.length) {
    throw SettingsError(
      '$where: invalid regular expression flags ${quote(set)} (a flag is repeated)',
    );
  }
  try {
    return RegExp(
      pattern,
      caseSensitive: !set.contains('i'),
      multiLine: set.contains('m'),
      dotAll: set.contains('s'),
      unicode: set.contains('u'),
    );
  } on FormatException catch (error) {
    throw SettingsError(
      '$where: invalid regular expression ${quote(pattern)} (${error.message})',
    );
  }
}

List<String> _stringArray(Object? value, String where) {
  if (value is! List || value.any((item) => item is! String || item.isEmpty)) {
    throw SettingsError('$where: must be an array of non-empty strings');
  }
  return value.cast<String>();
}

String? _optionalString(JsonObject section, String key, String where) {
  if (!section.containsKey(key)) {
    return null;
  }
  final value = section[key];
  if (value is! String || value.isEmpty) {
    throw SettingsError('$where: must be a non-empty string');
  }
  return value;
}

void _rejectUnknownKeys(JsonObject value, List<String> known, String where) {
  for (final key in value.keys) {
    if (!known.contains(key)) {
      throw SettingsError('$where: unknown key ${quote(key)}');
    }
  }
}

/// `parent[key]` as an object with only [known] keys; empty when absent.
JsonObject _section(
  JsonObject parent,
  String key,
  List<String> known,
  String where,
) {
  if (!parent.containsKey(key)) {
    return const {};
  }
  final value = asObject(parent[key]);
  if (value == null) {
    throw SettingsError('$where: must be an object');
  }
  _rejectUnknownKeys(value, known, where);
  return value;
}

/// `section[key]` as a list; empty when absent or `null` (upstream reads
/// these with `?? []`).
List<Object?> _list(JsonObject section, String key, String where) {
  final value = section[key];
  if (value == null) {
    return const [];
  }
  if (value is! List) {
    throw SettingsError('$where: must be an array');
  }
  return value;
}

void _optionalBool(JsonObject section, String key, String where) {
  if (section.containsKey(key) && section[key] is! bool) {
    throw SettingsError('$where: must be a boolean');
  }
}

void _optionalText(JsonObject section, String key, String where) {
  if (section.containsKey(key) && section[key] is! String) {
    throw SettingsError('$where: must be a string');
  }
}

String? _flags(JsonObject item) => item['flags'] as String?;

/// A `{ defaults, add }` rule list (`impureImports`, `impurePaths`,
/// `forbiddenSource`): the section, and the rules it resolves to.
(JsonObject, List<CompiledRule>) _compileRules(
  JsonObject settings,
  String key,
  List<(String, String)> defaults, [
  List<String> extraKeys = const [],
]) {
  final where = 'settings.$key';
  final config = _section(settings, key, [
    'defaults',
    'add',
    ...extraKeys,
  ], where);
  _optionalBool(config, 'defaults', '$where.defaults');
  final rules = [
    if (config['defaults'] != false)
      for (final (pattern, reason) in defaults)
        CompiledRule(_compile(pattern, where), reason),
  ];
  for (final (index, item) in _list(config, 'add', '$where.add').indexed) {
    final at = '$where.add[$index]';
    if (item is String && item.isNotEmpty) {
      rules.add(CompiledRule(_compile(item, at), 'matches $item'));
      continue;
    }
    final rule = asObject(item);
    final pattern = rule?['pattern'];
    if (rule == null || pattern is! String || pattern.isEmpty) {
      throw SettingsError(
        '$at: must be a pattern string or { pattern, flags?, reason? }',
      );
    }
    _rejectUnknownKeys(rule, const ['pattern', 'flags', 'reason'], at);
    _optionalText(rule, 'flags', '$at.flags');
    _optionalText(rule, 'reason', '$at.reason');
    rules.add(
      CompiledRule(
        _compile(pattern, at, _flags(rule)),
        rule['reason'] as String? ?? 'matches $pattern',
      ),
    );
  }
  return (config, rules);
}

List<String> _names(JsonObject item, String at) {
  final names = _stringArray(item['names'], '$at.names');
  if (names.isEmpty) {
    throw SettingsError('$at.names: must list at least one name');
  }
  return names;
}

/// The settings `check` acts on, resolved.
typedef _CheckSettings = ({
  List<CompiledRule> impureImports,
  List<RegExp> allowedImports,
  List<NamedImportRule> impureNamedImports,
  List<CompiledRule> impurePaths,
  List<CompiledRule> forbiddenSource,
  bool forbiddenSourceDefaults,
  List<ImportAlias> importAliases,
  ImportMode importMode,
  List<ImportAllowRule> importAllow,
});

_CheckSettings _resolveCheckSettings(JsonObject settings) {
  final (imports, impureImports) = _compileRules(
    settings,
    'impureImports',
    defaultImpureImports,
    const ['allow'],
  );
  const allowWhere = 'settings.impureImports.allow';
  final allowedImports = [
    if (imports.containsKey('allow'))
      for (final (index, pattern) in _stringArray(
        imports['allow'],
        allowWhere,
      ).indexed)
        _compile(pattern, '$allowWhere[$index]'),
  ];
  final (_, impurePaths) = _compileRules(
    settings,
    'impurePaths',
    defaultImpurePaths,
  );
  // The built-in rules of forbiddenSource are found in the syntax, not with a
  // pattern, so only `add` is compiled here.
  final (forbidden, forbiddenSource) = _compileRules(
    settings,
    'forbiddenSource',
    const [],
  );

  const namedWhere = 'settings.impureNamedImports';
  final named = _section(settings, 'impureNamedImports', const [
    'defaults',
    'add',
  ], namedWhere);
  _optionalBool(named, 'defaults', '$namedWhere.defaults');
  // There is no built-in rule: `defaults` is accepted and changes nothing.
  final impureNamedImports = <NamedImportRule>[];
  for (final (index, item) in _list(named, 'add', '$namedWhere.add').indexed) {
    final at = '$namedWhere.add[$index]';
    final rule = asObject(item);
    final module = rule?['module'];
    if (rule == null || module is! String || module.isEmpty) {
      throw SettingsError('$at: must be { module, names, reason? }');
    }
    _rejectUnknownKeys(rule, const ['module', 'names', 'reason'], at);
    final names = _names(rule, at);
    _optionalText(rule, 'reason', '$at.reason');
    impureNamedImports.add(
      NamedImportRule(
        module: module,
        names: names,
        reason: rule['reason'] as String? ?? 'not allowed in a pure module',
      ),
    );
  }

  final importAliases = <ImportAlias>[];
  for (final (index, item) in _list(
    settings,
    'importAliases',
    'settings.importAliases',
  ).indexed) {
    final at = 'settings.importAliases[$index]';
    final alias = asObject(item);
    final prefix = alias?['prefix'];
    final target = alias?['target'];
    if (alias == null ||
        prefix is! String ||
        prefix.isEmpty ||
        target is! String) {
      throw SettingsError('$at: must be { prefix, target }');
    }
    _rejectUnknownKeys(alias, const ['prefix', 'target'], at);
    importAliases.add(ImportAlias(prefix, target));
  }

  final importsSection = _section(settings, 'imports', const [
    'mode',
    'allow',
  ], 'settings.imports');
  if (importsSection.containsKey('mode') &&
      !const ['blocklist', 'allowlist'].contains(importsSection['mode'])) {
    throw SettingsError(
      'settings.imports.mode: must be "blocklist" or "allowlist"',
    );
  }
  final importAllow = <ImportAllowRule>[];
  for (final (index, item) in _list(
    importsSection,
    'allow',
    'settings.imports.allow',
  ).indexed) {
    final at = 'settings.imports.allow[$index]';
    if (item is String && item.isNotEmpty) {
      importAllow.add(ImportAllowRule(module: item));
      continue;
    }
    final entry = asObject(item);
    final pattern = entry?['pattern'];
    final module = entry?['module'];
    if (entry != null && pattern is String && pattern.isNotEmpty) {
      _rejectUnknownKeys(entry, const ['pattern', 'flags'], at);
      _optionalText(entry, 'flags', '$at.flags');
      importAllow.add(
        ImportAllowRule(regex: _compile(pattern, at, _flags(entry))),
      );
    } else if (entry != null && module is String && module.isNotEmpty) {
      _rejectUnknownKeys(entry, const ['module', 'names'], at);
      importAllow.add(
        ImportAllowRule(module: module, names: _names(entry, at)),
      );
    } else {
      throw SettingsError(
        '$at: must be a package name, { pattern, flags? } or { module, names }',
      );
    }
  }

  return (
    impureImports: impureImports,
    allowedImports: allowedImports,
    impureNamedImports: impureNamedImports,
    impurePaths: impurePaths,
    forbiddenSource: forbiddenSource,
    forbiddenSourceDefaults: forbidden['defaults'] != false,
    importAliases: importAliases,
    importMode: importsSection['mode'] == 'allowlist'
        ? ImportMode.allowlist
        : ImportMode.blocklist,
    importAllow: importAllow,
  );
}

/// Validates the sections that only upstream acts on (a mistake in them is
/// still an error) and returns `settings.stryker.reportFile`.
String? _validateUnusedSections(JsonObject settings) {
  final selfcheck = _selfcheckSection(settings);
  const failureWhere = 'settings.selfcheck.failurePattern';
  final failurePattern = _optionalString(
    selfcheck,
    'failurePattern',
    failureWhere,
  );
  if (failurePattern != null) {
    _compile(failurePattern.split('{gate}').join('x'), failureWhere);
  }

  final stryker = _section(settings, 'stryker', const [
    'configFile',
    'reportFile',
  ], 'settings.stryker');
  _optionalString(stryker, 'configFile', 'settings.stryker.configFile');
  return _optionalString(stryker, 'reportFile', 'settings.stryker.reportFile');
}

/// Applies defaults to `settings` of test-gates.json and compiles every
/// pattern. Throws [SettingsError] on anything it does not understand: a typo
/// in a setting must not silently fall back to a default.
///
/// [raw] is the value of the `settings` key; pass an empty map when the
/// manifest has none.
ResolvedSettings resolveSettings(Object? raw) {
  final settings = _section(
    {'settings': raw},
    'settings',
    settingsKeys,
    'settings',
  );

  final gateExtensions = settings.containsKey('gateExtensions')
      ? _stringArray(settings['gateExtensions'], 'settings.gateExtensions')
      : defaultGateExtensions;
  if (gateExtensions.isEmpty ||
      gateExtensions.any((extension) => !extension.startsWith('.'))) {
    throw SettingsError(
      'settings.gateExtensions: must list at least one extension starting with "."',
    );
  }

  final spec = _section(settings, 'spec', const [
    'suffixes',
    'rewrite',
  ], 'settings.spec');
  final specSuffixes = spec.containsKey('suffixes')
      ? _stringArray(spec['suffixes'], 'settings.spec.suffixes')
      : null;
  // `"rewrite": null` is "not set", as it is upstream (`?? []`).
  final specRewrite = spec['rewrite'] == null
      ? null
      : [
          for (final (index, item) in _list(
            spec,
            'rewrite',
            'settings.spec.rewrite',
          ).indexed)
            _specRewrite(item, 'settings.spec.rewrite[$index]'),
        ];

  final check = _resolveCheckSettings(settings);
  final reportFile = _validateUnusedSections(settings);

  final mutation = _section(settings, 'mutation', const [
    'maxTimeouts',
  ], 'settings.mutation');
  final maxTimeouts = asInteger(mutation['maxTimeouts']);
  if (mutation.containsKey('maxTimeouts') &&
      (maxTimeouts == null || maxTimeouts < 0)) {
    throw SettingsError(
      'settings.mutation.maxTimeouts: must be an integer >= 0',
    );
  }

  final lcov = _section(settings, 'lcov', const [
    'file',
    'summaryExclude',
  ], 'settings.lcov');
  const excludeWhere = 'settings.lcov.summaryExclude';

  return ResolvedSettings(
    gateExtensions: gateExtensions,
    specSuffixes: specSuffixes,
    specRewrite: specRewrite,
    impureImports: check.impureImports,
    allowedImports: check.allowedImports,
    impureNamedImports: check.impureNamedImports,
    impurePaths: check.impurePaths,
    forbiddenSource: check.forbiddenSource,
    forbiddenSourceDefaults: check.forbiddenSourceDefaults,
    importAliases: check.importAliases,
    importMode: check.importMode,
    importAllow: check.importAllow,
    lcovFile: _optionalString(lcov, 'file', 'settings.lcov.file'),
    lcovSummaryExclude: [
      if (lcov.containsKey('summaryExclude'))
        for (final (index, pattern) in _stringArray(
          lcov['summaryExclude'],
          excludeWhere,
        ).indexed)
          _compile(pattern, '$excludeWhere[$index]'),
    ],
    maxTimeouts: maxTimeouts ?? defaultMaxTimeouts,
    reportFile: reportFile ?? defaultReportFile,
    gateCommand: _gateCommand(settings),
    selfcheckMode:
        _selfcheckSection(settings)['mode'] as String? ?? defaultSelfcheckMode,
  );
}

List<String>? _gateCommand(JsonObject settings) {
  if (!settings.containsKey('gateCommand')) {
    return null;
  }
  final command = _stringArray(settings['gateCommand'], 'settings.gateCommand');
  if (command.isEmpty) {
    throw SettingsError('settings.gateCommand: must not be empty');
  }
  return command;
}

JsonObject _selfcheckSection(JsonObject settings) {
  final selfcheck = _section(settings, 'selfcheck', const [
    'mode',
    'failurePattern',
  ], 'settings.selfcheck');
  if (selfcheck.containsKey('mode') &&
      !const ['all', 'first'].contains(selfcheck['mode'])) {
    throw SettingsError('settings.selfcheck.mode: must be "all" or "first"');
  }
  return selfcheck;
}

SpecRewrite _specRewrite(Object? item, String at) {
  final rewrite = asObject(item);
  final from = rewrite?['from'];
  final to = rewrite?['to'];
  if (rewrite == null || from is! String || to is! String) {
    throw SettingsError('$at: must be { from, to }');
  }
  _rejectUnknownKeys(rewrite, const ['from', 'to'], at);
  return SpecRewrite(_compile(from, at), to);
}
