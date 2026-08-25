package com.sofilover10.localconnect.local_connect

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat

/**
 * لا وظيفة داخلية فعلية لهذه الخدمة سوى إبقاء عملية التطبيق حيّة بأولوية
 * عالية (Foreground) بعد إغلاق المستخدم للشاشة (سحبها من التطبيقات
 * الأخيرة) — بدونها يقتل أندرويد العملية فور تدمير آخر Activity، فيتوقف
 * محرّك Flutter المُخزَّن في [LocalConnectApplication] (وبالتالي اكتشاف
 * الشبكة، خادم الرسائل، البلوتوث، اتصال المُرحِّل، استقبال المكالمات...)
 * تمامًا حتى يُعاد فتح التطبيق يدويًا. الإشعار الثابت إلزامي من أندرويد
 * نفسه لأي خدمة خلفية دائمة — لا يمكن إخفاؤه، لكنه بأدنى أولوية ممكنة.
 */
class LocalConnectForegroundService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, buildNotification())
        }
        return START_STICKY
    }

    private fun buildNotification(): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            val channel = NotificationChannel(
                CHANNEL_ID,
                "LocalConnect نشط بالخلفية",
                NotificationManager.IMPORTANCE_MIN,
            )
            manager.createNotificationChannel(channel)
        }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                0,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("LocalConnect يعمل بالخلفية")
            .setContentText("جاهز لاستقبال الرسائل والمكالمات")
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "local_connect_background"
        private const val NOTIFICATION_ID = 1

        fun start(context: Context) {
            val intent = Intent(context, LocalConnectForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }
}
