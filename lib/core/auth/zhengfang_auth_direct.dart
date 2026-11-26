part of 'zhengfang_auth.dart';

extension ZhengfangAuthDirectExtension on ZhengfangAuth {
  /// 设置连接模式
  ///
  /// 不再失效已备好的验证码事务：每个事务在 prepare 时显式绑定自己的模式
  /// （独立会话 + 目标 jar），与全局模式无关；否则后台恢复/guard 切一次模式
  /// 就会让用户正在填的验证码作废。事务提交成功后全局模式收敛到该事务的模式。
  void setMode(ZhengfangMode mode) {
    if (!_adoptMode(mode)) return;
    _notifyAuthListeners();
  }

  /// 回滚全局模式且不通知监听者：供「改道恢复」失败时撤回恢复链路里做的
  /// 切换，避免下一次请求带着未建成的 WebVPN 模式走普通过期路径。
  void restoreModeWithoutNotify(ZhengfangMode mode) => _adoptMode(mode);

  /// 只切换全局模式与 base URL，不通知；返回是否真的变化。
  bool _adoptMode(ZhengfangMode mode) {
    if (_mode == mode) return false;
    _mode = mode;
    DioClient.instance.updateBaseUrl(_baseUrl);
    DioClient.instance
        .ensureInitialized()
        .then((_) => DioClient.instance.updateBaseUrl(_baseUrl))
        .catchError((_) {});
    AppLogger.instance.auth(
      LogLevel.info,
      '教务系统连接模式切换为: ${mode == ZhengfangMode.direct ? "直连" : "WebVPN"}',
    );
    return true;
  }

  /// 兼容包装：手动 UI 只消费验证码图片字节；同时 arm 当前 challenge。
  Future<Uint8List> fetchCaptcha({CancelToken? cancelToken}) async {
    final challenge = await prepareCaptchaChallenge(cancelToken: cancelToken);
    return challenge.bytes;
  }

  Future<LoginResult> login(
    String username,
    String password,
    String captcha, {
    CancelToken? cancelToken,
    String? challengeId,
  }) async {
    if (challengeId != null) {
      return submitCaptchaChallenge(
        challengeId: challengeId,
        username: username,
        password: password,
        captcha: captcha,
        cancelToken: cancelToken,
      );
    }
    // 兼容路径：只引用当前 challenge，绝不重新初始化上下文。
    cancelToken.throwIfCancelled();
    final revisionAtStart = _sessionRevision;
    final attempt = _captchaChallenges.consumeCurrent(
      accountRevision: revisionAtStart,
    );
    if (attempt == null) {
      return LoginFailure(
        '验证码已失效，请刷新后重试',
        kind: AuthFailureKind.staleOperation,
      );
    }
    if (cancelToken?.isCancelled ?? false) {
      return LoginFailure('登录已取消', kind: AuthFailureKind.staleOperation);
    }
    return _performLogin(
      context: attempt.context,
      username: username,
      password: password,
      captcha: captcha,
      revisionAtStart: revisionAtStart,
      attemptGeneration: attempt.generation,
      store: _captchaChallenges,
      cancelToken: cancelToken,
    );
  }

  /// 必须同时满足网络会话 active 且学生号非空——跳转首页只证明会话有效，
  /// 不证明身份，因此无学生号不算已登录（与统一认证一致）。
  bool get isLoggedIn =>
      _sessionActive && (currentStudentId?.trim().isNotEmpty ?? false);

  /// 当前已验证的正方学生号（trim 后）；未登录 / 空白学生号一律 null（fail closed）。
  String? get verifiedStudentId {
    if (!isLoggedIn) return null;
    final id = currentStudentId?.trim();
    return (id == null || id.isEmpty) ? null : id;
  }

  bool get isWebVpnLoggedIn => _webVpnSessionActive;

  void markWebVpnLoggedIn() {
    _webVpnSessionActive = true;
  }

  void markWebVpnLoggedOut() {
    _webVpnSessionActive = false;
  }

