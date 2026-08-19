import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

enum SaberPiMode { quiet, seek }

enum SaberPiPhase {
  rest,
  awakening,
  awaitingConfirmation,
  seeking,
  ready,
  quiet,
}

const _journeyRoutes = {'life', 'space', 'work'};

String _journeyRouteLabel(String? route) => switch (route) {
  'life' => '经历线',
  'space' => '地点线',
  'work' => '作品线',
  _ => '待展开',
};

String _journeyPrompt(String? route, int step) {
  if (route == 'space') {
    if (step == 0) return '下一笔，写下这条人生线的第一个地点。';
    if (step == 1) return '下一笔，再写一个与他有关的地点。';
    if (step == 2) return '下一笔，写下前面地点之间发生了怎样的变化。';
    return '下一笔，回望这条地点线，写下你想留下的问题。';
  }
  if (route == 'work') {
    if (step == 0) return '下一笔，写下他的一件作品或一句诗。';
    if (step == 1) return '下一笔，再写一件作品或一句诗。';
    if (step == 2) return '下一笔，写下这些作品背后的经历。';
    return '下一笔，回望这条作品线，写下你想留下的问题。';
  }
  if (route == 'life') {
    if (step == 0) return '下一笔，写下他人生中的一次转折。';
    if (step == 1) return '下一笔，再写一次改变方向的经历。';
    if (step == 2) return '下一笔，写下这段经历与时代的关系。';
    return '下一笔，回望这条经历线，写下你想留下的问题。';
  }
  return '先选一条路线，再写第一条线索。';
}

class SaberPiJourneyState {
  const SaberPiJourneyState({
    required this.personId,
    required this.anchor,
    required this.route,
    required this.step,
    required this.visitedNodes,
    required this.unresolvedQuestions,
  });

  final String personId;
  final String anchor;
  final String? route;
  final int step;
  final List<String> visitedNodes;
  final List<String> unresolvedQuestions;

  factory SaberPiJourneyState.fromAnchor(Map<String, dynamic> value) {
    final personId = value['id'];
    final anchor = value['name'];
    if (personId is! String ||
        personId.trim().isEmpty ||
        anchor is! String ||
        anchor.trim().isEmpty) {
      throw const SaberPiBridgeException('invalid_person_anchor');
    }
    return SaberPiJourneyState(
      personId: personId.trim(),
      anchor: anchor.trim(),
      route: null,
      step: 0,
      visitedNodes: const [],
      unresolvedQuestions: [_journeyPrompt(null, 0)],
    );
  }

  SaberPiJourneyState selectRoute(String nextRoute) {
    if (!_journeyRoutes.contains(nextRoute) || route != null) return this;
    return SaberPiJourneyState(
      personId: personId,
      anchor: anchor,
      route: nextRoute,
      step: step,
      visitedNodes: visitedNodes,
      unresolvedQuestions: [_journeyPrompt(nextRoute, step)],
    );
  }

  SaberPiJourneyState advance(Map<String, dynamic>? outcome) {
    if (route == null || outcome?['kind'] != 'evidence') return this;
    final path = (outcome?['path'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .map((node) => node.trim())
        .where((node) => node.isNotEmpty && node != anchor);
    final nodes = <String>[...visitedNodes, ...path];
    final bounded = <String>[];
    for (final node in nodes) {
      if (!bounded.contains(node)) bounded.add(node);
    }
    final nextStep = step + 1;
    return SaberPiJourneyState(
      personId: personId,
      anchor: anchor,
      route: route,
      step: nextStep,
      visitedNodes: bounded.take(24).toList(growable: false),
      unresolvedQuestions: [_journeyPrompt(route, nextStep)],
    );
  }

  Map<String, dynamic> toJson() => {
    'personId': personId,
    'anchor': anchor,
    'route': route,
    'step': step,
    'visitedNodes': visitedNodes,
    'unresolvedQuestions': unresolvedQuestions,
  };

  String get routeLabel => _journeyRouteLabel(route);
  String get nextPrompt => unresolvedQuestions.isEmpty
      ? _journeyPrompt(route, step)
      : unresolvedQuestions.first;
}

String? saberPiSeekError(SaberPiBridgeResult result) => switch (result.status) {
  'ok' => null,
  // A confirmed person-first seek can legitimately stop at a verified
  // Souyun anchor before the reader chooses a route for the next stroke.
  // Treating this as an error made the paper show
  // “寻迹未完成：anchor_ready” even though the anchor was accepted.
  'anchor_ready' => null,
  'graph_unconfigured' => '当前图谱数据尚未就绪。',
  'graph_timed_out' => '图谱检索超时，请重试。',
  'graph_unavailable' => '图谱暂时不可用，请重试。',
  'model_unconfigured' => '寻迹模型尚未配置。',
  'needs_transcription' => '请先确认一段文字。',
  'route_selection_required' => '人物已确认；请先选择地点、经历或作品路线。',
  _ => '寻迹未完成：${result.status}',
};

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
    this.anchor,
  });

  final String status;
  final String stage;
  final bool originalInkRetained;
  final SaberPiTranscription? transcription;
  final Map<String, dynamic>? outcome;
  final String? providerStatus;
  final Map<String, dynamic>? anchor;

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
      anchor: json['anchor'] is Map<String, dynamic>
          ? json['anchor'] as Map<String, dynamic>
          : null,
    );
  }
}

