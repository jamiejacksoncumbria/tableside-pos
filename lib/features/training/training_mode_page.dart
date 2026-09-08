import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../core/training_mode.dart';
import '../../data/printer_device_repository.dart';
import '../../data/production_command_repository.dart';
import '../notifications/notification_centre.dart';
import '../pos/domain.dart';
import '../pos/pos_controller.dart';

class TrainingModePage extends ConsumerStatefulWidget {
  const TrainingModePage({super.key});

  @override
  ConsumerState<TrainingModePage> createState() => _TrainingModePageState();
}

class _TrainingModePageState extends ConsumerState<TrainingModePage> {
  final _pin = TextEditingController();
  String? _targetDeviceId;
  bool _busy = false;

  @override
  void dispose() {
    _pin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final active = ref.watch(trainingModeProvider);
    if (scope == null) {
      return const Scaffold(body: Center(child: Text('Choose a venue first.')));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Training mode')),
      body: StreamBuilder<List<PrinterDevice>>(
        stream: PrinterDeviceRepository(
          FirebaseFirestore.instance,
        ).watchVenueDevices(tenantId: scope.tenantId, venueId: scope.venueId),
        builder: (context, snapshot) {
          final devices =
              snapshot.data?.where((item) => item.active).toList() ??
              const <PrinterDevice>[];
          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                color: active == null
                    ? null
                    : Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        active == null
                            ? 'Start a training session'
                            : 'TRAINING MODE ACTIVE',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Training orders are isolated from live sales, stock, vouchers, deposits and production reporting. The mode ends automatically when this staff PIN session locks.',
                      ),
                      if (active == null) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String?>(
                          initialValue: _targetDeviceId,
                          decoration: const InputDecoration(
                            labelText: 'Dedicated test printer (optional)',
                          ),
                          items: [
                            const DropdownMenuItem<String?>(
                              value: null,
                              child: Text('Do not print training tickets'),
                            ),
                            for (final device in devices)
                              DropdownMenuItem<String?>(
                                value: device.id,
                                child: Text(
                                  '${device.name} · ${device.platform}',
                                ),
                              ),
                          ],
                          onChanged: (value) => _targetDeviceId = value,
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _pin,
                          onChanged: (_) => setState(() {}),
                          obscureText: true,
                          keyboardType: TextInputType.number,
                          maxLength: 6,
                          decoration: const InputDecoration(
                            labelText: 'Fresh manager PIN',
                          ),
                        ),
                        FilledButton.icon(
                          onPressed: _busy ? null : () => _start(scope),
                          icon: const Icon(Icons.school_rounded),
                          label: const Text('Start training mode'),
                        ),
                      ] else ...[
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => Navigator.pop(context),
                              icon: const Icon(Icons.point_of_sale_rounded),
                              label: const Text('Back to training POS'),
                            ),
                            FilledButton.icon(
                              onPressed: _busy
                                  ? null
                                  : () => _end(scope, active),
                              icon: const Icon(Icons.stop_circle_outlined),
                              label: const Text('End and return to settings'),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Remove training records',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const Text(
                'Managers can remove up to 500 isolated training orders at a time. The deletion itself remains in the audit trail.',
              ),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : () => _clear(scope),
                icon: const Icon(Icons.delete_sweep_outlined),
                label: const Text('Clear training orders'),
              ),
              const SizedBox(height: 24),
              Text(
                'Recent training records',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              _TrainingRecordList(
                scope: scope,
                currencyCode: ref.watch(tenantProfileProvider).currencyCode,
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _start(VenueScope scope) async {
    if (_pin.text.length != 6) return;
    setState(() => _busy = true);
    try {
      final result = await ProductionCommandRepository().startTrainingMode(
        scope: scope,
        managerPin: _pin.text,
        targetDeviceId: _targetDeviceId,
      );
      ref.read(activePersistedOrderIdProvider.notifier).select(null);
      ref.read(selectedTableProvider.notifier).select('');
      ref.read(trainingOpenOrdersProvider.notifier).clear();
      ref
          .read(trainingModeProvider.notifier)
          .start(
            TrainingModeSession(
              id: result.sessionId,
              targetDeviceId: result.targetDeviceId,
            ),
          );
      if (mounted) Navigator.pop(context);
    } on Object catch (error, stack) {
      AppLogger.error('Start training mode', error, stack);
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Could not start training mode',
          message: '$error',
          level: AppNotificationLevel.error,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _end(VenueScope scope, TrainingModeSession session) async {
    setState(() => _busy = true);
    try {
      await ProductionCommandRepository().endTrainingMode(
        scope: scope,
        trainingSessionId: session.id,
      );
      ref.read(trainingModeProvider.notifier).clear();
      ref.read(activePersistedOrderIdProvider.notifier).select(null);
      ref.read(selectedTableProvider.notifier).select('');
      ref.read(trainingOpenOrdersProvider.notifier).clear();
      if (mounted) Navigator.pop(context);
    } on Object catch (error, stack) {
      AppLogger.error('End training mode', error, stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear(VenueScope scope) async {
    final pin = await showDialog<String>(
      context: context,
      builder: (context) {
        final controller = TextEditingController();
        return AlertDialog(
          title: const Text('Clear training orders'),
          content: TextField(
            controller: controller,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            decoration: const InputDecoration(labelText: 'Fresh manager PIN'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, controller.text),
              child: const Text('Clear'),
            ),
          ],
        );
      },
    );
    if (pin == null || pin.length != 6) return;
    setState(() => _busy = true);
    try {
      final count = await ProductionCommandRepository().clearTrainingData(
        scope: scope,
        managerPin: pin,
      );
      if (mounted) {
        showAppNotification(
          context,
          ref: ref,
          title: 'Training data cleared',
          message: '$count training order${count == 1 ? '' : 's'} removed.',
          level: AppNotificationLevel.success,
        );
      }
    } on Object catch (error, stack) {
      AppLogger.error('Clear training orders', error, stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _TrainingRecordList extends StatelessWidget {
  const _TrainingRecordList({required this.scope, required this.currencyCode});

  final VenueScope scope;
  final String currencyCode;

  @override
  Widget build(BuildContext context) =>
      StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('tenants/${scope.tenantId}/trainingOrders')
            .where('venueId', isEqualTo: scope.venueId)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Text(
              'Training records could not be loaded: ${snapshot.error}',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final documents = snapshot.data!.docs.toList(growable: false)
            ..sort((left, right) {
              final leftTime =
                  (left.data()['updatedAt'] as Timestamp?)
                      ?.millisecondsSinceEpoch ??
                  0;
              final rightTime =
                  (right.data()['updatedAt'] as Timestamp?)
                      ?.millisecondsSinceEpoch ??
                  0;
              return rightTime.compareTo(leftTime);
            });
          if (documents.isEmpty) {
            return const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text('No training orders have been saved yet.'),
              ),
            );
          }
          return Column(
            children: [
              for (final document in documents.take(100))
                _TrainingRecordCard(
                  data: document.data(),
                  currencyCode: currencyCode,
                ),
            ],
          );
        },
      );
}

class _TrainingRecordCard extends StatelessWidget {
  const _TrainingRecordCard({required this.data, required this.currencyCode});

  final Map<String, dynamic> data;
  final String currencyCode;

  @override
  Widget build(BuildContext context) {
    final rawLines = data['lines'] as List? ?? const [];
    final lines = rawLines.whereType<Map>().toList(growable: false);
    final status = (data['status'] as String? ?? 'saved').toUpperCase();
    final location = data['locationLabel'] as String? ?? 'Training order';
    final totalMinor = data['totalMinor'] as int? ?? 0;
    return Card(
      child: ExpansionTile(
        leading: const Icon(Icons.school_rounded),
        title: Text(location),
        subtitle: Text('$status · ${lines.length} item line(s)'),
        trailing: Text(
          formatMoney(totalMinor, currencyCode: currencyCode),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        children: [
          for (final rawLine in lines)
            Builder(
              builder: (context) {
                final line = Map<String, dynamic>.from(rawLine);
                final details = (line['details'] as List? ?? const [])
                    .whereType<String>()
                    .where((value) => value.trim().isNotEmpty)
                    .join(' · ');
                return ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    child: Text('${line['quantity'] as int? ?? 0}'),
                  ),
                  title: Text(line['productName'] as String? ?? 'Menu item'),
                  subtitle: details.isEmpty ? null : Text(details),
                );
              },
            ),
        ],
      ),
    );
  }
}

class TrainingPosPage extends ConsumerStatefulWidget {
  const TrainingPosPage({super.key, required this.currencyCode});

  final String currencyCode;

  @override
  ConsumerState<TrainingPosPage> createState() => _TrainingPosPageState();
}

class _TrainingPosPageState extends ConsumerState<TrainingPosPage> {
  final _location = TextEditingController(text: 'Training Table');
  final _search = TextEditingController();
  final _quantities = <String, int>{};
  String _orderId = 'training-${DateTime.now().microsecondsSinceEpoch}';
  bool _busy = false;

  @override
  void dispose() {
    _location.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final products =
        ref.watch(menuProductsProvider).value ?? const <MenuProduct>[];
    final query = _search.text.trim().toLowerCase();
    final visible = products
        .where(
          (item) => query.isEmpty || item.name.toLowerCase().contains(query),
        )
        .toList(growable: false);
    final selected = products.where((item) => (_quantities[item.id] ?? 0) > 0);
    final total = selected.fold<int>(
      0,
      (runningTotal, item) =>
          runningTotal + item.priceMinor * _quantities[item.id]!,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final menu = Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: _search,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  prefixIcon: Icon(Icons.search_rounded),
                  labelText: 'Search training products',
                ),
              ),
            ),
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: constraints.maxWidth > 900 ? 4 : 2,
                  childAspectRatio: 1.8,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: visible.length,
                itemBuilder: (context, index) {
                  final product = visible[index];
                  return FilledButton.tonal(
                    onPressed: () => setState(
                      () => _quantities[product.id] =
                          (_quantities[product.id] ?? 0) + 1,
                    ),
                    child: Text(
                      '${product.name}\n${formatMoney(product.priceMinor, currencyCode: widget.currencyCode)}',
                      textAlign: TextAlign.center,
                    ),
                  );
                },
              ),
            ),
          ],
        );
        final basket = ListView(
          padding: const EdgeInsets.all(12),
          children: [
            TextField(
              controller: _location,
              decoration: const InputDecoration(
                labelText: 'Training table/name',
              ),
            ),
            const SizedBox(height: 12),
            for (final product in selected)
              ListTile(
                title: Text(product.name),
                subtitle: Text('Quantity ${_quantities[product.id]}'),
                trailing: IconButton(
                  onPressed: () => setState(() {
                    final next = _quantities[product.id]! - 1;
                    if (next <= 0) {
                      _quantities.remove(product.id);
                    } else {
                      _quantities[product.id] = next;
                    }
                  }),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
              ),
            const Divider(),
            Text(
              'Training total ${formatMoney(total, currencyCode: widget.currencyCode)}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _quantities.isEmpty || _busy
                  ? null
                  : () => _save(products, 'sent'),
              icon: const Icon(Icons.send_rounded),
              label: const Text('Send training order'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _quantities.isEmpty || _busy
                  ? null
                  : () => _save(products, 'closed'),
              icon: const Icon(Icons.school_outlined),
              label: const Text('Complete training bill'),
            ),
          ],
        );
        if (constraints.maxWidth >= 760) {
          return Row(
            children: [
              Expanded(flex: 2, child: menu),
              const VerticalDivider(width: 1),
              SizedBox(width: 340, child: basket),
            ],
          );
        }
        return Column(
          children: [
            Expanded(flex: 2, child: menu),
            const Divider(height: 1),
            Expanded(child: basket),
          ],
        );
      },
    );
  }

  Future<void> _save(List<MenuProduct> products, String status) async {
    final scope = ref.read(activeVenueScopeProvider);
    final session = ref.read(trainingModeProvider);
    if (scope == null || session == null) return;
    setState(() => _busy = true);
    try {
      await ProductionCommandRepository().recordTrainingOrder(
        scope: scope,
        trainingSessionId: session.id,
        trainingOrderId: _orderId,
        reference: _orderId.split('-').last,
        locationLabel: _location.text.trim().isEmpty
            ? 'Training order'
            : _location.text.trim(),
        status: status,
        lines: [
          for (final product in products)
            if ((_quantities[product.id] ?? 0) > 0)
              {
                'productId': product.id,
                'productName': product.name,
                'quantity': _quantities[product.id],
                'unitPriceMinor': product.priceMinor,
              },
        ],
      );
      if (!mounted) return;
      showAppNotification(
        context,
        ref: ref,
        title: status == 'closed'
            ? 'Training bill completed'
            : 'Training order saved',
        message: 'No live sale, payment, voucher or stock data was changed.',
        level: AppNotificationLevel.success,
      );
      if (status == 'closed') {
        setState(() {
          _quantities.clear();
          _orderId = 'training-${DateTime.now().microsecondsSinceEpoch}';
        });
      }
    } on Object catch (error, stack) {
      AppLogger.error('Save training order', error, stack);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
