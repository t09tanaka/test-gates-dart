import 'types.dart';

/// Where the tests of a package live when `settings.spec.rewrite` is not set:
/// next to the gate, or under `test/` with the same path below `lib/`.
final _libPrefix = RegExp('^lib/');

/// The configured gate extension [gatePath] ends with (longest wins), or
/// `null`.
String? gateExtensionOf(String gatePath, List<String> gateExtensions) {
  String? longest;
  for (final extension in gateExtensions) {
    if (gatePath.endsWith(extension) &&
        extension.length > (longest?.length ?? 0)) {
      longest = extension;
    }
  }
  return longest;
}

List<String> _suffixesFor(String extension, ResolvedSettings settings) =>
    settings.specSuffixes ?? ['_test$extension'];

/// `text.replace(regex, to)` of JavaScript for a pattern without the `g`
/// flag: the first match is replaced, and `$1`, `$&` and `$$` in [to] are
/// expanded. The same `settings.spec.rewrite` then means the same upstream.
String replaceFirstLikeJs(String text, RegExp regex, String to) {
  final match = regex.firstMatch(text);
  if (match == null) {
    return text;
  }
  final replacement = to.replaceAllMapped(RegExp(r'\$(\$|&|\d{1,2})'), (ref) {
    final key = ref[1]!;
    if (key == r'$') {
      return r'$';
    }
    if (key == '&') {
      return match[0]!;
    }
    final group = int.parse(key);
    // An index that is not a group of the pattern is kept as it is written.
    return group >= 1 && group <= match.groupCount
        ? match[group] ?? ''
        : ref[0]!;
  });
  return text.replaceRange(match.start, match.end, replacement);
}

/// Where the test of a gate may live, in order of preference.
///
/// By default `lib/a/b.dart` → `lib/a/b_test.dart` (next to the gate) and
/// `test/a/b_test.dart` (the mirror under `test/`). `settings.spec.suffixes`
/// replaces the suffix list (an empty list means "this project has no spec
/// convention"), and `settings.spec.rewrite`, once set, replaces the two
/// default directories with the one it rewrites the path to.
List<String> specCandidatesFor(String gatePath, ResolvedSettings settings) {
  final extension = gateExtensionOf(gatePath, settings.gateExtensions);
  if (extension == null) {
    return [];
  }
  final base = gatePath.substring(0, gatePath.length - extension.length);
  final rewrite = settings.specRewrite;
  final List<String> bases;
  if (rewrite == null) {
    bases = [base, base.replaceFirst(_libPrefix, 'test/')];
  } else {
    var rewritten = base;
    for (final rule in rewrite) {
      rewritten = replaceFirstLikeJs(rewritten, rule.regex, rule.to);
    }
    bases = [rewritten];
  }
  return {
    for (final candidate in bases)
      for (final suffix in _suffixesFor(extension, settings))
        candidate + suffix,
  }.toList();
}

/// True when [gatePath] has a gate extension and is itself named like a test.
bool looksLikeSpec(String gatePath, ResolvedSettings settings) {
  final extension = gateExtensionOf(gatePath, settings.gateExtensions);
  return extension != null &&
      _suffixesFor(extension, settings).any(gatePath.endsWith);
}
