part of '../reports_page.dart';

class _Metric extends StatelessWidget {
  const _Metric(this.label, this.value, this.currencyCode);
  final String label;
  final int value;
  final String currencyCode;
  @override
  Widget build(BuildContext context) => _MetricCard(
    label: label,
    value: formatMoney(value, currencyCode: currencyCode),
  );
}

class _CountMetric extends StatelessWidget {
  const _CountMetric(this.label, this.value);
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) =>
      _MetricCard(label: label, value: '$value');
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({required this.label, required this.value});
  final String label;
  final String value;
  @override
  Widget build(BuildContext context) => SizedBox(
    width: 190,
    child: Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(label),
          ],
        ),
      ),
    ),
  );
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({required this.title, required this.rows});
  final String title;
  final List<(String, String)> rows;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 10),
          if (rows.isEmpty)
            const Text('No closed sales in this period.')
          else
            for (final row in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    Expanded(child: Text(row.$1)),
                    const SizedBox(width: 12),
                    Text(row.$2),
                  ],
                ),
              ),
        ],
      ),
    ),
  );
}
