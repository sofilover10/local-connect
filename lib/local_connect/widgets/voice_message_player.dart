import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';

/// مشغّل مصغَّر لرسالة صوتية واحدة داخل فقاعة المحادثة: زر تشغيل/إيقاف
/// ومدة العرض. كل فقاعة تملك مشغّلها الخاص (بسيط ومعزول، لا حاجة لمشاركة
/// حالة تشغيل مركزية في هذا الإصدار الأول).
class VoiceMessagePlayer extends StatefulWidget {
  const VoiceMessagePlayer({super.key, required this.filePath, required this.iconColor});

  final String filePath;
  final Color iconColor;

  @override
  State<VoiceMessagePlayer> createState() => _VoiceMessagePlayerState();
}

class _VoiceMessagePlayerState extends State<VoiceMessagePlayer> {
  final _player = AudioPlayer();
  PlayerState _state = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _state = state);
    });
    _player.onDurationChanged.listen((duration) {
      if (mounted) setState(() => _duration = duration);
    });
    _player.onPositionChanged.listen((position) {
      if (mounted) setState(() => _position = position);
    });
  }

  Future<void> _toggle() async {
    if (_state == PlayerState.playing) {
      await _player.pause();
    } else {
      await _player.play(DeviceFileSource(widget.filePath));
    }
  }

  String _format(Duration d) {
    final minutes = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shown = _duration > Duration.zero ? _duration : _position;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(),
          icon: Icon(
            _state == PlayerState.playing ? Icons.pause_circle : Icons.play_circle,
            color: widget.iconColor,
            size: 32,
          ),
          onPressed: _toggle,
        ),
        const SizedBox(width: 6),
        Text(_format(shown), style: TextStyle(color: widget.iconColor)),
      ],
    );
  }
}
