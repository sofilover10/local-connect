package com.sofilover10.localconnect.local_connect

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothServerSocket
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.IOException
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/**
 * بلوتوث كلاسيكي (RFCOMM) كبديل مباشر آخر بين جهازين، لا يمرّ بالراوتر
 * إطلاقًا. لا توجد حزمة Flutter جاهزة ومحدَّثة تدعم *استقبال* اتصالات
 * بلوتوث واردة (كلها تدعم الاتصال الصادر فقط)، لذا هذا تطبيق مباشر لنمط
 * Android القياسي: كل جهاز يشغّل [BluetoothServerSocket] (استقبال) بجانب
 * قدرته على فتح [BluetoothSocket] صادر لجهاز آخر — بالضبط كما يعمل خادم
 * ومقبس TCP في كود Flutter، لكن عبر بلوتوث بدل IP.
 *
 * بروتوكول الرسائل نفسه (JSON مفصول بسطر جديد) يُعاد استخدامه فوق تيار
 * البايتات هذا من طرف Dart، فلا حاجة لتكرار منطق التسلسل هنا.
 */
class BluetoothClassicHandler(private val context: Context) : MethodChannel.MethodCallHandler {

    companion object {
        /** UUID ثابت خاص بخدمة LocalConnect — يجب أن يتطابق على كل نسخ التطبيق. */
        val SERVICE_UUID: UUID = UUID.fromString("8ce255c0-200a-11e0-ac64-0800200c9a66")
    }

    private val adapter: BluetoothAdapter? = BluetoothAdapter.getDefaultAdapter()
    private val mainHandler = Handler(Looper.getMainLooper())

    private var devicesSink: EventChannel.EventSink? = null
    private var dataSink: EventChannel.EventSink? = null

    private var serverSocket: BluetoothServerSocket? = null
    private var serverThread: Thread? = null
    private var serverRunning = false

    private val connections = ConcurrentHashMap<String, BluetoothSocket>()
    private var discoveryReceiver: BroadcastReceiver? = null

    fun setDevicesSink(sink: EventChannel.EventSink?) {
        devicesSink = sink
    }

    fun setDataSink(sink: EventChannel.EventSink?) {
        dataSink = sink
    }

    fun start() {
        // يُستدعى فور إقلاع التطبيق قبل أن يطلب المستخدم صلاحية البلوتوث
        // من واجهة Flutter — على أندرويد 12+ يرمي listenUsingRfcommWithServiceRecord
        // استثناء SecurityException إن لم تُمنح BLUETOOTH_CONNECT بعد. أي
        // استثناء غير مُلتقَط داخل Thread على أندرويد يُنهي التطبيق كله فورًا
        // (وليس تلك المهمة فقط)، فيجب عدم افتراض منح الصلاحية هنا إطلاقًا.
        startServer()
    }

    /** يُعاد استدعاؤها من Dart بعد منح صلاحية البلوتوث لتفعيل الخادم فعليًا. */
    fun restartServer() {
        serverRunning = false
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        startServer()
    }

    fun stop() {
        serverRunning = false
        stopDiscoveryInternal()
        try {
            serverSocket?.close()
        } catch (_: IOException) {
        }
        connections.values.forEach {
            try {
                it.close()
            } catch (_: IOException) {
            }
        }
        connections.clear()
    }

    @SuppressLint("MissingPermission")
    private fun startServer() {
        val adapter = adapter ?: return
        serverRunning = true
        serverThread = Thread {
            try {
                serverSocket =
                    adapter.listenUsingRfcommWithServiceRecord("LocalConnect", SERVICE_UUID)
                while (serverRunning) {
                    val socket = serverSocket?.accept() ?: break
                    attachConnection(socket)
                }
            } catch (_: IOException) {
                // الخادم توقف — إغلاق طبيعي عند stop()، أو تعذّر تفعيل البلوتوث.
            } catch (_: SecurityException) {
                // صلاحية البلوتوث غير ممنوحة بعد؛ سيُعاد المحاولة عبر
                // restartServer() بعد منحها من واجهة Flutter. يجب عدم ترك
                // هذا الاستثناء يهرب بلا التقاط — أي استثناء غير مُلتقَط في
                // Thread يُنهي عملية التطبيق كاملة على أندرويد.
            }
        }
        serverThread?.start()
    }

