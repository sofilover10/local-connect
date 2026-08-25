package com.sofilover10.localconnect.local_connect

import android.annotation.SuppressLint
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pDeviceList
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * يربط جهازين مباشرة عبر Wi-Fi Direct بدون المرور بالراوتر إطلاقًا، فيتجاوز
 * أي "عزل أجهزة" (AP Isolation) يفعّله الراوتر بين عملائه.
 *
 * بمجرد تكوّن اتصال Wi-Fi Direct، يُنشئ أندرويد واجهة شبكة IP عادية بين
 * الجهازين (أحدهما "مالك المجموعة" بعنوان شبيه بـ192.168.49.1). لا حاجة
 * لأي بروتوكول رسائل جديد هنا — خدمتا الاكتشاف (UDP) والمراسلة (TCP)
 * الموجودتان أصلًا في كود Flutter تعملان تلقائيًا فوق أي واجهة شبكة نشطة،
 * فتلتقطان هذه الواجهة الجديدة من تلقاء نفسها في الدورة التالية للبث.
 */
class WifiDirectHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    private val manager: WifiP2pManager? =
        context.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var channel: WifiP2pManager.Channel? = null

    private var peersSink: EventChannel.EventSink? = null
    private var connectionSink: EventChannel.EventSink? = null
    private var receiver: BroadcastReceiver? = null

    fun setPeersSink(sink: EventChannel.EventSink?) {
        peersSink = sink
    }

    fun setConnectionSink(sink: EventChannel.EventSink?) {
        connectionSink = sink
    }

    fun start() {
        val manager = manager ?: return
        channel = manager.initialize(context, context.mainLooper, null)

        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
        }
        receiver = object : BroadcastReceiver() {
            override fun onReceive(receivedContext: Context, intent: Intent) {
                when (intent.action) {
                    WifiP2pManager.WIFI_P2P_PEERS_CHANGED_ACTION -> requestPeers()
                    WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> requestConnectionInfo()
                }
            }
        }
        // على أندرويد 13+ يجب تحديد ExportedFlag صراحة، وإلا يرمي النظام
        // SecurityException عند التسجيل وقت التشغيل. ContextCompat يتولى
        // اختيار المسار الصحيح حسب إصدار النظام تلقائيًا.
        ContextCompat.registerReceiver(context, receiver, filter, ContextCompat.RECEIVER_NOT_EXPORTED)
    }

    fun stop() {
        receiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
                // لم يكن مسجَّلًا أصلًا.
            }
        }
        receiver = null
    }

    @SuppressLint("MissingPermission")
    private fun requestPeers() {
        // يُستدعى من مستقبِل بث مُسجَّل منذ إقلاع التطبيق، وقد يصل بث
        // WIFI_P2P_PEERS_CHANGED_ACTION من النظام قبل أن يمنح المستخدم صلاحية
        // "الأجهزة القريبة" من واجهة Flutter. استثناء غير مُلتقَط هنا يُنهي
        // التطبيق كاملًا لأنه يعمل على الخيط الرئيسي (مستقبِلات البث الافتراضية).
        try {
            manager?.requestPeers(channel) { peers: WifiP2pDeviceList ->
                val list = peers.deviceList.map { device ->
                    mapOf(
                        "deviceName" to device.deviceName,
                        "deviceAddress" to device.deviceAddress,
                    )
                }
                peersSink?.success(list)
            }
        } catch (_: SecurityException) {
        }
    }

    private fun requestConnectionInfo() {
        try {
            manager?.requestConnectionInfo(channel) { info: WifiP2pInfo ->
                connectionSink?.success(
                    mapOf(
                        "isConnected" to info.groupFormed,
                        "isGroupOwner" to info.isGroupOwner,
                        "groupOwnerAddress" to (info.groupOwnerAddress?.hostAddress ?: ""),
                    )
                )
            }
        } catch (_: SecurityException) {
        }
    }

    @SuppressLint("MissingPermission")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val manager = manager
        if (manager == null) {
            result.success(false)
            return
        }
        try {
            when (call.method) {
                "isSupported" -> result.success(true)
                "startDiscovery" -> manager.discoverPeers(channel, simpleListener(result))
                "stopDiscovery" -> manager.stopPeerDiscovery(channel, simpleListener(result))
                "connect" -> {
                    val address = call.argument<String>("address")
                    if (address == null) {
                        result.success(false)
                        return
                    }
                    val config = WifiP2pConfig().apply { deviceAddress = address }
                    manager.connect(channel, config, simpleListener(result))
                }
                "disconnect" -> manager.removeGroup(channel, simpleListener(result))
                else -> result.notImplemented()
            }
        } catch (_: SecurityException) {
            result.success(false)
        }
    }

    private fun simpleListener(result: MethodChannel.Result) = object : WifiP2pManager.ActionListener {
        override fun onSuccess() = result.success(true)
        override fun onFailure(reason: Int) = result.success(false)
    }
}
