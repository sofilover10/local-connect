import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../models/call_session.dart';
import '../services/call_service.dart';

/// طبقة عامة تُوضَع أعلى كل شاشات التطبيق (عبر `MaterialApp.builder` في
/// main.dart) — تعرض شاشة المكالمة كاملة كلما كان هناك [CallSession] جارٍ،
/// بغض النظر عن الشاشة الحالية التي يتصفّحها المستخدم. هذا يحقق سلوك "رنين
/// يظهر فورًا أينما كنت في التطبيق" كبرامج المحادثة العادية.
class CallOverlay extends StatelessWidget {
  const CallOverlay({super.key, required this.callService});

  final CallService callService;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: callService,
      builder: (context, _) {
        final call = callService.currentCall;
        if (call == null) return const SizedBox.shrink();
        return CallScreen(callService: callService, call: call);
      },
    );
  }
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.callService, required this.call});

  final CallService callService;
  final CallSession call;

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  Timer? _durationTicker;
  Timer? _vibrateTimer;

  @override
  void initState() {
    super.initState();
    // يُحدِّث عداد مدة المكالمة كل ثانية أثناء الاتصال الفعلي — الودجت
    // نفسها لا تُعاد بالضرورة عند كل تغيّر في CallSession (كائن قابل
    // للتحوّل، لا Widget جديدة)، فيحتاج عدّاده تحديثًا مستقلًا هنا.
    _durationTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _durationTicker?.cancel();
    _vibrateTimer?.cancel();
    super.dispose();
  }

  /// بلا ملف نغمة رنين مُرفَق بالتطبيق (لا أصول صوتية)، فالاهتزاز المتكرر
  /// + شارة "مكالمة واردة" النابضة بصريًا هما بديل "الرنين" الفعلي هنا.
  void _syncVibration(CallSession call) {
    final shouldVibrate = call.state == CallState.ringing && call.direction == CallDirection.incoming;
    if (shouldVibrate && _vibrateTimer == null) {
      HapticFeedback.vibrate();
      _vibrateTimer = Timer.periodic(const Duration(seconds: 1), (_) => HapticFeedback.vibrate());
    } else if (!shouldVibrate && _vibrateTimer != null) {
      _vibrateTimer?.cancel();
      _vibrateTimer = null;
    }
  }

  String _formatDuration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '${h.toString().padLeft(2, '0')}:$m:$s' : '$m:$s';
  }

  String _statusText(CallSession call) {
    switch (call.state) {
      case CallState.ringing:
        if (call.direction != CallDirection.incoming) return 'جارٍ الاتصال...';
        // نوع المكالمة (صوتية/فيديو) مطلوب أن يظهر بوضوح على شاشة المكالمة
        // الواردة — كان النص السابق "مكالمة واردة" فقط بلا تمييز النوع.
        return call.mediaType == CallMediaType.video ? 'مكالمة فيديو واردة' : 'مكالمة صوتية واردة';
      case CallState.connecting:
        return 'جارٍ الاتصال...';
      case CallState.reconnecting:
        return 'جارٍ إعادة الاتصال...';
      case CallState.active:
        if (call.pendingOutgoingVideoUpgrade) return 'بانتظار موافقة الطرف الآخر على الفيديو...';
        return _formatDuration(call.elapsed);
      case CallState.ended:
        return call.endReason ?? 'انتهت المكالمة';
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final callService = widget.callService;
    _syncVibration(call);

    // أثناء إعادة الاتصال تُعامَل كالحالة النشطة في العرض (يبقى الفيديو
    // الأخير ظاهرًا بدل وميض للشعار) — النص وحده يتغير لـ«جاري إعادة
    // الاتصال…».
    final ongoing = call.state == CallState.active || call.state == CallState.reconnecting;
    final showRemoteVideo = call.mediaType == CallMediaType.video && ongoing;
    final showLocalPreview = call.mediaType == CallMediaType.video &&
        (call.state == CallState.connecting || ongoing) &&
        !callService.isCameraOff;

    return PopScope(
      // لا يُغلَق بزر الرجوع — يجب إنهاء المكالمة صراحة عبر زر الإنهاء، وإلا
      // بقيت جلسة WebRTC مفتوحة بصمت خلف الشاشة السابقة.
      canPop: false,
      child: Material(
        color: Colors.black,
        child: SafeArea(
          child: Stack(
            children: [
              if (showRemoteVideo)
                Positioned.fill(
                  child: RTCVideoView(callService.remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover),
                )
              else
                _AudioBackground(call: call),
              if (showLocalPreview)
                Positioned(
                  top: 16,
                  right: 16,
                  width: 100,
                  height: 140,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: RTCVideoView(callService.localRenderer, mirror: true),
                  ),
                ),
              Positioned(
                top: 24,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    Text(
                      call.peerDisplayName,
                      style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 2),
                    // رقم المتصل الداخلي — يظهر دومًا، ومهم خصوصًا في شاشة
                    // المكالمة الواردة حتى يعرف المستخدم مين المتصل بدقة ولو
                    // لم يحفظه بعد كجهة اتصال.
                    Text(
                      call.peerInternalNumber,
                      style: const TextStyle(color: Colors.white54, fontSize: 13),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _statusText(call),
                      style: const TextStyle(color: Colors.white70, fontSize: 15),
                    ),
                  ],
                ),
              ),
              if (call.pendingIncomingVideoUpgrade)
                Positioned(
                  left: 16,
                  right: 16,
                  bottom: 160,
                  child: _VideoUpgradeRequestBanner(callService: callService, call: call),
                ),
              Positioned(
                bottom: 40,
                left: 0,
                right: 0,
                child: call.state == CallState.ringing && call.direction == CallDirection.incoming
                    ? _IncomingCallControls(callService: callService)
                    : _ActiveCallControls(callService: callService, call: call),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AudioBackground extends StatelessWidget {
  const _AudioBackground({required this.call});

  final CallSession call;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.grey.shade900,
      alignment: Alignment.center,
      child: _PulsingAvatar(active: call.state == CallState.ringing, name: call.peerDisplayName),
    );
  }
}

class _PulsingAvatar extends StatefulWidget {
  const _PulsingAvatar({required this.active, required this.name});

  final bool active;
  final String name;

  @override
  State<_PulsingAvatar> createState() => _PulsingAvatarState();
}

class _PulsingAvatarState extends State<_PulsingAvatar> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  )..repeat(reverse: true);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final initial = widget.name.isNotEmpty ? widget.name.characters.first : '?';
    return ScaleTransition(
      scale: widget.active
          ? Tween(begin: 0.95, end: 1.08).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut))
          : const AlwaysStoppedAnimation(1.0),
      child: CircleAvatar(
        radius: 56,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Text(initial, style: const TextStyle(fontSize: 40, color: Colors.white)),
      ),
    );
  }
}

