import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

enum SaberPiMode { quiet, seek }

enum SaberPiPhase { rest, awakening, awaitingConfirmation, ready, quiet }

class SaberPiBridgeException implements Exception {
  const SaberPiBridgeException(this.message);

  final String message;

  @override
  String toString() => 'SaberPiBridgeException: $message';
}

class SaberPiTranscription {
  const SaberPiTranscription({required this.text, required this.candidates});

  final String text;
  final List<String> candidates;

  factory SaberPiTranscription.fromJson(Map<String, dynamic> json) {
    final text = json['text'];
    if (text is! String || text.trim().isEmpty) {
      throw const SaberPiBridgeException('invalid_transcription');
    }
    final candidates = (json['candidates'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .toList(growable: false);
    return SaberPiTranscription(text: text, candidates: candidates);
  }
}

class SaberPiBridgeResult {
  const SaberPiBridgeResult({
    required this.status,
    required this.stage,
    required this.originalInkRetained,
    this.transcription,
    this.outcome,
    this.providerStatus,
  });

  final String status;
  final String stage;
  final bool originalInkRetained;
  final SaberPiTranscription? transcription;
  final Map<String, dynamic>? outcome;
  final String? providerStatus;

  factory SaberPiBridgeResult.fromJson(Map<String, dynamic> json) {
    final status = json['status'];
    final stage = json['stage'];
    final originalInk = json['originalInk'];
    if (status is! String ||
        stage is! String ||
        originalInk != 'retained_by_saber') {
      throw const SaberPiBridgeException('invalid_bridge_envelope');
    }

    final transcriptionJson = json['transcription'];
    final outcomeJson = json['outcome'];
    return SaberPiBridgeResult(
      status: status,
      stage: stage,
      originalInkRetained: true,
      transcription: transcriptionJson is Map<String, dynamic>
          ? SaberPiTranscription.fromJson(transcriptionJson)
          : null,
      outcome: outcomeJson is Map<String, dynamic> ? outcomeJson : null,
      providerStatus: json['providerStatus'] as String?,
    );
  }
}

class SaberPiBridgeClient {
  SaberPiBridgeClient({
    required this.baseUri,
    http.Client? client,
    this.timeout = const Duration(seconds: 8),
  }) : _httpClient = client ?? http.Client(),
       _ownsHttpClient = client == null;

  static const _prefix = '/spike/saber-pi/v1';

  final Uri baseUri;
  final http.Client _httpClient;
  final bool _ownsHttpClient;
  final Duration timeout;

  void close() {
    if (_ownsHttpClient) _httpClient.close();
  }

  Uri _endpoint(String name) {
    final basePath = baseUri.path.endsWith('/')
        ? baseUri.path.substring(0, baseUri.path.length - 1)
        : baseUri.path;
    return baseUri.replace(path: '$basePath$_prefix/$name');
  }

  Future<SaberPiBridgeResult> transcribe({
    required String pageId,
    required String strokeSegmentId,
    required SaberPiMode mode,
    required Uint8List png,
  }) => _post('transcribe', {
    'pageId': pageId,
    'strokeSegmentId': strokeSegmentId,
    'mode': mode.name,
    'image': {
      'mimeType': 'image/png',
      'data': 'data:image/png;base64,${base64Encode(png)}',
    },
  });

  Future<SaberPiBridgeResult> seek({
    required String pageId,
    required String strokeSegmentId,
    required Uint8List png,
    required String confirmedText,
  }) => _post('seek', {
    'pageId': pageId,
    'strokeSegmentId': strokeSegmentId,
    'mode': SaberPiMode.seek.name,
    'image': {
      'mimeType': 'image/png',
      'data': 'data:image/png;base64,${base64Encode(png)}',
    },
    'confirmedText': confirmedText,
  });

  Future<SaberPiBridgeResult> _post(
    String endpoint,
    Map<String, dynamic> body,
  ) async {
    final response = await _httpClient
        .post(
          _endpoint(endpoint),
          headers: const {'Content-Type': 'application/json'},
          body: jsonEncode(body),
        )
        .timeout(timeout);
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, dynamic>) {
      throw const SaberPiBridgeException('invalid_bridge_response');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw SaberPiBridgeException(
        decoded['status'] as String? ?? 'bridge_rejected',
      );
    }
    final expectedStage = endpoint == 'transcribe'
        ? 'transcription'
        : 'annotation';
    if (decoded['schema'] != 'saber-pi-bridge-v1' ||
        decoded['pageId'] != body['pageId'] ||
        decoded['strokeSegmentId'] != body['strokeSegmentId'] ||
        decoded['mode'] != body['mode'] ||
        decoded['stage'] != expectedStage) {
      throw const SaberPiBridgeException('invalid_bridge_identity');
    }
    return SaberPiBridgeResult.fromJson(decoded);
  }
}

class SaberPiSessionState {
  const SaberPiSessionState({
    required this.phase,
    this.pageId,
    this.strokeSegmentId,
    this.ink,
    this.transcription,
    this.result,
    this.error,
  });

