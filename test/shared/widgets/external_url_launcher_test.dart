import 'package:flutter_test/flutter_test.dart';
import 'package:jxu_campus_hub/shared/widgets/external_url_launcher.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  tearDown(() {
    debugResetExternalUrlLauncher();
  });

  group('isSafeExternalScheme', () {
    test('accepts safe schemes including http, https, tel, mailto, sms, weixin, alipay', () {
      expect(isSafeExternalScheme('http'), isTrue);
      expect(isSafeExternalScheme('https'), isTrue);
      expect(isSafeExternalScheme('tel'), isTrue);
      expect(isSafeExternalScheme('mailto'), isTrue);
      expect(isSafeExternalScheme('sms'), isTrue);
      expect(isSafeExternalScheme('weixin'), isTrue);
      expect(isSafeExternalScheme('alipays'), isTrue);
      expect(isSafeExternalScheme('alipay'), isTrue);
    });

    test('rejects dangerous and unknown schemes', () {
      expect(isSafeExternalScheme('file'), isFalse);
      expect(isSafeExternalScheme('javascript'), isFalse);
      expect(isSafeExternalScheme('data'), isFalse);
      expect(isSafeExternalScheme('intent'), isFalse);
      expect(isSafeExternalScheme('content'), isFalse);
      expect(isSafeExternalScheme('about'), isFalse);
      expect(isSafeExternalScheme('unknownapp'), isFalse);
      expect(isSafeExternalScheme(''), isFalse);
    });
  });

  group('scrubSensitiveUrl', () {
    test('redacts credentials and sensitive token parameters from URL', () {
      final scrubbed = scrubSensitiveUrl(
        'https://user:password@newca.zjxu.edu.cn/cas/login?ticket=ST-123456&access_token=secretToken&password=pwd123&code=DOC_001&id=42',
      );

      final sanitizedUri = Uri.parse(scrubbed);
      expect(sanitizedUri.userInfo, isEmpty);
      for (final key in ['ticket', 'access_token', 'password']) {
        expect(sanitizedUri.queryParameters[key], '[REDACTED]');
      }
      expect(scrubbed, isNot(contains('password@')));
      expect(scrubbed, isNot(contains('ST-123456')));
      expect(scrubbed, isNot(contains('secretToken')));
      expect(scrubbed, isNot(contains('pwd123')));
      // Business code and id parameters should be preserved
      expect(scrubbed, contains('code=DOC_001'));
      expect(scrubbed, contains('id=42'));
    });
  });

  group('upgradeTrustedAcademicHttpUri', () {
    test(
      'upgrades the trusted host and preserves deep-link query and fragment',
      () {
        final upgraded = upgradeTrustedAcademicHttpUri(
          Uri.parse(
            'http://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs&menu=score#term',
          ),
        );
        expect(
          upgraded.toString(),
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/index_initMenu.html?jsdm=xs&menu=score#term',
        );
      },
    );

    test(
      'preserves percent-encoded SSO parameters without double encoding',
      () {
        final upgraded = upgradeTrustedAcademicHttpUri(
          Uri.parse(
            'http://jwzx.zjxu.edu.cn/jwglxt/entry?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn%2Fhome%3Fx%3D1',
          ),
        );
        expect(
          upgraded.toString(),
          'https://jwzx.zjxu.edu.cn/jwglxt/entry?service=https%3A%2F%2Fmobilehall.zjxu.edu.cn%2Fhome%3Fx%3D1',
        );
      },
    );

    test(
      'rejects untrusted hosts, paths, credentials, and nonstandard ports',
      () {
        for (final raw in <String>[
          'http://jwzx.zjxu.edu.cn.evil.test/jwglxt/index.html',
          'http://jwzx.zjxu.edu.cn/other/page',
          'http://user@jwzx.zjxu.edu.cn/jwglxt/page',
          'http://jwzx.zjxu.edu.cn:8080/jwglxt/page',
          'https://jwzx.zjxu.edu.cn/jwglxt/page',
        ]) {
          expect(
            upgradeTrustedAcademicHttpUri(Uri.parse(raw)),
            isNull,
            reason: raw,
          );
        }
      },
    );
  });

  group('urlLocationForLog', () {
    test('omits query, fragment, and userinfo', () {
      expect(
        urlLocationForLog(
          'https://user:pw@jwzx.zjxu.edu.cn/jwglxt/page?ticket=secret#token',
        ),
        'https://jwzx.zjxu.edu.cn/jwglxt/page',
      );
    });
  });

  group('isSensitiveAuthIntermediateUrl', () {
    test('detects CAS ST ticket and OAuth token intermediate URLs', () {
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://mobilehall.zjxu.edu.cn/mportal/start/index.html?ticket=ST-123-abc',
        ),
        isTrue,
      );
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://example.com/oauth/callback?access_token=token123',
        ),
        isTrue,
      );
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://example.com/callback?refresh_token=ref123',
        ),
        isTrue,
      );
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://newca.zjxu.edu.cn/cas/login?service=test',
        ),
        isTrue,
      );
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html',
        ),
        isTrue,
      );
    });

    test('preserves normal document and academic URLs with business code parameters', () {
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://jwzx.zjxu.edu.cn/jwglxt/xtgl/downloadAttachment.html?code=20240901&id=100',
        ),
        isFalse,
      );
      expect(
        isSensitiveAuthIntermediateUrl(
          'https://libapp.zjxu.edu.cn/attachment/view?fileCode=xyz789',
        ),
        isFalse,
      );
    });
  });

  group('isExternalHttpUri', () {
    test('accepts valid http and https URIs with authority', () {
      expect(
        isExternalHttpUri(
          Uri.parse('https://jwzx.zjxu.edu.cn/jwglxt/xtgl/login_slogin.html'),
        ),
        isTrue,
      );
      expect(
        isExternalHttpUri(Uri.parse('http://example.com:8080/path?id=1#frag')),
        isTrue,
      );
    });

    test('rejects non-http/https URIs and URIs without host', () {
      expect(isExternalHttpUri(null), isFalse);
      expect(isExternalHttpUri(Uri.parse('javascript:void(0)')), isFalse);
      expect(isExternalHttpUri(Uri.parse('file:///sdcard/download')), isFalse);
      expect(isExternalHttpUri(Uri.parse('weixin://dl/business')), isFalse);
      expect(isExternalHttpUri(Uri.parse('about:blank')), isFalse);
      expect(isExternalHttpUri(Uri.parse('http://')), isFalse);
    });
  });

  group('isExternalHttpUrl', () {
    test('accepts valid URL strings with trimming', () {
      expect(isExternalHttpUrl('https://jwzx.zjxu.edu.cn'), isTrue);
      expect(
        isExternalHttpUrl('   https://example.com/attachment.pdf   '),
        isTrue,
      );
      expect(isExternalHttpUrl('http://127.0.0.1:8080'), isTrue);
    });

    test('rejects empty, malformed, or non-http URLs', () {
      expect(isExternalHttpUrl(null), isFalse);
      expect(isExternalHttpUrl(''), isFalse);
      expect(isExternalHttpUrl('   '), isFalse);
      expect(isExternalHttpUrl('not_a_valid_url'), isFalse);
      expect(isExternalHttpUrl('javascript:alert(1)'), isFalse);
      expect(isExternalHttpUrl('file:///etc/passwd'), isFalse);
      expect(isExternalHttpUrl('content://media/external/1'), isFalse);
    });
  });

  group('openInExternalBrowser', () {
    test(
      'rejects invalid or non-http URLs without invoking launcher',
      () async {
        var delegateCalled = false;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              delegateCalled = true;
              return true;
            };

        final result = await openInExternalBrowser('javascript:void(0)');
        expect(result, isFalse);
        expect(delegateCalled, isFalse);
      },
    );

    test(
      'rejects sensitive auth intermediate URLs without invoking launcher',
      () async {
        var delegateCalled = false;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              delegateCalled = true;
              return true;
            };

        final result = await openInExternalBrowser(
          'https://mobilehall.zjxu.edu.cn/wfw?ticket=ST-123456789',
        );
        expect(result, isFalse);
        expect(delegateCalled, isFalse);
      },
    );

    test('invokes externalApplication mode for valid document URLs preserving code param', () async {
      Uri? launchedUri;
      LaunchMode? launchedMode;
      debugUrlLauncherOverride =
          (uri, {mode = LaunchMode.platformDefault}) async {
            launchedUri = uri;
            launchedMode = mode;
            return true;
          };

      final result = await openInExternalBrowser(
        'https://jwzx.zjxu.edu.cn/notice/attachment.pdf?code=ATT_2026&id=88',
      );

      expect(result, isTrue);
      expect(
        launchedUri,
        Uri.parse(
          'https://jwzx.zjxu.edu.cn/notice/attachment.pdf?code=ATT_2026&id=88',
        ),
      );
      expect(launchedMode, LaunchMode.externalApplication);
    });

    test('returns false when launcher returns false or throws', () async {
      debugUrlLauncherOverride =
          (uri, {mode = LaunchMode.platformDefault}) async {
            return false;
          };

      final failResult = await openInExternalBrowser('https://example.com');
      expect(failResult, isFalse);

      debugUrlLauncherOverride =
          (uri, {mode = LaunchMode.platformDefault}) async {
            throw StateError('launch failed');
          };

      final throwResult = await openInExternalBrowser('https://example.com');
      expect(throwResult, isFalse);
    });
  });

  group('launchExternalUriFromWebView', () {
    test(
      'rejects dangerous schemes such as file, intent, javascript',
      () async {
        var delegateCalled = false;
        debugUrlLauncherOverride =
            (uri, {mode = LaunchMode.platformDefault}) async {
              delegateCalled = true;
              return true;
            };

        expect(
          await launchExternalUriFromWebView(Uri.parse('file:///etc/hosts')),
          isFalse,
        );
        expect(
          await launchExternalUriFromWebView(
            Uri.parse('intent:#Intent;action=android.intent.action.VIEW;end'),
          ),
          isFalse,
        );
        expect(
          await launchExternalUriFromWebView(Uri.parse('javascript:alert(1)')),
          isFalse,
        );
        expect(delegateCalled, isFalse);
      },
    );

    test('allows communication and safe app deep links', () async {
      Uri? launchedUri;
      debugUrlLauncherOverride =
          (uri, {mode = LaunchMode.platformDefault}) async {
            launchedUri = uri;
            return true;
          };

      expect(
        await launchExternalUriFromWebView(Uri.parse('tel:10086')),
        isTrue,
      );
      expect(launchedUri, Uri.parse('tel:10086'));

      expect(
        await launchExternalUriFromWebView(
          Uri.parse('mailto:support@zjxu.edu.cn'),
        ),
        isTrue,
      );
      expect(launchedUri, Uri.parse('mailto:support@zjxu.edu.cn'));

      expect(
        await launchExternalUriFromWebView(
          Uri.parse('weixin://dl/business/?t=123'),
        ),
        isTrue,
      );
      expect(launchedUri, Uri.parse('weixin://dl/business/?t=123'));
    });
  });
}
