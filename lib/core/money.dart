/// Formats an amount stored in the configured currency's ISO minor units.
///
/// The ISO code is intentionally displayed rather than a symbol: `$` is
/// ambiguous in a multi-restaurant product, while `USD`, `CAD`, and `AUD`
/// are clear on an order screen and receipt. The ISO 4217 exceptions below
/// cover zero-, three-, and four-decimal currencies; all other supported
/// currencies use the standard two decimal places.
String formatMoney(
  int minorUnits, {
  required String currencyCode,
}) {
  final normalizedCode = currencyCode.trim().toUpperCase();
  final code = normalizedCode.isEmpty ? 'GBP' : normalizedCode;
  final decimalDigits = currencyDecimalDigits(code);
  final sign = minorUnits.isNegative ? '-' : '';
  final absolute = minorUnits.abs();
  final scale = _powerOfTen(decimalDigits);
  final major = absolute ~/ scale;
  if (decimalDigits == 0) return '$code $sign$major';

  final fraction = (absolute % scale).toString().padLeft(decimalDigits, '0');
  return '$code $sign$major.$fraction';
}

/// ISO 4217 decimal places for an amount represented in that currency's
/// minor units. Most active ISO currencies have two decimal places.
int currencyDecimalDigits(String currencyCode) => switch (currencyCode) {
  'BIF' ||
  'CLP' ||
  'DJF' ||
  'GNF' ||
  'JPY' ||
  'KMF' ||
  'KRW' ||
  'PYG' ||
  'RWF' ||
  'UGX' ||
  'VND' ||
  'VUV' ||
  'XAF' ||
  'XOF' ||
  'XPF' => 0,
  'BHD' || 'IQD' || 'JOD' || 'KWD' || 'LYD' || 'OMR' || 'TND' => 3,
  'CLF' || 'UYW' => 4,
  _ => 2,
};

int _powerOfTen(int exponent) {
  var result = 1;
  for (var index = 0; index < exponent; index++) {
    result *= 10;
  }
  return result;
}
