/// Result of checking the platform's local preferences file before plugins
/// start reading it.
class LocalPreferencesRecoveryResult {
  const LocalPreferencesRecoveryResult({
    required this.recovered,
    this.recoveredEntryCount = 0,
  });

  final bool recovered;
  final int recoveredEntryCount;
}

/// Browsers and non-Windows platforms use storage implementations which do
/// not expose the Windows JSON corruption failure this repair targets.
Future<LocalPreferencesRecoveryResult>
recoverLocalPreferencesIfNeeded() async =>
    const LocalPreferencesRecoveryResult(recovered: false);
