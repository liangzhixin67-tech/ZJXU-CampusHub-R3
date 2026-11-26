import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:jxu_campus_hub/core/auth/zhengfang_auth.dart';
import 'package:jxu_campus_hub/core/network/dio_client.dart';
import 'package:jxu_campus_hub/core/network/network_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ZhengfangAuth auth;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    NetworkSettings.instance.debugReset();
    DioClient.instance.debugReset();
    DioClient.instance.debugCookieDirectoryPathProvider = (folderName) async {
      final dir = await Directory.systemTemp.createTemp('zhengfang_auth_test_');
      return '${dir.path}/$folderName/';
    };
    auth = ZhengfangAuth.instance;
  });

  tearDown(() {
    auth.setMode(ZhengfangMode.direct);
    auth.debugReset();
    DioClient.instance.debugReset();
    NetworkSettings.instance.debugReset();
  });

  group('extractCsrfFromHtml', () {
    test('extracts csrftoken from id-anchored input', () {
      const html =
          '<input type="hidden" id="csrftoken" name="csrftoken" value="abc123def" />';
      expect(auth.extractCsrfFromHtml(html), 'abc123def');
    });

    test('extracts csrftoken from name-anchored input', () {
      const html =
          '<input type="hidden" name="csrftoken" value="xyz789" id="csrftoken" />';
      expect(auth.extractCsrfFromHtml(html), 'xyz789');
    });

    test('extracts csrftoken with single quotes', () {
      const html =
          "<input type='hidden' name='csrftoken' value='single_quote_val' />";
      expect(auth.extractCsrfFromHtml(html), 'single_quote_val');
    });

    test('returns empty string when csrftoken is absent', () {
      const html = '<html><body>No CSRF here</body></html>';
      expect(auth.extractCsrfFromHtml(html), '');
    });
  });

  group('isLoginSuccess', () {
    test('returns true for redirect to authenticated page', () {
      expect(
        auth.isLoginSuccess(
          302,
          '/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
          '',
        ),
        isTrue,
      );
    });

    test('returns false for redirect back to login page', () {
      expect(
        auth.isLoginSuccess(302, '/jwglxt/xtgl/login_slogin.html', ''),
        isFalse,
      );
    });

    test('returns false for returned login page html', () {
      const loginHtml =
          '<form action="/jwglxt/xtgl/login_slogin.html"><input id="yhm" /><input id="mm" /></form>';
      expect(auth.isLoginSuccess(200, '', loginHtml), isFalse);
    });

    test('returns true for returned authenticated html', () {
      const authenticatedHtml = '<html>/xtgl/index_initMenu.html</html>';
      expect(auth.isLoginSuccess(200, '', authenticatedHtml), isTrue);
    });
  });

  group('extractLoginFailureMessage', () {
    test('extracts message from tips element', () {
      const html = '<div id="tips">用户名或密码错误</div>';
      expect(auth.extractLoginFailureMessage(html), '用户名或密码错误');
    });

    test('does not infer captcha rejection from ordinary form prompts', () {
      const html = '<html><body><input placeholder="请输入验证码"></body></html>';
      expect(auth.extractLoginFailureMessage(html), '登录失败，请检查用户名、密码和验证码');
    });

    test('prefers tips content over generic captcha fallback', () {
      const html = '<span id="tips">验证码已失效，请刷新</span><div>验证码</div>';
      expect(auth.extractLoginFailureMessage(html), '验证码已失效，请刷新');
    });

    test('keeps an ordinary prompt in tips as a prompt, not a rejection', () {
      const html = '<span id="tips"><font color="red">请输入验证码</font></span>';
      expect(auth.extractLoginFailureMessage(html), '请输入验证码');
    });
  });

  group('decodeHtmlEntities', () {
    test('decodes common HTML entities', () {
      expect(auth.decodeHtmlEntities('&lt;script&gt;'), '<script>');
      expect(auth.decodeHtmlEntities('&quot;hello&quot;'), '"hello"');
      expect(auth.decodeHtmlEntities('a&nbsp;b'), 'a b');
      expect(auth.decodeHtmlEntities('&#39;text&#39;'), "'text'");
      expect(auth.decodeHtmlEntities('a &amp; b'), 'a & b');
    });
  });

  group('login flow regression', () {
    test('does not logout before submitting the login form', () async {
      await DioClient.instance.ensureInitialized();
      auth.setMode(ZhengfangMode.direct);

      final adapter = _RecordingZhengfangAdapter();
      DioClient.instance.dio.httpClientAdapter = adapter;

      await auth.fetchCaptcha();
      final result = await auth.login('2024001', 'password123', '2468');

      expect(result, isA<LoginSuccess>());
      expect(auth.isLoggedIn, isTrue);
      expect(auth.currentStudentId, '2024001');
      expect(adapter.logoutCount, 0);
      expect(
        adapter.requestLog,
        equals([
          'GET /jwglxt/xtgl/login_slogin.html',
          'GET /jwglxt/kaptcha',
          'GET /jwglxt/xtgl/login_getPublicKey.html',
          'POST /jwglxt/xtgl/login_slogin.html',
          'GET /jwglxt/xtgl/index_initMenu.html',
        ]),
      );
    });

    test('surfaces captcha failure from login response html', () async {
      await DioClient.instance.ensureInitialized();
      auth.setMode(ZhengfangMode.direct);

      final adapter = _RecordingZhengfangAdapter(forceCaptchaFailure: true);
      DioClient.instance.dio.httpClientAdapter = adapter;

      await auth.fetchCaptcha();
      final result = await auth.login('2024001', 'password123', '2468');

      expect(result, isA<LoginFailure>());
      expect((result as LoginFailure).message, '验证码错误或已过期');
      expect(adapter.logoutCount, 0);
      expect(adapter.requestLog.last, 'POST /jwglxt/xtgl/login_slogin.html');
    });

    test('unknown existing session is reset once and never bound', () async {
      await DioClient.instance.ensureInitialized();
      auth.setMode(ZhengfangMode.direct);

      final adapter = _RecordingZhengfangAdapter(existingSession: true);
      DioClient.instance.dio.httpClientAdapter = adapter;

      // 首页跳转只证明会话有效，不证明学号：重置一次会话仍跳转则明确失败，
      // 不循环、不写身份。
      await expectLater(auth.fetchCaptcha(), throwsA(isA<CaptchaException>()));
      expect(auth.isLoggedIn, isFalse);
      expect(auth.currentStudentId, isNull);
      expect(adapter.logoutCount, 0);
      expect(
        adapter.requestLog,
        equals([
          'GET /jwglxt/xtgl/login_slogin.html',
          'GET /jwglxt/xtgl/login_slogin.html',
        ]),
      );
    });

    test(
      'existing session short-circuits only for trusted same account',
      () async {
        await DioClient.instance.ensureInitialized();
        auth.setMode(ZhengfangMode.direct);
        // 可信身份来源：恢复/先前真实登录写入的学生号。
        auth.debugSetSession(active: true, studentId: '2024001');

        final adapter = _RecordingZhengfangAdapter(existingSession: true);
        DioClient.instance.dio.httpClientAdapter = adapter;

        await auth.fetchCaptcha();
        final result = await auth.login('2024001', 'password123', '2468');

        expect(result, isA<LoginSuccess>());
        expect(auth.currentStudentId, '2024001');
        expect(adapter.logoutCount, 0);
        expect(
          adapter.requestLog,
          equals(['GET /jwglxt/xtgl/login_slogin.html', 'GET /jwglxt/kaptcha']),
        );
      },
    );
  });
}