class _IncomingCallControls extends StatelessWidget {
  const _IncomingCallControls({required this.callService});

  final CallService callService;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _CallButton(
          icon: Icons.call_end,
          color: Colors.red,
          label: 'رفض',
          onPressed: callService.rejectCall,
        ),
        _CallButton(
          icon: Icons.call,
          color: Colors.green,
          label: 'قبول',
          onPressed: callService.acceptCall,
        ),
      ],
    );
  }
}

class _ActiveCallControls extends StatelessWidget {
  const _ActiveCallControls({required this.callService, required this.call});

  final CallService callService;
  final CallSession call;

  @override
  Widget build(BuildContext context) {
    final ended = call.state == CallState.ended;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _ToggleButton(
              icon: callService.isMuted ? Icons.mic_off : Icons.mic,
              active: callService.isMuted,
              onPressed: ended ? null : callService.toggleMute,
            ),
            const SizedBox(width: 20),
            _ToggleButton(
              icon: callService.isSpeakerOn ? Icons.volume_up : Icons.hearing,
              active: callService.isSpeakerOn,
              onPressed: ended ? null : callService.toggleSpeaker,
            ),
            if (call.mediaType == CallMediaType.video) ...[
              const SizedBox(width: 20),
              _ToggleButton(
                icon: callService.isCameraOff ? Icons.videocam_off : Icons.videocam,
                active: callService.isCameraOff,
                onPressed: ended ? null : callService.toggleCamera,
              ),
              const SizedBox(width: 20),
              _ToggleButton(
                icon: Icons.cameraswitch,
                active: false,
                onPressed: ended ? null : callService.switchCamera,
              ),
            ] else if (call.state == CallState.active) ...[
              const SizedBox(width: 20),
              // التحويل من صوت لفيديو أثناء مكالمة جارية — لا تُشغَّل كاميرا
              // الطرف الآخر إطلاقًا قبل موافقته الصريحة (راجع
              // CallService.requestVideoUpgrade). الزر مُعطَّل أثناء انتظار
              // الرد لمنع طلبات متكررة.
              _ToggleButton(
                icon: Icons.videocam,
                active: call.pendingOutgoingVideoUpgrade,
                onPressed: call.pendingOutgoingVideoUpgrade ? null : callService.requestVideoUpgrade,
              ),
            ],
          ],
        ),
        const SizedBox(height: 24),
        _CallButton(
          icon: Icons.call_end,
          color: Colors.red,
          label: ended ? '' : 'إنهاء',
          onPressed: ended ? null : callService.endCall,
        ),
      ],
    );
  }
}

/// بانر طلب تحويل المكالمة لفيديو — يظهر لدى الطرف الذي وصله الطلب فقط،
/// ويسمح له بالقبول أو الرفض؛ لا شيء يحدث للكاميرا قبل ضغطة صريحة هنا.
class _VideoUpgradeRequestBanner extends StatelessWidget {
  const _VideoUpgradeRequestBanner({required this.callService, required this.call});

  final CallService callService;
  final CallSession call;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${call.peerDisplayName} يطلب التحويل لمكالمة فيديو',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              OutlinedButton(
                style: OutlinedButton.styleFrom(foregroundColor: Colors.white70),
                onPressed: () => callService.respondToVideoUpgrade(false),
                child: const Text('رفض'),
              ),
              const SizedBox(width: 12),
              FilledButton(
                onPressed: () => callService.respondToVideoUpgrade(true),
                child: const Text('موافق'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CallButton extends StatelessWidget {
  const _CallButton({required this.icon, required this.color, required this.label, this.onPressed});

  final IconData icon;
  final Color color;
  final String label;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkWell(
          onTap: onPressed == null ? null : () => onPressed!(),
          borderRadius: BorderRadius.circular(32),
          child: CircleAvatar(
            radius: 32,
            backgroundColor: onPressed == null ? color.withValues(alpha: 0.4) : color,
            child: Icon(icon, color: Colors.white, size: 30),
          ),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(label, style: const TextStyle(color: Colors.white70)),
        ],
      ],
    );
  }
}

class _ToggleButton extends StatelessWidget {
  const _ToggleButton({required this.icon, required this.active, this.onPressed});

  final IconData icon;
  final bool active;
  final Future<void> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed == null ? null : () => onPressed!(),
      borderRadius: BorderRadius.circular(28),
      child: CircleAvatar(
        radius: 26,
        backgroundColor: active ? Colors.white : Colors.white24,
        child: Icon(icon, color: active ? Colors.black : Colors.white),
      ),
    );
  }
}
