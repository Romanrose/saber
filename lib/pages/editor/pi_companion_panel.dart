import 'dart:async';

import 'package:flutter/material.dart';
import 'package:saber/data/pi_companion/pi_companion_client.dart';

class PiCompanionPanel extends StatelessWidget {
  const PiCompanionPanel({
    super.key,
    required this.mode,
    required this.state,
    required this.confirmationController,
    required this.error,
    required this.onModeChanged,
    required this.onConfirm,
  });

  final SaberPiMode mode;
  final SaberPiSessionState state;
  final TextEditingController confirmationController;
  final String? error;
  final ValueChanged<SaberPiMode> onModeChanged;
  final VoidCallback onConfirm;

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

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 280),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
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
                if (state.phase == SaberPiPhase.awakening)
                  const _PencilNote('识字中……')
                else if (state.phase == SaberPiPhase.awaitingConfirmation)
                  _TranscriptionConfirmation(
                    controller: confirmationController,
                    onConfirm: onConfirm,
                  )
                else if (response != null)
                  _PaperMarginWriting(
                    key: ValueKey('${outcomeKind}_${response.text}'),
                    response: response,
                  )
                else if (state.phase == SaberPiPhase.ready)
                  const _PencilNote('等待下一段笔迹。'),
                if (visibleError != null)
                  _PencilNote('桥接不可用：$visibleError', isError: true),
              ],
            ],
          ),
        ),
      ),
    );
  }
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

class _PaperMarginWriting extends StatefulWidget {
  const _PaperMarginWriting({super.key, required this.response});

  final _PaperResponse response;

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
    if (oldWidget.response.text != widget.response.text) _startWriting();
  }

  void _startWriting() {
    _timer?.cancel();
    _glyphs = widget.response.text.runes.map(String.fromCharCode).toList();
    _visibleGlyphs = 0;
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
      fontFamily: 'serif',
      fontSize: 16,
      height: 1.9,
      letterSpacing: 0.25,
    );

    return Semantics(
      label: '${widget.response.label}：${widget.response.text}',
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.only(top: 18, left: 10, right: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 4, right: 8),
                child: Text(
                  widget.response.seal,
                  style: const TextStyle(
                    color: Color(0xff8a503d),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: DecoratedBox(
                  decoration: const BoxDecoration(
                    border: Border(left: BorderSide(color: Color(0x66775a46))),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
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

class _TranscriptionConfirmation extends StatelessWidget {
  const _TranscriptionConfirmation({
    required this.controller,
    required this.onConfirm,
  });

  final TextEditingController controller;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8, left: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('请确认转写：'),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          maxLines: 3,
          maxLength: 240,
          decoration: const InputDecoration(
            isDense: true,
            border: UnderlineInputBorder(),
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton(onPressed: onConfirm, child: const Text('确认并寻迹')),
        ),
      ],
    ),
  );
}
