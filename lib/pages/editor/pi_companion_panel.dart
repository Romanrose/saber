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

  @override
  Widget build(BuildContext context) {
    final outcomeKind = state.result?.outcome?['kind'];
    final visibleError = error ?? state.error;
    return Card(
      margin: const EdgeInsets.all(12),
      elevation: 3,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 280),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButton<SaberPiMode>(
                value: mode,
                isDense: true,
                underline: const SizedBox.shrink(),
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
              if (mode == SaberPiMode.quiet)
                const Text('只保存笔迹，不调用 Pi。')
              else ...[
                if (state.phase == SaberPiPhase.awakening)
                  const Row(
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      SizedBox(width: 8),
                      Text('识字中'),
                    ],
                  )
                else if (state.phase == SaberPiPhase.awaitingConfirmation) ...[
                  const Text('请确认转写：'),
                  const SizedBox(height: 6),
                  TextField(
                    controller: confirmationController,
                    maxLines: 3,
                    maxLength: 240,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 6),
                  FilledButton(
                    onPressed: onConfirm,
                    child: const Text('确认并寻迹'),
                  ),
                ] else if (outcomeKind == 'evidence')
                  const Text(
                    '有证据',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  )
                else if (outcomeKind == 'ambiguous')
                  const Text(
                    '有歧义',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  )
                else if (outcomeKind == 'gap')
                  const Text(
                    '有缺口',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  )
                else if (state.phase == SaberPiPhase.ready)
                  const Text('等待下一段笔迹。'),
                if (visibleError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '桥接不可用：$visibleError',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }
}
