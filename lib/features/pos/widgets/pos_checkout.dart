part of '../pos_page.dart';

Future<void> _showCheckoutSheet(
  BuildContext pageContext, {
  required WidgetRef ref,
  required PosOrder order,
  required String currencyCode,
}) async {
  final isTraining = ref.read(trainingModeProvider) != null;
  final terminalController = TextEditingController();
  final voucherCodeController = TextEditingController();
  final baseCurrencyCode = currencyCode.trim().toUpperCase();
  final tenderedAmountController = TextEditingController(
    text: _moneyInputFromMinor(order.balanceDueMinor, currencyCode),
  );
  final exchangeRateController = TextEditingController(text: '1');
  final currencyChoices = checkoutTenderCurrencies(baseCurrencyCode);
  _CompletedCheckout? completed;
  // Keep mutable checkout state outside the route builder. Opening a native
  // keyboard changes MediaQuery.viewInsets and can rebuild that builder; when
  // these values lived inside it, a selected foreign currency silently reset
  // to the venue currency as soon as staff entered an amount.
  var method = PaymentMethod.cash;
  var tenderedCurrencyCode = baseCurrencyCode;
  var cardApproved = false;
  var saving = false;
  var printReceipt = isTraining ? false : defaultPrintPaidReceipt;
  var loadingOfficialRate = false;
  var showAmountKeypad = false;
  var showRateKeypad = false;
  ExchangeRateQuote? officialRateQuote;
  var voucherSuggestions = <String>[];
  final paymentEntries = <_CheckoutPaymentDraft>[];
  await showAppModalBottomSheet<void>(
    context: pageContext,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) {
      return StatefulBuilder(
        builder: (context, setSheetState) {
          final tenderedMinor = _minorFromMoneyInput(
            tenderedAmountController.text,
            tenderedCurrencyCode,
          );
          final convertedBaseMinor = tenderedMinor == null
              ? null
              : _convertedBaseMinor(
                  tenderedMinor: tenderedMinor,
                  tenderedCurrencyCode: tenderedCurrencyCode,
                  baseCurrencyCode: baseCurrencyCode,
                  exchangeRateText: exchangeRateController.text,
                );
          final recordedBaseMinor = paymentEntries.fold<int>(
            0,
            (total, payment) => total + payment.baseAmountMinor,
          );
          final remainingBaseMinor = order.balanceDueMinor - recordedBaseMinor;
          final cashChangeBaseMinor =
              method == PaymentMethod.cash &&
                  convertedBaseMinor != null &&
                  convertedBaseMinor > remainingBaseMinor
              ? convertedBaseMinor - remainingBaseMinor
              : 0;
          final appliedBaseMinor = convertedBaseMinor == null
              ? null
              : convertedBaseMinor - cashChangeBaseMinor;
          final amountFits =
              appliedBaseMinor != null &&
              appliedBaseMinor > 0 &&
              (method == PaymentMethod.cash ||
                  appliedBaseMinor <= remainingBaseMinor);
          // A hub may have durably accepted the final payment before its cloud
          // projection was interrupted. Once that payment is replayed, staff
          // must be able to finalise the now-zero bill without charging it a
          // second time.
          final alreadyPaidInFull =
              order.balanceDueMinor == 0 && paymentEntries.isEmpty;
          final canRecordPayment =
              alreadyPaidInFull ||
              (paymentEntries.isNotEmpty &&
                  remainingBaseMinor >= 0 &&
                  (!isTraining || remainingBaseMinor == 0));
          final willCloseBill = canRecordPayment && remainingBaseMinor == 0;
          final isForeignCash = tenderedCurrencyCode != baseCurrencyCode;
          final hasAmountInput = tenderedAmountController.text
              .trim()
              .isNotEmpty;
          final validationMessage = tenderedMinor == null
              ? 'Enter a valid payment amount.'
              : isForeignCash && convertedBaseMinor == null
              ? 'Load the official rate or enter a valid manager rate.'
              : method != PaymentMethod.cash &&
                    convertedBaseMinor != null &&
                    convertedBaseMinor > remainingBaseMinor
              ? 'This payment allocation is more than the amount remaining.'
              : 'This payment cannot be added.';
          final loadedOfficialRate = officialRateQuote;
          final activeScope = ref.read(activeVenueScopeProvider);
          final requiresHub =
              activeScope != null &&
              VenueHubClientRegistry.instance.requiresHub(activeScope);
          final usingOfflineLanHub =
              requiresHub &&
              !VenueHubRealtimeClient.instance.hubOnline &&
              VenueHubClientRegistry.instance.hasUsableSession(activeScope);
          return SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                24,
                0,
                24,
                24 + MediaQuery.viewInsetsOf(context).bottom,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        isTraining ? 'Simulate payment' : 'Take payment',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        order.tabName?.trim().isNotEmpty == true
                            ? 'Named tab: ${order.tabName}'
                            : 'Table bill',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          const Icon(Icons.receipt_long_outlined),
                          const SizedBox(width: 12),
                          const Expanded(child: Text('Amount remaining')),
                          Text(
                            formatMoney(
                              remainingBaseMinor,
                              currencyCode: currencyCode,
                            ),
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w800),
                          ),
                          const SizedBox(width: 8),
                          OutlinedButton.icon(
                            key: const ValueKey('checkout-view-bill-button'),
                            onPressed: saving
                                ? null
                                : () => _showCheckoutBillPreview(
                                    sheetContext,
                                    order: order,
                                    currencyCode: currencyCode,
                                    pendingPaymentMinor: recordedBaseMinor,
                                  ),
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 8,
                              ),
                            ),
                            icon: const Icon(Icons.list_alt_rounded, size: 18),
                            label: const Text('Items'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (order.payments.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Earlier payments',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    for (final payment in order.payments)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.check_circle_outline_rounded),
                        title: Text(
                          '${payment.method} · ${formatMoney(payment.tenderedAmountMinor, currencyCode: payment.tenderedCurrencyCode)}',
                        ),
                        subtitle: Text(
                          payment.recordedLocalDateTime?.trim().isNotEmpty ==
                                  true
                              ? formatVenueDateTimeSnapshot(
                                  payment.recordedLocalDateTime!,
                                )
                              : formatAppDateTime(payment.recordedAt),
                        ),
                      ),
                  ],
                  const SizedBox(height: 12),
                  SegmentedButton<PaymentMethod>(
                    segments: [
                      const ButtonSegment(
                        value: PaymentMethod.cash,
                        icon: Icon(Icons.payments_outlined),
                        label: Text('Cash'),
                      ),
                      const ButtonSegment(
                        value: PaymentMethod.cardTerminal,
                        icon: Icon(Icons.credit_card_rounded),
                        label: Text('Card'),
                      ),
                      if (!isTraining)
                        const ButtonSegment(
                          value: PaymentMethod.voucher,
                          icon: Icon(Icons.card_giftcard_rounded),
                          label: Text('Voucher'),
                        ),
                    ],
                    selected: {method},
                    onSelectionChanged: saving
                        ? null
                        : (selection) => setSheetState(() {
                            method = selection.first;
                            cardApproved = false;
                            if (method == PaymentMethod.cardTerminal ||
                                method == PaymentMethod.voucher) {
                              tenderedCurrencyCode = baseCurrencyCode;
                              exchangeRateController.text = '1';
                              showRateKeypad = false;
                              tenderedAmountController.text =
                                  _moneyInputFromMinor(
                                    order.balanceDueMinor,
                                    currencyCode,
                                  );
                            }
                            officialRateQuote = null;
                          }),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    method == PaymentMethod.cash
                        ? 'Cash currency'
                        : method == PaymentMethod.voucher
                        ? 'Voucher currency'
                        : 'Card currency',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  if (method == PaymentMethod.cash)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final code in currencyChoices)
                          ChoiceChip(
                            label: Text(code),
                            selected: tenderedCurrencyCode == code,
                            onSelected: saving
                                ? null
                                : (selected) {
                                    if (!selected ||
                                        tenderedCurrencyCode == code) {
                                      return;
                                    }
                                    setSheetState(() {
                                      tenderedCurrencyCode = code;
                                      exchangeRateController.text =
                                          code == baseCurrencyCode ? '1' : '';
                                      tenderedAmountController.clear();
                                      officialRateQuote = null;
                                    });
                                  },
                          ),
                      ],
                    )
                  else
                    InputDecorator(
                      decoration: const InputDecoration(
                        helperText:
                            'Card terminal payments use the venue reporting currency.',
                      ),
                      child: Text(baseCurrencyCode),
                    ),
                  if (method == PaymentMethod.voucher) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: voucherCodeController,
                      enabled: !saving,
                      textCapitalization: TextCapitalization.characters,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Scan or enter voucher QR code',
                        prefixIcon: Icon(Icons.qr_code_scanner_rounded),
                        helperText:
                            'Hardware QR scanners can type directly into this field.',
                      ),
                      onChanged: (value) async {
                        setSheetState(() {});
                        final normalized = value.toUpperCase().replaceAll(
                          RegExp('[^A-Z0-9]'),
                          '',
                        );
                        final scope = ref.read(activeVenueScopeProvider);
                        if (scope == null ||
                            normalized.length < 9 ||
                            (!kIsWeb &&
                                defaultTargetPlatform !=
                                    TargetPlatform.windows)) {
                          if (voucherSuggestions.isNotEmpty) {
                            setSheetState(() => voucherSuggestions = []);
                          }
                          return;
                        }
                        try {
                          final matches = await ref
                              .read(productionCommandRepositoryProvider)
                              .suggestVoucherCodes(
                                scope: scope,
                                prefix: normalized,
                              );
                          if (sheetContext.mounted &&
                              voucherCodeController.text == value) {
                            setSheetState(() => voucherSuggestions = matches);
                          }
                        } catch (error, stackTrace) {
                          AppLogger.error(
                            'Suggest voucher codes',
                            error,
                            stackTrace,
                          );
                        }
                      },
                    ),
                    if (!kIsWeb &&
                        (defaultTargetPlatform == TargetPlatform.android ||
                            defaultTargetPlatform == TargetPlatform.iOS))
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: saving
                              ? null
                              : () async {
                                  final code = await _scanVoucherQr(
                                    sheetContext,
                                  );
                                  if (code != null && sheetContext.mounted) {
                                    voucherCodeController.text = code;
                                    setSheetState(
                                      () => voucherSuggestions = [],
                                    );
                                  }
                                },
                          icon: const Icon(Icons.qr_code_scanner_rounded),
                          label: const Text('Scan QR'),
                        ),
                      ),
                    if (voucherSuggestions.isNotEmpty)
                      Wrap(
                        spacing: 8,
                        runSpacing: 6,
                        children: [
                          for (final code in voucherSuggestions)
                            ActionChip(
                              avatar: const Icon(
                                Icons.card_giftcard_rounded,
                                size: 18,
                              ),
                              label: Text(_displayVoucherCode(code)),
                              onPressed: () => setSheetState(() {
                                voucherCodeController.text = code;
                                voucherSuggestions = [];
                              }),
                            ),
                        ],
                      ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: tenderedAmountController,
                    enabled: !saving,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.done,
                    inputFormatters: [
                      _MoneyAmountInputFormatter(tenderedCurrencyCode),
                    ],
                    decoration: InputDecoration(
                      labelText: 'Amount received ($tenderedCurrencyCode)',
                      suffixIcon: IconButton(
                        tooltip: showAmountKeypad
                            ? 'Hide touch keypad'
                            : 'Show touch keypad',
                        onPressed: saving
                            ? null
                            : () => setSheetState(
                                () => showAmountKeypad = !showAmountKeypad,
                              ),
                        icon: Icon(
                          showAmountKeypad
                              ? Icons.keyboard_hide_rounded
                              : Icons.dialpad_rounded,
                        ),
                      ),
                      helperText: isForeignCash
                          ? 'Enter the physical cash received in $tenderedCurrencyCode.'
                          : 'Type the amount or use the touch keypad.',
                    ),
                    onChanged: (_) => setSheetState(() {}),
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                  ),
                  if (showAmountKeypad) ...[
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 340),
                        child: _DecimalKeypad(
                          controller: tenderedAmountController,
                          decimalDigits: currencyDecimalDigits(
                            tenderedCurrencyCode,
                          ),
                          onChanged: () => setSheetState(() {}),
                        ),
                      ),
                    ),
                  ],
                  if (isForeignCash) ...[
                    const SizedBox(height: 12),
                    if (usingOfflineLanHub)
                      Container(
                        margin: const EdgeInsets.only(bottom: 10),
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Theme.of(
                            context,
                          ).colorScheme.tertiaryContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(Icons.cloud_off_rounded, size: 20),
                            SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'Offline mode: the official rate cannot be checked. Enter and verify the exchange rate manually; the exact rate will be retained with the payment audit record.',
                              ),
                            ),
                          ],
                        ),
                      ),
                    TextField(
                      controller: exchangeRateController,
                      enabled: !saving,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: const [_ExchangeRateInputFormatter()],
                      decoration: InputDecoration(
                        labelText:
                            '1 $tenderedCurrencyCode = how many $currencyCode?',
                        suffixIcon: IconButton(
                          tooltip: showRateKeypad
                              ? 'Hide rate keypad'
                              : 'Show rate keypad',
                          onPressed: saving
                              ? null
                              : () => setSheetState(
                                  () => showRateKeypad = !showRateKeypad,
                                ),
                          icon: Icon(
                            showRateKeypad
                                ? Icons.keyboard_hide_rounded
                                : Icons.dialpad_rounded,
                          ),
                        ),
                        helperText: usingOfflineLanHub
                            ? 'Enter the approved manual rate. Example: 1 $tenderedCurrencyCode = 52.50 $currencyCode.'
                            : 'Use the official rate as a starting point, then review or override it. The exact rate is retained on the bill.',
                      ),
                      onChanged: (_) => setSheetState(() {
                        officialRateQuote = null;
                      }),
                    ),
                    if (showRateKeypad) ...[
                      const SizedBox(height: 10),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 340),
                          child: _DecimalKeypad(
                            controller: exchangeRateController,
                            decimalDigits: 6,
                            onChanged: () => setSheetState(() {
                              officialRateQuote = null;
                            }),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed:
                          saving || loadingOfficialRate || usingOfflineLanHub
                          ? null
                          : () async {
                              final scope = ref.read(activeVenueScopeProvider);
                              if (scope == null) {
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Rate not loaded',
                                  message:
                                      'Select a venue before looking up a rate.',
                                  level: AppNotificationLevel.error,
                                );
                                return;
                              }
                              setSheetState(() => loadingOfficialRate = true);
                              try {
                                final quote = await ref
                                    .read(productionCommandRepositoryProvider)
                                    .lookupExchangeRate(
                                      scope: scope,
                                      tenderCurrencyCode: tenderedCurrencyCode,
                                    );
                                if (!sheetContext.mounted) return;
                                setSheetState(() {
                                  exchangeRateController.text =
                                      quote.exchangeRateToBase;
                                  officialRateQuote = quote;
                                });
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Load official exchange rate',
                                  error,
                                  stackTrace,
                                );
                                if (!sheetContext.mounted) return;
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Official rate unavailable',
                                  message:
                                      '$error Enter a manager rate manually.',
                                  level: AppNotificationLevel.error,
                                );
                              } finally {
                                if (sheetContext.mounted) {
                                  setSheetState(
                                    () => loadingOfficialRate = false,
                                  );
                                }
                              }
                            },
                      icon: loadingOfficialRate
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.currency_exchange_rounded),
                      label: Text(
                        loadingOfficialRate
                            ? 'Loading official rate…'
                            : usingOfflineLanHub
                            ? 'Official rate unavailable offline'
                            : 'Use official CBRT rate',
                      ),
                    ),
                    if (loadedOfficialRate != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          '${loadedOfficialRate.source}${loadedOfficialRate.publishedDate == null ? '' : ' · ${loadedOfficialRate.publishedDate}'}. You can edit the rate before adding the payment.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                  ],
                  if (convertedBaseMinor != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      'Tender value: ${formatMoney(convertedBaseMinor, currencyCode: currencyCode)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: amountFits
                            ? Colors.green.shade700
                            : Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  if (cashChangeBaseMinor > 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      'Change due: ${formatMoney(cashChangeBaseMinor, currencyCode: currencyCode)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                    ),
                  ],
                  if (hasAmountInput && !amountFits)
                    Text(
                      validationMessage,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  if (paymentEntries.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      'Payment allocations',
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                    const SizedBox(height: 4),
                    for (var index = 0; index < paymentEntries.length; index++)
                      ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          paymentEntries[index].method == PaymentMethod.cash
                              ? Icons.payments_outlined
                              : paymentEntries[index].method ==
                                    PaymentMethod.voucher
                              ? Icons.card_giftcard_rounded
                              : Icons.credit_card_rounded,
                        ),
                        title: Text(
                          '${paymentEntries[index].method == PaymentMethod.cash
                              ? 'Cash'
                              : paymentEntries[index].method == PaymentMethod.voucher
                              ? 'Voucher'
                              : 'Card'} · ${formatMoney(paymentEntries[index].tenderedAmountMinor, currencyCode: paymentEntries[index].tenderedCurrencyCode)}',
                        ),
                        subtitle:
                            paymentEntries[index].tenderedCurrencyCode ==
                                    baseCurrencyCode &&
                                paymentEntries[index].cashChangeBaseMinor == 0
                            ? null
                            : Text(
                                '${paymentEntries[index].tenderedCurrencyCode == baseCurrencyCode ? 'Applied' : 'Rate ${paymentEntries[index].exchangeRateToBase} →'} ${formatMoney(paymentEntries[index].baseAmountMinor, currencyCode: currencyCode)}${paymentEntries[index].cashChangeBaseMinor > 0 ? ' after ${formatMoney(paymentEntries[index].cashChangeBaseMinor, currencyCode: currencyCode)} change' : ''}',
                              ),
                        trailing: IconButton(
                          tooltip: 'Remove payment allocation',
                          onPressed: saving
                              ? null
                              : () => setSheetState(
                                  () => paymentEntries.removeAt(index),
                                ),
                          icon: const Icon(Icons.close_rounded),
                        ),
                      ),
                  ],
                  if (method == PaymentMethod.cardTerminal) ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: terminalController,
                      enabled: !saving,
                      maxLength: 120,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Card terminal used (optional)',
                        hintText: 'For example, Bar terminal',
                      ),
                    ),
                    CheckboxListTile(
                      value: cardApproved,
                      contentPadding: EdgeInsets.zero,
                      onChanged: saving
                          ? null
                          : (value) => setSheetState(
                              () => cardApproved = value ?? false,
                            ),
                      title: const Text('Card terminal approved the payment'),
                      subtitle: const Text(
                        'Only record this after Card Plus confirms approval.',
                      ),
                    ),
                  ],
                  if (!isTraining)
                    CheckboxListTile(
                      value: printReceipt,
                      contentPadding: EdgeInsets.zero,
                      onChanged: saving
                          ? null
                          : (value) => setSheetState(
                              () => printReceipt = value ?? false,
                            ),
                      title: const Text('Print paid receipt'),
                      subtitle: const Text(
                        'Queues the full bill to this venue’s dedicated receipt printer after payment is recorded.',
                      ),
                    )
                  else
                    const ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.school_rounded),
                      title: Text('Simulated payment only'),
                      subtitle: Text(
                        'No payment, voucher, deposit, receipt or sales record will be created.',
                      ),
                    ),
                  const SizedBox(height: 12),
                  Text(
                    isForeignCash
                        ? 'Foreign cash retains its tender amount and rate for audit/reporting. Any overpayment is shown as change in the reporting currency.'
                        : 'Add one or more allocations. You may record a partial payment and leave the remaining balance on this table or tab.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: saving
                              ? null
                              : () => Navigator.of(sheetContext).pop(),
                          child: const Text('Cancel'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed:
                              saving ||
                                  paymentEntries.length >= 8 ||
                                  !amountFits ||
                                  tenderedMinor == null ||
                                  (method == PaymentMethod.cardTerminal &&
                                      !cardApproved) ||
                                  (method == PaymentMethod.voucher &&
                                      voucherCodeController.text.trim().isEmpty)
                              ? null
                              : () async {
                                  if (method == PaymentMethod.voucher) {
                                    final code = voucherCodeController.text
                                        .trim();
                                    final confirmed = await showAppDialog<bool>(
                                      context: sheetContext,
                                      builder: (context) => AlertDialog(
                                        title: const Text(
                                          'Confirm gift voucher',
                                        ),
                                        content: Text(
                                          'Apply ${_displayVoucherCode(code)} for ${formatMoney(appliedBaseMinor, currencyCode: currencyCode)}?',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('No'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text(
                                              'Yes, apply voucher',
                                            ),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed != true ||
                                        !sheetContext.mounted) {
                                      return;
                                    }
                                  }
                                  setSheetState(() {
                                    paymentEntries.add(
                                      _CheckoutPaymentDraft(
                                        method: method,
                                        tenderedAmountMinor: tenderedMinor,
                                        tenderedCurrencyCode:
                                            tenderedCurrencyCode,
                                        exchangeRateToBase:
                                            normalizeExchangeRateInput(
                                              exchangeRateController.text,
                                            ),
                                        baseAmountMinor: appliedBaseMinor,
                                        cardPaymentApproved: cardApproved,
                                        terminalLabel: terminalController.text
                                            .trim(),
                                        cashChangeBaseMinor:
                                            cashChangeBaseMinor,
                                        exchangeRateSource:
                                            officialRateQuote?.source ??
                                            (isForeignCash
                                                ? usingOfflineLanHub
                                                      ? 'Manual offline rate'
                                                      : 'Manual rate'
                                                : null),
                                        exchangeRatePublishedDate:
                                            officialRateQuote?.publishedDate,
                                        exchangeRateFetchedAt:
                                            officialRateQuote?.fetchedAt,
                                        voucherCode:
                                            method == PaymentMethod.voucher
                                            ? voucherCodeController.text.trim()
                                            : null,
                                      ),
                                    );
                                    final nextRemaining =
                                        order.balanceDueMinor -
                                        paymentEntries.fold<int>(
                                          0,
                                          (total, payment) =>
                                              total + payment.baseAmountMinor,
                                        );
                                    method = PaymentMethod.cash;
                                    tenderedCurrencyCode = baseCurrencyCode;
                                    cardApproved = false;
                                    exchangeRateController.text = '1';
                                    officialRateQuote = null;
                                    showRateKeypad = false;
                                    terminalController.clear();
                                    voucherCodeController.clear();
                                    tenderedAmountController.text =
                                        nextRemaining <= 0
                                        ? ''
                                        : _moneyInputFromMinor(
                                            nextRemaining,
                                            currencyCode,
                                          );
                                  });
                                },
                          icon: const Icon(Icons.add_card_rounded),
                          label: const Text('Add payment'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: saving || !canRecordPayment
                          ? null
                          : () async {
                              setSheetState(() => saving = true);
                              try {
                                final result = await ref
                                    .read(activeOrderProvider.notifier)
                                    .closeBill(
                                      payments: paymentEntries
                                          .map(
                                            (entry) => entry.toPaymentInput(),
                                          )
                                          .toList(growable: false),
                                      printReceipt: printReceipt,
                                    );
                                if (!sheetContext.mounted) return;
                                completed = _CompletedCheckout(
                                  result: result,
                                  payments: List<_CheckoutPaymentDraft>.of(
                                    paymentEntries,
                                  ),
                                  training: isTraining,
                                );
                                Navigator.of(sheetContext).pop();
                              } on Object catch (error, stackTrace) {
                                AppLogger.error(
                                  'Close bill',
                                  error,
                                  stackTrace,
                                );
                                if (!sheetContext.mounted) return;
                                setSheetState(() => saving = false);
                                showAppNotification(
                                  sheetContext,
                                  ref: ref,
                                  title: 'Payment was not recorded',
                                  message: '$error',
                                  level: AppNotificationLevel.error,
                                );
                              }
                            },
                      icon: saving
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.check_circle_outline_rounded),
                      label: Text(
                        saving
                            ? 'Recording…'
                            : alreadyPaidInFull
                            ? 'Finalise bill'
                            : willCloseBill
                            ? 'Close bill'
                            : 'Record partial payment',
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  ).whenComplete(() {
    terminalController.dispose();
    tenderedAmountController.dispose();
    exchangeRateController.dispose();
    voucherCodeController.dispose();
  });
  final checkoutResult = completed;
  if (checkoutResult != null && pageContext.mounted) {
    // Wait until the bottom sheet has detached its semantics tree before
    // presenting the payment result route.
    await Future<void>.delayed(const Duration(milliseconds: 320));
    if (!pageContext.mounted) return;
    await _showPaymentSummary(
      pageContext,
      order: order,
      completed: checkoutResult,
      baseCurrencyCode: baseCurrencyCode,
    );
  }
}

class _CompletedCheckout {
  const _CompletedCheckout({
    required this.result,
    required this.payments,
    required this.training,
  });

  final BillCloseResult result;
  final List<_CheckoutPaymentDraft> payments;
  final bool training;
}

Future<void> _showPaymentSummary(
  BuildContext context, {
  required PosOrder order,
  required _CompletedCheckout completed,
  required String baseCurrencyCode,
}) async {
  final result = completed.result;
  // Headline bill values are always denominated in the venue's functional
  // currency. A foreign currency belongs only to the payment that used it.
  final reportingCurrency = baseCurrencyCode.trim().toUpperCase();
  await showAppDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dialogContext) => AlertDialog(
      scrollable: true,
      icon: Icon(
        result.orderClosed
            ? Icons.check_circle_rounded
            : Icons.payments_outlined,
        color: Theme.of(dialogContext).colorScheme.primary,
        size: 38,
      ),
      title: Text(
        completed.training
            ? 'Training payment completed'
            : result.orderClosed
            ? 'Payment completed'
            : 'Partial payment completed',
      ),
      content: SizedBox(
        width: 560,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Receipt ${result.receiptNumber}'),
            const SizedBox(height: 12),
            Text('Items', style: Theme.of(dialogContext).textTheme.titleSmall),
            for (final line in order.lines)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text('${line.quantity} × ${line.productName}'),
                subtitle: line.productionDetails.isEmpty
                    ? null
                    : Text(line.productionDetails.join(' · ')),
                trailing: Text(
                  formatMoney(line.totalMinor, currencyCode: reportingCurrency),
                ),
              ),
            const Divider(),
            _PaymentSummaryRow(
              label: 'Total bill',
              value: formatMoney(
                result.totalMinor,
                currencyCode: reportingCurrency,
              ),
              emphasize: true,
            ),
            const SizedBox(height: 10),
            Text(
              'Payment made now',
              style: Theme.of(dialogContext).textTheme.titleSmall,
            ),
            for (final payment in completed.payments)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  payment.method == PaymentMethod.cash
                      ? Icons.payments_outlined
                      : payment.method == PaymentMethod.voucher
                      ? Icons.card_giftcard_rounded
                      : Icons.credit_card_rounded,
                ),
                title: Text(
                  '${_paymentMethodLabel(payment.method)} · ${formatMoney(payment.tenderedAmountMinor, currencyCode: payment.tenderedCurrencyCode)}',
                ),
                subtitle: payment.tenderedCurrencyCode == reportingCurrency
                    ? null
                    : Text(
                        'Applied ${formatMoney(payment.baseAmountMinor, currencyCode: reportingCurrency)} at rate ${payment.exchangeRateToBase}',
                      ),
                trailing: payment.cashChangeBaseMinor > 0
                    ? Text(
                        'Change\n${formatMoney(payment.cashChangeBaseMinor, currencyCode: reportingCurrency)}',
                        textAlign: TextAlign.end,
                      )
                    : null,
              ),
            const Divider(),
            _PaymentSummaryRow(
              label: 'Paid now',
              value: formatMoney(
                result.paidThisTimeMinor,
                currencyCode: reportingCurrency,
              ),
            ),
            _PaymentSummaryRow(
              label: 'Paid in total',
              value: formatMoney(
                result.paidTotalMinor,
                currencyCode: reportingCurrency,
              ),
            ),
            _PaymentSummaryRow(
              label: 'Balance remaining',
              value: formatMoney(
                result.balanceDueMinor,
                currencyCode: reportingCurrency,
              ),
              emphasize: result.balanceDueMinor > 0,
            ),
            if (result.receiptPrintRequested) ...[
              const SizedBox(height: 10),
              Text(
                result.receiptPrintQueued
                    ? 'The receipt has been queued for printing.'
                    : 'The receipt was requested, but no active receipt printer route was available.',
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton.icon(
          onPressed: () => Navigator.pop(dialogContext),
          icon: const Icon(Icons.done_rounded),
          label: const Text('Done'),
        ),
      ],
    ),
  );
}

class _PaymentSummaryRow extends StatelessWidget {
  const _PaymentSummaryRow({
    required this.label,
    required this.value,
    this.emphasize = false,
  });

  final String label;
  final String value;
  final bool emphasize;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      children: [
        Expanded(
          child: Text(
            label,
            style: emphasize
                ? const TextStyle(fontWeight: FontWeight.w700)
                : null,
          ),
        ),
        Text(
          value,
          style: emphasize
              ? const TextStyle(fontWeight: FontWeight.w700)
              : null,
        ),
      ],
    ),
  );
}

