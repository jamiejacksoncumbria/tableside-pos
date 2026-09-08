import 'package:flutter_riverpod/flutter_riverpod.dart';

class TrainingModeSession {
  const TrainingModeSession({required this.id, this.targetDeviceId});

  final String id;
  final String? targetDeviceId;
}

final trainingModeProvider =
    NotifierProvider<TrainingModeController, TrainingModeSession?>(
      TrainingModeController.new,
    );

class TrainingModeController extends Notifier<TrainingModeSession?> {
  @override
  TrainingModeSession? build() => null;

  void start(TrainingModeSession session) => state = session;

  void clear() => state = null;
}
