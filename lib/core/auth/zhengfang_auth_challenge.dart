part of 'zhengfang_auth.dart';

/// 登录 POST 判成功后、提交前的会话校验结论。
enum _PostLoginVerdict {
  /// 菜单入口返回正向已认证证据。
  verified,

  /// 被打回教务登录页 / 验证码 / 901 / 401 / 403：服务端没有保留会话。
  bounced,

  /// 被打回 WebVPN 网关 / 统一认证登录：网关会话过期，不是教务会话问题。
  gatewayExpired,

  /// 收到了响应但既无正向证据也无失效证据（如 WebVPN 菜单页签名未经设备
  /// 验证）。**不阻断提交**：后续 `validateSession` 对 unknown 同样不撤销。
  unconfirmed,

  /// 校验请求传输失败，无法确认登录结果：fail closed，不提交。
  networkError,
}

/// 教务验证码事务扩展。
///
/// 每个 challenge 持有独立内存 CookieJar + 冻结 Dio，从**本事务显式模式**
/// 对应 jar 或 WebVPN 网关 cookie 快照初始化；登录表单与验证码图片都在该会话内
/// 取得，提交只使用同一会话。成功后条件提交（epoch 校验）才把 cookie 合并
/// 回共享 jar 并写 envelope，全局模式随之收敛到本事务模式。
///
/// 人工与自动恢复各用一条 challenge 通道（`automatic`），互不顶替。
///
/// 登录 POST 判成功后、提交前会先在隔离会话里校验一次受信菜单入口
/// （[_PostLoginVerdict]），会话未被服务端保留则不提交。
extension ZhengfangAuthChallengeExtension on ZhengfangAuth {
  /// 准备一次教务验证码事务：隔离会话 → 登录页上下文 → 验证码 → arm。
  ///
  /// [mode] 为空时取当前全局模式；自动恢复必须显式传入自己解析出的模式，
  /// 不得为此修改全局模式。[automatic] 选择自动恢复通道。
  Future<CaptchaChallenge> prepareCaptchaChallenge({
    CancelToken? cancelToken,
    ZhengfangMode? mode,
    bool automatic = false,
  }) async {
    await DioClient.instance.ensureInitialized();
    cancelToken.throwIfCancelled();
    final txMode = mode ?? _mode;
    final store = _challengeStore(automatic: automatic);
    final revisionAtStart = _sessionRevision;
    final accountAtStart = currentStudentId;
    // prepare 时固定持久 epoch：提交必须用它做条件提交。
    final expectedEpoch = await AuthSessionPersistence.instance.readEpoch(
      CredentialSessionDomain.academic,
    );
    cancelToken.throwIfCancelled();
    if (revisionAtStart != _sessionRevision) {
      throw CaptchaException('登录上下文已过期，请重试');
    }

    var session = await IsolatedAuthSession.create(
      sourceJar: _cookieJarFor(txMode),
      seedUris: _challengeSeedUris(txMode),
      template: _dioFor(txMode),
    );

    var context = await _buildChallengeContext(
      session,
      txMode,
      expectedEpoch: expectedEpoch,
      revisionAtStart: revisionAtStart,
      accountAtStart: accountAtStart,
      cancelToken: cancelToken,
    );
    cancelToken.throwIfCancelled();
    if (revisionAtStart != _sessionRevision) {
      throw CaptchaException('登录上下文已过期，请重试');
    }

    // 服务端残留会话但本地没有可信身份：该会话无法绑定到任何账号，登录页
    // 只会跳首页、拿不到 CSRF，原样复用会永久失败。重置一次会话重新取登录页；
    // 仍跳转则明确报错，不循环。有可信身份时保留原短路语义。
    if (context.indicatesLoggedIn && !isLoggedIn) {
      AppLogger.instance.auth(LogLevel.info, '教务残留会话无可信身份，重置会话后重新获取登录页');
      session = await _resetStaleChallengeSession(
        session,
        txMode,
        cancelToken: cancelToken,
      );
      cancelToken.throwIfCancelled();
      context = await _buildChallengeContext(
        session,
        txMode,
        expectedEpoch: expectedEpoch,
        revisionAtStart: revisionAtStart,
        accountAtStart: accountAtStart,
        cancelToken: cancelToken,
      );
      cancelToken.throwIfCancelled();
      if (revisionAtStart != _sessionRevision) {
        throw CaptchaException('登录上下文已过期，请重试');
      }
      if (context.indicatesLoggedIn) {
        AppLogger.instance.auth(LogLevel.warn, '教务残留会话重置后仍跳转首页');
        throw CaptchaException('教务系统会话异常，请稍后重试');
      }
    }

    final bytes = await _fetchChallengeCaptcha(
      session,
      txMode,
      cancelToken: cancelToken,
    );
    cancelToken.throwIfCancelled();
    if (revisionAtStart != _sessionRevision) {
      throw CaptchaException('登录上下文已过期，请重试');
    }

    return store.arm(
      domain: CaptchaChallengeDomain.zhengfang,
      accountRevision: _sessionRevision,
      bytes: bytes,
      context: context,
    );
  }

