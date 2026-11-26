import 'package:flutter/foundation.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/logging/app_logger.dart';

@visibleForTesting
typedef UrlLauncherDelegate = Future<bool> Function(Uri uri, {LaunchMode mode});

@visibleForTesting
UrlLauncherDelegate? debugUrlLauncherOverride;

@visibleForTesting
void debugResetExternalUrlLauncher() {
  debugUrlLauncherOverride = null;
}

/// 明确禁止从 WebView 上下文唤起的危险或本地资源 Scheme。
///
/// 包含本地私有文件读取（file）、代码执行（javascript）、内嵌数据注入（data）、
/// 平台 Intent 劫持（intent）及 ContentProvider 访问（content）等安全风险。
const Set<String> blockedExternalSchemes = {
  'file',
  'javascript',
  'data',
  'intent',
  'content',
  'about',
};

/// 允许从 WebView 唤起的安全通信与必要应用 Deep Link Scheme。
///
/// - 系统基础通信：tel（电话拨号）、mailto（邮件草稿）、sms（短信发送）；
/// - 校园与支付必要集成：weixin（微信支付/业务跳转）、alipays/alipay（支付宝支付）。
const Set<String> safeNonHttpSchemes = {
  'tel',
  'mailto',
  'sms',
  'weixin',
  'alipays',
  'alipay',
};

/// 判定 URI scheme 是否可安全唤起外部应用。
///
/// 允许 http/https、基础通信（tel/mailto/sms）及已明确审计的必要 App deep links；
/// 严格拒绝危险 scheme（file/javascript/data/intent/content/about 等）及其他未声明的未知 scheme。
bool isSafeExternalScheme(String scheme) {
  final s = scheme.toLowerCase().trim();
  if (blockedExternalSchemes.contains(s)) return false;
  if (s == 'http' || s == 'https') return true;
  return safeNonHttpSchemes.contains(s);
}

/// 校验是否为合法且可外部打开的 http(s) URI。
bool isExternalHttpUri(Uri? uri) {
  if (uri == null) return false;
  final scheme = uri.scheme.toLowerCase();
  return (scheme == 'http' || scheme == 'https') &&
      uri.hasAuthority &&
      uri.host.isNotEmpty;
}

/// 校验是否为合法且可外部打开的 http(s) URL 字符串。
bool isExternalHttpUrl(String? rawUrl) {
  if (rawUrl == null || rawUrl.trim().isEmpty) return false;
  final uri = Uri.tryParse(rawUrl.trim());
  return isExternalHttpUri(uri);
}

/// 对用于日志打印的 URL 进行脱敏，避免泄露 userinfo 及敏感 query 参数（如 Ticket、Token、Password）。
String scrubSensitiveUrl(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null) return '[invalid-url]';

  final sanitizedQuery = uri.queryParameters.map((key, value) {
    final lowerKey = key.toLowerCase();
    if (lowerKey == 'ticket' ||
        lowerKey == 'access_token' ||
        lowerKey == 'refresh_token' ||
        lowerKey == 'token' ||
        lowerKey == 'password' ||
        lowerKey == 'pwd' ||
        lowerKey == 'jsessionid') {
      return MapEntry(key, '[REDACTED]');
    }
    return MapEntry(key, value);
  });

  final sanitizedUri = uri.replace(
    userInfo: '',
    queryParameters: uri.hasQuery ? sanitizedQuery : null,
  );
  return sanitizedUri.toString();
}

/// Upgrades only the legacy HTTP academic-system host to its HTTPS equivalent.
/// Query and fragment are retained because the academic portal uses them for
/// legitimate deep links. The value is for navigation only and must not be
/// written to logs.
Uri? upgradeTrustedAcademicHttpUri(Uri uri) {
  if (uri.scheme.toLowerCase() != 'http' ||
      uri.host.toLowerCase() != 'jwzx.zjxu.edu.cn' ||
      uri.userInfo.isNotEmpty ||
      (uri.hasPort && uri.port != 80) ||
      !(uri.path == '/jwglxt' || uri.path.startsWith('/jwglxt/'))) {
    return null;
  }
  return Uri(
    scheme: 'https',
    host: uri.host,
    path: uri.path,
    query: uri.hasQuery ? uri.query : null,
    fragment: uri.hasFragment ? uri.fragment : null,
  );
}

