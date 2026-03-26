import 'dart:developer' as dev;
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as image_lib;
import 'package:tflite_flutter/tflite_flutter.dart';

class ObjectDetector {
  Interpreter? _interpreter;
  List<String>? _labels;
  bool _isProcessing = false;

  Future<void> loadModel() async {
    try {
      final options = InterpreterOptions();
      _interpreter = await Interpreter.fromAsset('assets/models/best_int8.tflite', options: options);
      
      final labelData = await rootBundle.loadString('assets/models/labels.txt');
      _labels = labelData.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
      dev.log('Model and labels loaded successfully.');
    } catch (e) {
      dev.log('Error loading model: $e');
    }
  }

  Future<List<String>> processImage(CameraImage? cameraImage) async {
    if (_interpreter == null || _labels == null || cameraImage == null || _isProcessing) {
      return [];
    }

    _isProcessing = true;
    try {
      final format = cameraImage.format.group;
      final planes = cameraImage.planes.map((p) => {
        'bytes': p.bytes,
        'bytesPerRow': p.bytesPerRow,
        'bytesPerPixel': p.bytesPerPixel,
      }).toList();

      // Convert image to Float32List in an isolate
      final inputList = await Isolate.run(() {
        return _convertCameraImageToFloat32(
          planes,
          cameraImage.width,
          cameraImage.height,
          format,
        );
      });

      if (inputList == null) {
        _isProcessing = false;
        return [];
      }

      final inputShape = _interpreter!.getInputTensor(0).shape; // [1, 640, 640, 3]
      final outputShape = _interpreter!.getOutputTensor(0).shape; // [1, 84, 8400]

      var inputArray = [inputList.reshape([inputShape[1], inputShape[2], inputShape[3]])];
      var outputArray = List.generate(
        outputShape[0],
        (_) => List.generate(
          outputShape[1],
          (_) => List.filled(outputShape[2], 0.0),
        ),
      );

      _interpreter!.run(inputArray, outputArray);

      // Extract labels with basic NMS in an isolate
      final detectedIndices = await Isolate.run(() {
        return _processYoloOutput(outputArray[0]);
      });

      final Set<String> detectedLabels = {};
      for (var idx in detectedIndices) {
        if (idx >= 0 && idx < _labels!.length) {
          detectedLabels.add(_labels![idx]);
        }
      }

      _isProcessing = false;
      return detectedLabels.toList();
    } catch (e) {
      _isProcessing = false;
      dev.log('Error processing image: $e');
      return [];
    }
  }
}

// ================= Isolate Functions =================

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

    final resized = image_lib.copyResize(img!, width: 640, height: 640);
    
    final float32list = Float32List(1 * 640 * 640 * 3);
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
  } catch (e) {
    return null;
  }
}

List<int> _processYoloOutput(List<List<double>> output) {
  final numBoxes = output[0].length; 
  final numClasses = output.length - 4; 

  List<Map<String, dynamic>> boxes = [];
  const double confThreshold = 0.5;

  for (int i = 0; i < numBoxes; i++) {
    double maxClassConf = 0;
    int maxClassId = -1;

    for (int c = 0; c < numClasses; c++) {
      double conf = output[c + 4][i];
      if (conf > maxClassConf) {
        maxClassConf = conf;
        maxClassId = c;
      }
    }

    if (maxClassConf > confThreshold) {
      double xc = output[0][i];
      double yc = output[1][i];
      double w = output[2][i];
      double h = output[3][i];

      boxes.add({
        'box': [xc - w / 2, yc - h / 2, xc + w / 2, yc + h / 2],
        'score': maxClassConf,
        'class': maxClassId
      });
    }
  }

  boxes.sort((a, b) => (b['score'] as double).compareTo(a['score'] as double));
  List<int> resultObjects = [];
  List<Map<String, dynamic>> keptBoxes = [];
  
  for (var box in boxes) {
    bool keep = true;
    for (var keptBox in keptBoxes) {
      if (box['class'] == keptBox['class']) {
        double iou = _computeIou(box['box'], keptBox['box']);
        if (iou > 0.45) {
          keep = false;
          break;
        }
      }
    }
    if (keep) {
      keptBoxes.add(box);
      resultObjects.add(box['class']);
    }
  }
  return resultObjects;
}

double _computeIou(List<double> boxA, List<double> boxB) {
  double xA = max(boxA[0], boxB[0]);
  double yA = max(boxA[1], boxB[1]);
  double xB = min(boxA[2], boxB[2]);
  double yB = min(boxA[3], boxB[3]);
  
  double interArea = max(0, xB - xA) * max(0, yB - yA);
  double boxAArea = (boxA[2] - boxA[0]) * (boxA[3] - boxA[1]);
  double boxBArea = (boxB[2] - boxB[0]) * (boxB[3] - boxB[1]);
  
  if (boxAArea + boxBArea - interArea <= 0) return 0;
  return interArea / (boxAArea + boxBArea - interArea);
}

image_lib.Image _convertYUV420ToImage(List<Map<String, dynamic>> planes, int width, int height) {
  final image = image_lib.Image(width: width, height: height);

  final yBytes = planes[0]['bytes'] as Uint8List;
  final uBytes = planes[1]['bytes'] as Uint8List;
  final vBytes = planes[2]['bytes'] as Uint8List;

  final yRowStride = planes[0]['bytesPerRow'] as int;
  final uvRowStride = planes[1]['bytesPerRow'] as int;
  final uvPixelStride = planes[1]['bytesPerPixel'] as int;

  for (int x = 0; x < width; x++) {
    for (int y = 0; y < height; y++) {
      final uvIndex = uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);
      final index = y * yRowStride + x;

      final yp = yBytes[index];
      final up = uBytes[uvIndex];
      final vp = vBytes[uvIndex];

      int r = (yp + 1.402 * (vp - 128)).toInt();
      int g = (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).toInt();
      int b = (yp + 1.772 * (up - 128)).toInt();

      image.setPixelRgb(x, y, r.clamp(0, 255), g.clamp(0, 255), b.clamp(0, 255));
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
          return List.generate(shape[2], (_) {
            return this[idx++];
          });
        });
      });
    }
    return [];
  }
}
