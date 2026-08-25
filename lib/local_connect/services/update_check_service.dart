import 'dart:convert';

import 'package:http/http.dart' as http;

class UpdateInfo {
  UpdateInfo({required this.versionTag, required this.downloadUrl});

  final String versionTag;
  final String downloadUrl;
}

/// يفحص أحدث إصدار منشور على مستودع GitHub العام للمشروع، ويقارنه برقم
/// البناء الحالي. يعتمد على GitHub Releases تحديدًا لأنه المكان الثابت
/// الوحيد المتاح هنا (روابط رفع الملفات المؤقتة تتغيّر كل مرة ولا تصلح
/// كمرجع دائم يقارَن به).
///
/// لا يُستخدم إلا عند توفر إنترنت فعليًا — فشل الفحص (لا إنترنت، تعذّر
/// الوصول لـGitHub...) يُعامَل بصمت كـ"لا تحديث متاح الآن"، لأن التطبيق
/// أصلًا مصمَّم ليعمل بالكامل دون إنترنت.
class UpdateCheckService {
  static const _apiUrl = 'https://api.github.com/repos/sofilover10/local-connect/releases/latest';

  Future<UpdateInfo?> checkForUpdate({required int currentBuildNumber}) async {
    try {
      final response = await http.get(Uri.parse(_apiUrl)).timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) return null;

      final json = jsonDecode(response.body) as Map<String, dynamic>;
      final tagName = json['tag_name'] as String?;
      if (tagName == null) return null;

      final latestBuild = _buildNumberFromTag(tagName);
      if (latestBuild == null || latestBuild <= currentBuildNumber) return null;

      final assets = (json['assets'] as List<dynamic>? ?? const [])
          .cast<Map<String, dynamic>>();
      final apkAsset = assets.where((a) => (a['name'] as String? ?? '').endsWith('.apk'));
      final downloadUrl = apkAsset.isNotEmpty
          ? apkAsset.first['browser_download_url'] as String
          : (json['html_url'] as String? ?? '');
      if (downloadUrl.isEmpty) return null;

      return UpdateInfo(versionTag: tagName, downloadUrl: downloadUrl);
    } catch (_) {
      return null;
    }
  }

  /// يستخرج رقم البناء من صيغة الوسم `v<version>+<buildNumber>`.
  int? _buildNumberFromTag(String tag) {
    final match = RegExp(r'\+(\d+)').firstMatch(tag);
    if (match == null) return null;
    return int.tryParse(match.group(1)!);
  }
}
