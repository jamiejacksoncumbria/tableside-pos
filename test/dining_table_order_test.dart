import 'package:flutter_test/flutter_test.dart';
import 'package:tableside_pos/features/pos/domain.dart';

void main() {
  test('table labels use stable natural-number ordering', () {
    final tables = <DiningTable>[
      const DiningTable(id: '10', label: 'Table 10', seats: 4),
      const DiningTable(id: '2', label: 'Table 2', seats: 4),
      const DiningTable(id: '1', label: 'Table 1', seats: 4),
      const DiningTable(id: 'bar-10', label: 'Bar 10', seats: 2),
      const DiningTable(id: 'bar-2', label: 'Bar 2', seats: 2),
    ]..sort(compareDiningTables);

    expect(tables.map((table) => table.label), [
      'Bar 2',
      'Bar 10',
      'Table 1',
      'Table 2',
      'Table 10',
    ]);
  });

  test('configured order is used before natural label ordering', () {
    final tables = <DiningTable>[
      const DiningTable(
        id: 'terrace',
        label: 'Terrace 1',
        seats: 4,
        sortOrder: 1,
      ),
      const DiningTable(id: 'table', label: 'Table 1', seats: 4, sortOrder: 2),
      const DiningTable(id: 'unconfigured', label: 'Bar 1', seats: 2),
    ]..sort(compareDiningTables);

    expect(tables.map((table) => table.id), [
      'terrace',
      'table',
      'unconfigured',
    ]);
  });
}
