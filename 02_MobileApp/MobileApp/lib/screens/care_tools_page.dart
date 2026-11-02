import 'dart:async';

import 'package:flutter/material.dart';

/// Optional, gentle self-care activities. These are not prescribed treatment.
class CareToolsPage extends StatefulWidget {
  const CareToolsPage({super.key});

  @override
  State<CareToolsPage> createState() => _CareToolsPageState();
}

class _CareToolsPageState extends State<CareToolsPage> with SingleTickerProviderStateMixin {
  static const _duration = Duration(minutes: 2);
  final List<_CareActivity> _activities = const [
    _CareActivity('Paced breathing', 'Sit comfortably and breathe gently without holding your breath.', Icons.air_outlined, 120),
    _CareActivity('Hand opening', 'Rest your forearms on a support. Slowly open and close your hands only within a comfortable range.', Icons.back_hand_outlined, 60),
    _CareActivity('Shoulder release', 'Let your shoulders settle. Make a small, easy shoulder roll if it feels comfortable.', Icons.accessibility_new_outlined, 60),
    _CareActivity('Grounding pause', 'Notice five things you can see, four you can feel, and three sounds you can hear.', Icons.spa_outlined, 90),
  ];

  Timer? _timer;
  late final AnimationController _breathAnimation;
  int _selected = 0;
  int _remainingSeconds = 120;
  bool _running = false;

  @override
  void initState() {
    super.initState();
    _breathAnimation = AnimationController(vsync: this, duration: const Duration(seconds: 5), lowerBound: .82, upperBound: 1.08);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _breathAnimation.dispose();
    super.dispose();
  }

  void _start() {
    _timer?.cancel();
    final seconds = _activities[_selected].seconds;
    setState(() { _remainingSeconds = seconds; _running = true; });
    if (_selected == 0 && !MediaQuery.of(context).disableAnimations) _breathAnimation.repeat(reverse: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return timer.cancel();
      if (_remainingSeconds <= 1) {
        timer.cancel();
        _breathAnimation.stop();
        setState(() { _remainingSeconds = 0; _running = false; });
      } else {
        setState(() => _remainingSeconds--);
      }
    });
  }

  void _stop() {
    _timer?.cancel();
    _breathAnimation.stop();
    _breathAnimation.value = 1;
    setState(() { _running = false; _remainingSeconds = _activities[_selected].seconds; });
  }

  void _select(int index) {
    if (_running) _stop();
    setState(() { _selected = index; _remainingSeconds = _activities[index].seconds; });
  }

  String _clock(int seconds) => '${(seconds ~/ 60).toString().padLeft(1, '0')}:${(seconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final activity = _activities[_selected];
    final elapsed = activity.seconds - _remainingSeconds;
    final inhalePhase = elapsed % 10 < 4;
    final phaseText = !_running ? 'Ready when you are' : (_selected == 0 ? (inhalePhase ? 'Breathe in gently' : 'Breathe out slowly') : 'Move at your own pace');
    return Scaffold(
      appBar: AppBar(title: const Text('Care tools and exercises')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 30),
        children: [
          Text('Choose a short, gentle activity', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          Text('Stop any activity that causes pain, dizziness, fatigue, or worse symptoms. These activities are optional and do not replace clinical advice.', style: TextStyle(color: colors.onSurfaceVariant, height: 1.45)),
          const SizedBox(height: 16),
          for (var i = 0; i < _activities.length; i++) ...[
            _ActivityTile(activity: _activities[i], selected: _selected == i, onTap: () => _select(i)),
            const SizedBox(height: 9),
          ],
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                children: [
                  Row(children: [Icon(activity.icon, color: colors.primary), const SizedBox(width: 9), Expanded(child: Text(activity.title, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)))]),
                  const SizedBox(height: 8),
                  Text(activity.description, textAlign: TextAlign.center, style: TextStyle(color: colors.onSurfaceVariant, height: 1.45)),
                  const SizedBox(height: 20),
                  if (_selected == 0 && !MediaQuery.of(context).disableAnimations)
                    AnimatedBuilder(
                      animation: _breathAnimation,
                      builder: (context, _) => Transform.scale(
                        scale: _running ? _breathAnimation.value : 1.0,
                        child: _circle(colors, phaseText, _running ? _clock(_remainingSeconds) : _clock(activity.seconds)),
                      ),
                    )
                  else
                    _circle(colors, phaseText, _running ? _clock(_remainingSeconds) : _clock(activity.seconds)),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _running ? _stop : _start,
                      icon: Icon(_running ? Icons.stop_circle_outlined : Icons.play_arrow_rounded),
                      label: Text(_running ? 'Stop activity' : 'Start activity'),
                    ),
                  ),
                  if (_remainingSeconds == 0 && !_running) ...[
                    const SizedBox(height: 10),
                    const Text('Session complete. Take a moment to notice how you feel.', textAlign: TextAlign.center),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(color: colors.surfaceContainerHighest.withValues(alpha: .45), child: const Padding(padding: EdgeInsets.all(14), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Icon(Icons.info_outline), SizedBox(width: 10), Expanded(child: Text('No exercise is required. Choose only movements that are comfortable for you and follow any individualized advice from your clinician.', style: TextStyle(fontSize: 12, height: 1.45)))]))),
        ],
      ),
    );
  }

  Widget _circle(ColorScheme colors, String phase, String clock) => Container(
    width: 176,
    height: 176,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      gradient: RadialGradient(colors: [colors.primaryContainer.withValues(alpha: .8), colors.surface]),
      border: Border.all(color: colors.primary.withValues(alpha: .55), width: 2),
      boxShadow: [BoxShadow(color: colors.primary.withValues(alpha: .10), blurRadius: 24, spreadRadius: 2)],
    ),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Text(phase, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
      const SizedBox(height: 7),
      Text(clock, style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w800)),
    ]),
  );
}

class _CareActivity {
  final String title;
  final String description;
  final IconData icon;
  final int seconds;
  const _CareActivity(this.title, this.description, this.icon, this.seconds);
}

class _ActivityTile extends StatelessWidget {
  final _CareActivity activity;
  final bool selected;
  final VoidCallback onTap;
  const _ActivityTile({required this.activity, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: selected ? colors.primaryContainer.withValues(alpha: .52) : Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(18),
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(15),
            child: Row(children: [
              Container(width: 44, height: 44, decoration: BoxDecoration(color: colors.primary.withValues(alpha: .12), borderRadius: BorderRadius.circular(14)), child: Icon(activity.icon, color: colors.primary)),
              const SizedBox(width: 12),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(activity.title, style: const TextStyle(fontWeight: FontWeight.w700)), const SizedBox(height: 4), Text('${activity.seconds ~/ 60} min${activity.seconds % 60 == 0 ? '' : ' ${activity.seconds % 60} sec'}', style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant))])),
              Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off, color: selected ? colors.primary : colors.onSurfaceVariant),
            ]),
          ),
        ),
      ),
    );
  }
}
