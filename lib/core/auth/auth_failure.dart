import 'dart:async';
import 'dart:io' show SocketException;

import 'package:dio/dio.dart';

/// 认证/登录失败的共用分类。
///
/// 分类只依据调用方已解析出的**可靠**字符串与传输层错误类型：
/// - 服务端明确返回的验证码/密码错误文案；
/// - [DioException] / [TimeoutException] / [SocketException] 的传输语义。
///
/// 无法判定一律归入 [unknown]，**不得**把 [unknown] 当作密码错误，也不得
/// 据此自动重试（真实协议不猜）。这样自动恢复在遇到未知分支时会安全停下。
enum AuthFailureKind {
  /// 验证码错误/失效，明确可提示用户刷新验证码。
  captchaRejected,

  /// 明确的账号或密码错误（仅当服务端返回可靠文案时）。
  invalidCredentials,

  /// 网络不可达（连接错误、证书错误、DNS 失败等）。
  networkUnavailable,

  /// 请求超时（连接/发送/接收超时或显式 [TimeoutException]）。
  timeout,

  /// 协议/页面结构变化导致无法继续（上下文缺失、表单字段变化等）。
  protocolChanged,

  /// 过期操作：账号/epoch/challenge 已变化或被取消，结果必须丢弃。
  staleOperation,

  /// 登录 POST 看似成功，但随后的会话校验被打回登录页：服务端没有保留会话
  /// （常见于移动网络 / 高铁导致出口 IP 或 NAT 变化）。属于**瞬时**失败：
  /// 既不是密码错误（不计入 3 次身份失败暂停），也不是过期操作。
  sessionNotRetained,

  /// 无法可靠归类的失败。
  unknown,
}

/// 共享失败分类器。纯函数，无副作用、无网络、无日志（避免敏感串外泄）。
class AuthFailureClassifier {
  const AuthFailureClassifier._();

  /// 仅凭传输层错误对象的类型分类；不是网络语义的错误返回 [AuthFailureKind.unknown]。
  static AuthFailureKind fromTransport(Object? error) {
    if (error is TimeoutException) return AuthFailureKind.timeout;
    if (error is SocketException) return AuthFailureKind.networkUnavailable;
    if (error is DioException) {
      switch (error.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.receiveTimeout:
          return AuthFailureKind.timeout;
        case DioExceptionType.connectionError:
        case DioExceptionType.badCertificate:
          return AuthFailureKind.networkUnavailable;
        case DioExceptionType.cancel:
          return AuthFailureKind.staleOperation;
        default:
          return AuthFailureKind.unknown;
      }
    }
    return AuthFailureKind.unknown;
  }

  /// 从登录失败页面 HTML 中按可靠标记分类。
  ///
  /// 只在明确文案命中时给出具体分类；诸如「请检查账号、密码和验证码」这类
  /// 同时提到密码的兜底文案不会被归类为密码错误。
  static AuthFailureKind fromLoginHtml(String html) {
    if (html.isEmpty) return AuthFailureKind.unknown;
    final visibleText = html
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(
          RegExp(r'<(script|style)\b[^>]*>[\s\S]*?</\1>', caseSensitive: false),
          ' ',
        )
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (_captchaMarkers.any(visibleText.contains)) {
      return AuthFailureKind.captchaRejected;
    }
    if (_invalidCredentialMarkers.any(visibleText.contains)) {
      return AuthFailureKind.invalidCredentials;
    }
    return AuthFailureKind.unknown;
  }

  static const List<String> _captchaMarkers = <String>[
    '验证码错误',
    '验证码已失效',
    '验证码不正确',
    '验证码失效',
    '验证码输入错误',
  ];

  static const List<String> _invalidCredentialMarkers = <String>[
    '用户名或密码错误',
    '账号或密码错误',
    '密码错误',
    '用户名不存在',
    '账号不存在',
    '用户不存在',
  ];

  /// 组合分类。优先级：stale → 传输错误 → 协议变化 → 可靠 HTML 文案 → unknown。
  static AuthFailureKind classify({
    Object? error,
    String? html,
    bool stale = false,
    bool protocolChanged = false,
  }) {
    if (stale) return AuthFailureKind.staleOperation;
    final transport = fromTransport(error);
    if (transport != AuthFailureKind.unknown) return transport;
    if (protocolChanged) return AuthFailureKind.protocolChanged;
    if (html != null && html.isNotEmpty) {
      final htmlKind = fromLoginHtml(html);
      if (htmlKind != AuthFailureKind.unknown) return htmlKind;
    }
    return AuthFailureKind.unknown;
  }
}
