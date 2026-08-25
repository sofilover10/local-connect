package com.sofilover10.localconnect.local_connect

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val wifiDirectHandler by lazy { WifiDirectHandler(applicationContext) }
    private val bluetoothHandler by lazy { BluetoothClassicHandler(applicationContext) }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

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
    }

    override fun onDestroy() {
        wifiDirectHandler.stop()
        bluetoothHandler.stop()
        super.onDestroy()
    }
}
