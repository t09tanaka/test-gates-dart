import 'package:test/test.dart';
import 'package:test_gates/src/json.dart';

void main() {
  test('asObject: a JSON object and nothing else', () {
    final object = <String, Object?>{'a': 1};
    expect(asObject(object), same(object));
    expect(asObject(<Object?>[]), isNull);
    expect(asObject('{}'), isNull);
    expect(asObject(null), isNull);
  });

  test('isFilled: a string with something other than whitespace', () {
    expect(isFilled('a'), isTrue);
    expect(isFilled(' a '), isTrue);
    expect(isFilled(''), isFalse);
    expect(isFilled(' \t\n'), isFalse);
    expect(isFilled(1), isFalse);
    expect(isFilled(null), isFalse);
  });

  test('asText: a string, or null', () {
    expect(asText('a'), 'a');
    expect(asText(''), '');
    expect(asText(1), isNull);
    expect(asText(null), isNull);
    expect(asText(['a']), isNull);
  });

  test('asInteger: 1.0 is an integer, as for Number.isInteger', () {
    expect(asInteger(2), 2);
    expect(asInteger(0), 0);
    expect(asInteger(2.0), 2);
    expect(asInteger(2.0), isA<int>());
    expect(asInteger(-3.0), -3);
    expect(asInteger(2.5), isNull);
    expect(asInteger(double.infinity), isNull);
    expect(asInteger(double.negativeInfinity), isNull);
    expect(asInteger(double.nan), isNull);
    expect(asInteger('2'), isNull);
    expect(asInteger(null), isNull);
  });

  test('quote: as the string would be written in JSON', () {
    expect(quote('a'), '"a"');
    expect(quote(''), '""');
    expect(quote('a"b'), r'"a\"b"');
    expect(quote(r'a\b'), r'"a\\b"');
    // The backslash is escaped first, so the one of an escaped quote is not
    // escaped again.
    expect(quote(r'\"'), r'"\\\""');
  });
}
