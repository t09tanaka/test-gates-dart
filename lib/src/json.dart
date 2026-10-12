/// Small helpers for reading decoded JSON the way the upstream (TypeScript)
/// implementation does.
library;

typedef JsonObject = Map<String, Object?>;

/// The value as a JSON object, or `null` when it is anything else.
JsonObject? asObject(Object? value) => value is JsonObject ? value : null;

/// The value as a string, or `null` when it is anything else.
String? asText(Object? value) => value is String ? value : null;

/// True for a string that has something other than whitespace in it.
bool isFilled(Object? value) => value is String && value.trim().isNotEmpty;

/// The value as an integer, or `null`. `1.0` counts as an integer, as it does
/// for `Number.isInteger` upstream.
int? asInteger(Object? value) {
  if (value is int) {
    return value;
  }
  if (value is double && value.isFinite && value == value.truncateToDouble()) {
    return value.toInt();
  }
  return null;
}

/// A string as it would be written in JSON, for error messages.
String quote(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