  final SaberPiPhase phase;
  final String? pageId;
  final String? strokeSegmentId;
  final Uint8List? ink;
  final SaberPiTranscription? transcription;
  final SaberPiBridgeResult? result;
  final String? error;
}

class SaberPiSession {
  SaberPiSession({
    required this.bridge,
    this.onLocalAwakening,
    this.onStateChanged,
  });

  final SaberPiBridgeClient bridge;
  final void Function()? onLocalAwakening;
  final void Function(SaberPiSessionState state)? onStateChanged;
  var _state = const SaberPiSessionState(phase: SaberPiPhase.rest);
  var _turn = 0;

  SaberPiSessionState get state => _state;

  Future<SaberPiSessionState> onPenUp({
    required String pageId,
    required String strokeSegmentId,
    required SaberPiMode mode,
    required Future<Uint8List> Function() capturePng,
  }) async {
    final turn = ++_turn;
    if (mode == SaberPiMode.quiet) {
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.quiet,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
        ),
      );
    }

    if (mode == SaberPiMode.seek) {
      _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.awakening,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
        ),
      );
      // This callback is deliberately before screenshot capture and the first
      // awaited bridge call, so local feedback never waits on the network.
      onLocalAwakening?.call();
    }

    Uint8List? png;
    try {
      png = await capturePng();
      if (turn != _turn) return _state;

      final result = await bridge.transcribe(
        pageId: pageId,
        strokeSegmentId: strokeSegmentId,
        mode: mode,
        png: png,
      );
      if (turn != _turn) return _state;
      if (result.status == 'ok' && result.transcription != null) {
        return _publish(
          SaberPiSessionState(
            phase: SaberPiPhase.awaitingConfirmation,
            pageId: pageId,
            strokeSegmentId: strokeSegmentId,
            ink: png,
            transcription: result.transcription,
          ),
        );
      }
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
          ink: png,
          result: result,
        ),
      );
    } on SaberPiBridgeException catch (error) {
      if (turn != _turn) return _state;
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
          ink: png,
          error: error.message,
        ),
      );
    } on Object catch (error) {
      if (turn != _turn) return _state;
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
          ink: png,
          error: error.toString(),
        ),
      );
    }
  }

  Future<SaberPiSessionState> confirm(String text) async {
    final current = _state;
    final confirmedText = text.trim();
    if (current.phase != SaberPiPhase.awaitingConfirmation ||
        current.pageId == null ||
        current.strokeSegmentId == null ||
        current.ink == null ||
        confirmedText.isEmpty ||
        confirmedText.length > 240) {
      throw const SaberPiBridgeException('confirmation_required');
    }

    final turn = ++_turn;
    final result = await bridge.seek(
      pageId: current.pageId!,
      strokeSegmentId: current.strokeSegmentId!,
      png: current.ink!,
      confirmedText: confirmedText,
    );
    if (turn != _turn) return _state;
    return _publish(
      SaberPiSessionState(
        phase: SaberPiPhase.ready,
        pageId: current.pageId,
        strokeSegmentId: current.strokeSegmentId,
        ink: current.ink,
        result: result,
      ),
    );
  }

  SaberPiSessionState _publish(SaberPiSessionState state) {
    _state = state;
    onStateChanged?.call(state);
    return state;
  }
}
