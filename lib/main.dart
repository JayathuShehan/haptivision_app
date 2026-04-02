import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'haptic_engine.dart';
import 'object_detector.dart';

List<CameraDescription> _cameras = [];

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _cameras = await availableCameras();
  runApp(const HaptiVisionApp());
}

class HaptiVisionApp extends StatelessWidget {
  const HaptiVisionApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HaptiVision',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1A9FD6)),
        useMaterial3: true,
      ),
      home: const MainScreen(),
    );
  }
}

// pulsing indicator in the top-right corner of the preview

class HapticIndicator extends StatefulWidget {
  final HapticPattern? pattern;
  const HapticIndicator({super.key, required this.pattern});

  @override
  State<HapticIndicator> createState() => _HapticIndicatorState();
}

class _HapticIndicatorState extends State<HapticIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, lowerBound: 0.15, upperBound: 1.0)
      ..addStatusListener(_onStatus);
    _updateAnimation();
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _controller.reverse();
    if (status == AnimationStatus.dismissed) _controller.forward();
  }

  @override
  void didUpdateWidget(HapticIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pattern != widget.pattern) _updateAnimation();
  }

  void _updateAnimation() {
    _controller.stop();
    switch (widget.pattern) {
      case HapticPattern.danger:
        // fast blink for danger
        _controller.duration = const Duration(milliseconds: 80);
        _controller.forward();
        break;
      case HapticPattern.obstacle:
        // medium blink for obstacle
        _controller.duration = const Duration(milliseconds: 300);
        _controller.forward();
        break;
      case HapticPattern.batteryLow:
        // slow blink for low battery
        _controller.duration = const Duration(milliseconds: 800);
        _controller.forward();
        break;
      case HapticPattern.systemReady:
        // startup blink
        _controller.duration = const Duration(milliseconds: 300);
        _controller.forward();
        break;
      default:
        // no animation when clear
        _controller.value = 0.15;
        break;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color get _colour {
    switch (widget.pattern) {
      case HapticPattern.danger:
        return const Color(0xFFFF3232);     // bright red
      case HapticPattern.obstacle:
        return const Color(0xFFFF9532);     // orange
      case HapticPattern.systemReady:
        return const Color(0xFF32DC50);     // green
      case HapticPattern.batteryLow:
        return const Color(0xFFDCDC32);     // yellow
      default:
        return const Color(0xFF606060);     // dim grey
    }
  }

  String get _label {
    switch (widget.pattern) {
      case HapticPattern.danger:
        return 'DANGER';
      case HapticPattern.obstacle:
        return 'OBSTACLE';
      case HapticPattern.systemReady:
        return 'READY';
      case HapticPattern.batteryLow:
        return 'LOW BATT';
      default:
        return 'SAFE';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (_, __) {
        final opacity = widget.pattern == null || widget.pattern == HapticPattern.clear
            ? 0.3
            : _controller.value;
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Opacity(
              opacity: opacity,
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _colour,
                  boxShadow: widget.pattern != null && widget.pattern != HapticPattern.clear
                      ? [BoxShadow(color: _colour.withOpacity(0.5), blurRadius: 14, spreadRadius: 2)]
                      : null,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              _label,
              style: TextStyle(
                color: _colour,
                fontSize: 9,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
          ],
        );
      },
    );
  }
}

// MAIN SCREEN

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _permissionGranted = false;
  bool _initialized = false;

  final ObjectDetector _objectDetector = ObjectDetector();
  final FlutterTts _flutterTts = FlutterTts();
  final Battery _battery = Battery();
  final HapticEngine _haptic = HapticEngine.instance;

  String _currentCaption = 'Analyzing environment...';
  DateTime _lastCaptionTime = DateTime.fromMillisecondsSinceEpoch(0);

  HapticPattern? _hapticPattern;
  bool _isBatteryLow = false;
  Timer? _batteryTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initHaptic();
    _initTts();
    _objectDetector.loadModel();
    _initCamera();
    _startBatteryMonitor();
  }

  Future<void> _initHaptic() async {
    await _haptic.init();
    await _haptic.systemReady();
    if (mounted) setState(() => _hapticPattern = HapticPattern.systemReady);
    // reset indicator after startup vibration
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _hapticPattern = null);
    });
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.5);
  }

  // check battery every 30 seconds
  void _startBatteryMonitor() {
    _checkBattery(); // immediate first check
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBattery());
  }

  Future<void> _checkBattery() async {
    try {
      final level = await _battery.batteryLevel;
      final state = await _battery.batteryState;
      final isCharging = state == BatteryState.charging || state == BatteryState.full;
      final nowLow = level < 20 && !isCharging;

      if (nowLow != _isBatteryLow) {
        _isBatteryLow = nowLow;
        if (nowLow) {
          await _haptic.batteryLow();
          if (mounted) setState(() => _hapticPattern = HapticPattern.batteryLow);
        } else {
          // recovered or charging, let detection take over
          await _haptic.stop();
        }
      }
    } catch (_) {
      // not supported on this device
    }
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _permissionGranted = false);
      return;
    }

    setState(() => _permissionGranted = true);

    if (_cameras.isEmpty) return;

    CameraDescription camera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );

    _controller = CameraController(
      camera,
      ResolutionPreset.high,
      enableAudio: false,
    );

    try {
      await _controller!.initialize();
      if (mounted) {
        setState(() => _initialized = true);

        _controller!.startImageStream((CameraImage image) {
          // inference runs in the background isolate
          _objectDetector.processImage(image).then((result) {
            if (!mounted) return;
            final now = DateTime.now();

            // trigger haptic pattern
            if (!_isBatteryLow) {
              _haptic.updateFromCategory(
                category: result.category,
                isBatteryLow: false,
              );
              final newPattern = _patternFromCategory(result.category);
              if (newPattern != _hapticPattern) {
                setState(() => _hapticPattern = newPattern);
              }
            }

            // update caption every 3 seconds
            if (now.difference(_lastCaptionTime).inSeconds >= 3) {
              _lastCaptionTime = now;

              final String newCaption = _buildCaption(result.labels);

              if (_currentCaption != newCaption) {
                setState(() => _currentCaption = newCaption);
                _flutterTts.speak(newCaption);
              }
            }
          });
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  /// Builds a natural-language scene description from detected object labels,
  /// similar to BLIP captioning but using on-device YOLO detections.
  String _buildCaption(List<String> labels) {
    if (labels.isEmpty) return 'Clear ahead.';

    // Group objects into semantic categories
    const people = {'person'};
    const vehicles = {'car', 'truck', 'bus', 'motorcycle', 'bicycle', 'train'};
    const furniture = {'chair', 'couch', 'bed', 'dining table', 'bench'};
    const electronics = {'laptop', 'tv', 'cell phone', 'keyboard', 'mouse', 'monitor'};
    const dangers = {'traffic light', 'stop sign', 'fire hydrant'};

    final labelSet = labels.toSet();
    final hasPeople     = labelSet.intersection(people).isNotEmpty;
    final hasVehicles   = labelSet.intersection(vehicles).isNotEmpty;
    final hasFurniture  = labelSet.intersection(furniture).isNotEmpty;
    final hasElectronics = labelSet.intersection(electronics).isNotEmpty;
    final hasDangers    = labelSet.intersection(dangers).isNotEmpty;

    final int personCount = labels.where(people.contains).length;
    final vehicleTypes = labelSet.intersection(vehicles);
    final furnitureTypes = labelSet.intersection(furniture);

    // Build a contextual description
    final parts = <String>[];

    if (hasPeople) {
      parts.add(personCount == 1 ? 'a person' : '$personCount people');
    }
    if (hasVehicles) {
      final vList = vehicleTypes.toList();
      if (vList.length == 1) {
        parts.add('a ${vList.first}');
      } else {
        parts.add('${vList.sublist(0, vList.length - 1).join(', ')} and a ${vList.last}');
      }
    }
    if (hasFurniture) {
      final fList = furnitureTypes.toList();
      parts.add(fList.length == 1 ? 'a ${fList.first}' : '${fList.join(' and ')}');
    }
    if (hasElectronics) {
      parts.add('electronics');
    }

    // Other objects not in any named group
    final uncategorised = labelSet
        .difference(people)
        .difference(vehicles)
        .difference(furniture)
        .difference(electronics)
        .difference(dangers)
        .toList();
    for (final obj in uncategorised) {
      parts.add('a $obj');
    }

    if (hasDangers) {
      parts.add('a road hazard');
    }

    if (parts.isEmpty) return 'I see something ahead.';

    // Build sentence
    String subject;
    if (parts.length == 1) {
      subject = parts.first;
    } else {
      subject = '${parts.sublist(0, parts.length - 1).join(', ')} and ${parts.last}';
    }

    // Add context clue
    if (hasPeople && hasFurniture && hasElectronics) {
      return 'I see $subject in what looks like an office or workspace.';
    } else if (hasPeople && hasVehicles) {
      return 'Caution — I see $subject ahead.';
    } else if (hasPeople && hasFurniture) {
      return 'I see $subject in this space.';
    } else if (hasVehicles && !hasPeople) {
      return 'There is $subject nearby. Stay alert.';
    } else {
      return 'I see $subject.';
    }
  }

  HapticPattern? _patternFromCategory(HapticCategory category) {
    switch (category) {
      case HapticCategory.danger:
        return HapticPattern.danger;
      case HapticCategory.obstacle:
        return HapticPattern.obstacle;
      case HapticCategory.clear:
        return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      _haptic.stop();
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _batteryTimer?.cancel();
    _haptic.stop();
    _controller?.dispose();
    _objectDetector.dispose();
    super.dispose();
  }

  // builds the camera preview widget

  Widget _buildCameraPreview() {
    if (!_permissionGranted) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.camera_alt, color: Colors.white54, size: 48),
            const SizedBox(height: 12),
            const Text('Camera permission denied',
                style: TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: openAppSettings,
              child: const Text('Open Settings',
                  style: TextStyle(color: Color(0xFF1A9FD6))),
            ),
          ],
        ),
      );
    }

    if (!_initialized || _controller == null) {
      return const Center(child: CircularProgressIndicator(color: Colors.white38));
    }

    return Stack(
      children: [
        // camera feed
        ClipRect(
          child: OverflowBox(
            alignment: Alignment.center,
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width: _controller!.value.previewSize!.height,
                height: _controller!.value.previewSize!.width,
                child: CameraPreview(_controller!),
              ),
            ),
          ),
        ),

        // haptic indicator
        Positioned(
          top: 12,
          right: 12,
          child: HapticIndicator(pattern: _hapticPattern),
        ),

        // legend
        Positioned(
          bottom: 8,
          right: 8,
          child: _buildLegend(),
        ),
      ],
    );
  }

  Widget _buildLegend() {
    const style = TextStyle(fontSize: 9, color: Color(0xFFCCCCCC));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: const [
          Text('[ Haptic Indicator ]',
              style: TextStyle(fontSize: 9, color: Color(0xFFAAAAAA), fontWeight: FontWeight.bold)),
          SizedBox(height: 3),
          _LegendRow(color: Color(0xFFFF3232), text: 'Fast blink  = DANGER'),
          _LegendRow(color: Color(0xFFFF9532), text: '2×2 blink  = OBSTACLE'),
          _LegendRow(color: Color(0xFF32DC50), text: '3× blink    = READY'),
          _LegendRow(color: Color(0xFFDCDC32), text: 'Slow blink  = BATTERY LOW'),
          _LegendRow(color: Color(0xFF606060), text: 'No blink    = SAFE'),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // logo and caption
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text('HaptiVision',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF1A9FD6),
                      letterSpacing: 0.5,
                    )),
                const SizedBox(height: 48),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _currentCaption,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w400,
                        color: Colors.black87),
                  ),
                ),
              ],
            ),
          ),

          // camera preview
          Expanded(
            child: Container(
              width: double.infinity,
              color: Colors.black,
              child: _buildCameraPreview(),
            ),
          ),
        ],
      ),
    );
  }
}

// small coloured dot + label row used in the legend

class _LegendRow extends StatelessWidget {
  final Color color;
  final String text;
  const _LegendRow({required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 4),
          Text(text, style: TextStyle(fontSize: 9, color: color)),
        ],
      ),
    );
  }
}
