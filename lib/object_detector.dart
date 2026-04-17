import 'dart:async';
import 'dart:developer' as dev;
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'package:tflite_flutter/tflite_flutter.dart';
import 'haptic_engine.dart';

class DetectionResult {
  final List<String> labels;
  final HapticCategory category;
  const DetectionResult(this.labels, this.category);
  static const empty = DetectionResult([], HapticCategory.clear);
}

class _ModelBytesPayload {
  final Uint8List modelBytes;
  final List<String> labels;
  final SendPort replyPort;
  _ModelBytesPayload(this.modelBytes, this.labels, this.replyPort);
}

class _InferenceRequest {
  final int id;
  final List<Map<String, dynamic>> planes;
  final int width;
  final int height;
  final ImageFormatGroup formatGroup;
  final SendPort replyPort;
  _InferenceRequest(this.id, this.planes, this.width, this.height,
      this.formatGroup, this.replyPort);
}

class _InferenceReply {
  final int id;
  final List<int> detectedIndices;
  _InferenceReply(this.id, this.detectedIndices);
}

void _inferenceIsolateMain(SendPort mainSendPort) {
  final receivePort = ReceivePort();
  mainSendPort.send(receivePort.sendPort);

  Interpreter? interpreter;
  List<String>? labels;

  receivePort.listen((message) {
    if (message is _ModelBytesPayload) {
      try {
        interpreter = Interpreter.fromBuffer(message.modelBytes);
        labels = message.labels;
        message.replyPort.send(true);
      } catch (e) {
        message.replyPort.send(false);
      }
      return;
    }

    if (message is _InferenceRequest) {
      if (interpreter == null || labels == null) {
        message.replyPort.send(_InferenceReply(message.id, []));
        return;
      }
      try {
        final inputList = _convertCameraImageToFloat32(
          message.planes,
          message.width,
          message.height,
          message.formatGroup,
        );
        if (inputList == null) {
          message.replyPort.send(_InferenceReply(message.id, []));
          return;
        }

        final inputShape = interpreter!.getInputTensor(0).shape;
        final outputShape = interpreter!.getOutputTensor(0).shape;

        final inputArray = [
          inputList.reshape([inputShape[1], inputShape[2], inputShape[3]])
        ];
        final outputArray = List.generate(
          outputShape[0],
          (_) => List.generate(
            outputShape[1],
            (_) => List.filled(outputShape[2], 0.0),
          ),
        );

        interpreter!.run(inputArray, outputArray);

        final indices = _processYoloOutput(outputArray[0]);
        if (indices.isNotEmpty) dev.log('Detections: $indices');
        message.replyPort.send(_InferenceReply(message.id, indices));
      } catch (e, st) {
        dev.log('Inference Isolate run error: $e\n$st');
        message.replyPort.send(_InferenceReply(message.id, []));
      }
    }
  });
}

class ObjectDetector {
  Isolate? _isolate;
  SendPort? _isolateSendPort;
  List<String>? _labels;
  bool _ready = false;
  bool _isProcessing = false;
  int _nextId = 0;

  Future<void> loadModel() async {
    try {
      final modelData = await rootBundle.load('assets/models/best_int8.tflite');
      final modelBytes = modelData.buffer.asUint8List();

      final labelData = await rootBundle.loadString('assets/models/labels.txt');
      _labels = labelData
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final handshakePort = ReceivePort();
      _isolate = await Isolate.spawn(
        _inferenceIsolateMain,
        handshakePort.sendPort,
      );

      final handshakeCompleter = Completer<SendPort>();
      late StreamSubscription sub;
      sub = handshakePort.listen((msg) {
        if (msg is SendPort) {
          handshakeCompleter.complete(msg);
          sub.cancel();
          handshakePort.close();
        }
      });
      _isolateSendPort = await handshakeCompleter.future;

      final initReplyPort = ReceivePort();
      final initCompleter = Completer<bool>();
      initReplyPort.listen((msg) {
        if (msg is bool) {
          initCompleter.complete(msg);
          initReplyPort.close();
        }
      });
      _isolateSendPort!.send(
        _ModelBytesPayload(modelBytes, _labels!, initReplyPort.sendPort),
      );
      _ready = await initCompleter.future;

      dev.log(_ready
          ? 'ObjectDetector: model loaded on background isolate ✓'
          : 'ObjectDetector: model init failed on isolate ✗');
    } catch (e) {
      dev.log('ObjectDetector.loadModel error: $e');
    }
  }

  Future<DetectionResult> processImage(CameraImage? cameraImage) async {
    if (!_ready || cameraImage == null || _isProcessing) {
      return DetectionResult.empty;
    }

    _isProcessing = true;
    final id = _nextId++;

    try {
      final planes = cameraImage.planes
          .map((p) => {
                'bytes': p.bytes,
                'bytesPerRow': p.bytesPerRow,
                'bytesPerPixel': p.bytesPerPixel,
              })
          .toList();

      final replyPort = ReceivePort();
      final completer = Completer<_InferenceReply>();
      replyPort.listen((msg) {
        if (msg is _InferenceReply) {
          completer.complete(msg);
          replyPort.close();
        }
      });

      _isolateSendPort!.send(_InferenceRequest(
        id,
        planes,
        cameraImage.width,
        cameraImage.height,
        cameraImage.format.group,
        replyPort.sendPort,
      ));

      final reply = await completer.future;

      final Set<String> detectedLabels = {};
      for (var idx in reply.detectedIndices) {
        if (idx >= 0 && idx < _labels!.length) {
          detectedLabels.add(_labels![idx]);
        }
      }

      _isProcessing = false;
      final labels = detectedLabels.toList();
      return DetectionResult(labels, categoryFromLabels(labels));
    } catch (e) {
      _isProcessing = false;
      dev.log('ObjectDetector.processImage error: $e');
      return DetectionResult.empty;
    }
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _ready = false;
  }
}