class SaberPiBridgeClient {
  SaberPiBridgeClient({
    required this.baseUri,
    http.Client? client,
    this.timeout = const Duration(seconds: 10),
    this.seekTimeout = const Duration(seconds: 15),
  }) : _httpClient = client ?? http.Client(),
       _ownsHttpClient = client == null;

  static const _prefix = '/spike/saber-pi/v1';

  final Uri baseUri;
  final http.Client _httpClient;
  final bool _ownsHttpClient;

  /// OCR remains server-bounded at eight seconds. The client keeps two seconds
  /// of transport margin so it can receive the server's final safe result.
  /// Confirmed Pi seek may include a source-validated model turn and needs a
  /// separate, explicit allowance.
  final Duration timeout;
  final Duration seekTimeout;

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
    Map<String, dynamic>? journey,
  }) {
    final body = <String, dynamic>{
      'pageId': pageId,
      'strokeSegmentId': strokeSegmentId,
      'mode': SaberPiMode.seek.name,
      'image': {
        'mimeType': 'image/png',
        'data': 'data:image/png;base64,${base64Encode(png)}',
      },
      'confirmedText': confirmedText,
    };
    if (journey != null) body['journey'] = journey;
    return _post('seek', body);
  }

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
        .timeout(endpoint == 'seek' ? seekTimeout : timeout);
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
    this.journey,
  });

  final SaberPiPhase phase;
  final String? pageId;
  final String? strokeSegmentId;
  final Uint8List? ink;
  final SaberPiTranscription? transcription;
  final SaberPiBridgeResult? result;
  final String? error;
  final SaberPiJourneyState? journey;

  SaberPiSessionState copyWith({
    SaberPiPhase? phase,
    String? pageId,
    String? strokeSegmentId,
    Uint8List? ink,
    SaberPiTranscription? transcription,
    SaberPiBridgeResult? result,
    String? error,
    bool clearError = false,
    SaberPiJourneyState? journey,
  }) => SaberPiSessionState(
    phase: phase ?? this.phase,
    pageId: pageId ?? this.pageId,
    strokeSegmentId: strokeSegmentId ?? this.strokeSegmentId,
    ink: ink ?? this.ink,
    transcription: transcription ?? this.transcription,
    result: result ?? this.result,
    error: clearError ? null : error ?? this.error,
    journey: journey ?? this.journey,
  );
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
  SaberPiJourneyState? _journey;
  var _turn = 0;

  SaberPiSessionState get state => _state;

  void selectJourneyRoute(String route) {
    final current = _journey;
    if (current == null ||
        current.route != null ||
        !_journeyRoutes.contains(route))
      return;
    _journey = current.selectRoute(route);
    _publish(_state.copyWith(journey: _journey, clearError: true));
  }

  /// Shows the local page response immediately. Call [transcribeSegment] only
  /// once consecutive pen strokes have been grouped into one ink segment.
  void beginSegment({
    required String pageId,
    required String strokeSegmentId,
    required SaberPiMode mode,
  }) {
    ++_turn;
    if (mode == SaberPiMode.quiet) {
      _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.quiet,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
        ),
      );
      return;
    }

    _publish(
      SaberPiSessionState(
        phase: SaberPiPhase.awakening,
        pageId: pageId,
        strokeSegmentId: strokeSegmentId,
      ),
    );
    // This is deliberately before PNG capture and the bridge call, so the
    // paper response never waits on grouping, rendering, or the network.
    onLocalAwakening?.call();
  }

  Future<SaberPiSessionState> transcribeSegment({
    required String pageId,
    required String strokeSegmentId,
    required SaberPiMode mode,
    required Future<Uint8List> Function() capturePng,
  }) async {
    if (mode == SaberPiMode.quiet) return _state;
    final current = _state;
    if (current.phase != SaberPiPhase.awakening ||
        current.pageId != pageId ||
        current.strokeSegmentId != strokeSegmentId) {
      return current;
    }

    final turn = _turn;
    try {
      final png = await capturePng();
      if (turn != _turn) return _state;
      return _transcribeCapturedInk(
        pageId: pageId,
        strokeSegmentId: strokeSegmentId,
        png: png,
        turn: turn,
      );
    } on Object catch (error) {
      if (turn != _turn) return _state;
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
          error: error is SaberPiBridgeException
              ? error.message
              : error.toString(),
        ),
      );
    }
  }

  /// Retries only a failed, already-captured seek segment. The original ink
  /// stays in memory for this editor session and is neither recaptured nor
  /// persisted by this action.
  Future<SaberPiSessionState> retryTranscription() async {
    final current = _state;
    if (current.phase != SaberPiPhase.ready ||
        current.error == null ||
        current.pageId == null ||
        current.strokeSegmentId == null ||
        current.ink == null) {
      throw const SaberPiBridgeException('retry_unavailable');
    }
    final turn = ++_turn;
    _publish(
      SaberPiSessionState(
        phase: SaberPiPhase.awakening,
        pageId: current.pageId,
        strokeSegmentId: current.strokeSegmentId,
      ),
    );
    onLocalAwakening?.call();
    return _transcribeCapturedInk(
      pageId: current.pageId!,
      strokeSegmentId: current.strokeSegmentId!,
      png: current.ink!,
      turn: turn,
    );
  }

  Future<SaberPiSessionState> _transcribeCapturedInk({
    required String pageId,
    required String strokeSegmentId,
    required Uint8List png,
    required int turn,
  }) async {
    try {
      final result = await bridge.transcribe(
        pageId: pageId,
        strokeSegmentId: strokeSegmentId,
        mode: SaberPiMode.seek,
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

  Future<SaberPiSessionState> onPenUp({
    required String pageId,
    required String strokeSegmentId,
    required SaberPiMode mode,
    required Future<Uint8List> Function() capturePng,
  }) async {
    beginSegment(pageId: pageId, strokeSegmentId: strokeSegmentId, mode: mode);
    return transcribeSegment(
      pageId: pageId,
      strokeSegmentId: strokeSegmentId,
      mode: mode,
      capturePng: capturePng,
    );
  }

  /// Publishes an editable transcription produced from the selected raw ink.
  /// The PNG is still retained solely for the later, user-confirmed seek.
  Future<SaberPiSessionState> acceptLocalTranscription({
    required String pageId,
    required String strokeSegmentId,
    required String text,
    required List<String> candidates,
    required Future<Uint8List> Function() capturePng,
  }) async {
    final normalizedText = text.trim();
    if (normalizedText.isEmpty || normalizedText.length > 240) {
      throw const SaberPiBridgeException('invalid_transcription');
    }
    final turn = ++_turn;
    try {
      final png = await capturePng();
      if (turn != _turn) return _state;
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.awaitingConfirmation,
          pageId: pageId,
          strokeSegmentId: strokeSegmentId,
          ink: png,
          transcription: SaberPiTranscription(
            text: normalizedText,
            candidates: candidates,
          ),
        ),
      );
    } on SaberPiBridgeException {
      rethrow;
    } on Object {
      throw const SaberPiBridgeException('png_capture_failed');
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
    final transcription = SaberPiTranscription(
      text: confirmedText,
      candidates: current.transcription?.candidates ?? const [],
    );
    if (_journey != null && _journey!.route == null) {
      return _publish(
        current.copyWith(
          phase: SaberPiPhase.ready,
          transcription: transcription,
          error: 'route_selection_required',
        ),
      );
    }
    _publish(
      SaberPiSessionState(
        phase: SaberPiPhase.seeking,
        pageId: current.pageId,
        strokeSegmentId: current.strokeSegmentId,
        ink: current.ink,
        transcription: transcription,
      ),
    );
    try {
      final result = await bridge.seek(
        pageId: current.pageId!,
        strokeSegmentId: current.strokeSegmentId!,
        png: current.ink!,
        confirmedText: confirmedText,
        journey: _journey?.toJson(),
      );
      if (turn != _turn) return _state;
      if (result.status == 'anchor_ready' && result.anchor != null) {
        _journey = SaberPiJourneyState.fromAnchor(result.anchor!);
      } else if (result.status == 'ok' && result.outcome != null) {
        _journey = _journey?.advance(result.outcome);
      }
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: current.pageId,
          strokeSegmentId: current.strokeSegmentId,
          ink: current.ink,
          transcription: transcription,
          result: result,
          error: saberPiSeekError(result),
          journey: _journey,
        ),
      );
    } on SaberPiBridgeException catch (error) {
      if (turn != _turn) return _state;
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: current.pageId,
          strokeSegmentId: current.strokeSegmentId,
          ink: current.ink,
          transcription: transcription,
          error: error.message,
        ),
      );
    } on Object catch (error) {
      if (turn != _turn) return _state;
      return _publish(
        SaberPiSessionState(
          phase: SaberPiPhase.ready,
          pageId: current.pageId,
          strokeSegmentId: current.strokeSegmentId,
          ink: current.ink,
          transcription: transcription,
          error: error.toString(),
        ),
      );
    }
  }

  SaberPiSessionState _publish(SaberPiSessionState state) {
    if (state.journey == null && _journey != null) {
      state = state.copyWith(journey: _journey);
    }
    _state = state;
    onStateChanged?.call(state);
    return state;
  }
}
