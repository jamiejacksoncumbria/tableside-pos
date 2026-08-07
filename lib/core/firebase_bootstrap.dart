import 'package:firebase_core/firebase_core.dart';

import 'firebase_runtime_config.dart';

Future<void> initializeFirebase() async {
  if (Firebase.apps.isNotEmpty) return;
  await Firebase.initializeApp(options: FirebaseRuntimeConfig.options);
}
