import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img_lib;
import 'package:onnxruntime/onnxruntime.dart';

// ═══════════════════════════════════════════════════════════════════
// TENSOR NAME CONSTANTS
// If the Python export script prints different names, update here.
// ═══════════════════════════════════════════════════════════════════
const String _kEncInput        = 'pixel_values';
const String _kDecInputIds     = 'input_ids';
const String _kDecAttnMask     = 'attention_mask';
const String _kDecEncHidden    = 'encoder_hidden_states';
const String _kDecEncAttnMask  = 'encoder_attention_mask';

// ═══════════════════════════════════════════════════════════════════
// BLIP CONSTANTS
// ═══════════════════════════════════════════════════════════════════
const int    _imgSize    = 384;
const int    _numPatches = 577;   // (384/16)² + 1 CLS token
const int    _hiddenDim  = 768;
const int    _clsToken   = 101;
const int    _sepToken   = 102;
const int    _padToken   = 0;
const int    _maxTokens  = 30;

// BLIP image normalisation (matches BlipImageProcessor defaults)
const List<double> _mean = [0.48145466, 0.4578275,  0.40821073];
const List<double> _std  = [0.26862954, 0.26130258, 0.27577711];

// ═══════════════════════════════════════════════════════════════════
// ISOLATE MESSAGES
// ═══════════════════════════════════════════════════════════════════

class _InitMsg {
  final Uint8List encoderBytes;
  final Uint8List decoderBytes;
  final String    vocabJson;
  final SendPort  reply;
  _InitMsg(this.encoderBytes, this.decoderBytes, this.vocabJson, this.reply);
}

class _InferMsg {
  final int                      id;
  final List<Map<String,dynamic>> planes;
  final int                      width;
  final int                      height;
  final ImageFormatGroup         fmt;
  final SendPort                 reply;
  _InferMsg(this.id, this.planes, this.width, this.height, this.fmt, this.reply);
}

class _InferReply {
  final int     id;
  final String? caption;
  _InferReply(this.id, this.caption);
}

// ═══════════════════════════════════════════════════════════════════
// ISOLATE ENTRY POINT  (runs in background, never blocks UI)
// ═══════════════════════════════════════════════════════════════════

void _blipIsolateMain(SendPort mainPort) {
  final port = ReceivePort();
  mainPort.send(port.sendPort);

  OrtSession?       encoder;
  OrtSession?       decoder;
  Map<int, String>? vocab;

  port.listen((msg) {
    // ── Initialise sessions ─────────────────────────────────────
    if (msg is _InitMsg) {
      try {
        OrtEnv.instance.init();
        final opts = OrtSessionOptions()
          ..setInterOpNumThreads(2)
          ..setIntraOpNumThreads(2);
        encoder = OrtSession.fromBuffer(msg.encoderBytes, opts);
        decoder = OrtSession.fromBuffer(msg.decoderBytes, opts);
        final raw = jsonDecode(msg.vocabJson) as Map<String, dynamic>;
        vocab   = { for (final e in raw.entries) int.parse(e.key): e.value as String };
        msg.reply.send(true);
      } catch (e) {
        msg.reply.send(false);
      }
      return;
    }

    // ── Run captioning inference ────────────────────────────────
    if (msg is _InferMsg) {
      if (encoder == null || decoder == null || vocab == null) {
        msg.reply.send(_InferReply(msg.id, null));
        return;
      }
      try {
        final caption = _caption(encoder!, decoder!, vocab!, msg);
        msg.reply.send(_InferReply(msg.id, caption));
      } catch (e, st) {
        dev.log('[BLIP isolate] error: $e\n$st');
        msg.reply.send(_InferReply(msg.id, null));
      }
    }
  });
}

// ═══════════════════════════════════════════════════════════════════
// FULL INFERENCE PIPELINE  (runs inside the background isolate)
// ═══════════════════════════════════════════════════════════════════

