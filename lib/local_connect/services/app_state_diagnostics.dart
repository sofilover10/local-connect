part of 'app_state.dart';

/// فحص الأخطاء والإصلاح الذاتي.
extension DiagnosticsExtension on LocalConnectAppState {
  /// يفحص حالة الشبكة والاتصال، ويحاول إصلاح أي خدمة متوقفة (مثلًا بسبب
  /// منفذ كان محجوزًا عند الإقلاع) قبل إعادة عرض النتيجة. يُستدعى من شاشة
  /// "فحص الأخطاء" عند فتحها وعند الضغط على "إعادة الفحص والإصلاح".
  Future<List<DiagnosticCheck>> runDiagnostics() async {
    final checks = <DiagnosticCheck>[];

    if (!socket.isActive) {
      final port = await socket.restart();
      if (port > 0 && !discovery.isActive) {
        await discovery.start(identity: identity, tcpPort: port);
      }
    }
    checks.add(DiagnosticCheck(
      label: 'استقبال الرسائل (TCP)',
      ok: socket.isActive,
      detail: socket.isActive
          ? 'يعمل على المنفذ ${socket.boundPort}'
          : (socket.lastError ?? 'غير مفعّل لسبب غير معروف'),
    ));

    if (!discovery.isActive && socket.isActive) {
      await discovery.restart();
    }
    String discoveryDetail;
    if (!discovery.isActive) {
      discoveryDetail = discovery.lastError ?? 'غير مفعّل لسبب غير معروف';
    } else if (discovery.lastBroadcastError != null) {
      discoveryDetail = discovery.lastBroadcastError!;
    } else if (discovery.currentPeers.isEmpty) {
      // البث يعمل بلا أخطاء لكن لا أحد يظهر — إما لا يوجد جهاز آخر شغّال
      // فعليًا حاليًا، أو (وهذا شائع جدًا) الراوتر يفعّل "عزل الأجهزة"
      // (AP/Client Isolation) فيمنع وصول البث بين الأجهزة رغم اتصالها
      // بنفس الشبكة — لا يوجد إصلاح برمجي لهذا، فقط تعطيله من إعدادات
      // الراوتر، أو استخدام "إضافة بعنوان IP" كبديل مضمون.
      discoveryDetail = 'يعمل على المنفذ ${discovery.udpPort} — لا يظهر أي جهاز حاليًا. '
          'إن كان الجهاز الآخر شغّالًا فعلًا على نفس الشبكة، جرّب تعطيل "عزل الأجهزة/الضيوف" '
          '(AP أو Client Isolation) من إعدادات الراوتر، أو استخدم "إضافة يدوية بعنوان IP".';
    } else {
      discoveryDetail = 'يعمل على المنفذ ${discovery.udpPort} — ${discovery.currentPeers.length} جهاز ظاهر الآن';
    }
    checks.add(DiagnosticCheck(
      label: 'اكتشاف الأجهزة القريبة (بث UDP)',
      ok: discovery.isActive && discovery.lastBroadcastError == null,
      detail: discoveryDetail,
    ));

    try {
      final interfaces =
          await NetworkInterface.list(includeLoopback: false, type: InternetAddressType.IPv4);
      final addresses =
          interfaces.expand((i) => i.addresses.map((a) => '${i.name}: ${a.address}')).toList();
      checks.add(DiagnosticCheck(
        label: 'واجهات الشبكة المحلية',
        ok: addresses.isNotEmpty,
        detail: addresses.isEmpty
            ? 'لا توجد واجهة شبكة نشطة — تأكد من الاتصال بشبكة Wi-Fi أو إيثرنت'
            : addresses.join('، '),
      ));
    } catch (error) {
      checks.add(DiagnosticCheck(label: 'واجهات الشبكة المحلية', ok: false, detail: 'تعذر القراءة: $error'));
    }

    checks.add(DiagnosticCheck(
      label: 'المُرحِّل المركزي (اختياري، عبر الإنترنت)',
      ok: relay.isConnected,
      detail: relay.isConnected
          ? 'متصل — يعمل كخطة بديلة أخيرة إذا تعذّر الوصول المباشر'
          : (relay.lastError ?? 'غير متصل حاليًا (طبيعي بلا إنترنت؛ يعيد المحاولة تلقائيًا)'),
    ));

    // بدون هذه الصلاحية (أندرويد 13+)، كل الإشعارات (رسائل، مكالمات واردة،
    // خدمة الخلفية) تُبنى بصمت تام دون أي خطأ ظاهر — هذا الفحص هو الطريقة
    // الوحيدة لمعرفة أن هذا هو سبب عدم ظهور أي إشعار إطلاقًا.
    final notificationStatus = await Permission.notification.status;
    checks.add(DiagnosticCheck(
      label: 'صلاحية الإشعارات',
      ok: notificationStatus.isGranted,
      detail: notificationStatus.isGranted
          ? 'مُمنوحة — الإشعارات تعمل بشكل طبيعي'
          : 'غير مُمنوحة — لن تظهر أي إشعارات (رسائل، مكالمات واردة) إطلاقًا. '
              'امنحها من إعدادات النظام: التطبيقات ← LocalConnect ← الإشعارات.',
    ));

    // بدون هذا الاستثناء، بعض الأجهزة (خصوصًا سامسونج One UI) تضع التطبيق
    // في "سكون عميق" بعد ساعات من الخمول فتقتل خدمة الخلفية الدائمة رغم
    // وجودها — يتوقف استقبال الرسائل/المكالمات تمامًا ويظهر الجهاز "غير
    // متصل" لدى الآخرين بلا أي تفسير ظاهر. يُطلَب مرة واحدة تلقائيًا عند
    // أول فتح للتطبيق (راجع ensureNotificationPermission)، لكن قد يرفضه
    // المستخدم حينها أو يُسحَب لاحقًا من الإعدادات — هذا الفحص يكشف ذلك.
    final batteryStatus = await Permission.ignoreBatteryOptimizations.status;
    checks.add(DiagnosticCheck(
      label: 'استثناء تحسين البطارية',
      ok: batteryStatus.isGranted,
      detail: batteryStatus.isGranted
          ? 'مُمنوح — التطبيق مستثنى من إجراءات توفير البطارية العدوانية'
          : 'غير مُمنوح — قد يضع النظام التطبيق في وضع سكون بعد فترة خمول '
              'طويلة، فيتوقف استقبال الرسائل والمكالمات ويظهر جهازك "غير '
              'متصل" لدى الآخرين. امنحه من: إعدادات النظام ← التطبيقات ← '
              'مدى ← البطارية ← "بلا قيود" أو ما يعادلها.',
    ));

    final pendingCount = _messagesByConversation.values.expand((m) => m).where(
          (m) => m.outgoing && (m.status == MessageStatus.queued || m.status == MessageStatus.failed),
        ).length;
    checks.add(DiagnosticCheck(
      label: 'رسائل بانتظار التسليم',
      ok: pendingCount == 0,
      detail: pendingCount == 0
          ? 'لا توجد رسائل معلّقة'
          : '$pendingCount رسالة ستُعاد تلقائيًا عند ظهور الطرف الآخر على الشبكة',
    ));

    _safeNotify();
    return checks;
  }
}
