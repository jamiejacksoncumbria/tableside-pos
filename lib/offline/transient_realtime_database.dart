import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';

/// Creates an RTDB instance for transient control-plane data without LevelDB.
///
/// On Windows, Firebase C++ derives its persistence directory from the package
/// name and database URL, not the secondary Firebase app name. TableSide uses
/// separate, least-privileged Firebase apps for hub, POS, and printer tokens;
/// allowing all of them to enable persistence therefore makes several native
/// clients compete for the same LevelDB lock. Firebase C++ asserts instead of
/// returning that lock failure.
///
/// Presence, wake signals, and command acknowledgements are intentionally
/// ephemeral. Durable orders and print jobs remain in the encrypted hub ledger
/// and Firestore, so disabling RTDB persistence cannot lose business data.
abstract final class TransientRealtimeDatabase {
  static final Set<String> _configuredApps = <String>{};

  static FirebaseDatabase instanceFor({
    required FirebaseApp app,
    required String databaseUrl,
  }) {
    final database = FirebaseDatabase.instanceFor(
      app: app,
      databaseURL: databaseUrl,
    );
    if (_configuredApps.add(app.name)) {
      // Firebase requires this setting before the first reference is created.
      database.setPersistenceEnabled(false);
    }
    return database;
  }
}
