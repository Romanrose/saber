import 'dart:io';

import 'package:saber/data/pi_companion/pi_companion_sidecar.dart';

void expectCondition(bool condition, String message) {
  if (!condition) throw StateError(message);
}

SaberPiSidecarAnnotation annotation({String id = 'annotation-01'}) =>
    SaberPiSidecarAnnotation(
      id: id,
      pageIndex: 0,
      strokeSegmentId: 'segment-01',
      anchor: const SaberPiSidecarAnchor(
        x: 0.2,
        y: 0.3,
        width: 0.16,
        height: 0.08,
      ),
      outcome: {
        'kind': 'evidence',
        'transcription': '李白写过《将进酒》吗？',
        'evidence': '当前图谱记录：李白是《将进酒》的作者。',
        'association': '联想：可从酒诗继续阅读。',
        'source': [
          {'label': '固定来源', 'url': 'https://source.test/jiangjinjiu'},
        ],
        'path': ['李白', '作者', '将进酒'],
        'timeline': [
          {'year': 744, 'label': '李白 → 将进酒'},
        ],
        'places': ['长安'],
      },
      createdAt: '2026-08-15T10:00:00.000Z',
      isCollected: false,
    );

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp('saber-pi-sidecar-');
  const store = SaberPiSidecarStore();
  final note = File('${directory.path}${Platform.pathSeparator}travel.sbn2');
  final renamedNote = File(
    '${directory.path}${Platform.pathSeparator}renamed.sbn2',
  );
  await note.writeAsString('original Saber note');
  final document = SaberPiSidecarDocument(
    documentId: 'note-01',
    createdAt: '2026-08-15T10:00:00.000Z',
    updatedAt: '2026-08-15T10:00:00.000Z',
    annotations: [annotation()],
  );
  try {
    await store.writeForNote(note, document);
    final sidecar = store.fileForNote(note);
    expectCondition(
      sidecar.path.endsWith('travel.sbn2.shangtu-pi.json') &&
          await sidecar.exists(),
      'sidecar naming or atomic write failed',
    );
    expectCondition(
      SaberPiSidecarStore.isSidecarArtifactPath(sidecar.path) &&
          SaberPiSidecarStore.isSidecarArtifactPath(
            '${directory.path}${Platform.pathSeparator}.travel.sbn2.shangtu-pi.json.transaction.tmp',
          ) &&
          !SaberPiSidecarStore.isSidecarArtifactPath(note.path),
      'sidecar watcher exclusion did not cover only sidecar artifacts',
    );
    await store.writeForNote(
      note,
      document.copyWith(
        annotations: [
          SaberPiSidecarAnnotation(
            id: annotation().id,
            pageIndex: annotation().pageIndex,
            strokeSegmentId: annotation().strokeSegmentId,
            anchor: annotation().anchor,
            outcome: annotation().outcome,
            createdAt: annotation().createdAt,
            isCollected: true,
          ),
        ],
      ),
    );
    final restored = await store.readForNote(note);
    expectCondition(
      restored?.documentId == 'note-01' &&
          restored?.annotations.single.outcome['kind'] == 'evidence' &&
          restored?.annotations.single.outcome['timeline'] is List &&
          (restored?.annotations.single.outcome['places'] as List?)?.single ==
              '长安' &&
          restored?.annotations.single.isCollected == true,
      'sidecar did not restore a verified annotation',
    );
    final raw = await sidecar.readAsString();
    expectCondition(
      !raw.contains('data:image') && !raw.contains('Authorization'),
      'sidecar retained original ink or credentials',
    );
    await note.rename(renamedNote.path);
    await store.moveForNote(note, renamedNote);
    expectCondition(
      await store.readForNote(renamedNote) != null &&
          !await store.fileForNote(note).exists(),
      'sidecar did not follow a successful note rename',
    );
    await store.deleteForNote(renamedNote);
    expectCondition(
      !await store.fileForNote(renamedNote).exists(),
      'sidecar did not delete after its note',
    );
    final rejected = sanitizeSaberPiOutcome({
      ...annotation().outcome,
      'image': 'data:image/png;base64,AA==',
    });
    expectCondition(rejected == null, 'sidecar accepted raw ink data');
  } finally {
    await directory.delete(recursive: true);
  }
  stdout.writeln(
    'Saber Pi sidecar verified: atomic persistence, rename, delete, normalized anchor, and no raw ink.',
  );
}
