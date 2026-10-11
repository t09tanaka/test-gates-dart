import 'package:test/test.dart';
import 'package:test_gates_example/bulk_discount.dart';

Matcher _rejects(String name, String message) => throwsA(
  isA<ArgumentError>()
      .having((error) => error.name, 'name', name)
      .having((error) => error.message, 'message', message),
);

void main() {
  test('multiplies the price by the quantity', () {
    expect(lineTotalCents(250, 1), 250);
    expect(lineTotalCents(250, 9), 2250);
    expect(lineTotalCents(0, 3), 0);
  });

  test('takes 5 percent off from 10 items on', () {
    expect(lineTotalCents(250, 10), 2375);
    expect(lineTotalCents(250, 49), 11637);
  });

  test('takes 12 percent off from 50 items on', () {
    expect(lineTotalCents(250, 50), 11000);
    expect(lineTotalCents(250, 200), 44000);
  });

  test('rounds the discount half up to a whole cent', () {
    // 5% of 990 is 49.5, of 980 is 49.0, of 1010 is 50.5.
    expect(lineTotalCents(99, 10), 940);
    expect(lineTotalCents(98, 10), 931);
    expect(lineTotalCents(101, 10), 959);
  });

  test('rejects a negative price', () {
    expect(() => lineTotalCents(-1, 3), _rejects('unitCents', 'is negative'));
  });

  test('rejects a quantity below 1', () {
    expect(
      () => lineTotalCents(250, 0),
      _rejects('quantity', 'is less than 1'),
    );
  });
}
