import 'package:audioplayers/audioplayers.dart';

import '../../core/app_logger.dart';

/// Small, app-owned alert player for the order-flow board.
///
/// Bundled assets avoid platform-system sound differences: Android, Windows and
/// web all receive the same audible cue. Web browsers may require that the
/// user has interacted with the page once before permitting audio; this is
/// normally satisfied by signing in and selecting a venue.
class OrderFlowSound {
  OrderFlowSound()
      : _newOrderPlayer = AudioPlayer(playerId: 'tableside-order-new'),
        _alertPlayer = AudioPlayer(playerId: 'tableside-order-alert') {
    _newOrderPlayer.setReleaseMode(ReleaseMode.stop);
    _alertPlayer.setReleaseMode(ReleaseMode.stop);
  }

  final AudioPlayer _newOrderPlayer;
  final AudioPlayer _alertPlayer;

  Future<void> playNewOrder() => _play(
        _newOrderPlayer,
        'assets/sounds/order_new.wav',
        'Play new order alert',
      );

  Future<void> playLateOrder() => _play(
        _alertPlayer,
        'assets/sounds/order_alert.wav',
        'Play late order alert',
      );

  Future<void> playAllergyAlert() => _play(
        _alertPlayer,
        'assets/sounds/order_alert.wav',
        'Play allergy alert',
      );

  Future<void> _play(
    AudioPlayer player,
    String assetPath,
    String context,
  ) async {
    try {
      // Stop first so repeated allergy alerts remain distinct rather than
      // queueing indefinitely on a slow device or browser.
      await player.stop();
      await player.play(AssetSource(assetPath.replaceFirst('assets/', '')));
    } on Object catch (error, stackTrace) {
      // Audio is an operational aid, never a reason for KDS to stop updating.
      AppLogger.error(context, error, stackTrace);
    }
  }

  Future<void> dispose() async {
    await _newOrderPlayer.dispose();
    await _alertPlayer.dispose();
  }
}
