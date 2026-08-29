package com.sofilover10.localconnect.local_connect

import android.content.Context
import java.io.File
import java.io.PrintWriter
import java.io.StringWriter
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * يلتقط أي عطل غير مُعالَج على مستوى الخيوط الأصلية (كود Kotlin/Java، أو من
 * مكتبات أصلية مثل WebRTC أو البلوتوث/Wi-Fi Direct المكتوبة يدويًا هنا) قبل
 * أن تُقتَل العملية.
 *
 * هذه الأعطال لا تصل أبدًا لمعالجات الأخطاء في Dart
 * (FlutterError.onError/runZonedGuarded في main.dart) لأنها تحدث خارج محرّك
 * Dart بالكامل، فتظل "صندوقًا أسود" بلا أي تفاصيل فعلية — سامسونج (وأندرويد
 * عمومًا) يكتشفها ويُبلِغ عنها كـ"تعطّلات متكررة" في تقرير العناية بالجهاز،
 * لكن بلا أي سجل يصل فعليًا للمطوّر لتشخيص السبب.
 *
 * يُثبَّت كمعالج افتراضي لكل الخيوط في أول لحظة ممكنة من عمر العملية
 * ([LocalConnectApplication.onCreate]، قبل أي شيء آخر)، فيكتب تتبّع
 * الاستثناء الكامل إلى ملف محلي، ثم يُمرِّر التعامل فورًا للمعالج الافتراضي
 * الأصلي لأندرويد — سلوك النظام المعتاد (قتل العملية، تقارير Google/سامسونج)
 * يبقى كما هو دون أي تغيير؛ هذا يضيف تسجيلًا فقط، لا يمنع أو يُعالِج العطل.
 */
class CrashReporter private constructor(private val appContext: Context) {
    private val previousHandler = Thread.getDefaultUncaughtExceptionHandler()

    private fun handle(thread: Thread, throwable: Throwable) {
        try {
            val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).format(Date())
            val writer = StringWriter()
            throwable.printStackTrace(PrintWriter(writer))
            logFile(appContext).writeText("[$timestamp] Thread: ${thread.name}\n$writer")
        } catch (_: Throwable) {
            // لا شيء — الهدف تسجيل العطل الأصلي، ليس إضافة عطل ثانٍ فوقه.
        }
        previousHandler?.uncaughtException(thread, throwable)
    }

    companion object {
        private const val FILE_NAME = "native_crash_log.txt"

        private fun logFile(context: Context) = File(context.filesDir, FILE_NAME)

        fun install(context: Context) {
            val reporter = CrashReporter(context.applicationContext)
            Thread.setDefaultUncaughtExceptionHandler(reporter::handle)
        }

        /** يعيد نص آخر عطل مسجَّل، أو null إن لم يوجد أي عطل منذ آخر مسح. */
        fun readPendingCrash(context: Context): String? {
            val file = logFile(context)
            return if (file.exists()) file.readText() else null
        }

        /** يُستدعى من Dart بعد قراءة العطل وعرضه، حتى لا يتكرر عرضه كل إقلاع. */
        fun clearPendingCrash(context: Context) {
            logFile(context).delete()
        }
    }
}
