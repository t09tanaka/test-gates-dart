import 'dart:io';

import 'package:test_gates_example/bulk_discount.dart';
import 'package:test_gates_example/shipping_fee.dart';

/// Prints what an order costs:
/// `dart run bin/estimate.dart <unit cents> <quantity> <grams per item>`.
void main(List<String> arguments) {
  final [unitCents, quantity, gramsPerItem] = arguments.map(int.parse).toList();
  final items = lineTotalCents(unitCents, quantity);
  final shipping = shippingFeeCents(gramsPerItem * quantity);
  stdout.writeln('items $items + shipping $shipping = ${items + shipping}');
}
