import 'dart:async';

import 'package:flutter/material.dart';

import '../models/group_call_session.dart';
import '../services/group_call_service.dart';

/// طبقة عامة (مثل [CallOverlay] للمكالمات الثنائية) تعرض شاشة المكالمة
/// الجماعية كاملة أعلى أي شاشة أخرى فور وجود [GroupCallSession] جارية.
class GroupCallOverlay extends StatelessWidget {
  const GroupCallOverlay({super.key, required this.groupCallService});

  final GroupCallService groupCallService;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: groupCallService,
      builder: (context, _) {
        final call = groupCallService.currentCall;
        if (call == null) return const SizedBox.shrink();
        return GroupCallScreen(groupCallService: groupCallService, call: call);
      },
    );
  }
}

class GroupCallScreen extends StatefulWidget {
  const GroupCallScreen({super.key, required this.groupCallService, required this.call});

  final GroupCallService groupCallService;
  final GroupCallSession call;

  @override
  State<GroupCallScreen> createState() => _GroupCallScreenState();
}

class _GroupCallScreenState extends State<GroupCallScreen> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _statusText(GroupCallSession call) {
    switch (call.state) {
      case GroupCallState.ringing:
        return call.isInitiator ? 'جارٍ الاتصال...' : 'مكالمة جماعية واردة';
      case GroupCallState.active:
        return _formatDuration(call.elapsed);
      case GroupCallState.ended:
        return 'انتهت المكالمة';
    }
  }

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final service = widget.groupCallService;
    final isIncomingRinging = call.state == GroupCallState.ringing && !call.isInitiator;

    return PopScope(
      canPop: false,
      child: Material(
        color: Colors.black,
        child: SafeArea(
          child: Column(
            children: [
              const SizedBox(height: 24),
              const Icon(Icons.groups, color: Colors.white, size: 40),
              const SizedBox(height: 8),
              Text(
                call.groupName,
                style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 6),
              Text(_statusText(call), style: const TextStyle(color: Colors.white70, fontSize: 15)),
              const SizedBox(height: 16),
              Expanded(
                child: call.participants.isEmpty
                    ? const Center(
                        child: Text('بانتظار انضمام أحد...', style: TextStyle(color: Colors.white54)),
                      )
                    : ListView(
                        children: call.participants.values
                            .map((participant) => _ParticipantTile(participant: participant))
                            .toList(),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 32, top: 8),
                child: isIncomingRinging
                    ? _IncomingGroupCallControls(service: service)
                    : _ActiveGroupCallControls(service: service, call: call),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ParticipantTile extends StatelessWidget {
  const _ParticipantTile({required this.participant});

  final GroupCallParticipant participant;

  @override
  Widget build(BuildContext context) {
    final connected = participant.linkState == ParticipantLinkState.connected;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: Colors.teal.shade400,
        child: Text(
          participant.displayName.isEmpty ? '?' : participant.displayName[0],
          style: const TextStyle(color: Colors.white),
        ),
      ),
      title: Text(participant.displayName, style: const TextStyle(color: Colors.white)),
      subtitle: Text(
        switch (participant.linkState) {
          ParticipantLinkState.connecting => 'جارٍ الاتصال...',
          ParticipantLinkState.connected => 'متصل',
          ParticipantLinkState.failed => 'تعذّر الاتصال',
        },
        style: const TextStyle(color: Colors.white54, fontSize: 12),
      ),
      trailing: Icon(
        connected ? Icons.volume_up : Icons.hourglass_empty,
        color: connected ? Colors.greenAccent : Colors.white38,
      ),
    );
  }
}

class _IncomingGroupCallControls extends StatelessWidget {
  const _IncomingGroupCallControls({required this.service});

  final GroupCallService service;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _RoundButton(icon: Icons.call_end, color: Colors.red, label: 'رفض', onPressed: service.declineCall),
        _RoundButton(icon: Icons.call, color: Colors.green, label: 'انضمام', onPressed: service.joinCall),
      ],
    );
  }
}

class _ActiveGroupCallControls extends StatelessWidget {
  const _ActiveGroupCallControls({required this.service, required this.call});

  final GroupCallService service;
  final GroupCallSession call;

  @override
  Widget build(BuildContext context) {
    final ended = call.state == GroupCallState.ended;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ToggleRoundButton(
          icon: service.isMuted ? Icons.mic_off : Icons.mic,
          active: service.isMuted,
          onPressed: ended ? null : service.toggleMute,
        ),
        const SizedBox(height: 20),
        _RoundButton(
          icon: Icons.call_end,
          color: Colors.red,
          label: ended ? '' : 'مغادرة',
          onPressed: ended ? null : service.endCall,
        ),
      ],
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.icon, required this.color, required this.label, this.onPressed});

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

class _ToggleRoundButton extends StatelessWidget {
  const _ToggleRoundButton({required this.icon, required this.active, this.onPressed});

  final IconData icon;
  final bool active;
  final void Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(28),
      child: CircleAvatar(
        radius: 26,
        backgroundColor: active ? Colors.white : Colors.white24,
        child: Icon(icon, color: active ? Colors.black : Colors.white),
      ),
    );
  }
}