String? _caption(
  OrtSession       encoder,
  OrtSession       decoder,
  Map<int, String> vocab,
  _InferMsg        req,
) {
  // ── 1. Decode camera image ────────────────────────────────────
  final raw = _decodeCamera(req.planes, req.width, req.height, req.fmt);
  if (raw == null) return null;

  // ── 2. Resize + BLIP normalise → Float32 CHW [1,3,384,384] ──
  final resized     = img_lib.copyResize(raw, width: _imgSize, height: _imgSize);
  final pixelValues = Float32List(3 * _imgSize * _imgSize);
  for (int y = 0; y < _imgSize; y++) {
    for (int x = 0; x < _imgSize; x++) {
      final px  = resized.getPixelSafe(x, y);
      final pos = y * _imgSize + x;
      pixelValues[0 * _imgSize * _imgSize + pos] = (px.r / 255.0 - _mean[0]) / _std[0];
      pixelValues[1 * _imgSize * _imgSize + pos] = (px.g / 255.0 - _mean[1]) / _std[1];
      pixelValues[2 * _imgSize * _imgSize + pos] = (px.b / 255.0 - _mean[2]) / _std[2];
    }
  }

  // ── 3. Run vision encoder ─────────────────────────────────────
  final encIn = OrtValueTensor.createTensorWithDataList(
      pixelValues, [1, 3, _imgSize, _imgSize]);
  final encOuts = encoder.run(OrtRunOptions(), {_kEncInput: encIn});
  encIn.release();

  // Flatten last_hidden_state [1, 577, 768] → flat Float32List
  final hiddenFlat = Float32List(_numPatches * _hiddenDim);
  _flattenInto(encOuts[0]?.value, hiddenFlat);
  for (final v in encOuts) { v?.release(); }

  // ── 4. Greedy autoregressive decode ───────────────────────────
  // encoder_attention_mask: all-ones [1, 577]
  final encAttn = Int64List(_numPatches)..fillRange(0, _numPatches, 1);

  var inputIds = Int64List.fromList([_clsToken]);
  final generated = <int>[];

  for (int step = 0; step < _maxTokens; step++) {
    final seqLen  = inputIds.length;
    final attnMask = Int64List(seqLen)..fillRange(0, seqLen, 1);

    final tIds    = OrtValueTensor.createTensorWithDataList(inputIds,   [1, seqLen]);
    final tAttn   = OrtValueTensor.createTensorWithDataList(attnMask,   [1, seqLen]);
    final tHidden = OrtValueTensor.createTensorWithDataList(hiddenFlat, [1, _numPatches, _hiddenDim]);
    final tEncA   = OrtValueTensor.createTensorWithDataList(encAttn,    [1, _numPatches]);

    final decOuts = decoder.run(OrtRunOptions(), {
      _kDecInputIds    : tIds,
      _kDecAttnMask    : tAttn,
      _kDecEncHidden   : tHidden,
      _kDecEncAttnMask : tEncA,
    });

    tIds.release();
    tAttn.release();
    tHidden.release();
    tEncA.release();

    final rawLogits = decOuts[0]?.value;
    for (final v in decOuts) { v?.release(); }
    if (rawLogits == null) break;

    // argmax over vocab at last sequence position
    final nextToken = _argmaxLastPos(rawLogits, seqLen);
    if (nextToken == _sepToken || nextToken == _padToken) break;

    generated.add(nextToken);

    // Extend input_ids by one token
    final extended = Int64List(seqLen + 1);
    extended.setAll(0, inputIds);
    extended[seqLen] = nextToken;
    inputIds = extended;
  }

  // ── 5. Decode token IDs → string ─────────────────────────────
  return _idsToText(generated, vocab);
}

// ── Argmax of the last sequence position in logits ─────────────────

int _argmaxLastPos(dynamic raw, int seqLen) {
  // raw shape: [1][seqLen][vocabSize]
  final lastPos = (raw as List)[0][seqLen - 1] as List;
  double best = double.negativeInfinity;
  int    idx  = 0;
  for (int i = 0; i < lastPos.length; i++) {
    final v = (lastPos[i] as num).toDouble();
    if (v > best) {
      best = v;
      idx  = i;
    }
  }
  return idx;
}

// ── Recursive flatten of a nested List into a Float32List ──────────

void _flattenInto(dynamic nested, Float32List out) {
  int i = 0;
  void walk(dynamic v) {
    if (v is List) {
      for (final e in v) { walk(e); }
    } else {
      out[i++] = (v as num).toDouble();
    }
  }
  walk(nested);
}

// ── Token IDs → human-readable string (BERT WordPiece rules) ───────

String _idsToText(List<int> ids, Map<int, String> vocab) {
  final buf = StringBuffer();
  for (int i = 0; i < ids.length; i++) {
    final tok = vocab[ids[i]] ?? '';
    if (tok.isEmpty || tok.startsWith('[')) continue;  // skip special tokens
    if (tok.startsWith('##')) {
      buf.write(tok.substring(2));                     // suffix: no space
    } else {
      if (buf.isNotEmpty) buf.write(' ');
      buf.write(tok);
    }
  }
  return buf.toString().trim();
}

// ── Camera image → img_lib.Image ────────────────────────────────────

img_lib.Image? _decodeCamera(
  List<Map<String, dynamic>> planes,
  int width,
  int height,
  ImageFormatGroup fmt,
) {
  if (fmt == ImageFormatGroup.yuv420) {
    return _yuv420(planes, width, height);
  } else if (fmt == ImageFormatGroup.bgra8888) {
    return img_lib.Image.fromBytes(
      width:  width,
      height: height,
      bytes:  (planes[0]['bytes'] as Uint8List).buffer,
      order:  img_lib.ChannelOrder.bgra,
    );
  }
  return null;
}

