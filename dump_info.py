import tensorflow as tf
import pprint

interpreter = tf.lite.Interpreter(model_path='assets/models/best_int8.tflite')
interpreter.allocate_tensors()

with open('model_info.txt', 'w') as f:
    f.write("INPUT:\n")
    f.write(pprint.pformat(interpreter.get_input_details()))
    f.write("\n\nOUTPUT:\n")
    f.write(pprint.pformat(interpreter.get_output_details()))
