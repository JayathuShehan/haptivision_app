import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_tts/flutter_tts.dart';
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
  String _currentCaption = "Analyzing environment...";
  DateTime _lastCaptionTime = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initTts();
    _objectDetector.loadModel();
    _initCamera();
  }

  Future<void> _initTts() async {
    await _flutterTts.setLanguage("en-US");
    await _flutterTts.setSpeechRate(0.5);
  }

  Future<void> _initCamera() async {
    // Request camera permission at runtime
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      setState(() {
        _permissionGranted = false;
      });
      return;
    }

    setState(() => _permissionGranted = true);

    if (_cameras.isEmpty) return;

    // Use the first back-facing camera if available, otherwise fallback
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
        
        _controller!.startImageStream((CameraImage image) async {
          final now = DateTime.now();
          if (now.difference(_lastCaptionTime).inSeconds >= 3) {
            _lastCaptionTime = now;
            
            final detectedLabels = await _objectDetector.processImage(image);
            if (detectedLabels.isNotEmpty) {
              String newCaption;
              if (detectedLabels.length == 1) {
                newCaption = "There is a ${detectedLabels.first} in front of you.";
              } else if (detectedLabels.length == 2) {
                newCaption = "I see a ${detectedLabels[0]} and a ${detectedLabels[1]}.";
              } else {
                final last = detectedLabels.removeLast();
                newCaption = "I see ${detectedLabels.join(', ')}, and a $last.";
              }
              
              if (_currentCaption != newCaption && mounted) {
                setState(() => _currentCaption = newCaption);
                _flutterTts.speak(newCaption);
              }
            }
          }
        });
      }
    } catch (e) {
      debugPrint('Camera init error: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    if (state == AppLifecycleState.inactive) {
      controller.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initCamera();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
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
            const Text(
              'Camera permission denied',
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: openAppSettings,
              child: const Text(
                'Open Settings',
                style: TextStyle(color: Color(0xFF1A9FD6)),
              ),
            ),
          ],
        ),
      );
    }

    if (!_initialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Colors.white38),
      );
    }

    return ClipRect(
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
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          // ── Upper half: Logo + Caption ──────────────────────────────
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Logo
                const Text(
                  'HaptiVision',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1A9FD6),
                    letterSpacing: 0.5,
                  ),
                ),

                const SizedBox(height: 48),

                // Dynamic caption sentence
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _currentCaption,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w400,
                      color: Colors.black87,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Lower half: Live Camera Preview ─────────────────────────
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
