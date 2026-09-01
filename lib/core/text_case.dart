const _catalogueAcronyms = <String>{
  'BBQ',
  'IPA',
  'KDV',
  'NFC',
  'QR',
  'SKU',
  'VAT',
};

final _measurementToken = RegExp(
  r'^\d+(?:\.\d+)?(?:cl|g|kg|l|ml|oz)$',
  caseSensitive: false,
);
final _titleCaseLetter = RegExp(r'[A-Za-zÀ-ÖØ-öø-ÿ]');

/// Normalises catalogue labels while retaining common hospitality acronyms.
///
/// This is intentionally used for menu-owned names only. Customer names,
/// addresses and free-text notes must preserve the user's original casing.
String toCatalogueTitleCase(String value) {
  final words = value
      .trim()
      .split(RegExp(r'\s+'))
      .where((word) => word.isNotEmpty);
  return words.map(_titleCaseWord).join(' ');
}

String _titleCaseWord(String word) => word.splitMapJoin(
  RegExp(r'[-/]'),
  onMatch: (match) => match.group(0)!,
  onNonMatch: _titleCaseSegment,
);

String _titleCaseSegment(String segment) {
  if (segment.isEmpty) return segment;
  final upperLetters = segment
      .replaceAll(RegExp(r'[^A-Za-z]'), '')
      .toUpperCase();
  if (_catalogueAcronyms.contains(upperLetters)) return segment.toUpperCase();
  if (_measurementToken.hasMatch(segment)) return segment.toLowerCase();

  final lower = segment.toLowerCase();
  final firstLetter = _titleCaseLetter.firstMatch(lower);
  if (firstLetter == null) return lower;
  final index = firstLetter.start;
  return lower.replaceRange(index, index + 1, lower[index].toUpperCase());
}