class _RecordingZhengfangAdapter implements HttpClientAdapter {
  _RecordingZhengfangAdapter({
    this.forceCaptchaFailure = false,
    this.existingSession = false,
  });

  static const _modulus =
      '18vI4XcZMDybHwuQYgp+fxR8kAgAQWPnKFNLVDoTopVtDgtb1PlyJAmV85T1TVUmTVCGqw1adAmVgdDm3MaAO+CrS6bsfywyqMqT8yTNadF79hkFqf3DW0PUCWk59/vfc8QRnPyJBAIN6pNmukJxdL2Z4WLuQ4e63VivUoacFeE=';
  static const _exponent = 'AQAB';
  static const _loginPageHtml =
      '<html><input type="hidden" id="csrftoken" name="csrftoken" value="csrf-token-123" /></html>';

  final bool forceCaptchaFailure;
  final bool existingSession;
  final List<String> requestLog = <String>[];
  int logoutCount = 0;
  bool _sessionValid = true;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final path = options.uri.path;
    requestLog.add('${options.method} $path');

    if (path.endsWith('/xtgl/login_slogin.html') && options.method == 'GET') {
      if (existingSession) {
        return ResponseBody.fromString(
          '',
          302,
          isRedirect: true,
          headers: <String, List<String>>{
            'location': <String>['/jwglxt/xtgl/index_initMenu.html?jsdm=xs'],
          },
        );
      }
      return ResponseBody.fromString(
        _loginPageHtml,
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    }

    if (path.endsWith('/xtgl/login_getPublicKey.html')) {
      return ResponseBody.fromString(
        jsonEncode(<String, String>{
          'modulus': _modulus,
          'exponent': _exponent,
        }),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['application/json'],
        },
      );
    }

    if (path.endsWith('/kaptcha')) {
      return ResponseBody.fromBytes(
        Uint8List.fromList(<int>[
          0x89,
          0x50,
          0x4E,
          0x47,
          0x0D,
          0x0A,
          0x1A,
          0x0A,
        ]),
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['image/png'],
        },
      );
    }

    // 登录后会话校验：隔离会话 GET 受信菜单入口，返回已认证学生菜单页。
    if (path.endsWith('/xtgl/index_initMenu.html') && options.method == 'GET') {
      return ResponseBody.fromString(
        '<html><script>var sessionUserKey="x";</script>'
        '<a href="/jwglxt/kbcx/xskbcx_cxXskbcxIndex.html">课表</a></html>',
        200,
        headers: <String, List<String>>{
          Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
        },
      );
    }

    if (path.endsWith('/xtgl/login_logoutAccount.html')) {
      logoutCount += 1;
      _sessionValid = false;
      return ResponseBody.fromString('', 200);
    }

    if (path.endsWith('/xtgl/login_slogin.html') && options.method == 'POST') {
      if (!_sessionValid || forceCaptchaFailure) {
        return ResponseBody.fromString(
          '<html><div id="tips">验证码错误或已过期</div></html>',
          200,
          headers: <String, List<String>>{
            Headers.contentTypeHeader: <String>['text/html; charset=utf-8'],
          },
        );
      }

      return ResponseBody.fromString(
        '',
        302,
        isRedirect: true,
        headers: <String, List<String>>{
          'location': <String>['/jwglxt/xtgl/index_initMenu.html?jsdm=xs'],
        },
      );
    }

    throw UnsupportedError(
      'Unhandled request: ${options.method} ${options.uri}',
    );
  }

  @override
  void close({bool force = false}) {}
}
