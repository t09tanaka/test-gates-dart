/// The price of [quantity] items at [unitCents] each, in cents.
///
/// From 10 items on, 5 percent is taken off the line, and from 50 items on,
/// 12 percent. The discount is rounded half up to a whole cent.
int lineTotalCents(int unitCents, int quantity) {
  if (unitCents < 0) {
    throw ArgumentError.value(unitCents, 'unitCents', 'is negative');
  }
  if (quantity < 1) {
    throw ArgumentError.value(quantity, 'quantity', 'is less than 1');
  }
  final total = unitCents * quantity;
  var percent = 0;
  if (quantity >= 50) {
    percent = 12;
  } else if (quantity >= 10) {
    percent = 5;
  }
  final discount = (total * percent + 50) ~/ 100;
  return total - discount;
}
