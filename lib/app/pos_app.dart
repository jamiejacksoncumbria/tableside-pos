import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../core/app_theme_controller.dart';
import '../core/app_logger.dart';
import '../core/firebase_bootstrap.dart';
import '../core/firebase_runtime_config.dart';
import '../features/auth/auth_gate.dart';
import 'home_shell.dart';

class TableSideApp extends ConsumerWidget {
  const TableSideApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      appThemeControllerProvider.select((selection) => selection.effectiveMode),
    );
    return MaterialApp(
      title: 'TableSide POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      home: FirebaseRuntimeConfig.enabled
          ? const _FirebaseBootstrapGate()
          : const HomeShell(),
    );
  }
}

class _FirebaseBootstrapGate extends StatefulWidget {
  const _FirebaseBootstrapGate();

  @override
  State<_FirebaseBootstrapGate> createState() => _FirebaseBootstrapGateState();
}

class _FirebaseBootstrapGateState extends State<_FirebaseBootstrapGate> {
  late final Future<void> _bootstrap = _initialize();

  Future<void> _initialize() async {
    try {
      await initializeFirebase();
    } on Object catch (error, stackTrace) {
      AppLogger.error('Firebase startup', error, stackTrace);
      rethrow;
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _bootstrap,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Firebase could not start. Verify the generated FlutterFire configuration and the TABLESIDE_USE_FIREBASE flag.\n\n${snapshot.error}',
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          );
        }
        return const FirebaseAuthGate();
      },
    );
  }
}
