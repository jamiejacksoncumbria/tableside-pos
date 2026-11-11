part of '../menu_management_page.dart';

class _TaxRateTile extends StatelessWidget {
  const _TaxRateTile({
    required this.rate,
    required this.onEdit,
    required this.onDelete,
  });

  final TaxRate rate;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: CircleAvatar(child: Text(rate.percentageLabel)),
    title: Text(rate.name),
    subtitle: const Text('Used for tax-inclusive menu prices'),
    trailing: Wrap(
      children: [
        IconButton(
          tooltip: 'Edit tax rate',
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined),
        ),
        IconButton(
          tooltip: 'Delete tax rate',
          onPressed: onDelete,
          icon: const Icon(Icons.delete_outline_rounded),
        ),
      ],
    ),
  );
}

Future<void> _showTaxRateDialog({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  TaxRate? existing,
}) async {
  final savedName = await _showMenuDialog<String>(
    context: context,
    builder: (_) => _TaxRateEditorDialog(scope: scope, existing: existing),
  );
  if (savedName == null || !context.mounted) return;
  showAppNotification(
    context,
    ref: ref,
    title: existing == null ? 'Tax rate added' : 'Tax rate updated',
    message: '$savedName is now available for products.',
    level: AppNotificationLevel.success,
  );
}

/// Owns the tax editor's form state for the full lifetime of the dialog route.
///
/// Controllers created outside `showDialog` can be disposed as soon as the
/// route's result completes, while Flutter is still running its closing
/// animation. On Windows that left the text fields in the overlay with disposed
/// state and could corrupt the next layout pass when the barrier was clicked.
class _TaxRateEditorDialog extends ConsumerStatefulWidget {
  const _TaxRateEditorDialog({required this.scope, this.existing});

  final VenueScope scope;
  final TaxRate? existing;

  @override
  ConsumerState<_TaxRateEditorDialog> createState() =>
      _TaxRateEditorDialogState();
}

class _TaxRateEditorDialogState extends ConsumerState<_TaxRateEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _name;
  late final TextEditingController _percentage;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.existing?.name ?? '');
    _percentage = TextEditingController(
      text: _taxPercentText(widget.existing?.basisPoints ?? 0),
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _percentage.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving || !(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final basisPoints = _taxBasisPointsFromText(_percentage.text)!;
      final repository = ref.read(firestorePosRepositoryProvider);
      if (widget.existing == null) {
        await repository.createTaxRate(
          scope: widget.scope,
          name: _name.text,
          basisPoints: basisPoints,
        );
      } else {
        await repository.updateTaxRate(
          scope: widget.scope,
          existing: widget.existing!,
          name: _name.text,
          basisPoints: basisPoints,
        );
      }
      ref.invalidate(taxRatesProvider);
      if (mounted) Navigator.pop(context, _name.text.trim());
    } on Object catch (error, stackTrace) {
      AppLogger.error('Save tax rate', error, stackTrace);
      if (!mounted) return;
      setState(() => _saving = false);
      showAppNotification(
        context,
        ref: ref,
        title: 'Could not save tax rate',
        message: '$error',
        level: AppNotificationLevel.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.existing == null ? 'Add tax rate' : 'Edit tax rate'),
    // Scrolling keeps the form bounded when a touch keyboard, accessibility
    // text scaling, or a short tablet window reduces the available height.
    content: SizedBox(
      width: 420,
      child: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                maxLength: 80,
                decoration: const InputDecoration(
                  labelText: 'Tax rate name',
                  hintText: 'For example, Food VAT',
                ),
                validator: _requiredText,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _percentage,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'Rate (%)',
                  helperText:
                      'Prices are inclusive. 20 means 20% of the price is tax-inclusive.',
                ),
                validator: (value) => _taxBasisPointsFromText(value) == null
                    ? 'Enter a rate from 0% to 1,000% with at most two decimals.'
                    : null,
              ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(
          _saving
              ? 'Saving…'
              : widget.existing == null
              ? 'Save rate'
              : 'Save changes',
        ),
      ),
    ],
  );
}

Future<void> _deleteTaxRate({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required TaxRate rate,
}) async {
  final approved = await _showMenuDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Delete tax rate?'),
      content: Text(
        '“${rate.name}” can be deleted only when no products use it. Closed bills always retain their own tax records.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton.tonal(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  if (approved != true) return;
  try {
    await ref
        .read(firestorePosRepositoryProvider)
        .deleteTaxRate(scope: scope, rate: rate);
    ref.invalidate(taxRatesProvider);
    if (context.mounted) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Tax rate deleted',
        message: '${rate.name} is no longer available for new products.',
        level: AppNotificationLevel.success,
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error('Delete tax rate', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not delete tax rate',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}
