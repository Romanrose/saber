import 'dart:convert';
import 'dart:io';
import 'dart:math';

const saberPiSidecarSchema = 'shangtu-saber-companion-v1';
const _sidecarSuffix = '.shangtu-pi.json';
final _safeId = RegExp(r'^[A-Za-z0-9._:-]{1,120}$');

bool _hasOnlyKeys(Map<String, dynamic> value, Set<String> allowed) =>
    value.keys.every(allowed.contains);

bool _validTimestamp(Object? value) =>
    value is String && DateTime.tryParse(value) != null;

bool _validUnit(Object? value) => value is num && value >= 0 && value <= 1;

String _newDocumentId() {
  final random = Random.secure();
  final bytes = List<int>.generate(12, (_) => random.nextInt(256));
  return 'document-${base64UrlEncode(bytes).replaceAll('=', '')}';
}

String _newTransactionId() {
  final random = Random.secure();
  final bytes = List<int>.generate(8, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

List<Map<String, dynamic>>? _sanitizeTimeline(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final timeline = <Map<String, dynamic>>[];
  for (final item in value) {
    if (item is! Map<String, dynamic> ||
        !_hasOnlyKeys(item, {'year', 'label'}) ||
        item['year'] is! int ||
        (item['year'] as int) < 1 ||
        (item['year'] as int) > 9999 ||
        item['label'] is! String) {
      return null;
    }
    final label = (item['label'] as String).trim();
    if (label.isEmpty || label.length > 120) return null;
    timeline.add({'year': item['year'], 'label': label});
  }
  return timeline;
}

List<String>? _sanitizePlaces(Object? value) {
  if (value is! List || value.isEmpty) return null;
  final places = <String>[];
  for (final place in value) {
    if (place is! String) return null;
    final label = place.trim();
    if (label.isEmpty || label.length > 120) return null;
    places.add(label);
  }
  return places;
}

class SaberPiSidecarAnchor {
  const SaberPiSidecarAnchor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'height': height,
  };

  static SaberPiSidecarAnchor? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_hasOnlyKeys(value, {'x', 'y', 'width', 'height'}) ||
        !_validUnit(value['x']) ||
        !_validUnit(value['y']) ||
        !_validUnit(value['width']) ||
        !_validUnit(value['height'])) {
      return null;
    }
    final x = (value['x'] as num).toDouble();
    final y = (value['y'] as num).toDouble();
    final width = (value['width'] as num).toDouble();
    final height = (value['height'] as num).toDouble();
    if (x + width > 1 || y + height > 1) return null;
    return SaberPiSidecarAnchor(x: x, y: y, width: width, height: height);
  }
}

class SaberPiSidecarAnnotation {
  const SaberPiSidecarAnnotation({
    required this.id,
    required this.pageIndex,
    required this.strokeSegmentId,
    required this.anchor,
    required this.outcome,
    required this.createdAt,
    required this.isCollected,
  });

  final String id;
  final int pageIndex;
  final String strokeSegmentId;
  final SaberPiSidecarAnchor anchor;
  final Map<String, dynamic> outcome;
  final String createdAt;
  final bool isCollected;

  Map<String, dynamic> toJson() => {
    'id': id,
    'pageIndex': pageIndex,
    'strokeSegmentId': strokeSegmentId,
    'anchor': anchor.toJson(),
    'outcome': outcome,
    'createdAt': createdAt,
    'isCollected': isCollected,
  };

