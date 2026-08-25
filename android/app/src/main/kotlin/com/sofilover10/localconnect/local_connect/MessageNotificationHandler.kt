package com.sofilover10.localconnect.local_connect

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// إشعار رسالة واردة — ضروري لأن خدمة الخلفية تُبقي التطبيق يستقبل الرسائل
/// بصمت حتى وشاشته مغلقة تمامًا؛ بدون إشعار صريح هنا، لن يعرف المستخدم أن
/// رسالة وصلت أصلًا قبل أن يفتح التطبيق يدويًا بنفسه.
///
/// معرّف الإشعار مُشتقّ من hashCode الخاص بمعرّف المحادثة، حتى تحلّ كل رسالة
/// جديدة من نفس المحادثة محل سابقتها بدل تكديس إشعار منفصل لكل رسالة.
class MessageNotificationHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "showMessageNotification" -> {
                val conversationId = call.argument<String>("conversationId")
                val senderName = call.argument<String>("senderName") ?: "رسالة جديدة"
                val preview = call.argument<String>("preview") ?: ""
                if (conversationId != null) showMessageNotification(conversationId, senderName, preview)
                result.success(null)
            }
            "cancelMessageNotification" -> {
                val conversationId = call.argument<String>("conversationId")
                if (conversationId != null) cancelMessageNotification(conversationId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun showMessageNotification(conversationId: String, senderName: String, preview: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "رسائل جديدة",
                NotificationManager.IMPORTANCE_HIGH,
            )
            manager.createNotificationChannel(channel)
        }

        val contentIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            context,
            conversationId.hashCode(),
            contentIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(context, CHANNEL_ID)
            .setContentTitle(senderName)
            .setContentText(preview)
            .setSmallIcon(android.R.drawable.ic_dialog_email)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_MESSAGE)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()

        manager.notify(conversationId.hashCode(), notification)
    }

    private fun cancelMessageNotification(conversationId: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(conversationId.hashCode())
    }

    companion object {
        private const val CHANNEL_ID = "local_connect_messages"
    }
}
