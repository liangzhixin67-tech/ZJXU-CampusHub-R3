import 'package:flutter/foundation.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:jni/jni.dart';

import '../../core/logging/app_logger.dart';
import '../../core/platform/android_jni_bridge.dart';
import '../../core/platform/android_platform_bindings.dart';
import 'external_url_launcher.dart';

/// 系统下载原生能力网关（默认通过 JNIgen 直调 Kotlin，单测可注入 Fake）。
abstract interface class DownloadGateway {
  Future<bool> enqueue({
    required String url,
    required String fileName,
    String? mimeType,
    String? userAgent,
    String? cookieHeader,
    String? referer,
  });
}

class _JniDownloadGateway implements DownloadGateway {
  const _JniDownloadGateway();

  @override
  Future<bool> enqueue({
    required String url,
    required String fileName,
    String? mimeType,
    String? userAgent,
    String? cookieHeader,
    String? referer,
  }) async {
    return AndroidJniBridge.withActivity<bool>(
      (arena, activity) {
        final handler = DownloadChannelHandler(activity)..releasedBy(arena);
        final jUrl = url.toJString()..releasedBy(arena);
        final jFileName = fileName.toJString()..releasedBy(arena);
        final jMime = (mimeType != null && mimeType.isNotEmpty)
            ? (mimeType.toJString()..releasedBy(arena))
            : null;
        final jUa = (userAgent != null && userAgent.isNotEmpty)
            ? (userAgent.toJString()..releasedBy(arena))
            : null;
        final jCookie = (cookieHeader != null && cookieHeader.isNotEmpty)
            ? (cookieHeader.toJString()..releasedBy(arena))
            : null;
        final jReferer = (referer != null && referer.isNotEmpty)
            ? (referer.toJString()..releasedBy(arena))
            : null;
        return handler.enqueueDownload(
          jUrl,
          jFileName,
          jMime,
          jUa,
          jCookie,
          jReferer,
        );
      },
      unavailable: false,
      label: 'JNI 系统下载入队（${urlLocationForLog(url)}）',
      category: LogCategory.webview,
    );
  }
}

/// 把 WebView 附件交给系统下载服务（Android DownloadManager）。
///
/// 下载在系统进程执行，不共享 WebView 的 Cookie，所以这里显式从
/// [CookieManager] 取目标 URL 的 Cookie 并注入下载请求头。
class SystemDownloader {
  SystemDownloader._();

  static DownloadGateway _gateway = const _JniDownloadGateway();

  @visibleForTesting
  static void setGatewayForTesting(DownloadGateway? gateway) {
    _gateway = gateway ?? const _JniDownloadGateway();
  }

  /// 入队一次系统下载；返回是否成功入队。
  static Future<bool> enqueue({
    required String url,
    required String fileName,
    String? mimeType,
    String? userAgent,
    String? referer,
    String? cookieHeader,
  }) async {
    try {
      // 原生页面（非 WebView）可显式传入 Dio CookieJar 的 Cookie。
      cookieHeader ??= (await CookieManager.instance().getCookies(
        url: WebUri(url),
      )).map((cookie) => '${cookie.name}=${cookie.value}').join('; ');

      return await _gateway.enqueue(
        url: url,
        fileName: fileName,
        mimeType: mimeType,
        userAgent: userAgent,
        cookieHeader: cookieHeader,
        referer: referer,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '系统下载入队失败: ${urlLocationForLog(url)}',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
  }
}
