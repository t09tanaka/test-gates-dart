final _name = RegExp(
  r'''^(?:name|"name"|'name')[ \t]*:[ \t]*(['"]?)([A-Za-z_][A-Za-z0-9_]*)\1[ \t]*(#.*)?$''',
  multiLine: true,
);

/// `name` of a pubspec.yaml, or `null` when it has none.
///
/// Read with a pattern, not a YAML parser: the name is a top-level key on a
/// line of its own in the pubspecs that are written by hand or by the
/// tools. `check` reports a pubspec whose name is not found this way.
String? packageNameOf(String pubspec) => _name.firstMatch(
  pubspec.replaceAll('\r\n', '\n').replaceFirst(RegExp('^\uFEFF'), ''),
)?[2];
