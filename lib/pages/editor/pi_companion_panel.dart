import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/data/pi_companion/pi_companion_client.dart';

class PiCompanionPanel extends StatelessWidget {
  const PiCompanionPanel({
    super.key,
    required this.mode,
    required this.state,
    required this.anchor,
    required this.confirmationController,
    required this.error,
    this.notice,
    required this.onModeChanged,
    required this.onConfirm,
    this.onCandidate,
    this.onRetry,
    this.onJourneyRouteSelected,
    this.onToggleTraceCard,
    this.traceCardExpanded = false,
    this.showModeControl = true,
    this.showOutcome = true,
    this.animateOutcome = true,
    this.topOffset = 0,
    this.placeOnRight,
  });

  final SaberPiMode mode;
  final SaberPiSessionState state;
  final Rect anchor;
  final TextEditingController confirmationController;
  final String? error;
  final String? notice;
  final ValueChanged<SaberPiMode> onModeChanged;
  final VoidCallback onConfirm;
  final ValueChanged<String>? onCandidate;
  final VoidCallback? onRetry;
  final ValueChanged<String>? onJourneyRouteSelected;
  final VoidCallback? onToggleTraceCard;
  final bool traceCardExpanded;
  final bool showModeControl;
  final bool showOutcome;
  final bool animateOutcome;
  final double topOffset;
  final bool? placeOnRight;

  String? _textValue(Object? value) {
    if (value is! String) return null;
    final text = value.trim();
    return text.isEmpty ? null : text;
  }

