import 'package:flutter/material.dart';

import '../core/app_theme.dart';
import '../core/firebase_bootstrap.dart';
import '../core/firebase_runtime_config.dart';
import '../features/auth/auth_gate.dart';
import 'home_shell.dart';

class TableSideApp extends StatelessWidget {
  const TableSideApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TableSide POS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
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
  late final Future<void> _bootstrap = initializeFirebase();

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
                  'Firebase could not start. Check the TABLESIDE_USE_FIREBASE configuration.\n\n${snapshot.error}',
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
