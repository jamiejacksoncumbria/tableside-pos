import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shorebird_code_push/shorebird_code_push.dart';

import 'app_logger.dart';
import 'app_environment.dart';

/// Downloads Shorebird patches without delaying POS startup.
///
/// Shorebird is available only in releases built by `shorebird release`. The
/// updater safely becomes a no-op in Flutter debug/profile builds and on web.
/// A long-running Android venue hub may not restart for days, so this host also
/// checks periodically and clearly tells staff when a full process restart is
/// needed to activate an already-durable patch.
class ShorebirdUpdateHost extends StatefulWidget {
  const ShorebirdUpdateHost({required this.top, super.key});

  final double top;

  @override
  State<ShorebirdUpdateHost> createState() => _ShorebirdUpdateHostState();
}

class _ShorebirdUpdateHostState extends State<ShorebirdUpdateHost> {
  final ShorebirdUpdater _updater = ShorebirdUpdater();
  Timer? _startupCheck;
  Timer? _periodicCheck;
  bool _checking = false;
  bool _restartRequired = false;

  UpdateTrack get _track => AppEnvironment.isStaging
      ? const UpdateTrack('staging')
      : UpdateTrack.stable;

  @override
  void initState() {
    super.initState();
    if (_updater.isAvailable) {
      _periodicCheck = Timer.periodic(
        const Duration(hours: 6),
        (_) => unawaited(_checkForUpdate()),
      );
      _startupCheck = Timer(
        const Duration(seconds: 3),
        () => unawaited(_checkForUpdate()),
      );
    }
  }

  @override
  void dispose() {
    _startupCheck?.cancel();
    _periodicCheck?.cancel();
    super.dispose();
  }

  Future<void> _checkForUpdate() async {
    if (!_updater.isAvailable || _checking) return;
    _checking = true;
    try {
      var status = await _updater.checkForUpdate(track: _track);
      if (status == UpdateStatus.outdated) {
        await _updater.update(track: _track);
        status = await _updater.checkForUpdate(track: _track);
      }
      if (status == UpdateStatus.restartRequired && mounted) {
        if (!_restartRequired) {
          AppLogger.info(
            'A signed Shorebird patch is ready and will apply after restart.',
          );
        }
        setState(() => _restartRequired = true);
      }
    } on Object catch (error, stackTrace) {
      // Updates must never block ordering, offline mode, payment, or printing.
      AppLogger.error('Check for TableSideCY update', error, stackTrace);
    } finally {
      _checking = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_restartRequired) return const SizedBox.shrink();
    return Positioned(
      top: widget.top,
      left: 16,
      right: 16,
      child: IgnorePointer(
        child: Material(
          elevation: 10,
          color: Colors.blue.shade900,
          borderRadius: BorderRadius.circular(10),
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.system_update_alt_rounded, color: Colors.white),
                SizedBox(width: 10),
                Flexible(
                  child: Text(
                    'Update downloaded — fully restart TableSideCY when it is safe.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