  _PaperResponse? _paperResponse(String? kind) {
    final outcome = state.result?.outcome;
    if (outcome == null || kind == null) return null;

    if (kind == 'evidence') {
      final evidence = _textValue(outcome['evidence']);
      final path = (outcome['path'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .join(' → ');
      final sources = outcome['source'];
      final firstSource = sources is List && sources.isNotEmpty
          ? sources.first
          : null;
      final sourceLabel = firstSource is Map
          ? _textValue(firstSource['label'])
          : null;
      final sourceLine = sourceLabel == null ? null : '来源：$sourceLabel';
      final lines = <String>[
        ?evidence,
        if (path.isNotEmpty) '寻迹：$path',
        ?sourceLine,
      ];
      return lines.isEmpty
          ? null
          : _PaperResponse(seal: '据', label: '有证据', text: lines.join('\n'));
    }

    if (kind == 'ambiguous') {
      final clarification = _textValue(outcome['clarification']);
      final candidates = (outcome['candidates'] as List<dynamic>? ?? const [])
          .whereType<String>()
          .join('、');
      final lines = <String>[
        ?clarification,
        if (candidates.isNotEmpty) '可确认：$candidates',
      ];
      return lines.isEmpty
          ? null
          : _PaperResponse(seal: '问', label: '有歧义', text: lines.join('\n'));
    }

    if (kind == 'gap') {
      final gap = _textValue(outcome['gap']);
      final association = _textValue(outcome['association']);
      final lines = <String>[?gap, ?association];
      return lines.isEmpty
          ? null
          : _PaperResponse(seal: '缺', label: '有缺口', text: lines.join('\n'));
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final outcomeKind = state.result?.outcome?['kind'] as String?;
    final response = _paperResponse(outcomeKind);
    final visibleError = error ?? state.error;

    return SizedBox.expand(
      child: LayoutBuilder(
        builder: (context, constraints) {
          const edge = 18.0;
          const gap = 16.0;
          const preferredWidth = 280.0;
          const reservedHeight = 240.0;
          final width = (constraints.maxWidth - 2 * edge)
              .clamp(0.0, preferredWidth)
              .toDouble();
          final rightLeft = anchor.right + gap;
          final canFitRight =
              placeOnRight ?? rightLeft + width <= constraints.maxWidth - edge;
          final left = (canFitRight ? rightLeft : anchor.left - gap - width)
              .clamp(edge, constraints.maxWidth - edge - width)
              .toDouble();
          final maximumTop = (constraints.maxHeight - edge - reservedHeight)
              .clamp(edge, double.infinity)
              .toDouble();
          final top = (anchor.top + topOffset)
              .clamp(edge, maximumTop)
              .toDouble();
          final maxHeight = (constraints.maxHeight - top - edge)
              .clamp(0.0, double.infinity)
              .toDouble();

          return Stack(
            children: [
              if (state.phase == SaberPiPhase.awakening)
                IgnorePointer(
                  child: _InkAwakening(
                    key: ValueKey(state.strokeSegmentId),
                    anchor: anchor,
                  ),
                ),
              Positioned(
                left: left,
                top: top,
                width: width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxHeight),
                  child: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (showModeControl)
                          Align(
                            alignment: Alignment.centerRight,
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<SaberPiMode>(
                                value: mode,
                                isDense: true,
                                onChanged: (value) {
                                  if (value != null) onModeChanged(value);
                                },
                                items: const [
                                  DropdownMenuItem(
                                    value: SaberPiMode.seek,
                                    child: Text('寻迹模式'),
                                  ),
                                  DropdownMenuItem(
                                    value: SaberPiMode.quiet,
                                    child: Text('静读模式'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (mode == SaberPiMode.quiet)
                          const _PencilNote('只保存笔迹，不调用 Pi。')
                        else ...[
                          if (state.journey != null &&
                              state.journey!.route == null)
                            _JourneyRoutePicker(
                              journey: state.journey!,
                              onSelected: onJourneyRouteSelected,
                            )
                          else if (state.phase == SaberPiPhase.awakening)
                            const _PencilNote('识字中……首次可能需准备中文笔迹模型。')
                          else if (state.phase ==
                              SaberPiPhase.awaitingConfirmation)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                _TranscriptionConfirmation(
                                  controller: confirmationController,
                                  candidates:
                                      state.transcription?.candidates ??
                                      const [],
                                  onConfirm: onConfirm,
                                  onCandidate: onCandidate,
                                ),
                                if (notice != null) _PencilNote(notice!),
                              ],
                            )
                          else if (state.phase == SaberPiPhase.seeking)
                            const _PencilNote('寻迹中……')
                          else if (response != null && showOutcome)
                            _PaperResponseWithTraceCard(
                              response: response,
                              animate: animateOutcome,
                              outcome: state.result?.outcome,
                              expanded: traceCardExpanded,
                              onToggle: onToggleTraceCard,
                            )
                          else if (state.phase == SaberPiPhase.ready &&
                              showOutcome)
                            const _PencilNote('等待下一段笔迹。'),
                          if (visibleError != null) ...[
                            _PencilNote('寻迹暂不可用：$visibleError', isError: true),
                            if (onRetry != null)
                              Align(
                                alignment: Alignment.centerLeft,
                                child: TextButton.icon(
                                  onPressed: onRetry,
                                  icon: const Icon(Icons.refresh),
                                  label: const Text('重试识字'),
                                ),
                              ),
                          ],
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InkAwakening extends StatefulWidget {
  const _InkAwakening({super.key, required this.anchor});

  final Rect anchor;

  @override
  State<_InkAwakening> createState() => _InkAwakeningState();
}

class _InkAwakeningState extends State<_InkAwakening>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 720),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: _InkAwakeningPainter(anchor: widget.anchor, progress: _controller),
    child: const SizedBox.expand(),
  );
}

class _InkAwakeningPainter extends CustomPainter {
  const _InkAwakeningPainter({required this.anchor, required this.progress})
    : super(repaint: progress);

  final Rect anchor;
  final Animation<double> progress;

  @override
  void paint(Canvas canvas, Size size) {
    final pulse = progress.value;
    final breathingBounds = anchor.inflate(5 + 5 * pulse);
    final breathingPaint = Paint()
      ..color = const Color(0xff7b513f).withValues(alpha: 0.18 + 0.16 * pulse)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2 + pulse;
    canvas.drawRRect(
      RRect.fromRectAndRadius(breathingBounds, const Radius.circular(10)),
      breathingPaint,
    );

    const edge = 18.0;
    final hasRoomOnRight = anchor.right + 46 < size.width - edge;
    final direction = hasRoomOnRight ? 1.0 : -1.0;
    final start = Offset(
      hasRoomOnRight ? anchor.right + 6 : anchor.left - 6,
      anchor.center.dy,
    );
    final available = hasRoomOnRight
        ? size.width - edge - start.dx
        : start.dx - edge;
    final length = available.clamp(0.0, 54.0 + 22.0 * pulse).toDouble();
    if (length <= 0) return;

    final end = Offset(start.dx + direction * length, start.dy - 10);
    final path = Path()
      ..moveTo(start.dx, start.dy)
      ..quadraticBezierTo(
        start.dx + direction * length * 0.45,
        start.dy + 8,
        end.dx,
        end.dy,
      );
    final metric = path.computeMetrics().single;
    final drawn = metric.extractPath(0, metric.length * (0.35 + 0.65 * pulse));
    final trailPaint = Paint()
      ..color = const Color(0xff8a503d).withValues(alpha: 0.28 + 0.24 * pulse)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(drawn, trailPaint);
  }

  @override
  bool shouldRepaint(covariant _InkAwakeningPainter oldDelegate) =>
      oldDelegate.anchor != anchor || oldDelegate.progress != progress;
}

class _PaperResponse {
  const _PaperResponse({
    required this.seal,
    required this.label,
    required this.text,
  });

  final String seal;
  final String label;
  final String text;
}

class _PaperResponseWithTraceCard extends StatelessWidget {
  const _PaperResponseWithTraceCard({
    required this.response,
    required this.animate,
    required this.outcome,
    required this.expanded,
    required this.onToggle,
  });

  final _PaperResponse response;
  final bool animate;
  final Map<String, dynamic>? outcome;
  final bool expanded;
  final VoidCallback? onToggle;

  @override
  Widget build(BuildContext context) {
    final canExpand = outcome?['kind'] == 'evidence' && onToggle != null;
    final responseWriting = _PaperMarginWriting(
      key: ValueKey('${response.label}_${response.text}'),
      response: response,
      animate: animate,
    );
    if (!canExpand) return responseWriting;

    return Semantics(
      button: true,
      label: expanded ? '有证据，轻触收起寻迹卡' : '有证据，轻触展开寻迹卡',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onToggle,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            responseWriting,
            if (expanded) _TraceCard(outcome: outcome!),
          ],
        ),
      ),
    );
  }
}

class _TraceCard extends StatelessWidget {
  const _TraceCard({required this.outcome});

  final Map<String, dynamic> outcome;

  @override
  Widget build(BuildContext context) {
    final sources = (outcome['source'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((source) => source['label'])
        .whereType<String>()
        .toList(growable: false);
    final pathNodes = (outcome['path'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .map((node) => node.trim())
        .where((node) => node.isNotEmpty)
        .toList(growable: false);
    final timeline = (outcome['timeline'] as List<dynamic>? ?? const [])
        .whereType<Map>()
        .map((item) {
          final year = item['year'];
          final label = item['label'];
          if (year is! int || label is! String || label.trim().isEmpty) {
            return null;
          }
          return '$year年 · ${label.trim()}';
        })
        .whereType<String>()
        .toList(growable: false);
    final places = (outcome['places'] as List<dynamic>? ?? const [])
        .whereType<String>()
        .map((place) => place.trim())
        .where((place) => place.isNotEmpty)
        .toList(growable: false);

    return Container(
      margin: const EdgeInsets.only(top: 8, left: 25, right: 2),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 9),
      decoration: BoxDecoration(
        color: const Color(0x11745146),
        border: Border.all(color: const Color(0x55745146)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Color(0xff604638),
          fontFamily: 'cursive',
          fontSize: 13,
          height: 1.55,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('寻迹卡', style: TextStyle(fontSize: 14)),
            if (pathNodes.isNotEmpty) ...[
              const SizedBox(height: 3),
              const Text('关系路径'),
              const SizedBox(height: 2),
              _TracePath(nodes: pathNodes),
            ],
            if (timeline.isNotEmpty || places.isNotEmpty) ...[
              const SizedBox(height: 5),
              const Text('二级时空索引'),
            ],
            if (timeline.isNotEmpty) ...[
              const SizedBox(height: 2),
              const Text('时间线'),
              for (final item in timeline) Text('• $item'),
            ],
            if (places.isNotEmpty) ...[
              const SizedBox(height: 2),
              const Text('地点索引'),
              for (final place in places) Text('• $place'),
            ],
            for (final source in sources) Text('来源：$source'),
          ],
        ),
      ),
    );
  }
}

class _TracePath extends StatelessWidget {
  const _TracePath({required this.nodes});

  final List<String> nodes;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (var index = 0; index < nodes.length; index++)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 14,
              child: Column(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    margin: const EdgeInsets.only(top: 5),
                    decoration: const BoxDecoration(
                      color: Color(0xff8a503d),
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (index < nodes.length - 1)
                    Container(
                      width: 1,
                      height: 15,
                      color: const Color(0x99745146),
                    ),
                ],
              ),
            ),
            Expanded(child: Text(nodes[index])),
          ],
        ),
    ],
  );
}

class _PaperMarginWriting extends StatefulWidget {
  const _PaperMarginWriting({
    super.key,
    required this.response,
    required this.animate,
  });

  final _PaperResponse response;
  final bool animate;

  @override
  State<_PaperMarginWriting> createState() => _PaperMarginWritingState();
}

class _PaperMarginWritingState extends State<_PaperMarginWriting> {
  static const _writingInterval = Duration(milliseconds: 42);
  Timer? _timer;
  late List<String> _glyphs;
  var _visibleGlyphs = 0;

  @override
  void initState() {
    super.initState();
    _startWriting();
  }

  @override
  void didUpdateWidget(covariant _PaperMarginWriting oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.response.text != widget.response.text ||
        oldWidget.animate != widget.animate) {
      _startWriting();
    }
  }

  void _startWriting() {
    _timer?.cancel();
    _glyphs = widget.response.text.runes.map(String.fromCharCode).toList();
    _visibleGlyphs = widget.animate ? 0 : _glyphs.length;
    if (!widget.animate) return;
    _timer = Timer.periodic(_writingInterval, (timer) {
      if (!mounted || _visibleGlyphs >= _glyphs.length) {
        timer.cancel();
        return;
      }
      setState(() => _visibleGlyphs += 1);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final revealed = _glyphs.take(_visibleGlyphs).join();
    final isWriting = _visibleGlyphs < _glyphs.length;
    final textStyle = Theme.of(context).textTheme.bodyLarge?.copyWith(
      color: const Color(0xff443126),
      fontFamily: 'cursive',
      fontSize: 17,
      height: 1.95,
      letterSpacing: 0.45,
    );

    return Semantics(
      label: '${widget.response.label}：${widget.response.text}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: 18, left: 10, right: 2),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: 0,
                top: 3,
                child: Transform.rotate(
                  angle: -0.08,
                  child: Text(
                    widget.response.seal,
                    style: const TextStyle(
                      color: Color(0xff8a503d),
                      fontFamily: 'cursive',
                      fontSize: 15,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 25, right: 2),
                child: Text.rich(
                  TextSpan(
                    style: textStyle,
                    children: [
                      TextSpan(text: revealed),
                      if (isWriting)
                        const WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: _InkCursor(),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _InkCursor extends StatelessWidget {
  const _InkCursor();

  @override
  Widget build(BuildContext context) => Container(
    width: 1.5,
    height: 17,
    margin: const EdgeInsets.only(left: 1),
    color: const Color(0xff6f4536),
  );
}

class _PencilNote extends StatelessWidget {
  const _PencilNote(this.text, {this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      textAlign: TextAlign.right,
      style: TextStyle(
        color: isError
            ? Theme.of(context).colorScheme.error
            : const Color(0xff705d4c),
        fontSize: 13,
        fontStyle: FontStyle.italic,
      ),
    ),
  );
}

class _JourneyRoutePicker extends StatelessWidget {
  const _JourneyRoutePicker({required this.journey, this.onSelected});

  final SaberPiJourneyState journey;
  final ValueChanged<String>? onSelected;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    label: '人物确认后的路线引导',
    child: Padding(
      padding: const EdgeInsets.only(top: 10, left: 4, right: 2),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: const Color(0xffefe0c7),
          border: Border.all(color: const Color(0x88b08a6d)),
          borderRadius: BorderRadius.circular(2),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '引导 · 人物已确认',
                style: TextStyle(
                  color: Color(0xff8b523e),
                  fontSize: 11,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                '你已从“${journey.anchor}”起笔。',
                style: const TextStyle(
                  color: Color(0xff604638),
                  fontFamily: 'cursive',
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '下一步请选择一条路线，纸页会告诉你下一笔写什么：',
                style: TextStyle(color: Color(0xff705d4c), fontSize: 13),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 5,
                runSpacing: 5,
                children: [
                  _JourneyRouteButton(
                    label: '地点',
                    hint: '他走过哪里',
                    onPressed: onSelected == null
                        ? null
                        : () => onSelected!('space'),
                  ),
                  _JourneyRouteButton(
                    label: '经历',
                    hint: '哪些事改变了他',
                    onPressed: onSelected == null
                        ? null
                        : () => onSelected!('life'),
                  ),
                  _JourneyRouteButton(
                    label: '作品',
                    hint: '哪些文字留下回声',
                    onPressed: onSelected == null
                        ? null
                        : () => onSelected!('work'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _JourneyRouteButton extends StatelessWidget {
  const _JourneyRouteButton({
    required this.label,
    required this.hint,
    this.onPressed,
  });

  final String label;
  final String hint;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => OutlinedButton(
    onPressed: onPressed,
    style: OutlinedButton.styleFrom(
      minimumSize: const Size(82, 38),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      foregroundColor: const Color(0xff604638),
      side: const BorderSide(color: Color(0x99745146)),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 14)),
        Text(hint, style: const TextStyle(fontSize: 10)),
      ],
    ),
  );
}

class _TranscriptionConfirmation extends StatelessWidget {
  const _TranscriptionConfirmation({
    required this.controller,
    required this.candidates,
    required this.onConfirm,
    this.onCandidate,
  });

  final TextEditingController controller;
  final List<String> candidates;
  final VoidCallback onConfirm;
  final ValueChanged<String>? onCandidate;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 16, left: 6, right: 4),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '识到：',
          style: TextStyle(
            color: Color(0xff745346),
            fontFamily: 'cursive',
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 2),
        DecoratedBox(
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: Color(0x88775a46))),
          ),
          child: TextField(
            controller: controller,
            maxLines: 3,
            maxLength: 240,
            onSubmitted: (_) => onConfirm(),
            cursorColor: const Color(0xff6f4536),
            style: const TextStyle(
              color: Color(0xff443126),
              fontFamily: 'cursive',
              fontSize: 18,
              height: 1.75,
              letterSpacing: 0.45,
            ),
            decoration: const InputDecoration(
              isDense: true,
              border: InputBorder.none,
              counterText: '',
              contentPadding: EdgeInsets.only(bottom: 3),
            ),
          ),
        ),
        if (onCandidate != null)
          Builder(
            builder: (context) {
              final alternatives = candidates
                  .map((candidate) => candidate.trim())
                  .where(
                    (candidate) =>
                        candidate.isNotEmpty &&
                        candidate != controller.text.trim(),
                  )
                  .toSet()
                  .take(2)
                  .toList(growable: false);
              if (alternatives.isEmpty) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 5,
                  children: [
                    for (final candidate in alternatives)
                      GestureDetector(
                        onTap: () => onCandidate!(candidate),
                        child: Text(
                          '候选：$candidate',
                          style: const TextStyle(
                            color: Color(0xff76503d),
                            fontFamily: 'cursive',
                            fontSize: 14,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
        const SizedBox(height: 5),
        GestureDetector(
          onTap: onConfirm,
          child: const Text(
            '↳ 以此寻迹',
            style: TextStyle(
              color: Color(0xff76503d),
              fontFamily: 'cursive',
              fontSize: 15,
            ),
          ),
        ),
      ],
    ),
  );
}