/// Stable location suitable for diagnostics; intentionally omits userinfo,
/// query parameters and fragments because those may contain authentication data.
String urlLocationForLog(String rawUrl) {
  final uri = Uri.tryParse(rawUrl.trim());
  if (uri == null) return '[invalid-url]';
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

/// 判定是否处于统一认证/教务认证的敏感中间过渡状态。
///
/// 避免将带有一次性 CAS Service Ticket、OAuth access_token 等敏感参数的过渡链接
/// 或纯登录跳转页暴露给外部浏览器（防止票据泄露、单次票据被消费作废或会话混乱）。
/// 同时保护业务参数（如附件下载参数 code/fileCode 等），不影响正常文件下载。
bool isSensitiveAuthIntermediateUrl(String rawUrl) {
  final trimmed = rawUrl.trim();
  if (trimmed.isEmpty) return false;

  final uri = Uri.tryParse(trimmed);
  if (uri == null) return false;

  // 1. 检查是否存在敏感认证/票据参数
  final queryKeys = uri.queryParameters.keys
      .map((k) => k.toLowerCase())
      .toSet();
  if (queryKeys.contains('ticket') ||
      queryKeys.contains('access_token') ||
      queryKeys.contains('refresh_token') ||
      queryKeys.contains('id_token')) {
    return true;
  }

  // 2. 检查是否为 CAS 登录/认证跳转端点
  final path = uri.path.toLowerCase();
  if (path.contains('/cas/login') ||
      path.contains('/cas/validate') ||
      path.contains('/cas/servicevalidate') ||
      path.contains('/cas/p3/servicevalidate') ||
      path.contains('/casclient/login')) {
    return true;
  }

  // 3. 检查是否为正方教务初始登录页
  if (path.contains('/xtgl/login_slogin.html')) {
    return true;
  }

  // 4. WebVPN 纯网关登录入口
  if (uri.host.toLowerCase() == 'webvpn.zjxu.edu.cn' && path == '/login') {
    return true;
  }

  return false;
}

/// 在系统外部浏览器中打开指定的 URL。
///
/// 仅允许合法的 http/https 链接，拒绝处于 CAS Ticket / Token 敏感认证过渡状态的链接；
/// 不主动传递 Cookie、Token 等应用内鉴权凭据（外部浏览器运行于独立系统沙箱），
/// 亦不承诺系统浏览器继承当前会话登录态。若打开成功返回 true，否则返回 false。
Future<bool> openInExternalBrowser(
  String rawUrl, {
  String logPrefix = '外部浏览器',
}) async {
  final trimmed = rawUrl.trim();
  if (!isExternalHttpUrl(trimmed)) {
    AppLogger.instance.webview(
      LogLevel.warn,
      '$logPrefix 拒绝非 http(s) 或无效地址: ${scrubSensitiveUrl(rawUrl)}',
    );
    return false;
  }

  if (isSensitiveAuthIntermediateUrl(trimmed)) {
    AppLogger.instance.webview(
      LogLevel.warn,
      '$logPrefix 拒绝认证过渡态链接外部打开: ${scrubSensitiveUrl(trimmed)}',
    );
    return false;
  }

  final uri = Uri.parse(trimmed);
  return launchExternalUriFromWebView(uri, logPrefix: logPrefix);
}

/// 从 WebView 上下文唤起外部 URI（如系统浏览器或已知安全应用 scheme）。
Future<bool> launchExternalUriFromWebView(
  Uri uri, {
  String logPrefix = '外部链接',
}) async {
  final scheme = uri.scheme.toLowerCase().trim();
  if (!isSafeExternalScheme(scheme)) {
    AppLogger.instance.webview(
      LogLevel.warn,
      '$logPrefix 拒绝非安全或未知 Scheme: $scheme url=${scrubSensitiveUrl(uri.toString())}',
    );
    return false;
  }

  try {
    final launched = debugUrlLauncherOverride != null
        ? await debugUrlLauncherOverride!(
            uri,
            mode: LaunchMode.externalApplication,
          )
        : await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched) {
      AppLogger.instance.webview(
        LogLevel.warn,
        '$logPrefix 唤起失败: ${scrubSensitiveUrl(uri.toString())}',
      );
      return false;
    }
    return true;
  } catch (error) {
    AppLogger.instance.webview(
      LogLevel.warn,
      '$logPrefix 唤起异常: ${scrubSensitiveUrl(uri.toString())} error=$error',
    );
    return false;
  }
}
