package com.sofilover10.localconnect.local_connect

import android.app.Application
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * تُنشئ محرّك Flutter عند بدء تشغيل عملية التطبيق نفسها (وليس عند فتح
 * MainActivity)، وتحتفظ به في [FlutterEngineCache]. هذا هو ما يسمح لكود
 * Dart (اكتشاف الشبكة، خادم TCP، بلوتوث، اتصال المُرحِّل، المكالمات...)
 * بالاستمرار في العمل حتى بعد أن يُغلِق المستخدم الشاشة (يسحبها من
 * التطبيقات الأخيرة)، طالما ظلت [LocalConnectForegroundService] تُبقي
 * العملية حيّة. عند إعادة فتح التطبيق، تلتحق MainActivity بنفس هذا
 * المحرّك القائم أصلًا بدل إنشاء واحد جديد (انظر MainActivity)، فلا يُعاد
 * تشغيل main() Dart ولا تنقطع أي اتصالات جارية.
 */
class LocalConnectApplication : Application() {

    private val wifiDirectHandler by lazy { WifiDirectHandler(applicationContext) }
    private val bluetoothHandler by lazy { BluetoothClassicHandler(applicationContext) }
    private val ringtoneHandler by lazy { RingtoneHandler(applicationContext) }

    override fun onCreate() {
        super.onCreate()

        val engine = FlutterEngine(this)
        // تسجيل الإضافات (path_provider، permission_handler، flutter_webrtc...)
        // يجب أن يسبق تشغيل main() في Dart — وإلا فقد يستدعي كود Dart قناة
        // إضافة قبل أن يكون الطرف الأصلي (أندرويد) قد سجّل معالِجها بعد،
        // وهذا عكس الترتيب المعتاد عندما تُنشئ FlutterActivity المحرّك بنفسها.
        GeneratedPluginRegistrant.registerWith(engine)
        configureCustomChannels(engine)
        engine.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        FlutterEngineCache.getInstance().put(ENGINE_ID, engine)

        LocalConnectForegroundService.start(this)
    }

    private fun configureCustomChannels(engine: FlutterEngine) {
        val messenger = engine.dartExecutor.binaryMessenger

        MethodChannel(messenger, "local_connect/wifi_direct").setMethodCallHandler(wifiDirectHandler)
        EventChannel(messenger, "local_connect/wifi_direct/peers").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) =
                    wifiDirectHandler.setPeersSink(events)
                override fun onCancel(arguments: Any?) = wifiDirectHandler.setPeersSink(null)
            }
        )
        EventChannel(messenger, "local_connect/wifi_direct/connection").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) =
                    wifiDirectHandler.setConnectionSink(events)
                override fun onCancel(arguments: Any?) = wifiDirectHandler.setConnectionSink(null)
            }
        )
        wifiDirectHandler.start()

        MethodChannel(messenger, "local_connect/bluetooth").setMethodCallHandler(bluetoothHandler)
        EventChannel(messenger, "local_connect/bluetooth/devices").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) =
                    bluetoothHandler.setDevicesSink(events)
                override fun onCancel(arguments: Any?) = bluetoothHandler.setDevicesSink(null)
            }
        )
        EventChannel(messenger, "local_connect/bluetooth/data").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) =
                    bluetoothHandler.setDataSink(events)
                override fun onCancel(arguments: Any?) = bluetoothHandler.setDataSink(null)
            }
        )
        bluetoothHandler.start()

        MethodChannel(messenger, "local_connect/ringtone").setMethodCallHandler(ringtoneHandler)
    }

    companion object {
        const val ENGINE_ID = "local_connect_engine"
    }
}
