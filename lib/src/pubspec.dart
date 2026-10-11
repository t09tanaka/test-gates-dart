final _name = RegExp(
  r'''^name:[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[ \t]*(#.*)?$''',
  multiLine: true,
);

/// `name` of a pubspec.yaml, or `null` when it has none.
///
/// Read with a pattern, not a YAML parser: the name is a top-level key on a
/// line of its own in every pubspec `dart pub` accepts.
String? packageNameOf(String pubspec) => _name.firstMatch(
  pubspec.replaceAll('\r\n', '\n').replaceFirst(RegExp('^\uFEFF'), ''),
)?[2];
