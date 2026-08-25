import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';

enum AppNotificationLevel { success, information, warning, error }

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.level,
    required this.createdAt,
    this.isRead = false,
  });

  final String id;
  final String title;
  final String message;
  final AppNotificationLevel level;
  final DateTime createdAt;
  final bool isRead;

  AppNotification copyWith({bool? isRead}) => AppNotification(
    id: id,
    title: title,
    message: message,
    level: level,
    createdAt: createdAt,
    isRead: isRead ?? this.isRead,
  );
}

final appNotificationsProvider =
    NotifierProvider<AppNotificationsController, List<AppNotification>>(
      AppNotificationsController.new,
    );

class AppNotificationsController extends Notifier<List<AppNotification>> {
  @override
  List<AppNotification> build() => const [];

  void add({
    required String title,
    required String message,
    AppNotificationLevel level = AppNotificationLevel.information,
  }) {
    final notification = AppNotification(
      id: 'notification-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      message: message,
      level: level,
      createdAt: DateTime.now(),
    );
    // Keep a useful, bounded session history. Notifications remain visible
    // until dismissed; the cap merely prevents a shared till from growing
    // without limit during a very long shift.
    state = [notification, ...state].take(100).toList(growable: false);
    AppLogger.info('Notification recorded: ${notification.title}.');
  }

  void markAllRead() => state = state
      .map((notification) => notification.copyWith(isRead: true))
      .toList(growable: false);

  void markRead(String id) => state = state
      .map(
        (notification) => notification.id == id
            ? notification.copyWith(isRead: true)
            : notification,
      )
      .toList(growable: false);

  void dismiss(String id) => state = state
      .where((notification) => notification.id != id)
      .toList(growable: false);

  void clearAll() => state = const [];
}

int unreadNotificationCount(List<AppNotification> notifications) =>
    notifications.where((notification) => !notification.isRead).length;

/// Records every important message before showing the familiar short toast.
/// The notification centre is therefore the reliable record if a waiter
/// misses the transient visual confirmation.
void showAppNotification(
  BuildContext context, {
  WidgetRef? ref,
  required String title,
  required String message,
  AppNotificationLevel level = AppNotificationLevel.information,
}) {
  final AppNotificationsController controller;
  if (ref != null) {
    controller = ref.read(appNotificationsProvider.notifier);
  } else {
    controller = ProviderScope.containerOf(
      context,
    ).read(appNotificationsProvider.notifier);
  }
  controller.add(title: title, message: message, level: level);
  final colour = _colourFor(level, Theme.of(context).colorScheme);
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        backgroundColor: colour,
        content: Text(message),
        action: SnackBarAction(
          label: 'VIEW',
          textColor: Theme.of(context).colorScheme.onPrimary,
          onPressed: () => openNotificationCentre(context),
        ),
      ),
    );
}

void openNotificationCentre(BuildContext context) {
  Navigator.of(context).push<void>(
    MaterialPageRoute<void>(builder: (_) => const NotificationCentrePage()),
  );
}

class NotificationCentrePage extends ConsumerWidget {
  const NotificationCentrePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifications = ref.watch(appNotificationsProvider);
    final controller = ref.read(appNotificationsProvider.notifier);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          if (notifications.any((notification) => !notification.isRead))
            TextButton(
              onPressed: controller.markAllRead,
              child: const Text('Mark read'),
            ),
          if (notifications.isNotEmpty)
            IconButton(
              tooltip: 'Clear all notifications',
              onPressed: controller.clearAll,
              icon: const Icon(Icons.delete_sweep_outlined),
            ),
        ],
      ),
      body: notifications.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.notifications_none_rounded, size: 48),
                    SizedBox(height: 12),
                    Text('No notifications yet.'),
                    SizedBox(height: 4),
                    Text(
                      'Important app messages will stay here until dismissed.',
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(12),
              itemCount: notifications.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final notification = notifications[index];
                final scheme = Theme.of(context).colorScheme;
                return Card(
                  color: notification.isRead ? null : scheme.secondaryContainer,
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: _colourFor(notification.level, scheme),
                      foregroundColor: scheme.onPrimary,
                      child: Icon(_iconFor(notification.level)),
                    ),
                    title: Text(notification.title),
                    subtitle: Text(
                      '${notification.message}\n${_dateTimeLabel(context, notification.createdAt)}',
                    ),
                    isThreeLine: true,
                    onTap: () => controller.markRead(notification.id),
                    trailing: IconButton(
                      tooltip: 'Dismiss notification',
                      onPressed: () => controller.dismiss(notification.id),
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

Color _colourFor(AppNotificationLevel level, ColorScheme scheme) =>
    switch (level) {
      AppNotificationLevel.success => Colors.green.shade700,
      AppNotificationLevel.information => scheme.primary,
      AppNotificationLevel.warning => Colors.orange.shade800,
      AppNotificationLevel.error => scheme.error,
    };

IconData _iconFor(AppNotificationLevel level) => switch (level) {
  AppNotificationLevel.success => Icons.check_rounded,
  AppNotificationLevel.information => Icons.info_outline_rounded,
  AppNotificationLevel.warning => Icons.warning_amber_rounded,
  AppNotificationLevel.error => Icons.error_outline_rounded,
};

String _dateTimeLabel(BuildContext context, DateTime value) {
  final localizations = MaterialLocalizations.of(context);
  return '${localizations.formatMediumDate(value)} · ${localizations.formatTimeOfDay(TimeOfDay.fromDateTime(value))}';
}
