import 'package:test/test.dart';
import 'package:test_gates_example/shipping_fee.dart';

void main() {
  test('charges 500 cents for every kilogram or part of one', () {
    expect(shippingFeeCents(1), 500);
    expect(shippingFeeCents(1000), 500);
    expect(shippingFeeCents(1001), 1000);
    expect(shippingFeeCents(4000), 2000);
  });

  test('never charges more than the maximum', () {
    expect(shippingFeeCents(4001), 2000);
    expect(shippingFeeCents(30000), 2000);
  });

  test('rejects a weight that is not positive', () {
    expect(
      () => shippingFeeCents(0),
      throwsA(
        isA<ArgumentError>()
            .having((error) => error.name, 'name', 'weightGrams')
            .having((error) => error.message, 'message', 'is not positive'),
      ),
    );
  });
}