String _paymentMethodLabel(PaymentMethod method) => switch (method) {
  PaymentMethod.cash => 'Cash',
  PaymentMethod.cardTerminal => 'Card',
  PaymentMethod.voucher => 'Voucher',
  PaymentMethod.online => 'Online',
};

class _CheckoutPaymentDraft {
  const _CheckoutPaymentDraft({
    required this.method,
    required this.tenderedAmountMinor,
    required this.tenderedCurrencyCode,
    required this.exchangeRateToBase,
    required this.baseAmountMinor,
    required this.cardPaymentApproved,
    this.terminalLabel,
    this.cashChangeBaseMinor = 0,
    this.exchangeRateSource,
    this.exchangeRatePublishedDate,
    this.exchangeRateFetchedAt,
    this.voucherCode,
  });

  final PaymentMethod method;
  final int tenderedAmountMinor;
  final String tenderedCurrencyCode;
  final String exchangeRateToBase;
  final int baseAmountMinor;
  final bool cardPaymentApproved;
  final String? terminalLabel;
  final int cashChangeBaseMinor;
  final String? exchangeRateSource;
  final String? exchangeRatePublishedDate;
  final String? exchangeRateFetchedAt;
  final String? voucherCode;

  BillPaymentInput toPaymentInput() => BillPaymentInput(
    method: method,
    tenderedAmountMinor: tenderedAmountMinor,
    tenderedCurrencyCode: tenderedCurrencyCode,
    exchangeRateToBase: exchangeRateToBase,
    cardPaymentApproved: cardPaymentApproved,
    terminalLabel: terminalLabel,
    cashChangeBaseMinor: cashChangeBaseMinor,
    exchangeRateSource: exchangeRateSource,
    exchangeRatePublishedDate: exchangeRatePublishedDate,
    exchangeRateFetchedAt: exchangeRateFetchedAt,
    voucherCode: voucherCode,
  );
}

