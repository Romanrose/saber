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
    defaultTimeouts.timeout == const Duration(seconds: 8) &&
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
  final failedSession = SaberPiSession(
    bridge: SaberPiBridgeClient(
      baseUri: Uri.parse('http://127.0.0.1:4175'),
      client: MockClient((request) async {
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
    'Saber Dart companion client verified: local awakening, confirmation gate, ink retention, evidence, and quiet mode.',
  );
}