    private fun attachConnection(socket: BluetoothSocket) {
        val address = socket.remoteDevice.address
        connections[address]?.let {
            // اتصال سابق بنفس العنوان (احتمال ضئيل لتزامن اتصال صادر ووارد
            // في نفس اللحظة) — نغلقه قبل استبداله لتفادي تسريب الموارد.
            try {
                it.close()
            } catch (_: IOException) {
            }
        }
        connections[address] = socket
        mainHandler.post {
            dataSink?.success(mapOf("address" to address, "connected" to true))
        }
        Thread {
            val input = socket.inputStream
            val buffer = ByteArray(4096)
            try {
                while (true) {
                    val bytesRead = input.read(buffer)
                    if (bytesRead == -1) break
                    val chunk = buffer.copyOf(bytesRead)
                    mainHandler.post {
                        dataSink?.success(mapOf("address" to address, "bytes" to chunk))
                    }
                }
            } catch (_: IOException) {
                // انقطع الاتصال من الطرف الآخر أو محليًا.
            } finally {
                connections.remove(address)
                try {
                    socket.close()
                } catch (_: IOException) {
                }
                mainHandler.post {
                    dataSink?.success(mapOf("address" to address, "disconnected" to true))
                }
            }
        }.start()
    }

    @SuppressLint("MissingPermission")
    private fun connectToDevice(address: String, result: MethodChannel.Result) {
        val adapter = adapter
        if (adapter == null) {
            result.success(false)
            return
        }
        Thread {
            try {
                val device = adapter.getRemoteDevice(address)
                adapter.cancelDiscovery()
                val socket = device.createRfcommSocketToServiceRecord(SERVICE_UUID)
                socket.connect()
                attachConnection(socket)
                mainHandler.post { result.success(true) }
            } catch (_: IOException) {
                mainHandler.post { result.success(false) }
            } catch (_: SecurityException) {
                mainHandler.post { result.success(false) }
            }
        }.start()
    }

    private fun sendTo(address: String, bytes: ByteArray, result: MethodChannel.Result) {
        val socket = connections[address]
        if (socket == null) {
            result.success(false)
            return
        }
        Thread {
            try {
                socket.outputStream.write(bytes)
                socket.outputStream.flush()
                mainHandler.post { result.success(true) }
            } catch (_: IOException) {
                mainHandler.post { result.success(false) }
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    @SuppressLint("MissingPermission")
    private fun startDiscovery(result: MethodChannel.Result) {
        val adapter = adapter
        if (adapter == null) {
            result.success(false)
            return
        }

        if (discoveryReceiver == null) {
            discoveryReceiver = object : BroadcastReceiver() {
                override fun onReceive(receivedContext: Context, intent: Intent) {
                    if (intent.action != BluetoothDevice.ACTION_FOUND) return
                    val device = intent.getParcelableExtra<BluetoothDevice>(BluetoothDevice.EXTRA_DEVICE)
                        ?: return
                    mainHandler.post {
                        devicesSink?.success(
                            mapOf("name" to (device.name ?: device.address), "address" to device.address)
                        )
                    }
                }
            }
            ContextCompat.registerReceiver(
                context,
                discoveryReceiver,
                IntentFilter(BluetoothDevice.ACTION_FOUND),
                ContextCompat.RECEIVER_NOT_EXPORTED,
            )
        }

        try {
            // الأجهزة المقترَنة مسبقًا تُبلَّغ فورًا أيضًا (لا تحتاج مسحًا لظهورها).
            adapter.bondedDevices?.forEach { device ->
                devicesSink?.success(
                    mapOf("name" to (device.name ?: device.address), "address" to device.address),
                )
            }
            result.success(adapter.startDiscovery())
        } catch (_: SecurityException) {
            result.success(false)
        }
    }

    private fun stopDiscoveryInternal() {
        try {
            adapter?.cancelDiscovery()
        } catch (_: SecurityException) {
        }
        discoveryReceiver?.let {
            try {
                context.unregisterReceiver(it)
            } catch (_: IllegalArgumentException) {
            }
        }
        discoveryReceiver = null
    }

    @SuppressLint("MissingPermission")
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isSupported" -> result.success(adapter != null)
            "isEnabled" -> result.success(adapter?.isEnabled == true)
            "restartServer" -> {
                restartServer()
                result.success(true)
            }
            "startDiscovery" -> startDiscovery(result)
            "stopDiscovery" -> {
                stopDiscoveryInternal()
                result.success(true)
            }
            "connect" -> {
                val address = call.argument<String>("address")
                if (address == null) result.success(false) else connectToDevice(address, result)
            }
            "send" -> {
                val address = call.argument<String>("address")
                val bytes = call.argument<ByteArray>("bytes")
                if (address == null || bytes == null) result.success(false) else sendTo(address, bytes, result)
            }
            "disconnectDevice" -> {
                val address = call.argument<String>("address")
                connections[address]?.let {
                    try {
                        it.close()
                    } catch (_: IOException) {
                    }
                }
                connections.remove(address)
                result.success(true)
            }
            else -> result.notImplemented()
        }
    }
}
