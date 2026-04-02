import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() {
  test('inspect tflite model', () {
    final modelBytes = File('assets/models/best_int8.tflite').readAsBytesSync();
    final interpreter = Interpreter.fromBuffer(modelBytes);

    print('Inputs:');
    for (var tensor in interpreter.getInputTensors()) {
      print('  - Name: ${tensor.name}');
      print('  - Shape: ${tensor.shape}');
      print('  - Type: ${tensor.type}');
    }

    print('Outputs:');
    for (var tensor in interpreter.getOutputTensors()) {
      print('  - Name: ${tensor.name}');
      print('  - Shape: ${tensor.shape}');
      print('  - Type: ${tensor.type}');
    }
    
    interpreter.close();
  });
}
