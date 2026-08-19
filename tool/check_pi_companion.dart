import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:saber/data/pi_companion/pi_companion_client.dart';

void expectCondition(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Map<String, dynamic> envelope({
  required String stage,
  required String status,
  String? pageId,
  String? strokeSegmentId,
  String? mode,
  Map<String, dynamic>? transcription,
  Map<String, dynamic>? outcome,
  Map<String, dynamic>? anchor,
}) {
  final result = <String, dynamic>{
    'schema': 'saber-pi-bridge-v1',
    'stage': stage,
    'status': status,
    'originalInk': 'retained_by_saber',
  };
  if (pageId != null) result['pageId'] = pageId;
  if (strokeSegmentId != null) result['strokeSegmentId'] = strokeSegmentId;
  if (mode != null) result['mode'] = mode;
  if (transcription != null) result['transcription'] = transcription;
  if (outcome != null) result['outcome'] = outcome;
  if (anchor != null) result['anchor'] = anchor;
  return result;
}

Future<SaberPiBridgeResult> runOutcomeCase({
  required Uint8List ink,
  required String text,
}) async {
  final client = MockClient((request) async {
    final isSeek = request.url.path.endsWith('/seek');
    final requestBody = jsonDecode(request.body) as Map<String, dynamic>;
    final confirmedText = requestBody['confirmedText'];
    final Map<String, dynamic> outcome;
    if (confirmedText == '李贺和长安有什么关联？') {
      outcome = {
        'kind': 'ambiguous',
        'clarification': '这段文字可能指向两个实体。',
        'candidates': ['李贺', '李白'],
      };
    } else if (confirmedText == '珊瑚与唐诗有什么关联？') {
      outcome = {
        'kind': 'gap',
        'gap': '当前图谱没有这条可核验的直接关联。',
        'association': null,
      };
    } else {
      outcome = {
        'kind': 'evidence',
        'evidence': '当前图谱记录：李白是《将进酒》的作者。',
        'source': [
          {'label': '固定来源', 'url': 'https://example.test/source'},
        ],
        'path': ['李白', '作者', '将进酒'],
      };
    }
    final body = envelope(
      stage: isSeek ? 'annotation' : 'transcription',
      status: 'ok',
      pageId: requestBody['pageId'] as String,
      strokeSegmentId: requestBody['strokeSegmentId'] as String,
      mode: requestBody['mode'] as String,
      transcription: isSeek ? null : {'text': text, 'candidates': <String>[]},
      outcome: isSeek ? outcome : null,
    );
    return http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final session = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: client,
    ),
  );
  await session.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-outcome',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  final state = await session.confirm(text);
  return state.result!;
}

Future<void> main() async {
  final ink = Uint8List.fromList([137, 80, 78, 71]);
  final defaultTimeouts = SaberPiBridgeClient(
    baseUri: Uri.parse('http://127.0.0.1:4175'),
  );
  expectCondition(
    defaultTimeouts.timeout == const Duration(seconds: 10) &&
        defaultTimeouts.seekTimeout == const Duration(seconds: 15),
    'transcription and confirmed seek must keep separate deadlines',
  );
  defaultTimeouts.close();
  final calls = <String>[];
  final requests = <http.BaseRequest>[];
  final client = MockClient((request) async {
    requests.add(request);
    final isSeek = request.url.path.endsWith('/seek');
    calls.add(isSeek ? 'seek' : 'transcribe');
    final body = jsonEncode(
      isSeek
          ? envelope(
              stage: 'annotation',
              status: 'ok',
              pageId: 'note-01-page-01',
              strokeSegmentId: 'segment-01',
              mode: 'seek',
              outcome: {
                'kind': 'evidence',
                'path': ['李白', '作者', '将进酒'],
                'timeline': [
                  {'year': 744, 'label': '李白 → 将进酒'},
                ],
                'places': ['长安'],
              },
            )
          : envelope(
              stage: 'transcription',
              status: 'ok',
              pageId: 'note-01-page-01',
              strokeSegmentId: 'segment-01',
              mode: 'seek',
              transcription: {'text': '李白写过《将进酒》吗？', 'candidates': <String>[]},
            ),
    );
    return http.Response.bytes(
      utf8.encode(body),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final phases = <SaberPiPhase>[];
  final session = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: client,
    ),
    onLocalAwakening: () => calls.add('local_awakening'),
    onStateChanged: (state) => phases.add(state.phase),
  );

  await session.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-01',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  expectCondition(
    calls.join(',') == 'local_awakening,transcribe',
    'transport ran before local awakening',
  );
  expectCondition(
    phases.join(',') ==
        '${SaberPiPhase.awakening},${SaberPiPhase.awaitingConfirmation}',
    'client state order drifted',
  );
  expectCondition(session.state.ink == ink, 'original ink reference was lost');
  expectCondition(
    !requests.single.headers.containsKey('authorization'),
    'client attempted to send a credential header',
  );

  final seekingPhases = <SaberPiPhase>[];
  final seekingClient = MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (!request.url.path.endsWith('/seek')) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(
            envelope(
              stage: 'transcription',
              status: 'ok',
              pageId: body['pageId'] as String,
              strokeSegmentId: body['strokeSegmentId'] as String,
              mode: body['mode'] as String,
              transcription: {'text': '李白', 'candidates': <String>[]},
            ),
          ),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response.bytes(
      utf8.encode(
        jsonEncode(
          envelope(
            stage: 'annotation',
            status: 'ok',
            pageId: body['pageId'] as String,
            strokeSegmentId: body['strokeSegmentId'] as String,
            mode: body['mode'] as String,
            outcome: {'kind': 'gap', 'gap': '当前图谱没有可核验证据。'},
          ),
        ),
      ),
      200,
    );
  });
  final seekingSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: seekingClient,
    ),
    onStateChanged: (state) => seekingPhases.add(state.phase),
  );
  await seekingSession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-seeking',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  await seekingSession.confirm('李白');
  expectCondition(
    seekingPhases.join(',') ==
        '${SaberPiPhase.awakening},${SaberPiPhase.awaitingConfirmation},${SaberPiPhase.seeking},${SaberPiPhase.ready}',
    'confirmation did not publish an immediate local seeking state',
  );

  final journeyRequests = <Map<String, dynamic>>[];
  final journeyClient = MockClient((request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    journeyRequests.add(body);
    final isSeek = request.url.path.endsWith('/seek');
    if (!isSeek) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(
            envelope(
              stage: 'transcription',
              status: 'ok',
              pageId: body['pageId'] as String,
              strokeSegmentId: body['strokeSegmentId'] as String,
              mode: body['mode'] as String,
              transcription: {
                'text': body['strokeSegmentId'] == 'journey-anchor'
                    ? '苏轼'
                    : '黄州',
                'candidates': <String>[],
              },
            ),
          ),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    if (body['journey'] == null) {
      return http.Response.bytes(
        utf8.encode(
          jsonEncode(
            envelope(
              stage: 'annotation',
              status: 'anchor_ready',
              pageId: body['pageId'] as String,
              strokeSegmentId: body['strokeSegmentId'] as String,
              mode: body['mode'] as String,
              anchor: {'id': 'souyun:person:29937', 'name': '苏轼'},
            ),
          ),
        ),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    }
    return http.Response.bytes(
      utf8.encode(
        jsonEncode(
          envelope(
            stage: 'annotation',
            status: 'ok',
            pageId: body['pageId'] as String,
            strokeSegmentId: body['strokeSegmentId'] as String,
            mode: body['mode'] as String,
            outcome: {
              'kind': 'evidence',
              'evidence': '当前图谱记录：苏轼的黄州路线。',
              'path': ['苏轼', '经历', '黄州'],
            },
          ),
        ),
      ),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final journeySession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: journeyClient,
    ),
  );
  await journeySession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'journey-anchor',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  final confirmedAnchor = await journeySession.confirm('苏轼');
  expectCondition(
    confirmedAnchor.journey?.anchor == '苏轼' &&
        confirmedAnchor.journey?.route == null &&
        confirmedAnchor.error == null &&
        journeyRequests.last['journey'] == null,
    'person anchor did not open the route-selection state',
  );
  final beforeRouteSeekCount = journeyRequests
      .where((request) => request['confirmedText'] != null)
      .length;
  await journeySession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'journey-no-route',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  final routeRequired = await journeySession.confirm('黄州');
  expectCondition(
    routeRequired.error == 'route_selection_required' &&
        journeyRequests
                .where((request) => request['confirmedText'] != null)
                .length ==
            beforeRouteSeekCount,
    'person anchor allowed a seek before a route was selected',
  );
  journeySession.selectJourneyRoute('space');
  expectCondition(
    journeySession.state.journey?.route == 'space' &&
        journeySession.state.journey?.nextPrompt.contains('地点') == true,
    'route selection did not update the next handwritten prompt',
  );
  await journeySession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'journey-route',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  final routeOutcome = await journeySession.confirm('黄州');
  final routeRequest = journeyRequests.last;
  expectCondition(
    routeOutcome.result?.outcome?['kind'] == 'evidence' &&
        routeOutcome.journey?.route == 'space' &&
        routeOutcome.journey?.step == 1 &&
        (routeRequest['journey'] as Map?)?['route'] == 'space',
    'selected route was not carried into the next evidence seek',
  );
  journeySession.bridge.close();

  var localInkBridgeCalls = 0;
  final localInkSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: MockClient((_) async {
        localInkBridgeCalls++;
        throw StateError('on-device ink must not call the OCR bridge');
      }),
    ),
  );
  localInkSession.beginSegment(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-local-ink',
    mode: SaberPiMode.seek,
  );
  await localInkSession.acceptLocalTranscription(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-local-ink',
    text: '杜甫',
    candidates: const ['杜甫', '杜牧'],
    capturePng: () async => ink,
  );
  expectCondition(
    localInkBridgeCalls == 0 &&
        localInkSession.state.phase == SaberPiPhase.awaitingConfirmation &&
        localInkSession.state.ink == ink &&
        localInkSession.state.transcription?.text == '杜甫' &&
        localInkSession.state.transcription?.candidates.length == 2,
    'on-device ink did not retain the PNG and editable candidates locally',
  );

  final delayedCalls = <String>[];
  final delayedSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: MockClient((request) async {
        delayedCalls.add('transcribe');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response.bytes(
          utf8.encode(
            jsonEncode(
              envelope(
                stage: 'transcription',
                status: 'ok',
                pageId: body['pageId'] as String,
                strokeSegmentId: body['strokeSegmentId'] as String,
                mode: body['mode'] as String,
                transcription: {'text': '合并笔迹', 'candidates': <String>[]},
              ),
            ),
          ),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    ),
    onLocalAwakening: () => delayedCalls.add('local_awakening'),
  );
  delayedSession.beginSegment(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-grouped',
    mode: SaberPiMode.seek,
  );
  expectCondition(
    delayedCalls.join(',') == 'local_awakening' &&
        delayedSession.state.phase == SaberPiPhase.awakening,
    'local awakening waited for the segment debounce',
  );
  var staleCaptureCount = 0;
  await delayedSession.transcribeSegment(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'other-segment',
    mode: SaberPiMode.seek,
    capturePng: () async {
      staleCaptureCount++;
      return ink;
    },
  );
  expectCondition(
    staleCaptureCount == 0 && delayedCalls.join(',') == 'local_awakening',
    'a stale segment captured or crossed the bridge',
  );
  await delayedSession.transcribeSegment(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-grouped',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  expectCondition(
    delayedCalls.join(',') == 'local_awakening,transcribe' &&
        delayedSession.state.phase == SaberPiPhase.awaitingConfirmation,
    'grouped segment did not transcribe after local awakening',
  );

  var confirmationRejected = false;
  try {
    await session.confirm('');
  } on SaberPiBridgeException catch (error) {
    confirmationRejected = error.message == 'confirmation_required';
  }
  expectCondition(confirmationRejected, 'empty confirmation was accepted');
  expectCondition(!calls.contains('seek'), 'seek ran before confirmation');

  await session.confirm('李白写过《将进酒》吗？');
  expectCondition(calls.last == 'seek', 'confirmation did not call seek');
  expectCondition(
    session.state.result?.outcome?['kind'] == 'evidence',
    'evidence outcome was not retained',
  );
  expectCondition(
    (session.state.result?.outcome?['timeline'] as List?)?.single is Map &&
        (session.state.result?.outcome?['places'] as List?)?.single == '长安',
    'secondary spatiotemporal context was not retained',
  );
  expectCondition(session.state.ink == ink, 'annotation replaced original ink');

  var quietCalls = 0;
  var quietCaptures = 0;
  final quietSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: MockClient((request) async {
        quietCalls++;
        return http.Response('{}', 200);
      }),
    ),
  );
  await quietSession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-quiet',
    mode: SaberPiMode.quiet,
    capturePng: () async {
      quietCaptures++;
      return ink;
    },
  );
  expectCondition(
    quietSession.state.phase == SaberPiPhase.quiet &&
        quietCalls == 0 &&
        quietCaptures == 0,
    'quiet mode crossed the Pi transport boundary',
  );

  var failedCaptures = 0;
  var retryRequests = 0;
  final retryImages = <Object?>[];
  final failedSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: MockClient((request) async {
        retryRequests++;
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        retryImages.add((body['image'] as Map<String, dynamic>)['data']);
        if (retryRequests == 2) {
          return http.Response.bytes(
            utf8.encode(
              jsonEncode(
                envelope(
                  stage: 'transcription',
                  status: 'ok',
                  pageId: body['pageId'] as String,
                  strokeSegmentId: body['strokeSegmentId'] as String,
                  mode: body['mode'] as String,
                  transcription: {'text': '重试成功', 'candidates': <String>[]},
                ),
              ),
            ),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response.bytes(
          utf8.encode('{"status":"vision_unavailable"}'),
          503,
          headers: {'content-type': 'application/json'},
        );
      }),
    ),
  );
  final failedState = await failedSession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-failed',
    mode: SaberPiMode.seek,
    capturePng: () async {
      failedCaptures++;
      return ink;
    },
  );
  expectCondition(
    failedState.phase == SaberPiPhase.ready &&
        failedState.error == 'vision_unavailable' &&
        failedState.ink == ink &&
        failedCaptures == 1,
    'transcription failure left the session stuck or dropped ink',
  );
  final retriedState = await failedSession.retryTranscription();
  expectCondition(
    retriedState.phase == SaberPiPhase.awaitingConfirmation &&
        retriedState.transcription?.text == '重试成功' &&
        retryRequests == 2 &&
        retryImages.length == 2 &&
        retryImages.first == retryImages.last &&
        failedCaptures == 1,
    'retry did not reuse the failed in-memory ink segment',
  );

  final identityClient = MockClient((request) async {
    final body = envelope(
      stage: 'transcription',
      status: 'ok',
      pageId: 'other-page',
      strokeSegmentId: 'segment-identity',
      mode: 'seek',
      transcription: {'text': '错误页', 'candidates': <String>[]},
    );
    return http.Response.bytes(utf8.encode(jsonEncode(body)), 200);
  });
  final identitySession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: identityClient,
    ),
  );
  final identityState = await identitySession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-identity',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  expectCondition(
    identityState.error == 'invalid_bridge_identity' &&
        identityState.ink == ink,
    'response from another page crossed the identity boundary',
  );

  final ambiguousResult = await runOutcomeCase(ink: ink, text: '李贺和长安有什么关联？');
  expectCondition(
    ambiguousResult.outcome?['kind'] == 'ambiguous' &&
        (ambiguousResult.outcome?['candidates'] as List).length == 2,
    'ambiguity candidates were not retained for the margin panel',
  );
  final gapResult = await runOutcomeCase(ink: ink, text: '珊瑚与唐诗有什么关联？');
  expectCondition(
    gapResult.outcome?['kind'] == 'gap' && gapResult.outcome?['gap'] is String,
    'evidence gap was not retained for the margin panel',
  );

  final firstTranscription = Completer<http.Response>();
  final firstRequestStarted = Completer<void>();
  final staleClient = MockClient((request) async {
    final requestBody = jsonDecode(request.body) as Map<String, dynamic>;
    if (requestBody['strokeSegmentId'] == 'segment-stale') {
      firstRequestStarted.complete();
      return firstTranscription.future;
    }
    final body = envelope(
      stage: 'transcription',
      status: 'ok',
      pageId: requestBody['pageId'] as String,
      strokeSegmentId: requestBody['strokeSegmentId'] as String,
      mode: requestBody['mode'] as String,
      transcription: {'text': '第二段笔迹', 'candidates': <String>[]},
    );
    return http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );
  });
  final staleSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: staleClient,
    ),
  );
  final staleTurn = staleSession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-stale',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  await firstRequestStarted.future;
  await staleSession.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-current',
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  expectCondition(
    staleSession.state.transcription?.text == '第二段笔迹',
    'current transcription was not published',
  );
  final staleBody = envelope(
    stage: 'transcription',
    status: 'ok',
    pageId: 'note-01-page-01',
    strokeSegmentId: 'segment-stale',
    mode: 'seek',
    transcription: {'text': '迟到的第一段笔迹', 'candidates': <String>[]},
  );
  firstTranscription.complete(
    http.Response.bytes(
      utf8.encode(jsonEncode(staleBody)),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'},
    ),
  );
  await staleTurn;
  expectCondition(
    staleSession.state.transcription?.text == '第二段笔迹',
    'stale transcription overwrote the current turn',
  );

  stdout.writeln(
    'Saber Dart companion client verified: local awakening, confirmation gate, ink retention, evidence, ambiguity, gap, quiet mode, and person-route journey guidance.',
  );
}
