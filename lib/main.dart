import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:battery_plus/battery_plus.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image_lib;
import 'package:permission_handler/permission_handler.dart';

import 'haptic_engine.dart';
import 'object_detector.dart';

// Use 10.0.2.2 for Android emulator; for a physical device set this to
// your PC's LAN IP (e.g. http://192.168.1.42:5000).
const String kBlipServerUrl = 'http://10.0.2.2:5000';

class BlipCaptionService {
  static Future<bool> isReachable() async {
    try {
      final resp = await http
          .get(Uri.parse('$kBlipServerUrl/health'))
          .timeout(const Duration(seconds: 2));
      return resp.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  static Future<String?> fetchCaption(CameraImage cameraImage) async {
    try {
      final jpegBytes = _cameraImageToJpeg(cameraImage);
      if (jpegBytes == null) return null;

      final b64 = base64Encode(jpegBytes);
      final resp = await http
          .post(
            Uri.parse('$kBlipServerUrl/caption'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'image': b64}),
          )
          .timeout(const Duration(seconds: 8));

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        return (data['caption'] as String?)?.trim();
      }
    } catch (_) {
    }
    return null;
  }

  static Uint8List? _cameraImageToJpeg(CameraImage img) {
    try {
      image_lib.Image? decoded;
      if (img.format.group == ImageFormatGroup.yuv420) {
        decoded = _yuv420ToImage(img);
      } else if (img.format.group == ImageFormatGroup.bgra8888) {
        decoded = image_lib.Image.fromBytes(
          width: img.width,
          height: img.height,
          bytes: img.planes[0].bytes.buffer,
          order: image_lib.ChannelOrder.bgra,
        );
      }
      if (decoded == null) return null;
      final resized = image_lib.copyResize(decoded, width: 480, height: 480);
      return image_lib.encodeJpg(resized, quality: 75);
    } catch (_) {
      return null;
    }
  }

  static image_lib.Image _yuv420ToImage(CameraImage img) {
    final w = img.width, h = img.height;
    final out = image_lib.Image(width: w, height: h);
    final yBytes  = img.planes[0].bytes;
    final uBytes  = img.planes[1].bytes;
    final vBytes  = img.planes[2].bytes;
    final yStride = img.planes[0].bytesPerRow;
    final uvStride = img.planes[1].bytesPerRow;
    final uvPixel  = img.planes[1].bytesPerPixel ?? 2;
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final uvIdx = uvPixel * (x ~/ 2) + uvStride * (y ~/ 2);
        final yIdx  = y * yStride + x;
        if (yIdx >= yBytes.length || uvIdx >= uBytes.length || uvIdx >= vBytes.length) break;
        final yp = yBytes[yIdx], up = uBytes[uvIdx], vp = vBytes[uvIdx];
        final r = (yp + 1.402   * (vp - 128)).toInt();
        final g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).toInt();
        final b = (yp + 1.772   * (up - 128)).toInt();
        out.setPixelRgb(x, y, r.clamp(0,255), g.clamp(0,255), b.clamp(0,255));
      }
    }
    return out;
  }
}

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
      case HapticPattern.danger:
        return const Color(0xFFFF3232);
      case HapticPattern.obstacle:
        return const Color(0xFFFF9532);
      case HapticPattern.systemReady:
        return const Color(0xFF32DC50);
      case HapticPattern.batteryLow:
        return const Color(0xFFDCDC32);
      default:
        return const Color(0xFF606060);
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
  String _lastSpokenCaption = '';

  bool _blipAvailable = false;
  bool _captionInFlight = false;

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
    _checkBlipServer();
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

  Future<void> _checkBlipServer() async {
    final ok = await BlipCaptionService.isReachable();
    if (mounted) setState(() => _blipAvailable = ok);
    if (ok) { debugPrint('[BLIP] Server is reachable ✓'); }
    else     { debugPrint('[BLIP] Server unreachable — using offline fallback'); }

    Timer.periodic(const Duration(seconds: 15), (t) async {
      if (!mounted) { t.cancel(); return; }
      final alive = await BlipCaptionService.isReachable();
      if (alive != _blipAvailable && mounted) {
        setState(() => _blipAvailable = alive);
        debugPrint('[BLIP] Server ${alive ? "back online" : "went offline"}');
      }
    });
  }

  void _startBatteryMonitor() {
    _checkBattery();
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
          await _haptic.stop();
        }
      }
    } catch (_) {
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
          _objectDetector.processImage(image).then((result) {
            if (!mounted) return;
            // Skip frames where the detector was still processing a previous frame.
            // Acting on these empty results causes the caption cooldown to fire
            // with "Clear ahead." and then block the real inference result.
            if (result.wasSkipped) return;

            final now = DateTime.now();

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

            if (now.difference(_lastCaptionTime).inSeconds >= 3 &&
                !_captionInFlight) {
              _lastCaptionTime = now;
              _captionInFlight = true;

              if (_blipAvailable) {
                BlipCaptionService.fetchCaption(image).then((blipCaption) {
                  _captionInFlight = false;
                  if (!mounted) return;
                  final caption = (blipCaption != null && blipCaption.isNotEmpty)
                      ? blipCaption
                      : _buildCaption(result.labels);
                  _applyCaption(caption, result.labels);
                });
              } else {
                _captionInFlight = false;
                final caption = _buildCaption(result.labels);
                _applyCaption(caption, result.labels);
              }
            }
          });
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  void _applyCaption(String newCaption, List<String> labels) {
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
      final gr = grooming.firstWhere(detected.contains,  orElse: () => '');
      if (gr.isNotEmpty) {
        return gr == 'toothbrush'
            ? 'A person brushing their teeth.' : 'A person using a hair dryer.';
      }

      final tc = tech.firstWhere(detected.contains,      orElse: () => '');
      if (tc.isNotEmpty) return 'A person with a ${tc.replaceAll(" ", " ")}.';

      final fd = food.firstWhere(detected.contains,      orElse: () => '');
      if (fd.isNotEmpty) return 'A person eating or drinking.';

      final sp = sports.firstWhere(detected.contains,    orElse: () => '');
      if (sp.isNotEmpty) return 'A person playing sports.';

      final an = animals.firstWhere(detected.contains,   orElse: () => '');
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
    final lower = label.toLowerCase();
    const vowels = {'a', 'e', 'i', 'o', 'u'};
    final article = vowels.contains(lower[0]) ? 'an' : 'a';
    return '$article $label';
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
    _flutterTts.stop();
    _controller?.dispose();
    _objectDetector.dispose();
    super.dispose();
  }

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
        Positioned.fill(
          child: ClipRect(
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

        Positioned(
          top: 12,
          right: 12,
          child: HapticIndicator(pattern: _hapticPattern),
        ),

        Positioned(
          bottom: 8,
          right: 8,
          child: _buildLegend(),
        ),
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
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                  decoration: BoxDecoration(
                    color: _blipAvailable
                        ? const Color(0xFF1A9FD6).withValues(alpha: 0.12)
                        : Colors.grey.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _blipAvailable
                          ? const Color(0xFF1A9FD6)
                          : Colors.grey,
                      width: 0.8,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6, height: 6,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _blipAvailable
                              ? const Color(0xFF1A9FD6)
                              : Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Text(
                        _blipAvailable ? 'BLIP AI Captions' : 'Offline Captions',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: _blipAvailable
                              ? const Color(0xFF1A9FD6)
                              : Colors.grey,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ),
                ),
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
