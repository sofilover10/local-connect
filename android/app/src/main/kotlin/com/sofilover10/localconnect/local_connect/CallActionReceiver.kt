package com.sofilover10.localconnect.local_connect

import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

/**
 * يستقبل ضغطة زر "رد" أو "رفض" على إشعار المكالمة الواردة (انظر
 * RingtoneHandler.showIncomingCallNotification) — ضروري لأن أندرويد 14+
 * قد يُخفِّض إشعار الشاشة الكاملة إلى إشعار عادي (راجع التعليق هناك)، فلا
 * تُفتَح شاشة المكالمة تلقائيًا؛ هذان الزرّان يبقيان الطريقة الوحيدة
 * للتفاعل مع المكالمة دون فتح التطبيق يدويًا أولًا.
 *
 * يُلغي الإشعار فورًا هنا (استجابة بصرية فورية)، ثم يُمرِّر الحدث لكود
 * Dart عبر نفس محرّك Flutter المُخزَّن مسبقًا في [LocalConnectApplication]
 * (يعمل حتى إن كانت MainActivity غير مفتوحة إطلاقًا) — الرد/الرفض الفعليان
 * (إيقاف الرنين، إغلاق اتصال WebRTC...) ينفَّذان في CallService.acceptCall/
 * rejectCall الموجودَين أصلًا.
 */
class CallActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(RingtoneHandler.CALL_NOTIFICATION_ID)

        val method = when (intent.action) {
            ACTION_ANSWER -> "answer"
            ACTION_REJECT -> "reject"
            else -> return
        }

        val engine = FlutterEngineCache.getInstance().get(LocalConnectApplication.ENGINE_ID) ?: return
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME).invokeMethod(method, null)
    }

    companion object {
        const val ACTION_ANSWER = "com.sofilover10.localconnect.local_connect.ACTION_ANSWER_CALL"
        const val ACTION_REJECT = "com.sofilover10.localconnect.local_connect.ACTION_REJECT_CALL"
        const val CHANNEL_NAME = "local_connect/call_actions"
    }
}
