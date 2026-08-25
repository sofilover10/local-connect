package com.sofilover10.localconnect.local_connect

import android.app.KeyguardManager
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * لا تُنشئ محرّك Flutter الخاص بها ولا تُسجِّل أي قنوات — تلتحق بالمحرّك
 * القائم أصلًا في [LocalConnectApplication] (المُنشَأ عند بدء العملية،
 * وليس عند فتح هذه الشاشة)، وتتجنّب إتلافه عند تدميرها (`shouldDestroyEngineWithHost`)
 * حتى يستمر عمل الشبكة/البلوتوث/المكالمات في الخلفية بعد إغلاق المستخدم
 * لهذه الشاشة، طالما ظلت [LocalConnectForegroundService] تُبقي العملية حيّة.
 *
 * تتعامل أيضًا مع نيّة "شاشة كاملة" (full-screen intent) القادمة من إشعار
 * مكالمة واردة عالي الأولوية (انظر RingtoneHandler.showIncomingCallNotification):
 * تظهر فوق شاشة القفل مباشرة عند وجود هذه النيّة تحديدًا، بخلاف الفتح العادي
 * للتطبيق الذي يتطلب فتح القفل كالمعتاد.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        FlutterEngineCache.getInstance().get(LocalConnectApplication.ENGINE_ID)!!

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleIncomingCallIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIncomingCallIntent(intent)
    }

    private fun handleIncomingCallIntent(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_INCOMING_CALL, false) != true) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }
        val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as? KeyguardManager
        keyguardManager?.requestDismissKeyguard(this, null)
    }

    companion object {
        const val EXTRA_INCOMING_CALL = "incoming_call"
    }
}
