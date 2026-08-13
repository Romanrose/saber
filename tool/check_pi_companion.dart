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
  Map<String, dynamic>? transcription,
  Map<String, dynamic>? outcome,
}) {
  final result = <String, dynamic>{
    'schema': 'saber-pi-bridge-v1',
    'stage': stage,
    'status': status,
    'originalInk': 'retained_by_saber',
  };
  if (transcription != null) result['transcription'] = transcription;
  if (outcome != null) result['outcome'] = outcome;
  return result;
}

Future<void> main() async {
  final ink = Uint8List.fromList([137, 80, 78, 71]);
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
              outcome: {
                'kind': 'evidence',
                'path': ['李白', '作者', '将进酒'],
              },
            )
          : envelope(
              stage: 'transcription',
              status: 'ok',
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

  stdout.writeln(
    'Saber Dart companion client verified: local awakening, confirmation gate, ink retention, evidence, and quiet mode.',
  );
}
