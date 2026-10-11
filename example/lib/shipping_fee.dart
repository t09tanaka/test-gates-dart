/// No parcel costs more than this to send, in cents.
const maxFeeCents = 2000;

/// The fee for sending a parcel of [weightGrams], in cents.
///
/// 500 cents for every kilogram or part of a kilogram, and never more than
/// [maxFeeCents].
int shippingFeeCents(int weightGrams) {
  if (weightGrams <= 0) {
    throw ArgumentError.value(weightGrams, 'weightGrams', 'is not positive');
  }
  final kilos = (weightGrams + 999) ~/ 1000;
  var fee = kilos * 500;
  if (fee > maxFeeCents) {
    fee = maxFeeCents;
  }
  return fee;
}