  static SaberPiSidecarAnnotation? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_hasOnlyKeys(value, {
          'id',
          'pageIndex',
          'strokeSegmentId',
          'anchor',
          'outcome',
          'createdAt',
          'isCollected',
        }) ||
        value['id'] is! String ||
        !_safeId.hasMatch(value['id'] as String) ||
        value['pageIndex'] is! int ||
        (value['pageIndex'] as int) < 0 ||
        value['strokeSegmentId'] is! String ||
        !_safeId.hasMatch(value['strokeSegmentId'] as String) ||
        !_validTimestamp(value['createdAt']) ||
        value['isCollected'] is! bool) {
      return null;
    }
    final anchor = SaberPiSidecarAnchor.fromJson(value['anchor']);
    final outcome = sanitizeSaberPiOutcome(value['outcome']);
    if (anchor == null || outcome == null) return null;
    return SaberPiSidecarAnnotation(
      id: value['id'] as String,
      pageIndex: value['pageIndex'] as int,
      strokeSegmentId: value['strokeSegmentId'] as String,
      anchor: anchor,
      outcome: outcome,
      createdAt: value['createdAt'] as String,
      isCollected: value['isCollected'] as bool,
    );
  }
}

class SaberPiSidecarDocument {
  const SaberPiSidecarDocument({
    required this.documentId,
    required this.createdAt,
    required this.updatedAt,
    required this.annotations,
  });

  factory SaberPiSidecarDocument.empty({DateTime? now}) {
    final timestamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    return SaberPiSidecarDocument(
      documentId: _newDocumentId(),
      createdAt: timestamp,
      updatedAt: timestamp,
      annotations: const [],
    );
  }

  final String documentId;
  final String createdAt;
  final String updatedAt;
  final List<SaberPiSidecarAnnotation> annotations;

  SaberPiSidecarDocument copyWith({
    List<SaberPiSidecarAnnotation>? annotations,
    DateTime? updatedAt,
  }) => SaberPiSidecarDocument(
    documentId: documentId,
    createdAt: createdAt,
    updatedAt: (updatedAt ?? DateTime.now()).toUtc().toIso8601String(),
    annotations: annotations ?? this.annotations,
  );

  Map<String, dynamic> toJson() => {
    'schema': saberPiSidecarSchema,
    'documentId': documentId,
    'createdAt': createdAt,
    'updatedAt': updatedAt,
    'annotations': annotations
        .map((annotation) => annotation.toJson())
        .toList(),
  };

  static SaberPiSidecarDocument? fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        !_hasOnlyKeys(value, {
          'schema',
          'documentId',
          'createdAt',
          'updatedAt',
          'annotations',
        }) ||
        value['schema'] != saberPiSidecarSchema ||
        value['documentId'] is! String ||
        !_safeId.hasMatch(value['documentId'] as String) ||
        !_validTimestamp(value['createdAt']) ||
        !_validTimestamp(value['updatedAt']) ||
        value['annotations'] is! List) {
      return null;
    }
    final annotations = (value['annotations'] as List)
        .map(SaberPiSidecarAnnotation.fromJson)
        .toList(growable: false);
    if (annotations.any((annotation) => annotation == null)) return null;
    final resolved = annotations.cast<SaberPiSidecarAnnotation>();
    if (resolved.map((annotation) => annotation.id).toSet().length !=
        resolved.length) {
      return null;
    }
    return SaberPiSidecarDocument(
      documentId: value['documentId'] as String,
      createdAt: value['createdAt'] as String,
      updatedAt: value['updatedAt'] as String,
      annotations: resolved,
    );
  }
}