  /// 提交一次 challenge。单次提交；id 不匹配 / 过期 / 身份变化 / 本通道被
  /// 刷新或失效一律返回 [AuthFailureKind.staleOperation]。全局模式变化**不**
  /// 使事务过期：事务按自己的模式提交。
  ///
  /// [recoveryTicket] 非空表示自动恢复路径：唯一提交点是
  /// [AuthOperationCoordinator.commitIsolatedSessionForTicket]，成功后把真实
  /// [SessionCommitResult] 放进 [LoginSuccess.receipt]。ticket 域/账号必须与
  /// 登录输入一致，否则拒绝。人工调用保持 null，走原有固定合并路径。
  Future<LoginResult> submitCaptchaChallenge({
    required String challengeId,
    required String username,
    required String password,
    required String captcha,
    CancelToken? cancelToken,
    AuthRecoveryTicket? recoveryTicket,
  }) async {
    final revisionAtStart = _sessionRevision;
    // 通道由 challenge 自身决定（id 随机），提交方无需也不能指定通道。
    final store = _captchaChallenges.challenge?.id == challengeId
        ? _captchaChallenges
        : _automaticCaptchaChallenges;
    final attempt = store.consume(
      challengeId,
      accountRevision: revisionAtStart,
    );
    if (attempt == null) {
      AppLogger.instance.auth(
        LogLevel.warn,
        '教务验证码事务不可用（${recoveryTicket != null ? "自动" : "人工"}提交：'
        '已被刷新/失效/过期或身份变化）',
      );
      return LoginFailure(
        '验证码已失效，请刷新后重试',
        kind: AuthFailureKind.staleOperation,
      );
    }
    if (cancelToken?.isCancelled ?? false) {
      return LoginFailure('登录已取消', kind: AuthFailureKind.staleOperation);
    }
    if (recoveryTicket != null &&
        !_recoveryTicketMatchesInput(recoveryTicket, username)) {
      return _staleLoginFailure('自动票据与账号不符');
    }
    return _performLogin(
      context: attempt.context,
      username: username,
      password: password,
      captcha: captcha,
      revisionAtStart: revisionAtStart,
      attemptGeneration: attempt.generation,
      store: store,
      cancelToken: cancelToken,
      recoveryTicket: recoveryTicket,
    );
  }

  /// 自动票据必须属于教务域且账号与本次登录输入一致；否则不得提交。
  bool _recoveryTicketMatchesInput(AuthRecoveryTicket ticket, String username) {
    if (ticket.domain != AuthRecoveryDomain.academic) return false;
    final trimmed = username.trim();
    return trimmed.isNotEmpty && ticket.account == trimmed;
  }

