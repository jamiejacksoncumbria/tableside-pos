/// The receipt widths currently supported by the first native print adapters.
/// The selected layout must match the paper configured in the printer driver.
enum ReceiptPaperWidth {
  mm58(58, '58 mm', 32),
  mm80(80, '80 mm', 48);

  const ReceiptPaperWidth(
    this.millimetres,
    this.label,
    this.approximateColumns,
  );

  final int millimetres;
  final String label;
  final int approximateColumns;

  bool get isNarrow => this == ReceiptPaperWidth.mm58;

  static ReceiptPaperWidth fromMillimetres(Object? value) => switch (value) {
    80 || '80' => ReceiptPaperWidth.mm80,
    _ => ReceiptPaperWidth.mm58,
  };
}
