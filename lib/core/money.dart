String formatMoney(int minorUnits, {String currencySymbol = '£'}) {
  final sign = minorUnits.isNegative ? '-' : '';
  final absolute = minorUnits.abs();
  final major = absolute ~/ 100;
  final cents = (absolute % 100).toString().padLeft(2, '0');
  return '$sign$currencySymbol$major.$cents';
}