  /// 传 [challengeId] 时只失效该 id（不误清更新 widget 的新 challenge）；
  /// 不传时只失效人工通道（页面刷新/关闭语义），不打断自动通道。
  void invalidateChallenge({String? challengeId}) {
    if (challengeId == null) {
      _captchaChallenges.invalidate();
      return;
    }
    if (!_captchaChallenges.invalidate(challengeId: challengeId)) {
      _automaticCaptchaChallenges.invalidate(challengeId: challengeId);
    }
  }

  @visibleForTesting
  bool get hasActiveCaptchaChallenge =>
      _captchaChallenges.hasChallenge ||
      _automaticCaptchaChallenges.hasChallenge;

  List<Uri> _challengeSeedUris(ZhengfangMode mode) {
    if (mode == ZhengfangMode.webVpn) {
      return [
        Uri.parse('${ZhengfangAuth._webVpnBase}/'),
        Uri.parse(
          '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnLoginPath}',
        ),
        Uri.parse(
          '${ZhengfangAuth._webVpnBase}${ZhengfangAuth._webVpnJwglxtPrefix}/',
        ),
      ];
    }
    return [
      Uri.parse('${ZhengfangAuth._directOrigin}/'),
      Uri.parse(
        '${ZhengfangAuth._directOrigin}${ZhengfangAuth._directLoginPath}',
      ),
      Uri.parse('${ZhengfangAuth._directBase}/'),
    ];
  }

