import 'package:flutter/services.dart';
import 'package:saber/components/canvas/_stroke.dart';

class SaberDigitalInkResult {
  const SaberDigitalInkResult(this.status, this.candidates);
  final String status;
  final List<String> candidates;
  String? get text => candidates.isEmpty ? null : candidates.first;
}

class SaberDigitalInkRecognizer {
  static const _channel = MethodChannel('saber/digital_ink');

  Future<SaberDigitalInkResult> recognizeChinese(
    List<Stroke> strokes, {
    required Size writingArea,
  }) async {
    try {
      final raw = await _channel.invokeMapMethod<String, dynamic>(
        'recognizeChinese',
        {
          'strokes': strokes
              .map((stroke) => stroke.digitalInkPoints())
              .toList(),
          'writingArea': {
            'width': writingArea.width,
            'height': writingArea.height,
          },
        },
      );
      final candidates = (raw?['candidates'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .where((text) => text.trim().isNotEmpty)
          .toList(growable: false);
      return SaberDigitalInkResult(
        raw?['status'] as String? ?? 'unavailable',
        candidates,
      );
    } on MissingPluginException {
      return const SaberDigitalInkResult('unsupported_platform', []);
    } on PlatformException {
      return const SaberDigitalInkResult('unavailable', []);
    }
  }
}
