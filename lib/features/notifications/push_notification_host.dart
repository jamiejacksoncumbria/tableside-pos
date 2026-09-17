import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/app_logger.dart';
import '../../core/tenant_scope.dart';
import '../../data/production_command_repository.dart';
import '../auth/staff_pin_gate.dart';
import '../printing/local_printer_device_identity.dart';

/// Registers the current Android/iOS installation for generic lock-screen
/// order alerts. Windows and web continue to receive the live in-app event
/// stream without invoking an unsupported native messaging plugin.
class PushNotificationHost extends ConsumerStatefulWidget {
  const PushNotificationHost({super.key});

  @override
  ConsumerState<PushNotificationHost> createState() =>
      _PushNotificationHostState();
}

class _PushNotificationHostState extends ConsumerState<PushNotificationHost> {
  StreamSubscription<String>? _tokenSubscription;
  String? _registeredKey;
  bool _registering = false;

  bool get _supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    if (_supported) {
      _tokenSubscription = FirebaseMessaging.instance.onTokenRefresh.listen(
        (_) => _scheduleRegistration(force: true),
        onError: (Object error, StackTrace stack) =>
            AppLogger.error('Refresh push notification token', error, stack),
      );
    }
  }

  @override
  void dispose() {
    _tokenSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scope = ref.watch(activeVenueScopeProvider);
    final staff = ref.watch(activeStaffPinSessionProvider);
    if (_supported && scope != null && staff != null) {
      _scheduleRegistration();
    } else {
      _registeredKey = null;
    }
    return const SizedBox.shrink();
  }

  void _scheduleRegistration({bool force = false}) {
    scheduleMicrotask(() => _register(force: force));
  }

  Future<void> _register({bool force = false}) async {
    if (!_supported || _registering || !mounted) return;
    final scope = ref.read(activeVenueScopeProvider);
    final staff = ref.read(activeStaffPinSessionProvider);
    if (scope == null || staff == null) return;
    _registering = true;
    try {
      final permission = await FirebaseMessaging.instance.requestPermission(
        alert: true,
        badge: true,
        sound: true,
      );
      if (permission.authorizationStatus == AuthorizationStatus.denied) return;
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null || token.isEmpty) return;
      final deviceId = await LocalPrinterDeviceIdentity().getOrCreate();
      final key =
          '${scope.tenantId}/${scope.venueId}/${staff.userId}/$deviceId/$token';
      if (!force && _registeredKey == key) return;
      await ref
          .read(productionCommandRepositoryProvider)
          .manageFulfilment(
            scope: scope,
            operation: 'registerNotificationDevice',
            values: <String, Object?>{
              'deviceId': deviceId,
              'token': token,
              'platform': defaultTargetPlatform == TargetPlatform.iOS
                  ? 'ios'
                  : 'android',
            },
          );
      _registeredKey = key;
      AppLogger.info('Push notification device registered for this venue.');
    } on Object catch (error, stack) {
      AppLogger.error('Register push notification device', error, stack);
    } finally {
      _registering = false;
    }
  }
}