  /// 为残留会话换一个可登录的隔离会话；只作用于本事务，不动共享 jar。
  ///
  /// 直连：换成空 cookie 会话，服务端会签发新会话，旧会话原样留在共享 jar，
  /// 登录成功后才被覆盖。WebVPN：后端会话挂在网关 cookie 上，无法靠换 jar
  /// 得到新会话，只能在本隔离会话内注销教务账号（保留网关 cookie）。
  Future<IsolatedAuthSession> _resetStaleChallengeSession(
    IsolatedAuthSession session,
    ZhengfangMode mode, {
    CancelToken? cancelToken,
  }) async {
    if (mode == ZhengfangMode.direct) {
      return IsolatedAuthSession.create(
        sourceJar: CookieJar(),
        seedUris: _challengeSeedUris(mode),
        template: _dioFor(mode),
      );
    }
    try {
      await session.send<String>(
        label: '教务残留会话注销',
        cancelToken: cancelToken,
        request: (dio, token) => dio.post<String>(
          '${_baseUrlFor(mode)}/xtgl/login_logoutAccount.html',
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            headers: {'Referer': _loginPageUrlFor(mode)},
          ),
        ),
      );
    } on DioException catch (error) {
      if (CancelToken.isCancel(error)) rethrow;
      // 注销失败不在此处判定；重新取登录页仍跳转时统一报错。
      AppLogger.instance.auth(LogLevel.warn, '教务残留会话注销请求失败', error: error);
    }
    return session;
  }

  Future<_ZhengfangChallengeContext> _buildChallengeContext(
    IsolatedAuthSession session,
    ZhengfangMode mode, {
    required int expectedEpoch,
    required int revisionAtStart,
    required String? accountAtStart,
    CancelToken? cancelToken,
  }) async {
    final loginPageUrl = _loginPageUrlFor(mode);
    final cookiesBeforePage = session.cookieStateSnapshot();
    final pageResp = await session.send<String>(
      label: '教务登录页上下文',
      cancelToken: cancelToken,
      request: (dio, token) => dio.get<String>(
        '${_baseUrlFor(mode)}/xtgl/login_slogin.html',
        cancelToken: token,
        options: Options(
          responseType: ResponseType.plain,
          headers: {'Referer': loginPageUrl},
        ),
      ),
    );

    final statusCode = pageResp.statusCode ?? 0;
    final location = pageResp.headers.value('location') ?? '';
    final pageHtml = pageResp.data ?? '';
    final csrfToken = extractCsrfFromHtml(pageHtml);
    AppLogger.instance.auth(
      LogLevel.info,
      'academic_login_diag stage=login_page status=$statusCode '
      'form_recognized=${_hasZhengfangLoginForm(pageHtml)} '
      'error_prompt_present=${_hasExplicitLoginError(pageHtml)} '
      'csrf_present=${csrfToken.isNotEmpty} '
      'cookie_changed=${session.cookieStateChangedSince(cookiesBeforePage)}',
    );
    if (isZhengfangGatewayLoginUrl(location)) {
      AppLogger.instance.auth(LogLevel.warn, '检测到 WebVPN 登录页重定向，当前认证已过期');
      // 网关掉线不能撤销独立的教务身份；交给路由准备与 CAS 恢复处理。
      throw CaptchaException('WebVPN 认证已过期，请重新登录');
    }

    if (isLoginSuccess(statusCode, location, '')) {
      // 访问登录入口却被重定向到首页：只证明**网络会话**有效，不证明学生号。
      // 因此不写 active、不通知；身份只有在已有可信 currentStudentId 时才成立。
      // 该事实只记在本事务上下文里，不再写全局标志、不失效其它通道。
      AppLogger.instance.auth(LogLevel.info, '检测到教务已有有效会话（未凭跳转绑定身份）');
      return _ZhengfangChallengeContext(
        mode: mode,
        baseUrl: _baseUrlFor(mode),
        loginPageUrl: loginPageUrl,
        origin: _originFor(mode),
        csrfToken: '',
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        session: session,
        expectedEpoch: expectedEpoch,
        indicatesLoggedIn: true,
      );
    }

    if (csrfToken.isEmpty) {
      AppLogger.instance.auth(LogLevel.warn, 'CSRF Token 为空，可能连接异常');
    }
    return _ZhengfangChallengeContext(
      mode: mode,
      baseUrl: _baseUrlFor(mode),
      loginPageUrl: loginPageUrl,
      origin: _originFor(mode),
      csrfToken: csrfToken,
      timestampMs: DateTime.now().millisecondsSinceEpoch,
      session: session,
      expectedEpoch: expectedEpoch,
    );
  }

  Future<Uint8List> _fetchChallengeCaptcha(
    IsolatedAuthSession session,
    ZhengfangMode mode, {
    CancelToken? cancelToken,
  }) async {
    final ts = DateTime.now().millisecondsSinceEpoch;
    final cookiesBeforeCaptcha = session.cookieStateSnapshot();
    final resp = await session.send<List<int>>(
      label: '教务验证码',
      cancelToken: cancelToken,
      request: (dio, token) => dio.get<List<int>>(
        '${_baseUrlFor(mode)}/kaptcha',
        queryParameters: {'time': ts},
        cancelToken: token,
        options: Options(
          responseType: ResponseType.bytes,
          headers: {'Referer': _loginPageUrlFor(mode)},
        ),
      ),
    );
    AppLogger.instance.auth(
      LogLevel.info,
      'academic_login_diag stage=captcha '
      'cookie_changed=${session.cookieStateChangedSince(cookiesBeforeCaptcha)}',
    );

    final location = resp.headers.value('location') ?? '';
    if (isZhengfangGatewayLoginUrl(location)) {
      AppLogger.instance.auth(LogLevel.warn, '教务验证码请求被重定向到 WebVPN 登录页');
      throw CaptchaException('WebVPN 认证已过期，请重新登录');
    }

    final contentType = resp.headers.value('content-type') ?? '';
    if (contentType.contains('text/html')) {
      AppLogger.instance.auth(LogLevel.warn, '验证码返回 HTML，可能未在校园网环境');
      if (mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 认证已过期，请重新登录');
      }
    }

    final bytes = resp.data;
    if (bytes == null || bytes.isEmpty) {
      throw CaptchaException('验证码数据为空，请重试');
    }

    final data = Uint8List.fromList(bytes);
    if (!ZhengfangAuth._isValidImage(data)) {
      AppLogger.instance.auth(LogLevel.warn, '验证码数据非有效图片，可能未在校园网环境');
      if (mode == ZhengfangMode.direct) {
        throw CaptchaException('无法连接到教务系统，请确保在校园网环境或已连接VPN');
      } else {
        throw CaptchaException('WebVPN 连接异常，请重试');
      }
    }

    AppLogger.instance.auth(LogLevel.info, '验证码获取成功, ${data.length} 字节');
    return data;
  }

  Future<LoginResult> _performLogin({
    required _ZhengfangChallengeContext context,
    required String username,
    required String password,
    required String captcha,
    required int revisionAtStart,
    required int? attemptGeneration,
    required CaptchaChallengeStore<_ZhengfangChallengeContext> store,
    CancelToken? cancelToken,
    AuthRecoveryTicket? recoveryTicket,
  }) async {
    final mode = context.mode;
    bool isStale() => _isLoginStale(revisionAtStart, attemptGeneration, store);
    try {
      cancelToken.throwIfCancelled();
      if (isStale()) {
        return _staleLoginFailure('公钥请求前');
      }

      if (context.csrfToken.isEmpty) {
        // 空 CSRF 只允许「已有可信身份且与输入账号一致」短路；绝不在没有
        // 真实 POST 的情况下把调用方输入的学号绑定到未知 session。
        if (context.indicatesLoggedIn &&
            username.isNotEmpty &&
            currentStudentId == username) {
          AppLogger.instance.auth(LogLevel.info, '检测到教务有效会话且身份一致，跳过登录请求');
          return LoginSuccess();
        }
        return LoginFailure(
          '初始化登录参数失败，请刷新验证码后重试',
          kind: AuthFailureKind.protocolChanged,
        );
      }

      final ts = context.timestampMs;
      final cookiesBeforePublicKey = context.session.cookieStateSnapshot();
      final keyResp = await context.session.send<Map<String, dynamic>>(
        label: '教务登录公钥',
        cancelToken: cancelToken,
        request: (dio, token) => dio.get<Map<String, dynamic>>(
          '${context.baseUrl}/xtgl/login_getPublicKey.html',
          queryParameters: {'time': ts},
          cancelToken: token,
          options: Options(
            headers: {
              'Referer': context.loginPageUrl,
              'X-Requested-With': 'XMLHttpRequest',
            },
          ),
        ),
      );
      AppLogger.instance.auth(
        LogLevel.info,
        'academic_login_diag stage=public_key '
        'cookie_changed=${context.session.cookieStateChangedSince(cookiesBeforePublicKey)}',
      );
      cancelToken.throwIfCancelled();
      if (isStale()) {
        return _staleLoginFailure('公钥请求后');
      }

      final publicKeyRedirect = keyResp.headers.value('location') ?? '';
      if (isZhengfangGatewayLoginUrl(publicKeyRedirect)) {
        return LoginFailure('WebVPN 认证已过期，请重新登录');
      }
      final modulus = keyResp.data?['modulus'] as String?;
      final exponent = keyResp.data?['exponent'] as String?;
      if (modulus == null ||
          exponent == null ||
          modulus.isEmpty ||
          exponent.isEmpty) {
        return LoginFailure('获取登录公钥失败，请稍后重试');
      }

      final encryptedPwd = _encryptPassword(password, modulus, exponent);
      final cookiesBeforeSubmit = context.session.cookieStateSnapshot();
      final loginResp = await context.session.send<String>(
        label: '教务登录',
        cancelToken: cancelToken,
        request: (dio, token) => dio.post<String>(
          '${context.baseUrl}/xtgl/login_slogin.html',
          queryParameters: {'time': ts},
          cancelToken: token,
          data: {
            'csrftoken': context.csrfToken,
            'language': 'zh_CN',
            'yhm': username,
            'mm': encryptedPwd,
            'yzm': captcha,
          },
          options: Options(
            contentType: 'application/x-www-form-urlencoded',
            followRedirects: false,
            responseType: ResponseType.plain,
            validateStatus: (s) => s != null && s < 400,
            headers: {
              'Referer': context.loginPageUrl,
              'Origin': context.origin,
            },
          ),
        ),
      );
      AppLogger.instance.auth(
        LogLevel.info,
        'academic_login_diag stage=login_submit '
        'cookie_changed=${context.session.cookieStateChangedSince(cookiesBeforeSubmit)}',
      );

      cancelToken.throwIfCancelled();
      if (isStale()) {
        return _staleLoginFailure('登录响应后');
      }

      final location = loginResp.headers.value('location') ?? '';
      final html = loginResp.data ?? '';
      // 诊断：只记状态码与 Location 的 path（无 query / 路径参数 / Cookie / 凭据）。
      AppLogger.instance.auth(
        LogLevel.info,
        '教务登录 POST 响应 [${mode == ZhengfangMode.direct ? "直连" : "WebVPN"}] '
        'status=${loginResp.statusCode} location=${_locationPathForLog(location)}',
      );
      if (isZhengfangGatewayLoginUrl(location)) {
        AppLogger.instance.auth(LogLevel.warn, '教务系统登录被重定向到 WebVPN 登录页');
        return LoginFailure('WebVPN 认证已过期，请重新登录');
      }
      if (isLoginSuccess(loginResp.statusCode, location, html)) {
        // POST 被判成功不等于服务端保留了会话（移动网络 / 高铁换 IP 时会话会被
        // 立刻丢弃，随后任何业务请求都被打回登录页）。提交前先用本事务的隔离
        // 会话校验一次；校验未通过则不提交、不通知，避免「静默假成功」。
        final verdict = await _verifyPostLoginSession(
          context,
          cancelToken: cancelToken,
        );
        cancelToken.throwIfCancelled();
        if (isStale()) {
          return _staleLoginFailure('登录后会话校验后');
        }
        switch (verdict) {
          case _PostLoginVerdict.bounced:
            return LoginFailure(
              '登录未生效：教务系统没有保持会话，可能是网络切换（如移动网络/高铁）导致，'
              '请稍后重试或连接稳定网络',
              kind: AuthFailureKind.sessionNotRetained,
            );
          case _PostLoginVerdict.gatewayExpired:
            return LoginFailure('WebVPN 认证已过期，请重新登录');
          case _PostLoginVerdict.networkError:
            return LoginFailure(
              '登录结果无法确认（网络异常），请重试',
              kind: AuthFailureKind.networkUnavailable,
            );
          case _PostLoginVerdict.verified:
          case _PostLoginVerdict.unconfirmed:
            break;
        }
        // 条件提交：epoch 校验通过才合并 cookie + 写 envelope；使用 prepare 时
        // 固定的 context.expectedEpoch，绝不重新读取当前 epoch。
        // 自动恢复路径（recoveryTicket != null）唯一走 typed ticket commit。
        final result = await _commitChallengeSession(
          context,
          username,
          context.expectedEpoch,
          recoveryTicket: recoveryTicket,
        );
        if (result == null) {
          // 别的提交（logout 或更新的登录）已胜出：绝不全局 revoke。
          return _staleLoginFailure('条件提交未胜出');
        }
        if (isStale()) {
          // 本提交已写入但已过期：只在 envelope 仍是本次提交时条件撤销。
          await AuthSessionPersistence.instance.revokeIfCurrent(
            CredentialSessionDomain.academic,
            account: result.account,
            epoch: result.epoch,
          );
          return _staleLoginFailure('提交后身份已变化');
        }
        // 成功提交了一次新会话：同账号重登也必须推进 sessionRevision，
        // 使旧 guard/旧提交的迟到结果失效，绝不允许旧响应进入新会话。
        _applySessionIdentity(
          active: true,
          studentId: username,
          forceRevision: true,
        );
        // cookie 已提交到本事务模式对应的 jar：全局模式随之收敛，后续业务请求
        // 才会走这套会话。
        _adoptMode(mode);

        AppLogger.instance.auth(
          LogLevel.info,
          '教务系统登录成功 [${mode == ZhengfangMode.direct ? "直连" : "WebVPN"}]',
        );
        _notifyAuthListeners();
        return LoginSuccess(receipt: result);
      }

      final msg = extractLoginFailureMessage(html);
      final kind = AuthFailureClassifier.classify(html: html);

      AppLogger.instance.auth(
        LogLevel.warn,
        'academic_login_diag stage=login_result '
        'form_recognized=${_hasZhengfangLoginForm(html)} '
        'error_prompt_present=${_hasExplicitLoginError(html)} '
        'csrf_present=${context.csrfToken.isNotEmpty} failure_category=$kind',
      );
      return LoginFailure(msg, kind: kind);
    } on DioException catch (e) {
      if (isStale()) {
        return _staleLoginFailure('网络异常时已过期');
      }
      if (CancelToken.isCancel(e)) {
        // 被人工登录接管 / 调用方取消：不是网络故障，不记 ERROR。
        AppLogger.instance.auth(LogLevel.info, '教务登录已取消（被人工登录接管）');
        return LoginFailure('登录已取消', kind: AuthFailureKind.staleOperation);
      }
      AppLogger.instance.auth(
        LogLevel.error,
        'academic_login_diag stage=exception failure_category='
        '${AuthFailureClassifier.fromTransport(e)} transport=${e.type}',
      );
      return LoginFailure(
        '网络错误：${e.message}',
        kind: AuthFailureClassifier.fromTransport(e),
      );
    } catch (e) {
      return LoginFailure('登录异常：$e');
    }
  }

  bool _hasZhengfangLoginForm(String html) {
    bool containsField(String field) => RegExp(
      "(?:name|id)\\s*=\\s*[\"']$field[\"']",
      caseSensitive: false,
    ).hasMatch(html);
    return containsField('yhm') && containsField('mm') && containsField('yzm');
  }

  bool _hasExplicitLoginError(String html) =>
      AuthFailureClassifier.fromLoginHtml(html) != AuthFailureKind.unknown;

  /// 登录 POST 判成功后、提交前的会话校验：用本事务的**隔离会话**请求受信
  /// 菜单入口，判定逻辑复用 [classifyAcademicEntryResponse]（与受信入口探测
  /// 同一份），不碰共享 jar、不改全局模式、不撤销任何会话。
  ///
  /// 取消异常原样上抛；其它传输失败归为 [_PostLoginVerdict.networkError]。
  Future<_PostLoginVerdict> _verifyPostLoginSession(
    _ZhengfangChallengeContext context, {
    CancelToken? cancelToken,
  }) async {
    const caller = 'post_login_verify';
    final requestUrl = '${context.baseUrl}/xtgl/index_initMenu.html';
    try {
      final cookiesBeforeVerify = context.session.cookieStateSnapshot();
      final response = await context.session.send<String>(
        label: '教务登录后会话校验',
        cancelToken: cancelToken,
        request: (dio, token) => dio.get<String>(
          requestUrl,
          queryParameters: {'jsdm': 'xs'},
          cancelToken: token,
          options: Options(
            responseType: ResponseType.plain,
            followRedirects: false,
            validateStatus: (status) => status != null && status < 1000,
            headers: {'Referer': context.loginPageUrl},
          ),
        ),
      );
      AppLogger.instance.auth(
        LogLevel.info,
        'academic_login_diag stage=session_verify '
        'cookie_changed=${context.session.cookieStateChangedSince(cookiesBeforeVerify)}',
      );
      final status = response.statusCode ?? 0;
      final location = response.headers.value('location') ?? '';
      final requestUri = response.requestOptions.uri;
      final classified = classifyAcademicEntryResponse(
        mode: context.mode,
        requestUri: requestUri,
        status: status,
        location: location,
        html: response.data ?? '',
      );
      var verdict = switch (classified) {
        AcademicEntrySessionStatus.authenticated => _PostLoginVerdict.verified,
        AcademicEntrySessionStatus.academicLoginRequired =>
          _PostLoginVerdict.bounced,
        AcademicEntrySessionStatus.unifiedLoginRequired =>
          _PostLoginVerdict.gatewayExpired,
        _ => _PostLoginVerdict.unconfirmed,
      };
      // 901 是正方「会话无效」状态码（与 validateSession 一致）。
      if (verdict == _PostLoginVerdict.unconfirmed && status == 901) {
        verdict = _PostLoginVerdict.bounced;
      } else if (verdict == _PostLoginVerdict.unconfirmed && status >= 400) {
        // 5xx / 400 等错误状态：服务端没有给出任何可用结论，无法确认登录结果，
        // 与传输失败同样 fail closed（不能把错误页当作「未发现问题」）。
        verdict = _PostLoginVerdict.networkError;
      }
      final reason = switch (verdict) {
        _PostLoginVerdict.bounced || _PostLoginVerdict.gatewayExpired =>
          location.isNotEmpty &&
                  classifyLoginUrl(requestUri.resolve(location).toString()) !=
                      null
              ? 'redirected'
              : status == 200
              ? 'loginHtml'
              : 'status$status',
        _PostLoginVerdict.networkError => 'httpError',
        _ => verdict.name,
      };
      _logAcademicSessionProbe(
        caller: caller,
        reason: reason,
        outcome: verdict.name,
        response: response,
        level: verdict == _PostLoginVerdict.verified
            ? LogLevel.info
            : LogLevel.warn,
      );
      return verdict;
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) rethrow;
      _logAcademicSessionProbe(
        caller: caller,
        reason: e.type.name,
        outcome: 'networkError',
        response: e.response,
        request: e.requestOptions,
      );
      return _PostLoginVerdict.networkError;
    } catch (_) {
      _logAcademicSessionProbe(
        caller: caller,
        reason: 'exception',
        outcome: 'networkError',
      );
      return _PostLoginVerdict.networkError;
    }
  }

  Future<SessionCommitResult?> _commitChallengeSession(
    _ZhengfangChallengeContext context,
    String account,
    int expectedEpoch, {
    AuthRecoveryTicket? recoveryTicket,
  }) {
    if (recoveryTicket != null) {
      return AuthOperationCoordinator.instance.commitIsolatedSessionForTicket(
        recoveryTicket,
        expectedSessionEpoch: expectedEpoch,
        sessionDomain: CredentialSessionDomain.academic,
        session: context.session,
        target: _cookieJarFor(context.mode),
      );
    }
    return AuthSessionPersistence.instance.commitWithIsolatedSession(
      CredentialSessionDomain.academic,
      account: account,
      expectedEpoch: expectedEpoch,
      session: context.session,
      target: _cookieJarFor(context.mode),
    );
  }

  /// 过期结果：必须丢弃；记录发生位置便于真机诊断（不含凭据）。
  LoginFailure _staleLoginFailure(String where) {
    AppLogger.instance.auth(LogLevel.warn, '教务登录结果已过期，丢弃（$where）');
    return LoginFailure('登录状态已变化，请重试', kind: AuthFailureKind.staleOperation);
  }

  bool _isLoginStale(
    int revisionAtStart,
    int? attemptGeneration,
    CaptchaChallengeStore<_ZhengfangChallengeContext> store,
  ) {
    if (revisionAtStart != _sessionRevision) return true;
    if (attemptGeneration != null &&
        !store.isAttemptCurrent(attemptGeneration)) {
      return true;
    }
    return false;
  }
}
