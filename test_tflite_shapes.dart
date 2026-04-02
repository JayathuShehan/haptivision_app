import 'dart:io';
import 'dart:typed_data';
import 'package:tflite_flutter/tflite_flutter.dart';

void main() async {
  try {
    final modelFile = File('assets/models/best_int8.tflite');
    final modelBytes = await modelFile.readAsBytes();
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
  } catch (e) {
    print('Error: $e');
  }
}
