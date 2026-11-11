part of '../home_shell.dart';

class _CloudFeatureUnavailable extends StatelessWidget {
  const _CloudFeatureUnavailable({required this.feature});

  final String feature;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 520),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.cloud_off_rounded, size: 42),
              const SizedBox(height: 12),
              Text(
                '$feature requires an internet connection',
                style: Theme.of(context).textTheme.titleLarge,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'The POS, kitchen flow and local ticket printing continue through the venue hub while offline.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<void> _endTrainingFromWorkspace({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
  required TrainingModeSession session,
}) async {
  try {
    await ref
        .read(productionCommandRepositoryProvider)
        .endTrainingMode(scope: scope, trainingSessionId: session.id);
    ref.read(trainingModeProvider.notifier).clear();
    ref.read(trainingOpenOrdersProvider.notifier).clear();
    ref.read(homeSectionProvider.notifier).select(HomeSection.settings);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Training mode ended',
      message: 'Returned to venue settings. No live sale data was changed.',
      level: AppNotificationLevel.success,
    );
  } on Object catch (error, stackTrace) {
    AppLogger.error('End training mode from POS', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not end training mode',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}

Future<void> _changeOwnAppearance({
  required BuildContext context,
  required WidgetRef ref,
  required VenueScope scope,
}) async {
  final selected = await showAppDialog<String>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('My appearance'),
      children: [
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'venue'),
          child: const ListTile(
            leading: Icon(Icons.storefront_outlined),
            title: Text('Venue default'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'light'),
          child: const ListTile(
            leading: Icon(Icons.light_mode_outlined),
            title: Text('Light'),
          ),
        ),
        SimpleDialogOption(
          onPressed: () => Navigator.pop(dialogContext, 'dark'),
          child: const ListTile(
            leading: Icon(Icons.dark_mode_outlined),
            title: Text('Dark'),
          ),
        ),
      ],
    ),
  );
  if (selected == null || !context.mounted) return;
  try {
    await ref
        .read(productionCommandRepositoryProvider)
        .updateOwnThemePreference(scope: scope, themeMode: selected);
    ref.read(appThemeControllerProvider.notifier).applyUserPreference(selected);
    final session = ref.read(activeStaffPinSessionProvider);
    if (session != null) {
      await VenueHubClientCache().saveStaffPreferences(
        scope,
        userId: session.userId,
        themeModePreference: selected,
        posCategoryViewPreference: session.posCategoryViewPreference,
        posProductSortPreference: session.posProductSortPreference,
      );
    }
    if (context.mounted) {
      showAppNotification(
        context,
        ref: ref,
        title: 'Appearance updated',
        message: selected == 'venue'
            ? 'You are now using the venue default appearance.'
            : 'Your ${selected == 'dark' ? 'dark' : 'light'} appearance will follow you across devices.',
        level: AppNotificationLevel.success,
      );
    }
  } on Object catch (error, stackTrace) {
    AppLogger.error('Update own appearance', error, stackTrace);
    if (!context.mounted) return;
    showAppNotification(
      context,
      ref: ref,
      title: 'Could not update appearance',
      message: '$error',
      level: AppNotificationLevel.error,
    );
  }
}
