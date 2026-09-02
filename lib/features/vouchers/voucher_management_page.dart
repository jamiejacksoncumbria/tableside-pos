import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/app_logger.dart';
import '../../core/money.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';

class VoucherManagementPage extends ConsumerWidget {
  const VoucherManagementPage({super.key, required this.currencyCode});
  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(activeVenueScopeProvider);
    if (scope == null) {
      return const Scaffold(body: Center(child: Text('Select a venue first.')));
    }
    final stream = FirebaseFirestore.instance
        .collection('tenants/${scope.tenantId}/vouchers')
        .orderBy('createdAt', descending: true)
        .limit(250)
        .snapshots();
    return Scaffold(
      appBar: AppBar(title: const Text('Gift vouchers')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _issue(context, ref, scope),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Create voucher'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            AppLogger.error(
              'Load gift vouchers',
              snapshot.error!,
              StackTrace.current,
            );
            return Center(
              child: Text('Could not load vouchers: ${snapshot.error}'),
            );
          }
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final vouchers = snapshot.data!.docs;
          if (vouchers.isEmpty) {
            return const Center(
              child: Text('No vouchers have been issued yet.'),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: vouchers.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final data = vouchers[index].data();
              final expiry = data['expiresAt'] as Timestamp?;
              final balance =
                  (data['remainingValueMinor'] as num?)?.toInt() ?? 0;
              return Card(
                child: ListTile(
                  leading: const Icon(Icons.card_giftcard_rounded),
                  title: Text('Voucher •••${data['codeSuffix'] ?? ''}'),
                  subtitle: Text(
                    '${data['chargeable'] == true ? 'Paid' : 'Complimentary'} · '
                    '${data['status'] ?? 'active'}${expiry == null ? '' : ' · expires ${DateFormat('dd-MM-yyyy').format(expiry.toDate())}'}',
                  ),
                  trailing: Text(
                    formatMoney(balance, currencyCode: currencyCode),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }

  Future<void> _issue(
    BuildContext pageContext,
    WidgetRef ref,
    VenueScope scope,
  ) async {
    final amount = TextEditingController();
    final reason = TextEditingController(text: 'Gift voucher sale');
    var chargeable = true;
    var paymentMethod = 'cash';
    var cardApproved = false;
    DateTime? expiresAt = DateTime.now().add(const Duration(days: 365));
    final result = await showDialog<IssuedVoucher>(
      context: pageContext,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create gift voucher'),
          content: SingleChildScrollView(
            child: SizedBox(
              width: 460,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: amount,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: InputDecoration(
                      labelText: 'Voucher value ($currencyCode)',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: reason,
                    maxLength: 240,
                    decoration: const InputDecoration(
                      labelText: 'Reason',
                      helperText:
                          'Required for sales, prizes and service recovery.',
                    ),
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: chargeable,
                    onChanged: (value) => setState(() => chargeable = value),
                    title: const Text('Customer is paying for this voucher'),
                  ),
                  if (chargeable) ...[
                    SegmentedButton<String>(
                      segments: const [
                        ButtonSegment(value: 'cash', label: Text('Cash')),
                        ButtonSegment(
                          value: 'cardTerminal',
                          label: Text('Card'),
                        ),
                      ],
                      selected: {paymentMethod},
                      onSelectionChanged: (value) => setState(() {
                        paymentMethod = value.first;
                        cardApproved = false;
                      }),
                    ),
                    if (paymentMethod == 'cardTerminal')
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        value: cardApproved,
                        onChanged: (value) =>
                            setState(() => cardApproved = value ?? false),
                        title: const Text('Card terminal approved payment'),
                      ),
                  ],
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Expiry date'),
                    subtitle: Text(
                      expiresAt == null
                          ? 'No expiry'
                          : DateFormat('dd-MM-yyyy').format(expiresAt!),
                    ),
                    trailing: Wrap(
                      children: [
                        IconButton(
                          tooltip: 'No expiry',
                          onPressed: () => setState(() => expiresAt = null),
                          icon: const Icon(Icons.all_inclusive_rounded),
                        ),
                        IconButton(
                          tooltip: 'Choose expiry',
                          onPressed: () async {
                            final chosen = await showDatePicker(
                              context: context,
                              initialDate:
                                  expiresAt ??
                                  DateTime.now().add(const Duration(days: 365)),
                              firstDate: DateTime.now().add(
                                const Duration(days: 1),
                              ),
                              lastDate: DateTime.now().add(
                                const Duration(days: 3650),
                              ),
                            );
                            if (chosen != null)
                              setState(() => expiresAt = chosen);
                          },
                          icon: const Icon(Icons.calendar_month_rounded),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  chargeable && paymentMethod == 'cardTerminal' && !cardApproved
                  ? null
                  : () async {
                      final value = double.tryParse(
                        amount.text.trim().replaceAll(',', '.'),
                      );
                      final minor = value == null
                          ? null
                          : (value * 100).round();
                      if (minor == null ||
                          minor <= 0 ||
                          reason.text.trim().isEmpty)
                        return;
                      try {
                        final issued = await ref
                            .read(productionCommandRepositoryProvider)
                            .issueVoucher(
                              scope: scope,
                              amountMinor: minor,
                              expiresAt: expiresAt,
                              chargeable: chargeable,
                              paymentMethod: paymentMethod,
                              cardPaymentApproved: cardApproved,
                              issueReason: reason.text.trim(),
                            );
                        if (context.mounted) Navigator.pop(context, issued);
                      } catch (error, stackTrace) {
                        AppLogger.error(
                          'Issue gift voucher',
                          error,
                          stackTrace,
                        );
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text('Could not issue voucher: $error'),
                            ),
                          );
                        }
                      }
                    },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
    amount.dispose();
    reason.dispose();
    if (result != null && pageContext.mounted) {
      // Let the creation dialog finish its route/layout transition before
      // presenting the QR. Showing two dialogs in the same frame can leave
      // the incoming AlertDialog without a laid-out render box on desktop.
      await Future<void>.delayed(const Duration(milliseconds: 220));
      if (!pageContext.mounted) return;
      await showDialog<void>(
        context: pageContext,
        builder: (context) => AlertDialog(
          title: const Text('Voucher created'),
          content: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 220,
                    child: QrImageView(data: result.code),
                  ),
                  SelectableText(
                    result.code,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    formatMoney(result.amountMinor, currencyCode: currencyCode),
                  ),
                  const Text(
                    'This QR was also queued to the venue receipt printer when one was available. Only the final six characters are shown later.',
                  ),
                ],
              ),
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    }
  }
}