String _displayVoucherCode(String raw) {
  final value = raw.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '');
  if (value.length != 21 || !value.startsWith('TSV')) return raw.toUpperCase();
  return 'TSV-${value.substring(3, 9)}-${value.substring(9, 15)}-${value.substring(15, 21)}';
}

Future<String?> _scanVoucherQr(BuildContext context) async {
  var detected = false;
  return await showAppModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    builder: (sheetContext) => SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.72,
        child: Column(
          children: [
            ListTile(
              title: const Text('Scan gift voucher'),
              subtitle: const Text(
                'Place the voucher QR code inside the camera view.',
              ),
              trailing: IconButton(
                onPressed: () => Navigator.pop(sheetContext),
                icon: const Icon(Icons.close_rounded),
              ),
            ),
            Expanded(
              child: MobileScanner(
                onDetect: (capture) {
                  if (detected) return;
                  final value = capture.barcodes
                      .map((barcode) => barcode.rawValue?.trim())
                      .whereType<String>()
                      .firstOrNull;
                  if (value == null || !value.toUpperCase().startsWith('TSV')) {
                    return;
                  }
                  detected = true;
                  Navigator.pop(sheetContext, value);
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

String _moneyInputFromMinor(int minorUnits, String currencyCode) {
  final digits = currencyDecimalDigits(currencyCode);
  final scale = _minorScale(digits);
  final major = minorUnits ~/ scale;
  if (digits == 0) return '$major';
  final fraction = (minorUnits.abs() % scale).toString().padLeft(digits, '0');
  return '$major.$fraction';
}

int? _minorFromMoneyInput(String raw, String currencyCode) {
  final value = raw.trim().replaceAll(',', '.');
  final digits = currencyDecimalDigits(currencyCode);
  final expression = digits == 0
      ? RegExp(r'^\d+$')
      : RegExp('^\\d+(?:\\.\\d{0,$digits})?\$');
  if (!expression.hasMatch(value)) return null;
  final pieces = value.split('.');
  final major = int.tryParse(pieces.first);
  if (major == null) return null;
  final scale = _minorScale(digits);
  final fraction = digits == 0 || pieces.length == 1
      ? 0
      : int.tryParse(pieces.last.padRight(digits, '0'));
  if (fraction == null) return null;
  final amount = (major * scale) + fraction;
  return amount > 0 && amount <= 100000000 ? amount : null;
}

int? _convertedBaseMinor({
  required int tenderedMinor,
  required String tenderedCurrencyCode,
  required String baseCurrencyCode,
  required String exchangeRateText,
}) {
  if (tenderedCurrencyCode == baseCurrencyCode) return tenderedMinor;
  final normalizedRate = normalizeExchangeRateInput(exchangeRateText);
  if (!RegExp(r'^(?:0|[1-9]\d{0,8})(?:\.\d{1,6})?$').hasMatch(normalizedRate)) {
    return null;
  }
  final pieces = normalizedRate.split('.');
  final major = int.tryParse(pieces.first);
  if (major == null) return null;
  final fractionalText = pieces.length == 1 ? '' : pieces.last;
  final fraction = int.tryParse(fractionalText.padRight(6, '0'));
  if (fraction == null) return null;
  // This mirrors the Cloud Function's fixed-scale integer calculation. The
  // earlier double calculation could differ by one minor unit, enabling the
  // Close bill button locally but making the server correctly reject the bill.
  final rateScaled = (major * 1000000) + fraction;
  if (rateScaled <= 0) return null;
  final tenderedScale = _minorScale(
    currencyDecimalDigits(tenderedCurrencyCode),
  );
  final baseScale = _minorScale(currencyDecimalDigits(baseCurrencyCode));
  final numerator = tenderedMinor * rateScaled * baseScale;
  final denominator = tenderedScale * 1000000;
  final result = (numerator + (denominator ~/ 2)) ~/ denominator;
  return result > 0 && result <= 100000000 ? result : null;
}

int _minorScale(int decimalDigits) {
  var result = 1;
  for (var index = 0; index < decimalDigits; index++) {
    result *= 10;
  }
  return result;
}

/// Always asks at the point an order leaves the basket. Bar staff often need
/// the order recorded and visible on the flow board without wasting a ticket.
Future<bool?> _confirmProductionPrint(BuildContext context) =>
    showAppDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ProductionPrintCountdownDialog(),
    );

class _ProductionPrintCountdownDialog extends StatefulWidget {
  const _ProductionPrintCountdownDialog();

  @override
  State<_ProductionPrintCountdownDialog> createState() =>
      _ProductionPrintCountdownDialogState();
}

class _ProductionPrintCountdownDialogState
    extends State<_ProductionPrintCountdownDialog> {
  static const _initialSeconds = 10;
  late final Timer _timer;
  var _seconds = _initialSeconds;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_seconds <= 1) {
        _timer.cancel();
        Navigator.of(context).pop(true);
      } else {
        setState(() => _seconds--);
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    icon: const Icon(Icons.print_outlined),
    title: const Text('Send order'),
    content: Text(
      'Do you need a production ticket printed for these new items?\n\n'
      'Sending and printing automatically in $_seconds seconds.',
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      OutlinedButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: const Text('No print'),
      ),
      FilledButton.icon(
        onPressed: () => Navigator.of(context).pop(true),
        icon: const Icon(Icons.print_rounded),
        label: Text('Send & print ($_seconds)'),
      ),
    ],
  );
}

class _MoneyAmountInputFormatter extends TextInputFormatter {
  _MoneyAmountInputFormatter(String currencyCode)
    : decimalDigits = currencyDecimalDigits(currencyCode);

  final int decimalDigits;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final expression = decimalDigits == 0
        ? RegExp(r'^\d{0,9}$')
        : RegExp('^\\d{0,9}(?:[.,]\\d{0,$decimalDigits})?\$');
    return expression.hasMatch(newValue.text) ? newValue : oldValue;
  }
}

class _ExchangeRateInputFormatter extends TextInputFormatter {
  const _ExchangeRateInputFormatter();

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    // Six decimal places retain substantially more precision than cash input
    // while still keeping the signed/audited rate bounded and readable.
    return RegExp(r'^\d{0,9}(?:[.,]\d{0,6})?$').hasMatch(newValue.text)
        ? newValue
        : oldValue;
  }
}

class _DecimalKeypad extends StatelessWidget {
  const _DecimalKeypad({
    required this.controller,
    required this.decimalDigits,
    required this.onChanged,
  });

  final TextEditingController controller;
  final int decimalDigits;
  final VoidCallback onChanged;

  void _replace(String text) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    onChanged();
  }

  void _enter(String value) {
    var text = controller.text;
    if (value == '.') {
      if (decimalDigits == 0 || text.contains('.') || text.contains(',')) {
        return;
      }
      if (text.isEmpty) text = '0';
    } else {
      final separator = text.contains('.')
          ? '.'
          : text.contains(',')
          ? ','
          : '';
      if (separator.isEmpty && text.length >= 9) return;
      if (separator.isNotEmpty &&
          text.split(separator).last.length >= decimalDigits) {
        return;
      }
    }
    _replace('$text$value');
  }

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          GridView.count(
            shrinkWrap: true,
            crossAxisCount: 3,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
            childAspectRatio: 2.6,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              for (final key in const [
                '1',
                '2',
                '3',
                '4',
                '5',
                '6',
                '7',
                '8',
                '9',
              ])
                FilledButton.tonal(
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                  ),
                  onPressed: () => _enter(key),
                  child: Text(key, style: const TextStyle(fontSize: 16)),
                ),
              OutlinedButton(
                style: OutlinedButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: controller.text.isEmpty ? null : () => _replace(''),
                child: const Text('Clear'),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: () => _enter('0'),
                child: const Text('0', style: TextStyle(fontSize: 16)),
              ),
              FilledButton.tonal(
                style: FilledButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: decimalDigits == 0 ? null : () => _enter('.'),
                child: const Text('.', style: TextStyle(fontSize: 18)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                visualDensity: VisualDensity.compact,
              ),
              onPressed: controller.text.isEmpty
                  ? null
                  : () => _replace(
                      controller.text.substring(0, controller.text.length - 1),
                    ),
              icon: const Icon(Icons.backspace_outlined),
              label: const Text('Delete'),
            ),
          ),
        ],
      ),
    ),
  );
}
