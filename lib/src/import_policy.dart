import 'dart_source.dart';
import 'types.dart';

/// What a gate may import in allowlist mode without being listed in
/// `settings.imports.allow`: the libraries of the SDK that compute and hold
/// data, and the packages that are annotations or pure data structures.
///
/// This list does not depend on the blocklist, so that `dart:io` stays out
/// when `settings.impureImports.defaults` is `false`.
const builtInImportAllow = [
  'dart:core',
  'dart:async',
  'dart:collection',
  'dart:convert',
  'dart:math',
  'dart:typed_data',
  'package:collection',
  'package:json_annotation',
  'package:meta',
];

/// Parts written by a code generator (`*.g.dart` of json_serializable and
/// others, `*.freezed.dart` of freezed): the same files that cannot be gates. Any other part is code of the gate that lives in a
/// file nobody listed.
final _generatedPart = RegExp(r'\.(g|freezed)\.dart$');

/// The alias every package has: `package:<name>/` is its own `lib/`.
List<ImportAlias> aliasesFor(String? packageName, List<ImportAlias> aliases) =>
    [
      if (packageName != null) ImportAlias('package:$packageName/', 'lib/'),
      ...aliases,
    ];

/// True for an import that stays inside the package: a relative URI, or one
/// through an alias (`package:<own name>/` included, see [aliasesFor]).
bool isProjectImport(String uri, List<ImportAlias> aliases) =>
    !uri.contains(':') || aliases.any((alias) => uri.startsWith(alias.prefix));

/// The path inside the package a URI points at, or `null` for another
/// package or the SDK. `../money.dart` imported from `lib/a/b.dart` is
/// `lib/money.dart`. A URI that leaves the package keeps its `..`
/// (`../outside.dart`): it names no file of the package.
String? resolveUri(String uri, String fromFile, List<ImportAlias> aliases) {
  String? joined;
  for (final alias in aliases) {
    if (uri.startsWith(alias.prefix)) {
      joined = alias.target + uri.substring(alias.prefix.length);
      break;
    }
  }
  if (joined == null) {
    if (uri.contains(':')) {
      return null;
    }
    final slash = fromFile.lastIndexOf('/');
    joined = slash == -1 ? uri : '${fromFile.substring(0, slash)}/$uri';
  }
  final segments = <String>[];
  for (final segment in joined.split('/')) {
    if (segment == '..') {
      // Above the package there is nothing of the package: the `..` stays,
      // and the path is then one that no file of the package has.
      if (segments.isEmpty || segments.last == '..') {
        segments.add(segment);
      } else {
        segments.removeLast();
      }
    } else if (segment != '.' && segment.isNotEmpty) {
      segments.add(segment);
    }
  }
  return segments.join('/');
}

bool _matches(String entry, String uri) =>
    uri == entry || uri.startsWith('$entry/');

/// Allowlist mode: an import of another package or of the SDK must be built
/// in ([builtInImportAllow]) or listed in `settings.imports.allow`.
///
/// Returns why the import is not allowed, or `null` when it is.
String? judgePackageImport(ImportRef ref, List<ImportAllowRule> allow) {
  final rules = [
    for (final rule in allow)
      if (rule.regex?.hasMatch(ref.uri) ?? _matches(rule.module!, ref.uri))
        rule,
  ];
  if (rules.isEmpty) {
    // An entry of the project wins over the built-in list, so that
    // `{ "module": "dart:math", "names": ["max"] }` narrows what is built in.
    if (builtInImportAllow.any((entry) => _matches(entry, ref.uri))) {
      return null;
    }
    return 'import of "${ref.uri}" is not in settings.imports.allow '
        '(allowlist mode allows the package\'s own files and listed '
        'libraries only)';
  }
  if (rules.any((rule) => rule.names == null)) {
    return null;
  }
  final allowedNames = [for (final rule in rules) ...rule.names!];
  final shown = ref.shown;
  if (shown == null) {
    return 'only ${allowedNames.join(', ')} may be imported from '
        '"${ref.uri}", with show (settings.imports.allow)';
  }
  final extra = shown.where((name) => !allowedNames.contains(name)).toList();
  return extra.isEmpty
      ? null
      : 'import of ${extra.join(', ')} from "${ref.uri}" is not in '
            'settings.imports.allow (allowed: ${allowedNames.join(', ')})';
}

/// Allowlist mode: an import of a file of the package must not point at a
/// file that could not be a gate itself (`settings.impurePaths`).
///
/// [target] is the result of [resolveUri]. Returns why the target is not
/// allowed, or `null` when it is.
String? judgeProjectImport(String target, List<CompiledRule> impurePaths) {
  for (final rule in impurePaths) {
    if (rule.regex.hasMatch(target)) {
      return rule.reason;
    }
  }
  return null;
}

/// True for a part a code generator writes next to the gate.
bool isGeneratedPart(String uri) => _generatedPart.hasMatch(uri);
