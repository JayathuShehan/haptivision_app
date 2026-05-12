import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:permission_handler/permission_handler.dart';

import 'blip_local.dart';
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

// ═══════════════════════════════════════════════════════════════════
// HAPTIC INDICATOR WIDGET
// ═══════════════════════════════════════════════════════════════════

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
        _controller.duration = const Duration(milliseconds: 80);
        _controller.forward();
        break;
      case HapticPattern.obstacle:
        _controller.duration = const Duration(milliseconds: 300);
        _controller.forward();
        break;
      case HapticPattern.batteryLow:
        _controller.duration = const Duration(milliseconds: 800);
        _controller.forward();
        break;
      case HapticPattern.systemReady:
        _controller.duration = const Duration(milliseconds: 300);
        _controller.forward();
        break;
      default:
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
      case HapticPattern.danger:      return const Color(0xFFFF3232);
      case HapticPattern.obstacle:    return const Color(0xFFFF9532);
      case HapticPattern.systemReady: return const Color(0xFF32DC50);
      case HapticPattern.batteryLow:  return const Color(0xFFDCDC32);
      default:                        return const Color(0xFF606060);
    }
  }

  String get _label {
    switch (widget.pattern) {
      case HapticPattern.danger:      return 'DANGER';
      case HapticPattern.obstacle:    return 'OBSTACLE';
      case HapticPattern.systemReady: return 'READY';
      case HapticPattern.batteryLow:  return 'LOW BATT';
      default:                        return 'SAFE';
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
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
                      ? [BoxShadow(color: _colour.withValues(alpha: 0.5), blurRadius: 14, spreadRadius: 2)]
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

// ═══════════════════════════════════════════════════════════════════
// MAIN SCREEN
// ═══════════════════════════════════════════════════════════════════

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> with WidgetsBindingObserver {
  CameraController? _controller;
  bool _permissionGranted = false;
  bool _initialized       = false;

  final ObjectDetector _objectDetector = ObjectDetector();
  final FlutterTts     _flutterTts     = FlutterTts();
  final Battery        _battery        = Battery();
  final HapticEngine   _haptic         = HapticEngine.instance;
  final BlipLocalCaptionService _blip  = BlipLocalCaptionService.instance;

  String   _currentCaption    = 'Initializing AI...';
  DateTime _lastCaptionTime   = DateTime.fromMillisecondsSinceEpoch(0);
  String   _lastSpokenCaption = '';
  bool     _captionInFlight   = false;

  HapticPattern?        _hapticPattern;
  bool                  _isBatteryLow = false;
  Timer?                _batteryTimer;
  List<DetectedObject>  _detections = [];
  int                   _sensorOrientation = 90;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initHaptic();
    _initTts();
    _objectDetector.loadModel();
    _initCamera();
    _startBatteryMonitor();
    // Load BLIP models in background — takes ~10-20 s on first run
    _blip.init().then((_) {
      if (mounted) {
        setState(() {
          if (_currentCaption == 'Initializing AI...') {
            _currentCaption = _blip.state == BlipState.ready
                ? 'Analyzing environment...'
                : 'AI unavailable — check model files.';
          }
        });
      }
    });
  }

  Future<void> _initHaptic() async {
    await _haptic.init();
    await _haptic.systemReady();
    if (mounted) setState(() => _hapticPattern = HapticPattern.systemReady);
    Future.delayed(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _hapticPattern = null);
    });
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage('en-US');
    await _flutterTts.setSpeechRate(0.42);
    await _flutterTts.awaitSpeakCompletion(true);
  }

  void _startBatteryMonitor() {
    _checkBattery();
    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkBattery());
  }

  Future<void> _checkBattery() async {
    try {
      final level     = await _battery.batteryLevel;
      final state     = await _battery.batteryState;
      final charging  = state == BatteryState.charging || state == BatteryState.full;
      final nowLow    = level < 20 && !charging;

      if (nowLow != _isBatteryLow) {
        _isBatteryLow = nowLow;
        if (nowLow) {
          await _haptic.batteryLow();
          if (mounted) setState(() => _hapticPattern = HapticPattern.batteryLow);
        } else {
          await _haptic.stop();
        }
      }
    } catch (_) {}
  }

  Future<void> _initCamera() async {
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() => _permissionGranted = false);
      return;
    }
    setState(() => _permissionGranted = true);
    if (_cameras.isEmpty) return;

    final camera = _cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => _cameras.first,
    );

    _sensorOrientation = camera.sensorOrientation;
    _controller = CameraController(camera, ResolutionPreset.high, enableAudio: false);

    try {
      await _controller!.initialize();
      if (!mounted) return;
      setState(() => _initialized = true);

      _controller!.startImageStream((CameraImage image) {
        _objectDetector.processImage(image).then((result) {
          if (!mounted) return;
          // Skip frames where the detector was still busy with a previous frame.
          // Acting on these empty results would set the caption to "Clear ahead."
          // and lock out the real result via the 3-second cooldown.
          if (result.wasSkipped) return;

          final now = DateTime.now();

          if (!_isBatteryLow) {
            _haptic.updateFromCategory(
              category: result.category,
              isBatteryLow: false,
            );
            final newPattern = _patternFromCategory(result.category);
            setState(() {
              _hapticPattern = newPattern;
              _detections = result.detections;
            });
          } else {
            setState(() => _detections = result.detections);
          }

          if (now.difference(_lastCaptionTime).inSeconds >= 3 && !_captionInFlight) {
            _lastCaptionTime  = now;
            _captionInFlight  = true;

            if (_blip.state == BlipState.ready) {
              // On-device BLIP — runs in background isolate
              _blip.generateCaption(image).then((blipCaption) {
                _captionInFlight = false;
                if (!mounted) return;
                final caption = (blipCaption != null && blipCaption.isNotEmpty)
                    ? blipCaption
                    : _buildCaption(result.labels);
                _applyCaption(caption);
              });
            } else {
              // BLIP still loading or failed — use YOLO-derived caption
              _captionInFlight = false;
              _applyCaption(_buildCaption(result.labels));
            }
          }
        });
      });
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  void _applyCaption(String newCaption) {
    if (!mounted) return;
    if (_currentCaption != newCaption) {
      setState(() => _currentCaption = newCaption);
    }
    if (newCaption.isNotEmpty && _lastSpokenCaption != newCaption) {
      _lastSpokenCaption = newCaption;
      unawaited(_speakCaption(newCaption));
    }
  }

  String _buildCaption(List<String> labels) {
    if (labels.isEmpty) return 'Clear ahead.';
    final detected = labels.toSet();

    const vehicles     = {'car','truck','bus','motorcycle','bicycle','train'};
    const roadWarnings = {'traffic light','stop sign'};
    const grooming     = {'toothbrush','hair drier'};
    const tech         = {'cell phone','laptop','keyboard','mouse','remote','tv'};
    const food         = {'bottle','cup','fork','knife','spoon','bowl',
                          'banana','apple','sandwich','orange','broccoli',
                          'carrot','hot dog','pizza','donut','cake'};
    const furniture    = {'chair','couch','bed','dining table','toilet',
                          'refrigerator','oven','microwave','sink','toaster'};
    const sports       = {'bicycle','skateboard','surfboard','skis',
                          'snowboard','tennis racket','baseball bat',
                          'sports ball','frisbee','kite'};
    const animals      = {'dog','cat','bird','horse','cow','sheep',
                          'elephant','bear','zebra','giraffe'};

    final hasPerson = detected.contains('person');

    final veh = vehicles.firstWhere(detected.contains, orElse: () => '');
    if (veh.isNotEmpty && !hasPerson) return '${_withArticle(veh)} ahead.';
    if (veh.isNotEmpty && hasPerson)  return 'A person near a $veh.';

    final rw = roadWarnings.firstWhere(detected.contains, orElse: () => '');
    if (rw.isNotEmpty) return 'Road warning ahead.';

    if (hasPerson) {
      final gr = grooming.firstWhere(detected.contains, orElse: () => '');
      if (gr.isNotEmpty) {
        return gr == 'toothbrush'
            ? 'A person brushing their teeth.' : 'A person using a hair dryer.';
      }
      final tc = tech.firstWhere(detected.contains,     orElse: () => '');
      if (tc.isNotEmpty) return 'A person with a $tc.';

      final fd = food.firstWhere(detected.contains,     orElse: () => '');
      if (fd.isNotEmpty) return 'A person eating or drinking.';

      final sp = sports.firstWhere(detected.contains,   orElse: () => '');
      if (sp.isNotEmpty) return 'A person playing sports.';

      final an = animals.firstWhere(detected.contains,  orElse: () => '');
      if (an.isNotEmpty) return 'A person with a $an.';

      final fu = furniture.firstWhere(detected.contains, orElse: () => '');
      if (fu.isNotEmpty) return 'A person near a $fu.';

      return 'A person ahead.';
    }

    final ranked = detected.toList()..sort();
    return '${_withArticle(ranked.first)} ahead.';
  }

  Future<void> _speakCaption(String caption) async {
    await _flutterTts.stop();
    await _flutterTts.speak(caption);
  }

  String _withArticle(String label) {
    const vowels = {'a', 'e', 'i', 'o', 'u'};
    return '${vowels.contains(label[0].toLowerCase()) ? "an" : "a"} $label';
  }

  HapticPattern? _patternFromCategory(HapticCategory category) {
    switch (category) {
      case HapticCategory.danger:   return HapticPattern.danger;
      case HapticCategory.obstacle: return HapticPattern.obstacle;
      case HapticCategory.clear:    return null;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final c = _controller;
    if (c == null || !c.value.isInitialized) return;
    if (state == AppLifecycleState.inactive) {
      _haptic.stop();
      c.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _batteryTimer?.cancel();
    _haptic.stop();
    _flutterTts.stop();
    _controller?.dispose();
    _objectDetector.dispose();
    _blip.dispose();
    super.dispose();
  }

  // ── UI ──────────────────────────────────────────────────────────

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
      return const Center(
          child: CircularProgressIndicator(color: Colors.white38));
    }

    return Stack(
      children: [
        Positioned.fill(
          child: ClipRect(
            child: FittedBox(
              fit: BoxFit.cover,
              child: SizedBox(
                width:  _controller!.value.previewSize!.height,
                height: _controller!.value.previewSize!.width,
                child:  CameraPreview(_controller!),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: CustomPaint(
            painter: _BoundingBoxPainter(_detections, _sensorOrientation),
          ),
        ),
        Positioned(top: 12, right: 12,
            child: HapticIndicator(pattern: _hapticPattern)),
        Positioned(bottom: 8, right: 8,
            child: _buildLegend()),
      ],
    );
  }

  Widget _buildLegend() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('[ Haptic Indicator ]',
              style: TextStyle(fontSize: 9, color: Color(0xFFAAAAAA),
                  fontWeight: FontWeight.bold)),
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

  // Badge shown in the header — reflects BLIP loading state
  Widget _buildAiBadge() {
    final Color badgeColor;
    final String badgeText;
    final bool showSpinner;

    switch (_blip.state) {
      case BlipState.loading:
        badgeColor  = Colors.orange;
        badgeText   = 'Loading AI...';
        showSpinner = true;
        break;
      case BlipState.ready:
        badgeColor  = const Color(0xFF1A9FD6);
        badgeText   = 'On-device AI';
        showSpinner = false;
        break;
      case BlipState.failed:
        badgeColor  = Colors.red;
        badgeText   = 'AI load failed';
        showSpinner = false;
        break;
      case BlipState.idle:
        badgeColor  = Colors.grey;
        badgeText   = 'AI offline';
        showSpinner = false;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: badgeColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: badgeColor, width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showSpinner)
            SizedBox(
              width: 8, height: 8,
              child: CircularProgressIndicator(
                  strokeWidth: 1.5, color: badgeColor),
            )
          else
            Container(
              width: 6, height: 6,
              decoration: BoxDecoration(
                  shape: BoxShape.circle, color: badgeColor),
            ),
          const SizedBox(width: 5),
          Text(badgeText,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: badgeColor,
                letterSpacing: 0.3,
              )),
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
                const SizedBox(height: 6),
                _buildAiBadge(),
                const SizedBox(height: 28),
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

class _LegendRow extends StatelessWidget {
  final Color  color;
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

class _BoundingBoxPainter extends CustomPainter {
  final List<DetectedObject> detections;
  final int sensorOrientation;

  const _BoundingBoxPainter(this.detections, this.sensorOrientation);

  static const Color _danger   = Color(0xFFFF3232);
  static const Color _obstacle = Color(0xFFFF9532);
  static const Color _neutral  = Color(0xFF1A9FD6);

  Color _colorFor(String label) {
    if (kDangerClasses.contains(label))   return _danger;
    if (kObstacleClasses.contains(label)) return _obstacle;
    return _neutral;
  }

  // Map a normalized [0,1] landscape sensor point → portrait display [0,1].
  // sensorOrientation = 90 means the sensor is rotated 90° CW from natural portrait,
  // so we apply a 90° CW transform: (x,y) → (1-y, x).
  Offset _rotatePt(double x, double y) {
    switch (sensorOrientation) {
      case 90:  return Offset(1 - y, x);
      case 180: return Offset(1 - x, 1 - y);
      case 270: return Offset(y, 1 - x);
      default:  return Offset(x, y);
    }
  }

  Rect _transformBox(List<double> box, Size size) {
    final corners = [
      _rotatePt(box[0], box[1]),
      _rotatePt(box[2], box[1]),
      _rotatePt(box[0], box[3]),
      _rotatePt(box[2], box[3]),
    ];
    double minX = 1, minY = 1, maxX = 0, maxY = 0;
    for (final c in corners) {
      if (c.dx < minX) minX = c.dx;
      if (c.dy < minY) minY = c.dy;
      if (c.dx > maxX) maxX = c.dx;
      if (c.dy > maxY) maxY = c.dy;
    }
    // Clamp to widget bounds
    return Rect.fromLTRB(
      (minX * size.width).clamp(0.0, size.width),
      (minY * size.height).clamp(0.0, size.height),
      (maxX * size.width).clamp(0.0, size.width),
      (maxY * size.height).clamp(0.0, size.height),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    for (final det in detections) {
      final color = _colorFor(det.label);
      final rect  = _transformBox(det.box, size);
      if (rect.isEmpty) continue;

      // Semi-transparent fill so the box is always visible regardless of background
      canvas.drawRect(rect, Paint()
        ..color = color.withValues(alpha: 0.15)
        ..style = PaintingStyle.fill);

      // Border
      canvas.drawRect(rect, Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0);

      // Label: sits at the top-left corner of the box.
      // If the box starts at or near the top edge, the label goes inside; otherwise above.
      final labelText = '${det.label} ${(det.score * 100).round()}%';
      final tp = TextPainter(
        text: TextSpan(
          text: labelText,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.width);

      const labelH = 20.0;
      final labelW = tp.width + 10;
      // Place label above the box when there is room, otherwise inside at top
      final labelTop = rect.top >= labelH ? rect.top - labelH : rect.top;

      canvas.drawRect(
        Rect.fromLTWH(rect.left, labelTop, labelW, labelH),
        Paint()..color = color,
      );
      tp.paint(canvas, Offset(rect.left + 5, labelTop + (labelH - tp.height) / 2));
    }
  }

  @override
  bool shouldRepaint(_BoundingBoxPainter old) => old.detections != detections;
}