img_lib.Image _yuv420(List<Map<String, dynamic>> planes, int w, int h) {
  final out = img_lib.Image(width: w, height: h);
  final yB  = planes[0]['bytes'] as Uint8List;
  final uB  = planes[1]['bytes'] as Uint8List;
  final vB  = planes[2]['bytes'] as Uint8List;
  final yS  = planes[0]['bytesPerRow'] as int? ?? w;
  final uvS = planes[1]['bytesPerRow'] as int? ?? (w ~/ 2);
  final uvP = planes[1]['bytesPerPixel'] as int? ?? 2;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final uvIdx = uvP * (x ~/ 2) + uvS * (y ~/ 2);
      final yIdx  = y * yS + x;
      if (yIdx >= yB.length || uvIdx >= uB.length || uvIdx >= vB.length) break;
      final yp = yB[yIdx], up = uB[uvIdx], vp = vB[uvIdx];
      out.setPixelRgb(
        x, y,
        (yp + 1.402   * (vp - 128)).toInt().clamp(0, 255),
        (yp - 0.344136 * (up - 128) - 0.714136 * (vp - 128)).toInt().clamp(0, 255),
        (yp + 1.772   * (up - 128)).toInt().clamp(0, 255),
      );
    }
  }
  return out;
}

// ═══════════════════════════════════════════════════════════════════
// PUBLIC API  (used from main.dart)
// ═══════════════════════════════════════════════════════════════════

enum BlipState { idle, loading, ready, failed }

class BlipLocalCaptionService {
  BlipLocalCaptionService._();
  static final BlipLocalCaptionService instance = BlipLocalCaptionService._();

  Isolate?  _isolate;
  SendPort? _port;
  BlipState _state = BlipState.idle;
  bool      _busy  = false;
  int       _nextId = 0;

  BlipState get state => _state;

  /// Call once from initState. Safe to call again if previously failed.
  Future<void> init() async {
    if (_state == BlipState.loading || _state == BlipState.ready) return;
    _state = BlipState.loading;
    dev.log('[BLIP] Loading on-device models...');

    try {
      // Load bytes on main isolate — rootBundle not available in isolates
      final encData  = await rootBundle.load('assets/models/encoder_int8.onnx');
      final decData  = await rootBundle.load('assets/models/decoder_int8.onnx');
      final vocabStr = await rootBundle.loadString('assets/models/blip_vocab.json');

      final handshake = ReceivePort();
      _isolate = await Isolate.spawn(_blipIsolateMain, handshake.sendPort);

      // Handshake: get isolate's SendPort
      final spCompleter = Completer<SendPort>();
      late StreamSubscription sub;
      sub = handshake.listen((m) {
        if (m is SendPort) { spCompleter.complete(m); sub.cancel(); handshake.close(); }
      });
      _port = await spCompleter.future;

      // Send model bytes to isolate, wait for init confirmation
      final initPort = ReceivePort();
      final initDone = Completer<bool>();
      initPort.listen((m) { if (m is bool) { initDone.complete(m); initPort.close(); } });

      _port!.send(_InitMsg(
        encData.buffer.asUint8List(),
        decData.buffer.asUint8List(),
        vocabStr,
        initPort.sendPort,
      ));

      final ok = await initDone.future;
      _state = ok ? BlipState.ready : BlipState.failed;
      dev.log(ok ? '[BLIP] On-device models ready ✓' : '[BLIP] Model init failed ✗');
    } catch (e) {
      _state = BlipState.failed;
      dev.log('[BLIP] Init error: $e');
    }
  }

  /// Returns a caption string, or null if unavailable / busy.
  Future<String?> generateCaption(CameraImage image) async {
    if (_state != BlipState.ready || _busy) return null;
    _busy = true;
    final id = _nextId++;

    try {
      final planes = image.planes.map((p) => {
        'bytes':        p.bytes,
        'bytesPerRow':  p.bytesPerRow,
        'bytesPerPixel': p.bytesPerPixel,
      }).toList();

      final replyPort = ReceivePort();
      final completer = Completer<_InferReply>();
      replyPort.listen((m) {
        if (m is _InferReply) { completer.complete(m); replyPort.close(); }
      });

      _port!.send(_InferMsg(
        id, planes, image.width, image.height, image.format.group,
        replyPort.sendPort,
      ));

      final reply = await completer.future;
      return (reply.caption?.isNotEmpty ?? false) ? reply.caption : null;
    } finally {
      _busy = false;
    }
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _state   = BlipState.idle;
  }
}