  /// 外部已确认教务会话有效时的标记；条件写入不再 fire-and-forget。
  Future<void> markLoggedIn() async {
    final account = currentStudentId?.trim();
    if (account == null || account.isEmpty) {
      _touchSessionRevision();
      _sessionActive = true;
      _invalidateAllChallenges();
      _notifyAuthListeners();
      return;
    }
    final expectedEpoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.academic,
    );
    final committed = await AuthSessionPersistence.instance.commit(
      CredentialSessionDomain.academic,
      account: account,
      expectedEpoch: expectedEpoch,
    );
    _applySessionIdentity(active: true, studentId: account);
    if (committed == null) {
      AppLogger.instance.auth(LogLevel.warn, '教务会话标记：持久 epoch 已变化，未写回旧身份');
    }
    _notifyAuthListeners();
  }

  Future<void> markLoggedOut() async {
    _clearSessionInMemory();
    await _revokeDurableAcademicSession();
  }

  /// 仅收敛内存会话态并通知页面，不做持久撤销。
  void _clearSessionInMemory() {
    _touchSessionRevision();
    _sessionActive = false;
    currentStudentId = null;

    _invalidateAllChallenges();
    _notifyAuthListeners();
  }

  Future<void> _revokeDurableAcademicSession() async {
    try {
      await AuthSessionPersistence.instance.revoke(
        CredentialSessionDomain.academic,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务会话持久撤销失败（不影响登出状态）',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// 读取教务域持久 epoch；读失败返回 `-1`（无可信 epoch）。
  ///
  /// 供 guard/validateSession 绑定**请求发起时**的持久身份，绝不把读失败当成
  /// 「可无条件撤销」的理由。
  Future<int> durableAcademicEpochOrUnknown() async {
    try {
      return await AuthSessionPersistence.instance.readEpoch(
        CredentialSessionDomain.academic,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务会话持久 epoch 读取失败',
        error: error,
        stackTrace: stackTrace,
      );
      return -1;
    }
  }

  /// 仅当内存会话仍是 [revision] 且账号仍为 [account] 时收敛本地态。
  ///
  /// 不触碰持久 envelope。已处于登出态时 no-op（不无谓推进 revision）。
  bool clearSessionIfCurrent({required int revision, String? account}) {
    if (_sessionRevision != revision) return false;
    if ((currentStudentId?.trim() ?? '') != (account?.trim() ?? '')) {
      return false;
    }
    if (!_sessionActive && currentStudentId == null) return false;
    _clearSessionInMemory();
    return true;
  }

  /// 条件撤销：仅当持久 envelope 仍**精确等于** [account]+[expectedEpoch]
  /// 时，才在同一域锁内写 inactive 并推进 epoch（`revokeIfCurrent` 原子 CAS）。
  ///
  /// 内存侧仅当 [revision]/[account] 仍当前时收敛。任何 await 后都复核，
  /// 因此期间切入的新会话（B 或同账号重登）既不会被撤销，也不会被误清。
  /// 返回是否真正撤销了持久会话。
  Future<bool> revokeSessionIfCurrent({
    required int revision,
    required String account,
    required int expectedEpoch,
  }) async {
    final expected = account.trim();
    if (expected.isEmpty || expectedEpoch < 0) return false;
    if (_sessionRevision != revision) return false;
    if ((currentStudentId?.trim() ?? '') != expected) return false;

    bool revoked;
    try {
      revoked = await AuthSessionPersistence.instance.revokeIfCurrent(
        CredentialSessionDomain.academic,
        account: expected,
        epoch: expectedEpoch,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务会话条件撤销失败',
        error: error,
        stackTrace: stackTrace,
      );
      return false;
    }
    // 撤销后只有同 revision/account 仍当前时才清本地，绝不误清后来者。
    if (revoked &&
        _sessionRevision == revision &&
        (currentStudentId?.trim() ?? '') == expected) {
      _clearSessionInMemory();
    }
    return revoked;
  }

  /// 收尾一次已失效的旧会话：有可信账号 + epoch 时走持久条件撤销；
  /// 否则（无账号 / 无可信 epoch / 读失败）至多条件清旧内存，绝不无条件 revoke。
  Future<bool> revokeExpiredSessionIfCurrent({
    required int revision,
    String? account,
    required int expectedEpoch,
  }) async {
    final owner = account?.trim() ?? '';
    if (owner.isEmpty || expectedEpoch < 0) {
      clearSessionIfCurrent(revision: revision, account: account);
      return false;
    }
    return revokeSessionIfCurrent(
      revision: revision,
      account: owner,
      expectedEpoch: expectedEpoch,
    );
  }

  Future<void> restoreSession({bool clearIfInactive = false}) async {
    final revision = _sessionRevision;
    final studentId = await CredentialStore.instance.loadZhengfangSession();
    if (revision != _sessionRevision) return;
    if (studentId == null) {
      if (clearIfInactive && isLoggedIn) {
        _applySessionIdentity(active: false, studentId: null);
        _notifyAuthListeners();
      }
      return;
    }
    final identityChanged = currentStudentId != studentId || !_sessionActive;
    _applySessionIdentity(active: true, studentId: studentId);
    if (identityChanged) _notifyAuthListeners();
  }

  /// 显式登出：**先本地持久撤销**，再 best-effort 网络清理；迟到的 cookie
  /// 清理不会删除新登录建立的 cookie（revision 已变则跳过）。
  Future<void> logout() async {
    _touchSessionRevision();
    final myRevision = _sessionRevision;
    _sessionActive = false;
    currentStudentId = null;

    _invalidateAllChallenges();
    _notifyAuthListeners();
    try {
      await AuthSessionPersistence.instance.revoke(
        CredentialSessionDomain.academic,
      );
    } catch (error, stackTrace) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务登出持久撤销失败（不影响登出状态）',
        error: error,
        stackTrace: stackTrace,
      );
    }

    try {
      await DioClient.instance.ensureInitialized();
      await _dio.post<void>('$_baseUrl/xtgl/login_logoutAccount.html');
    } catch (_) {}

    if (_sessionRevision != myRevision) {
      // 期间发生了新登录/换号：不得删除新身份的 cookie。
      AppLogger.instance.auth(LogLevel.debug, '教务登出清理跳过：revision 已变化');
      return;
    }
    await _clearZhengfangCookies();
  }

  Future<void> logoutWebVpn() async {
    await DioClient.instance.ensureInitialized();
    await _webVpnCookieJar.deleteAll();
    markWebVpnLoggedOut();
    _notifyAuthListeners();
  }

  Future<void> _clearZhengfangCookies() async {
    final uris = [
      Uri.parse('${ZhengfangAuth._directOrigin}/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}${ZhengfangAuth._directLoginPath}',
      ),
      Uri.parse('${ZhengfangAuth._directBase}/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}/jwglxt/xtgl/index_initMenu.html?jsdm=xs',
      ),
      Uri.parse(
        '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnJwglxtPrefix}/',
      ),
      Uri.parse(_loginPageUrl),
    ];

    for (final uri in uris) {
      final cookies = await _cookieJar.loadForRequest(uri);
      if (cookies.isEmpty) continue;
      await _cookieJar.delete(uri);
    }
  }

  Future<void> _clearWebViewCookiesForUri(
    CookieManager cookieManager,
    Uri uri,
    List<io.Cookie> cookies, {
    bool Function()? isIdentityCurrent,
    bool strict = false,
  }) async {
    if (cookies.isEmpty) return;

    final rootUrls = <String>{
      '${uri.scheme}://${uri.host}/',
      if (uri.scheme == 'https') 'http://${uri.host}/',
    };
    final normalizedPath = (uri.path.isEmpty ? '/' : uri.path).trim();

    for (final cookie in cookies) {
      if (isIdentityCurrent != null && !isIdentityCurrent()) return;
      final domain = (cookie.domain ?? '').trim();
      final targetDomain = domain.isNotEmpty ? domain : uri.host;
      final normalizedDomain = targetDomain.replaceFirst(RegExp(r'^\.'), '');
      final domainCandidates = <String>{
        targetDomain,
        normalizedDomain,
        '.$normalizedDomain',
      };
      final targetPath = (cookie.path ?? '').trim().isNotEmpty
          ? cookie.path!.trim()
          : normalizedPath;

      for (final rootUrl in rootUrls) {
        for (final candidate in domainCandidates) {
          if (isIdentityCurrent != null && !isIdentityCurrent()) return;
          try {
            await cookieManager.deleteCookie(
              url: WebUri(rootUrl),
              name: cookie.name,
              domain: candidate,
              path: '/',
            );
          } catch (_) {
            if (strict) {
              throw AcademicCookieSyncException(
                '清理旧 WebView Cookie 失败: ${uri.host}${uri.path}',
              );
            }
          }
          try {
            await cookieManager.deleteCookie(
              url: WebUri(rootUrl),
              name: cookie.name,
              domain: candidate,
              path: targetPath,
            );
          } catch (_) {
            if (strict) {
              throw AcademicCookieSyncException(
                '清理旧 WebView Cookie 失败: ${uri.host}${uri.path}',
              );
            }
          }
        }
      }
    }
  }

  @visibleForTesting
  String extractCsrfFromHtml(String html) {
    final matchById = RegExp(
      r'''id=["']csrftoken["'][^>]*value=["']([^"']+)["']''',
    ).firstMatch(html);
    final matchByName = RegExp(
      r'''name=["']csrftoken["'][^>]*value=["']([^"']+)["']''',
    ).firstMatch(html);
    return (matchById?.group(1) ?? matchByName?.group(1) ?? '').trim();
  }

  @visibleForTesting
  bool isLoginSuccess(int? statusCode, String location, String html) {
    if (statusCode == 302 || statusCode == 303) {
      if (isZhengfangLoginEntryUrl(location)) return false;
      return isZhengfangAuthenticatedUrl(location);
    }
    return html.contains('/xtgl/index_initMenu.html') ||
        html.contains('/xtgl/index_cxYhxxIndex.html');
  }

  @visibleForTesting
  String extractLoginFailureMessage(String html) {
    final tipMatch = RegExp(
      r'''id=["']tips["'][^>]*>([\s\S]*?)</[^>]+>''',
      caseSensitive: false,
    ).firstMatch(html);
    if (tipMatch != null) {
      final message = decodeHtmlEntities(
        (tipMatch.group(1) ?? '').replaceAll(RegExp(r'<[^>]+>'), '').trim(),
      );
      if (message.isNotEmpty) return message;
    }

    return '登录失败，请检查用户名、密码和验证码';
  }

  @visibleForTesting
  String decodeHtmlEntities(String value) {
    var result = value.trim();
    for (var i = 0; i < 3; i++) {
      final decoded = result
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&amp;', '&');
      if (decoded == result) break;
      result = decoded;
    }
    return result.trim();
  }

  @visibleForTesting
  void debugSetSession({
    required bool active,
    String? studentId,
    bool forceRevision = false,
  }) {
    _applySessionIdentity(
      active: active,
      studentId: studentId,
      forceRevision: forceRevision,
    );
  }

  @visibleForTesting
  void debugReset() {
    _sessionActive = false;
    currentStudentId = null;
    _mode = ZhengfangMode.direct;
    _sessionRevision = 0;
    _invalidateAllChallenges();
  }
}
