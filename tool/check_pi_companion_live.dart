import 'dart:io';
import 'dart:typed_data';

import 'package:saber/data/pi_companion/pi_companion_client.dart';

void expectCondition(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<SaberPiBridgeResult> seekFixture({
  required SaberPiBridgeClient bridge,
  required Uint8List ink,
  required String strokeSegmentId,
  required String text,
}) async {
  final session = SaberPiSession(bridge: bridge);
  final transcription = await session.onPenUp(
    pageId: 'note-01-page-01',
    strokeSegmentId: strokeSegmentId,
    mode: SaberPiMode.seek,
    capturePng: () async => ink,
  );
  expectCondition(
    transcription.phase == SaberPiPhase.awaitingConfirmation &&
        transcription.transcription?.text.isNotEmpty == true,
    'live transcribe did not return editable text',
  );
  final result = await session.confirm(text);
  return result.result!;
}

Future<void> main() async {
  final bridge = SaberPiBridgeClient(
    baseUri: Uri.parse(
      Platform.environment['SABER_PI_BRIDGE_URL'] ?? 'http://127.0.0.1:4175',
    ),
  );
  final ink = Uint8List.fromList([137, 80, 78, 71]);

  try {
    final evidence = await seekFixture(
      bridge: bridge,
      ink: ink,
      strokeSegmentId: 'live-evidence',
      text: '李白写过《将进酒》吗？',
    );
    expectCondition(
      evidence.outcome?['kind'] == 'evidence' &&
          evidence.outcome?['path'] is List &&
          evidence.originalInkRetained,
      'live evidence response crossed the contract boundary',
    );

    final ambiguous = await seekFixture(
      bridge: bridge,
      ink: ink,
      strokeSegmentId: 'live-ambiguous',
      text: '李贺和长安有什么关联？',
    );
    expectCondition(
      ambiguous.outcome?['kind'] == 'ambiguous' &&
          (ambiguous.outcome?['candidates'] as List).length >= 2,
      'live ambiguity response lost candidates',
    );

    final gap = await seekFixture(
      bridge: bridge,
      ink: ink,
      strokeSegmentId: 'live-gap',
      text: '珊瑚与唐诗有什么关联？',
    );
    expectCondition(
      gap.outcome?['kind'] == 'gap' && gap.outcome?['gap'] is String,
      'live evidence gap response was not explicit',
    );

    final quiet = SaberPiSession(bridge: bridge);
    final quietState = await quiet.onPenUp(
      pageId: 'note-01-page-01',
      strokeSegmentId: 'live-quiet',
      mode: SaberPiMode.quiet,
      capturePng: () async {
        throw StateError('quiet mode captured ink for Pi');
      },
    );
    expectCondition(
      quietState.phase == SaberPiPhase.quiet,
      'live quiet mode crossed the capture boundary',
    );
  } finally {
    bridge.close();
  }

  stdout.writeln(
    'Saber Dart live bridge verified: transcription, evidence, ambiguity, gap, and quiet mode.',
  );
}
