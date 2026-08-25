package com.sofilover10.localconnect.local_connect

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache

/**
 * لا تُنشئ محرّك Flutter الخاص بها ولا تُسجِّل أي قنوات — تلتحق بالمحرّك
 * القائم أصلًا في [LocalConnectApplication] (المُنشَأ عند بدء العملية،
 * وليس عند فتح هذه الشاشة)، وتتجنّب إتلافه عند تدميرها (`shouldDestroyEngineWithHost`)
 * حتى يستمر عمل الشبكة/البلوتوث/المكالمات في الخلفية بعد إغلاق المستخدم
 * لهذه الشاشة، طالما ظلت [LocalConnectForegroundService] تُبقي العملية حيّة.
 */
class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context: Context): FlutterEngine =
        FlutterEngineCache.getInstance().get(LocalConnectApplication.ENGINE_ID)!!

    override fun shouldDestroyEngineWithHost(): Boolean = false
}
