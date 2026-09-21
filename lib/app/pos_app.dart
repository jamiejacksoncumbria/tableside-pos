import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_theme.dart';
import '../core/app_theme_controller.dart';
import '../core/app_logger.dart';
import '../core/app_environment.dart';
import '../core/firebase_bootstrap.dart';
import '../core/firebase_runtime_config.dart';
import '../features/auth/auth_gate.dart';
import '../offline/venue_hub_remote_command_client.dart';
import 'home_shell.dart';

class TableSideCYApp extends ConsumerWidget {
  const TableSideCYApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(
      appThemeControllerProvider.select((selection) => selection.effectiveMode),
    );
    return MaterialApp(
      title: AppEnvironment.isStaging ? 'TableSideCY STAGING' : 'TableSideCY',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: themeMode,
      builder: (context, child) => ValueListenableBuilder<int>(
        valueListenable: RemoteHubWaitState.pending,
        builder: (context, pending, _) {
          final showStaging =
              FirebaseRuntimeConfig.enabled && AppEnvironment.isStaging;
          final topInset = MediaQuery.paddingOf(context).top;
          return Stack(
            children: [
              if (child != null) child,
              if (showStaging)
                Positioned(
                  top: topInset + 4,
                  left: 12,
                  child: IgnorePointer(
                    child: Material(
                      elevation: 12,
                      color: const Color(0xffff9800),
                      borderRadius: BorderRadius.circular(7),
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        child: Text(
                          'STAGING · TEST DATA ONLY',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 11,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.6,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (pending > 0)
                Positioned(
                  top: topInset + (showStaging ? 42 : 8),
                left: 16,
                right: 16,
                child: Material(
                  elevation: 8,
                  color: Theme.of(context).colorScheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2.5),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            pending == 1
                                ? 'Waiting for venue hub…'
                                : 'Waiting for venue hub… ($pending commands)',
                            style: Theme.of(context).textTheme.titleSmall,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                ),
            ],
          );
        },
      ),
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
                  'Firebase could not start. Verify the selected staging or production configuration.\n\n${snapshot.error}',
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
