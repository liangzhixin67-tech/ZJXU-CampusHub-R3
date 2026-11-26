import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:jxu_campus_hub/core/auth/auth_failure.dart';

DioException _dioError(DioExceptionType type) => DioException(
  requestOptions: RequestOptions(path: '/'),
  type: type,
);

void main() {
  group('AuthFailureClassifier.fromTransport', () {
    test('maps timeout transports', () {
      expect(
        AuthFailureClassifier.fromTransport(
          _dioError(DioExceptionType.connectionTimeout),
        ),
        AuthFailureKind.timeout,
      );
      expect(
        AuthFailureClassifier.fromTransport(TimeoutException('slow')),
        AuthFailureKind.timeout,
      );
    });

    test('maps connection errors to networkUnavailable', () {
      expect(
        AuthFailureClassifier.fromTransport(
          _dioError(DioExceptionType.connectionError),
        ),
        AuthFailureKind.networkUnavailable,
      );
      expect(
        AuthFailureClassifier.fromTransport(
          _dioError(DioExceptionType.badCertificate),
        ),
        AuthFailureKind.networkUnavailable,
      );
    });

    test('maps cancellation to staleOperation', () {
      expect(
        AuthFailureClassifier.fromTransport(_dioError(DioExceptionType.cancel)),
        AuthFailureKind.staleOperation,
      );
    });

    test('unknown transports stay unknown instead of being guessed', () {
      expect(
        AuthFailureClassifier.fromTransport(
          _dioError(DioExceptionType.badResponse),
        ),
        AuthFailureKind.unknown,
      );
      expect(
        AuthFailureClassifier.fromTransport(StateError('boom')),
        AuthFailureKind.unknown,
      );
    });
  });

  group('AuthFailureClassifier.fromLoginHtml', () {
    test('recognizes captcha markers', () {
      expect(
        AuthFailureClassifier.fromLoginHtml('<div>验证码错误</div>'),
        AuthFailureKind.captchaRejected,
      );
      expect(
        AuthFailureClassifier.fromLoginHtml('<div>验证码已失效</div>'),
        AuthFailureKind.captchaRejected,
      );
      expect(
        AuthFailureClassifier.fromLoginHtml('<div id="tips">验证码输入错误</div>'),
        AuthFailureKind.captchaRejected,
      );
    });

    test('normal captcha form labels and input hints stay unknown', () {
      expect(
        AuthFailureClassifier.fromLoginHtml(
          '<label>验证码</label><input placeholder="请输入验证码">',
        ),
        AuthFailureKind.unknown,
      );
      expect(
        AuthFailureClassifier.fromLoginHtml(
          '<script>验证码错误</script><input value="验证码错误">',
        ),
        AuthFailureKind.unknown,
      );
    });

    test('recognizes explicit credential markers', () {
      expect(
        AuthFailureClassifier.fromLoginHtml('<div>用户名或密码错误</div>'),
        AuthFailureKind.invalidCredentials,
      );
      expect(
        AuthFailureClassifier.fromLoginHtml('<div>账号或密码错误</div>'),
        AuthFailureKind.invalidCredentials,
      );
    });

    test('generic fallback text that merely mentions 密码 must stay unknown', () {
      expect(
        AuthFailureClassifier.fromLoginHtml('<div>登录失败，请检查账号、密码和验证码</div>'),
        AuthFailureKind.unknown,
      );
    });
  });

  group('AuthFailureClassifier.classify priority', () {
    test('stale wins over everything', () {
      expect(
        AuthFailureClassifier.classify(
          error: _dioError(DioExceptionType.connectionTimeout),
          html: '验证码错误',
          stale: true,
        ),
        AuthFailureKind.staleOperation,
      );
    });

    test('transport wins over protocol/html', () {
      expect(
        AuthFailureClassifier.classify(
          error: _dioError(DioExceptionType.receiveTimeout),
          html: '用户名或密码错误',
          protocolChanged: true,
        ),
        AuthFailureKind.timeout,
      );
    });

    test('protocolChanged applies when no transport/html marker', () {
      expect(
        AuthFailureClassifier.classify(protocolChanged: true),
        AuthFailureKind.protocolChanged,
      );
    });

    test('html markers classify when no transport error', () {
      expect(
        AuthFailureClassifier.classify(html: '<div>验证码不正确</div>'),
        AuthFailureKind.captchaRejected,
      );
    });

    test('falls back to unknown', () {
      expect(
        AuthFailureClassifier.classify(html: '<div>服务器开小差了</div>'),
        AuthFailureKind.unknown,
      );
    });
  });
}
