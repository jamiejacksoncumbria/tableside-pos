import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/date_formats.dart';
import '../../core/tenant_scope.dart';

enum AppNotificationLevel { success, information, warning, error }

class AppNotification {
  const AppNotification({
    required this.id,
    required this.title,
    required this.message,
    required this.level,
    required this.createdAt,
    this.isRead = false,
    this.deduplicationKey,
    this.requiresAttention = false,
  });

  final String id;
  final String title;
  final String message;
  final AppNotificationLevel level;
  final DateTime createdAt;
  final bool isRead;

  /// A stable key turns an on-going operational condition (such as a failed
  /// printer job) into one notification rather than one message per stream
  /// event or retry timer tick.
  final String? deduplicationKey;

  /// Critical operational alerts deliberately stay visible until the user
  /// dismisses them or the underlying condition is resolved.
  final bool requiresAttention;

  AppNotification copyWith({
    String? title,
    String? message,
    AppNotificationLevel? level,
    DateTime? createdAt,
    bool? isRead,
    bool? requiresAttention,
  }) => AppNotification(
    id: id,
    title: title ?? this.title,
    message: message ?? this.message,
    level: level ?? this.level,
    createdAt: createdAt ?? this.createdAt,
    isRead: isRead ?? this.isRead,
    deduplicationKey: deduplicationKey,
    requiresAttention: requiresAttention ?? this.requiresAttention,
  );
}

final appNotificationsProvider =
    NotifierProvider<AppNotificationsController, List<AppNotification>>(
      AppNotificationsController.new,
    );

/// Venue-owned notification retention. Existing venues safely use the five
/// second default until their owner saves a different value.
final venueNotificationRetentionSecondsProvider = StreamProvider<int>((ref) {
  final scope = ref.watch(activeVenueScopeProvider);
  if (scope == null) return Stream.value(5);
  return FirebaseFirestore.instance
      .doc('tenants/${scope.tenantId}/venues/${scope.venueId}')
      .snapshots()
      .map((snapshot) {
        final value = snapshot.data()?['notificationRetentionSeconds'];
        final seconds = value is int ? value : 5;
        return seconds.clamp(1, 60).toInt();
      });
});

class AppNotificationsController extends Notifier<List<AppNotification>> {
  final _autoDismissTimers = <String, Timer>{};
  final _dismissedAttentionKeys = <String>{};

  @override
  List<AppNotification> build() {
    ref.onDispose(() {
      for (final timer in _autoDismissTimers.values) {
        timer.cancel();
      }
    });
    return const [];
  }

  void add({
    required String title,
    required String message,
    AppNotificationLevel level = AppNotificationLevel.information,
    int retentionSeconds = 5,
    String? deduplicationKey,
    bool requiresAttention = false,
  }) {
    final existingIndex = deduplicationKey == null
        ? -1
        : state.indexWhere(
            (notification) => notification.deduplicationKey == deduplicationKey,
          );
    if (existingIndex >= 0) {
      final existing = state[existingIndex];
      // A timer may reconcile the same unresolved print job every few
      // seconds. Leave an identical message completely untouched so its
      // unread state and ordering remain meaningful.
      if (existing.title == title &&
          existing.message == message &&
          existing.level == level &&
          existing.requiresAttention == requiresAttention) {
        return;
      }
      _autoDismissTimers.remove(existing.id)?.cancel();
      final updated = existing.copyWith(
        title: title,
        message: message,
        level: level,
        createdAt: DateTime.now(),
        isRead: false,
        requiresAttention: requiresAttention,
      );
      state = [
        updated,
        ...state.where((notification) => notification.id != existing.id),
      ];
      _scheduleDismiss(updated, retentionSeconds);
      AppLogger.info('Notification updated: ${updated.title}.');
      return;
    }
    if (requiresAttention &&
        deduplicationKey != null &&
        _dismissedAttentionKeys.contains(deduplicationKey)) {
      return;
    }
    final notification = AppNotification(
      id: 'notification-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      message: message,
      level: level,
      createdAt: DateTime.now(),
      deduplicationKey: deduplicationKey,
      requiresAttention: requiresAttention,
    );
    // Keep a useful, bounded session history while allowing a busy shared
    // till to clear routine messages automatically.
    state = [notification, ...state].take(100).toList(growable: false);
    _scheduleDismiss(notification, retentionSeconds);
    AppLogger.info('Notification recorded: ${notification.title}.');
  }

  void resolve(String deduplicationKey) {
    _dismissedAttentionKeys.remove(deduplicationKey);
    final matchingIds = state
        .where(
          (notification) => notification.deduplicationKey == deduplicationKey,
        )
        .map((notification) => notification.id)
        .toList(growable: false);
    for (final id in matchingIds) {
      _autoDismissTimers.remove(id)?.cancel();
    }
    state = state
        .where(
          (notification) => notification.deduplicationKey != deduplicationKey,
        )
        .toList(growable: false);
  }

  void _scheduleDismiss(AppNotification notification, int retentionSeconds) {
    if (notification.requiresAttention) return;
    final safeRetention = retentionSeconds.clamp(1, 60).toInt();
    _autoDismissTimers[notification.id] = Timer(
      Duration(seconds: safeRetention),
      () {
        _autoDismissTimers.remove(notification.id);
        dismiss(notification.id);
      },
    );
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

  void dismiss(String id) {
    _autoDismissTimers.remove(id)?.cancel();
    final notification = state.where((item) => item.id == id).firstOrNull;
    if (notification?.requiresAttention == true &&
        notification?.deduplicationKey != null) {
      _dismissedAttentionKeys.add(notification!.deduplicationKey!);
    }
    state = state
        .where((notification) => notification.id != id)
        .toList(growable: false);
  }

  void clearAll() {
    for (final timer in _autoDismissTimers.values) {
      timer.cancel();
    }
    _autoDismissTimers.clear();
    state = const [];
  }
}

int unreadNotificationCount(List<AppNotification> notifications) =>
    notifications.where((notification) => !notification.isRead).length;

/// Records every important message for the non-blocking bottom notification
/// tray. Messages disappear after the venue's configured retention time.
void showAppNotification(
  BuildContext context, {
  WidgetRef? ref,
  required String title,
  required String message,
  AppNotificationLevel level = AppNotificationLevel.information,
  String? deduplicationKey,
  bool requiresAttention = false,
}) {
  final AppNotificationsController controller;
  if (ref != null) {
    controller = ref.read(appNotificationsProvider.notifier);
  } else {
    controller = ProviderScope.containerOf(
      context,
    ).read(appNotificationsProvider.notifier);
  }
  final AsyncValue<int> retentionState;
  if (ref != null) {
    retentionState = ref.read(venueNotificationRetentionSecondsProvider);
  } else {
    retentionState = ProviderScope.containerOf(
      context,
    ).read(venueNotificationRetentionSecondsProvider);
  }
  final retention = retentionState.when(
    data: (seconds) => seconds,
    loading: () => 5,
    error: (_, _) => 5,
  );
  controller.add(
    title: title,
    message: message,
    level: level,
    retentionSeconds: retention,
    deduplicationKey: deduplicationKey,
    requiresAttention: requiresAttention,
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
                      '${notification.message}\n${_dateTimeLabel(notification.createdAt)}${notification.requiresAttention ? ' · Requires attention' : ''}',
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

String _dateTimeLabel(DateTime value) {
  return formatAppDateTime(value);
}
