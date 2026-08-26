package com.sofilover10.localconnect.local_connect

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.media.Ringtone
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/// يشغّل نغمة رنين حقيقية (نغمة الجهاز الافتراضية نفسها) للمكالمات الواردة،
/// ونغمة "طنين انتظار" (ringback) بسيطة ومتكررة للمكالمات الصادرة أثناء
/// انتظار ردّ الطرف الآخر — لا توجد حزمة Flutter لهذا في المشروع، ولا يوجد
/// أصل صوتي (asset) مُرفَق، فاستخدام واجهات أندرويد الأصلية هنا يعطي صوتًا
/// حقيقيًا بدل الاعتماد فقط على الاهتزاز والنبض البصري.
class RingtoneHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private var ringtone: Ringtone? = null
    private var toneGenerator: ToneGenerator? = null
    private val handler = Handler(Looper.getMainLooper())
    private var ringbackRunnable: Runnable? = null

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "playRingtone" -> {
                playRingtone()
                result.success(null)
            }
            "stopRingtone" -> {
                stopRingtone()
                result.success(null)
            }
            "playRingback" -> {
                playRingback()
                result.success(null)
            }
            "stopRingback" -> {
                stopRingback()
                result.success(null)
            }
            "showIncomingCallNotification" -> {
                val callerName = call.argument<String>("callerName") ?: "مكالمة واردة"
                showIncomingCallNotification(callerName)
                result.success(null)
            }
            "cancelIncomingCallNotification" -> {
                cancelIncomingCallNotification()
                result.success(null)
            }
            "ensureFullScreenIntentPermission" -> {
                ensureFullScreenIntentPermission()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /// إشعار بأعلى أولوية مع نيّة "شاشة كاملة" (full-screen intent) — هذا ما
    /// يجعل اسم المتصل يظهر فعليًا حتى لو كانت الشاشة مقفلة أو التطبيق غير
    /// مفتوح إطلاقًا؛ بدونه، صوت الرنين (playRingtone) يعمل لكن لا يوجد أي
    /// مؤشر بصري لمن يتصل قبل أن يفتح المستخدم التطبيق بنفسه يدويًا.
    ///
    /// **أزرار رد/رفض على الإشعار نفسه** ضرورية بصرف النظر عن نجاح الشاشة
    /// الكاملة أم لا: أندرويد 14+ يتطلب صلاحية خاصة إضافية (غير الإذن في
    /// المانيفست) قد لا تُمنَح تلقائيًا لتطبيق مُثبَّت يدويًا (خارج متجر
    /// Google)، فيُخفِّض النظام الإشعار إلى إشعار عادي بلا فتح تلقائي لشاشة
    /// المكالمة — عندها الأزرار هنا هي الطريقة الوحيدة للرد أو الرفض دون
    /// فتح التطبيق يدويًا والانتظار حتى يُحمَّل.
    private fun showIncomingCallNotification(callerName: String) {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CALL_CHANNEL_ID,
                "مكالمات واردة",
                NotificationManager.IMPORTANCE_HIGH,
            )
            manager.createNotificationChannel(channel)
        }

        val fullScreenIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                Intent.FLAG_ACTIVITY_SINGLE_TOP or
                Intent.FLAG_ACTIVITY_CLEAR_TOP
            putExtra(MainActivity.EXTRA_INCOMING_CALL, true)
        }
        val fullScreenPendingIntent = PendingIntent.getActivity(
            context,
            0,
            fullScreenIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val answerIntent = Intent(context, CallActionReceiver::class.java)
            .setAction(CallActionReceiver.ACTION_ANSWER)
        val answerPendingIntent = PendingIntent.getBroadcast(
            context, 1, answerIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val rejectIntent = Intent(context, CallActionReceiver::class.java)
            .setAction(CallActionReceiver.ACTION_REJECT)
        val rejectPendingIntent = PendingIntent.getBroadcast(
            context, 2, rejectIntent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        val notification = NotificationCompat.Builder(context, CALL_CHANNEL_ID)
            .setContentTitle("مكالمة واردة")
            .setContentText(callerName)
            .setSmallIcon(android.R.drawable.sym_call_incoming)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setCategory(NotificationCompat.CATEGORY_CALL)
            .setFullScreenIntent(fullScreenPendingIntent, true)
            .setContentIntent(fullScreenPendingIntent)
            .addAction(android.R.drawable.sym_action_call, "رد", answerPendingIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "رفض", rejectPendingIntent)
            .setAutoCancel(true)
            .setOngoing(true)
            .build()

        manager.notify(CALL_NOTIFICATION_ID, notification)
    }

    /// أندرويد 14+ يتطلب صلاحية خاصة إضافية (منفصلة عن مجرّد إعلان
    /// USE_FULL_SCREEN_INTENT في المانيفست) لعرض إشعار المكالمة كشاشة كاملة
    /// فعليًا فوق شاشة القفل — قد لا تُمنَح تلقائيًا لتطبيق مُثبَّت يدويًا
    /// خارج متجر Google. إن لم تكن ممنوحة، نفتح شاشة الإعدادات الخاصة بها
    /// مباشرة حتى يفعّلها المستخدم بنفسه بضغطة واحدة؛ بدون هذا التحقق
    /// الاستباقي، الإشعار يُخفَّض بصمت إلى إشعار عادي ولا يظهر شيء فوق
    /// القفل رغم أن صوت الرنين يعمل بشكل طبيعي (لأنه مستقل تمامًا).
    private fun ensureFullScreenIntentPermission() {
        if (Build.VERSION.SDK_INT < 34) return
        if (NotificationManagerCompat.from(context).canUseFullScreenIntent()) return
        try {
            val intent = Intent(Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT)
                .setData(Uri.parse("package:${context.packageName}"))
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
        } catch (_: Exception) {
            // بعض الشرائح المخصَّصة لا تدعم هذه الشاشة تحديدًا — لا داعٍ
            // لإسقاط أي شيء، صوت الرنين يبقى يعمل بلا هذه الصلاحية.
        }
    }

    private fun cancelIncomingCallNotification() {
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.cancel(CALL_NOTIFICATION_ID)
    }

    private fun playRingtone() {
        stopRingtone()
        try {
            val uri = RingtoneManager.getActualDefaultRingtoneUri(context, RingtoneManager.TYPE_RINGTONE)
                ?: RingtoneManager.getValidRingtoneUri(context)
                ?: return
            val tone = RingtoneManager.getRingtone(context, uri) ?: return
            tone.audioAttributes = android.media.AudioAttributes.Builder()
                .setUsage(android.media.AudioAttributes.USAGE_NOTIFICATION_RINGTONE)
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .build()
            ringtone = tone
            tone.play()
        } catch (_: Exception) {
            // بلا نغمة افتراضية صالحة على بعض الأجهزة/الشرائح المخصَّصة —
            // تُتجاهَل بصمت، ويبقى الاهتزاز + النبض البصري مؤشرًا كافيًا.
        }
    }

    private fun stopRingtone() {
        try {
            ringtone?.stop()
        } catch (_: Exception) {
            // لا شيء.
        }
        ringtone = null
    }

    /// طنين انتظار قصير كل 3 ثوانٍ، بنفس نمط نغمة انتظار الرد المعتادة في
    /// تطبيقات الهاتف، حتى لا يبقى المتصِل في صمت تام أثناء انتظار الرد.
    private fun playRingback() {
        stopRingback()
        try {
            toneGenerator = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 70)
        } catch (_: Exception) {
            return
        }
        val runnable = object : Runnable {
            override fun run() {
                try {
                    toneGenerator?.startTone(ToneGenerator.TONE_SUP_RINGTONE, 1200)
                } catch (_: Exception) {
                    // لا شيء.
                }
                handler.postDelayed(this, 3000)
            }
        }
        ringbackRunnable = runnable
        handler.post(runnable)
    }

    private fun stopRingback() {
        ringbackRunnable?.let { handler.removeCallbacks(it) }
        ringbackRunnable = null
        try {
            toneGenerator?.stopTone()
            toneGenerator?.release()
        } catch (_: Exception) {
            // لا شيء.
        }
        toneGenerator = null
    }

    companion object {
        private const val CALL_CHANNEL_ID = "local_connect_incoming_call"
        const val CALL_NOTIFICATION_ID = 2
    }
}