Float32List? _convertCameraImageToFloat32(
  List<Map<String, dynamic>> planes,
  int width,
  int height,
  ImageFormatGroup formatGroup,
) {
  try {
    image_lib.Image? img;
    if (formatGroup == ImageFormatGroup.yuv420) {
      img = _convertYUV420ToImage(planes, width, height);
    } else if (formatGroup == ImageFormatGroup.bgra8888) {
      final bytes = planes[0]['bytes'] as Uint8List;
      img = image_lib.Image.fromBytes(
        width: width,
        height: height,
        bytes: bytes.buffer,
        order: image_lib.ChannelOrder.bgra,
      );
    } else {
      return null;
    }

    final resized = image_lib.copyResize(img, width: 640, height: 640);

    final float32list = Float32List(640 * 640 * 3);
    int p = 0;
    for (int y = 0; y < resized.height; y++) {
      for (int x = 0; x < resized.width; x++) {
        final pixel = resized.getPixelSafe(x, y);
        float32list[p++] = pixel.r / 255.0;
        float32list[p++] = pixel.g / 255.0;
        float32list[p++] = pixel.b / 255.0;
      }
    }
    return float32list;
  } catch (e, st) {
    dev.log('Image conversion error: $e\n$st');
    return null;
  }
}

List<int> _processYoloOutput(List<List<double>> output) {
  final numBoxes = output[0].length;
  final numClasses = output.length - 4;

  final List<Map<String, dynamic>> boxes = [];
  const double confThreshold = 0.25;

  for (int i = 0; i < numBoxes; i++) {
    double maxConf = 0;
    int maxClass = -1;
    for (int c = 0; c < numClasses; c++) {
      final conf = output[c + 4][i];
      if (conf > maxConf) {
        maxConf = conf;
        maxClass = c;
      }
    }
    if (maxConf > confThreshold) {
      final xc = output[0][i], yc = output[1][i];
      final w = output[2][i], h = output[3][i];
      boxes.add({
        'box': [xc - w / 2, yc - h / 2, xc + w / 2, yc + h / 2],
        'score': maxConf,
        'class': maxClass,
      });
    }
  }

  boxes.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));

  final List<int> result = [];
  final List<Map<String, dynamic>> kept = [];

  for (final box in boxes) {
    bool keep = true;
    for (final keptBox in kept) {
      if (box['class'] == keptBox['class'] &&
          _computeIou(box['box'], keptBox['box']) > 0.45) {
        keep = false;
        break;
      }
    }
    if (keep) {
      kept.add(box);
      result.add(box['class'] as int);
    }
  }
  return result;
}

double _computeIou(List<double> a, List<double> b) {
  final xA = max(a[0], b[0]), yA = max(a[1], b[1]);
  final xB = min(a[2], b[2]), yB = min(a[3], b[3]);
  final inter = max(0.0, xB - xA) * max(0.0, yB - yA);
  final union =
      (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - inter;
  return union <= 0 ? 0 : inter / union;
}

image_lib.Image _convertYUV420ToImage(
    List<Map<String, dynamic>> planes, int width, int height) {
  final image = image_lib.Image(width: width, height: height);

  final yBytes = planes[0]['bytes'] as Uint8List;
  final uBytes = planes[1]['bytes'] as Uint8List;
  final vBytes = planes[2]['bytes'] as Uint8List;

  final yRowStride = planes[0]['bytesPerRow'] as int? ?? width;
  final uvRowStride = planes[1]['bytesPerRow'] as int? ?? (width ~/ 2);
  final uvPixelStride = planes[1]['bytesPerPixel'] as int? ?? 2;

  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
      final index = y * yRowStride + x;
      
      if (index >= yBytes.length || uvIndex >= uBytes.length || uvIndex >= vBytes.length) {
        break;
      }
      
      final yp = yBytes[index];
      final up = uBytes[uvIndex];
      final vp = vBytes[uvIndex];
      final r = (yp + 1.402 * (vp - 128)).toInt();
      final g =
          (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).toInt();
      final bl = (yp + 1.772 * (up - 128)).toInt();
      image.setPixelRgb(
          x, y, r.clamp(0, 255), g.clamp(0, 255), bl.clamp(0, 255));
    }
  }
  return image;
}

extension Float32ListReshape on Float32List {
  List<dynamic> reshape(List<int> shape) {
    if (shape.length == 3) {
      int idx = 0;
      return List.generate(shape[0], (_) {
        return List.generate(shape[1], (_) {
          return List.generate(shape[2], (_) => this[idx++]);
        });
      });
    }
    return [];
  }
}
