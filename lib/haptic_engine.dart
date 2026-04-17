import 'package:vibration/vibration.dart';

enum HapticPattern { danger, obstacle, clear, systemReady, batteryLow }

class HapticEngine {
  HapticEngine._();
  static final HapticEngine instance = HapticEngine._();

  HapticPattern? _currentPattern;
  bool _hasVibrator = false;

  Future<void> init() async {
    _hasVibrator = (await Vibration.hasVibrator()) ?? false;
  }

  Future<void> danger() async {
    if (!_hasVibrator || _currentPattern == HapticPattern.danger) return;
    _currentPattern = HapticPattern.danger;
    await Vibration.cancel();
    final pattern = _buildPattern(
      pulses: 6,
      onMs: 80,
      offMs: 80,
      leadingDelay: 0,
    );
    Vibration.vibrate(pattern: pattern, repeat: 0);
  }

  Future<void> obstacle() async {
    if (!_hasVibrator || _currentPattern == HapticPattern.obstacle) return;
    _currentPattern = HapticPattern.obstacle;
    await Vibration.cancel();
    final pattern = [
      0,   200, 150,
      200, 150,
      400,
      200, 150,
      200, 800,
    ];
    Vibration.vibrate(pattern: pattern, repeat: 0);
  }

  Future<void> clear() async {
    if (_currentPattern == HapticPattern.clear) return;
    _currentPattern = HapticPattern.clear;
    await Vibration.cancel();
  }

  Future<void> systemReady() async {
    if (!_hasVibrator) return;
    _currentPattern = HapticPattern.systemReady;
    await Vibration.cancel();
    final pattern = _buildPattern(
      pulses: 3,
      onMs: 150,
      offMs: 250,
      leadingDelay: 0,
    );
    Vibration.vibrate(pattern: pattern, repeat: -1);
  }

  Future<void> batteryLow() async {
    if (!_hasVibrator || _currentPattern == HapticPattern.batteryLow) return;
    _currentPattern = HapticPattern.batteryLow;
    await Vibration.cancel();
    final pattern = [0, 300, 1700];
    Vibration.vibrate(pattern: pattern, repeat: 0);
  }

  Future<void> stop() async {
    _currentPattern = null;
    await Vibration.cancel();
  }

  List<int> _buildPattern({
    required int pulses,
    required int onMs,
    required int offMs,
    required int leadingDelay,
  }) {
    final pattern = <int>[leadingDelay];
    for (int i = 0; i < pulses; i++) {
      pattern.add(onMs);
      pattern.add(offMs);
    }
    return pattern;
  }

  Future<void> updateFromCategory({
    required HapticCategory category,
    required bool isBatteryLow,
  }) async {
    if (isBatteryLow) {
      await batteryLow();
      return;
    }
    switch (category) {
      case HapticCategory.danger:
        await danger();
        break;
      case HapticCategory.obstacle:
        await obstacle();
        break;
      case HapticCategory.clear:
        await clear();
        break;
    }
  }
}

enum HapticCategory { danger, obstacle, clear }

const Set<String> kDangerClasses = {
  'car', 'truck', 'bus', 'motorcycle', 'bicycle',
  'train', 'traffic light', 'stop sign',
};

const Set<String> kObstacleClasses = {
  'person', 'chair', 'couch', 'dining table', 'bed',
  'toilet', 'potted plant', 'bench', 'refrigerator',
  'suitcase', 'backpack',
};

HapticCategory categoryFromLabels(List<String> labels) {
  if (labels.isEmpty) return HapticCategory.clear;
  final detected = labels.toSet();
  if (detected.intersection(kDangerClasses).isNotEmpty) {
    return HapticCategory.danger;
  }
  if (detected.intersection(kObstacleClasses).isNotEmpty) {
    return HapticCategory.obstacle;
  }
  return HapticCategory.clear;
}