/// Accepts only a bridge-derived outcome and deliberately excludes PNGs,
/// headers, credentials, and arbitrary model text from the persisted layer.
Map<String, dynamic>? sanitizeSaberPiOutcome(
  Object? value, {
  String? transcription,
}) {
  if (value is! Map<String, dynamic>) return null;
  final kind = value['kind'];
  final text = value['transcription'] is String
      ? (value['transcription'] as String).trim()
      : transcription?.trim();
  if (kind is! String || text == null || text.isEmpty || text.length > 240) {
    return null;
  }
  if (kind == 'evidence') {
    final evidence = value['evidence'];
    final path = value['path'];
    final source = value['source'];
    if (!_hasOnlyKeys(value, {
          'kind',
          'transcription',
          'evidence',
          'association',
          'source',
          'path',
          'timeline',
          'places',
        }) ||
        evidence is! String ||
        path is! List ||
        path.isEmpty ||
        !path.every((node) => node is String) ||
        source is! List ||
        source.isEmpty) {
      return null;
    }
    final sources = <Map<String, String>>[];
    for (final item in source) {
      if (item is! Map || item['label'] is! String || item['url'] is! String) {
        return null;
      }
      final url = item['url'] as String;
      if (Uri.tryParse(url)?.scheme != 'https') return null;
      sources.add({'label': item['label'] as String, 'url': url});
    }
    final association = value['association'];
    final normalized = <String, dynamic>{
      'kind': kind,
      'transcription': text,
      'evidence': evidence,
      'association': association is String && association.startsWith('联想：')
          ? association
          : null,
      'source': sources,
      'path': path.cast<String>(),
    };
    if (value.containsKey('timeline')) {
      final timeline = _sanitizeTimeline(value['timeline']);
      if (timeline == null) return null;
      normalized['timeline'] = timeline;
    }
    if (value.containsKey('places')) {
      final places = _sanitizePlaces(value['places']);
      if (places == null) return null;
      normalized['places'] = places;
    }
    return normalized;
  }
  if (kind == 'ambiguous') {
    final clarification = value['clarification'];
    final candidates = value['candidates'];
    if (!_hasOnlyKeys(value, {
          'kind',
          'transcription',
          'clarification',
          'candidates',
        }) ||
        clarification is! String ||
        candidates is! List ||
        candidates.isEmpty ||
        !candidates.every((candidate) => candidate is String)) {
      return null;
    }
    return {
      'kind': kind,
      'transcription': text,
      'clarification': clarification,
      'candidates': candidates.cast<String>(),
    };
  }
  if (kind == 'gap') {
    final gap = value['gap'];
    if (!_hasOnlyKeys(value, {'kind', 'transcription', 'gap', 'association'}) ||
        gap is! String) {
      return null;
    }
    final association = value['association'];
    return {
      'kind': kind,
      'transcription': text,
      'gap': gap,
      'association': association is String && association.startsWith('联想：')
          ? association
          : null,
    };
  }
  return null;
}

class SaberPiSidecarStore {
  const SaberPiSidecarStore();

  static bool isSidecarPath(String path) => path.endsWith(_sidecarSuffix);

  /// Includes the atomically-written temporary sibling, which must be just as
  /// invisible to Saber file watching and sync as the completed sidecar.
  static bool isSidecarArtifactPath(String path) =>
      isSidecarPath(path) || path.contains('$_sidecarSuffix.');

  File fileForNote(File noteFile) {
    if (!noteFile.path.endsWith('.sbn2')) {
      throw ArgumentError.value(noteFile.path, 'noteFile', 'expected .sbn2');
    }
    return File('${noteFile.path}$_sidecarSuffix');
  }

  Future<SaberPiSidecarDocument?> readForNote(File noteFile) async {
    final file = fileForNote(noteFile);
    if (!await file.exists()) return null;
    try {
      return SaberPiSidecarDocument.fromJson(
        jsonDecode(await file.readAsString()),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeForNote(
    File noteFile,
    SaberPiSidecarDocument document,
  ) async {
    final target = fileForNote(noteFile);
    await target.parent.create(recursive: true);
    final temporary = File(
      '${target.parent.path}${Platform.pathSeparator}.${target.uri.pathSegments.last}.${_newTransactionId()}.tmp',
    );
    try {
      await temporary.writeAsString(jsonEncode(document.toJson()), flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  Future<void> moveForNote(File fromNote, File toNote) async {
    final from = fileForNote(fromNote);
    if (!await from.exists()) return;
    final to = fileForNote(toNote);
    if (await to.exists()) {
      throw StateError('sidecar_target_exists');
    }
    await to.parent.create(recursive: true);
    await from.rename(to.path);
  }

  Future<void> deleteForNote(File noteFile) async {
    final file = fileForNote(noteFile);
    if (await file.exists()) await file.delete();
  }
}
