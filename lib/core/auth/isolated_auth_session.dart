import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';

import '../network/cookie_interceptor.dart';
import '../network/proxy_fallback.dart';

/// 一次验证码事务的**隔离网络会话**：独立内存 [CookieJar] + 冻结的 [Dio]。
///
/// 动机：验证码图片与登录表单（lt/execution/csrftoken）绑定在服务端 session
/// 上。若 prepare A 与 prepare B 共用可变 CookieJar，会出现
/// `context_A + cookie_B + image_B` 的串扰。这里为每个 challenge 建独立 jar，
/// 并在 prepare 时从**可信来源**快照初始 cookie（CAS 当前 unified jar /
/// 教务当前模式对应 jar / WebVPN 网关 cookie），此后该 challenge 的所有请求
/// 只读写自己的 jar。
///
/// 成功提交时才把该 jar 的 cookie 合并回共享 jar（由调用方在 epoch 条件
/// 提交内执行），因此提交期间其他 refresh/mode/logout 无法改动本会话 cookie。
///
/// **跨 isolate 边界未消除**：共享 `PersistCookieJar` 的文件竞争仍存在，
/// 本类只保证单个 challenge 内部不与其它 challenge 混用。
class IsolatedAuthSession {
  IsolatedAuthSession._(
    this._sourceJar,
    this._seed, {
    required _TransactionCookieJar sessionJar,
    required Dio client,
    required Dio templateDio,
    required HttpClientAdapter? fallback,
  }) : _jar = sessionJar,
       _dio = client,
       _template = templateDio,
       _fallbackAdapter = fallback;

  final _TransactionCookieJar _jar;
  final CookieJar _sourceJar;
  final List<(Uri, SerializableCookie)> _seed;
  final Dio _dio;
  final Dio _template;
  final HttpClientAdapter? _fallbackAdapter;

  /// Opaque in-memory cookie state used only to compare stages in sanitized
  /// diagnostics. Cookie names and values never leave this object.
  Object cookieStateSnapshot() => _CookieStateSnapshot(_cookieState());

  bool cookieStateChangedSince(Object snapshot) =>
      snapshot is _CookieStateSnapshot && snapshot._state != _cookieState();

  String _cookieState() {
    final entries = <String>[];
    for (final (scope, hosts) in <(String, Map<String, dynamic>)>[
      ('host', _jar.hostCookies),
      ('domain', _jar.domainCookies.cast<String, dynamic>()),
    ]) {
      for (final host in hosts.entries) {
        final paths = host.value as Map<String, dynamic>;
        for (final path in paths.entries) {
          final cookies = path.value as Map<String, dynamic>;
          for (final cookie in cookies.entries) {
            entries.add(
              '$scope|${host.key}|${path.key}|${cookie.key}|${cookie.value}',
            );
          }
        }
      }
    }
    entries.sort();
    return entries.join('\n');
  }

  /// 从 [sourceJar] 为 [seedUris] 快照 cookie，构造独立会话。
  ///
  /// [sourceJar] 使用应用的 [DefaultCookieJar] 或 [PersistCookieJar]。
  /// [template] 提供 BaseOptions 与初始 adapter（冻结，不随代理模式切换）。
  static Future<IsolatedAuthSession> create({
    required CookieJar sourceJar,
    required List<Uri> seedUris,
    required Dio template,
    HttpClientAdapter? fallbackAdapter,
  }) async {
    final jar = _TransactionCookieJar();
    // DefaultCookieJar 和 PersistCookieJar 都公开实际存储的 scope。读取 Cookie
    // 请求视图只用于筛选，不能由当前请求 URI 推回无 Path Cookie 的存储路径。
    final source = sourceJar as DefaultCookieJar;
    final seed = <(Uri, SerializableCookie)>[];
    for (final uri in seedUris) {
      final visible = Set<Cookie>.identity()
        ..addAll(await source.loadForRequest(uri));
      for (final (hostOnly, cookies, snapshot) in [
        (true, source.hostCookies, jar.hostCookies),
        (false, source.domainCookies, jar.domainCookies),
      ]) {
        for (final domain in cookies.entries) {
          if (uri.host != domain.key &&
              (hostOnly || !_domainMatches(uri.host, domain.key))) {
            continue;
          }
          for (final path in _storedPaths(domain.value)) {
            if (!_pathMatches(uri.path, path.key)) continue;
            for (final entry
                in path.value.cast<String, SerializableCookie>().entries) {
              if (!visible.contains(entry.value.cookie)) continue;
              final scoped = (snapshot[domain.key] ??= {})[path.key] ??= {};
              if (scoped.containsKey(entry.key)) continue;
              final copy = SerializableCookie.fromJson(entry.value.toJson());
              scoped[entry.key] = copy;
              final anchor = uri.replace(path: '${path.key}/_');
              seed.add((anchor, copy));
            }
          }
        }
      }
    }

    final dio = Dio(cloneBaseOptions(template));
    dio.interceptors.add(buildCookieInterceptor(jar, responseOriginOnly: true));
    // 冻结 adapter：复用 template 当前 adapter，不因后续代理模式切换而变。
    // 共享引用，禁止对本 Dio 调用 close(force:true)（会关闭共享 adapter）。
    dio.httpClientAdapter = template.httpClientAdapter;

    return IsolatedAuthSession._(
      sourceJar,
      seed,
      sessionJar: jar,
      client: dio,
      templateDio: template,
      fallback: fallbackAdapter,
    );
  }

  /// 与共享代理回退同语义（[sendWithSystemProxyFallback]），但只作用于
  /// 隔离 dio/jar。
  Future<Response<T>> send<T>({
    required String label,
    required Future<Response<T>> Function(Dio dio, CancelToken token) request,
    CancelToken? cancelToken,
    Duration? requestTimeout,
  }) => sendWithSystemProxyFallback<T>(
    primary: _dio,
    createFallback: () => createSystemProxyFallbackDio(
      template: _template,
      jar: _jar,
      adapterOverride: _fallbackAdapter,
      responseOriginOnly: true,
    ),
    label: label,
    request: request,
    cancelToken: cancelToken,
    timeout: requestTimeout,
  );

  /// 把实际响应写入按原顺序合并回共享 [DefaultCookieJar]（成功提交时调用）。
  Future<void> commitTo(CookieJar target) async {
    final destination = target as DefaultCookieJar;
    // 同一 jar 的 seed 已存在，重放会复活事务期间被其它请求删除的 Cookie。
    // 向另一 jar 提交时仍保留原有的快照转移语义。
    if (!identical(target, _sourceJar)) {
      for (final (uri, entry) in _seed) {
        if (entry.isExpired()) continue;
        await destination.loadForRequest(uri);
        await destination.saveFromResponse(uri, [_cookieForReplay(entry)]);
      }
    }
    for (final (uri, entries) in _jar.responses) {
      // PersistCookieJar 按 host 延迟加载，saveFromResponse 本身不会先加载。
      await destination.loadForRequest(uri);
      final cookies = entries.map(_cookieForReplay).toList();
      await destination.saveFromResponse(uri, [
        ..._supersededCookies(destination, uri, cookies),
        ...cookies,
      ]);
    }
  }
}

class _CookieStateSnapshot {
  const _CookieStateSnapshot(this._state);

  final String _state;
}

class _TransactionCookieJar extends DefaultCookieJar {
  final responses = <(Uri, List<SerializableCookie>)>[];

  @override
  Future<void> saveFromResponse(Uri uri, List<Cookie> cookies) async {
    final accepted = cookies.where((cookie) {
      final domain = _domainKey(cookie);
      return domain == null || _domainMatches(uri.host, domain.toLowerCase());
    }).toList();
    if (accepted.isEmpty) return;
    final entries = accepted.map(SerializableCookie.new).toList();
    await super.saveFromResponse(uri, [
      ..._supersededCookies(this, uri, accepted),
      ...accepted,
    ]);
    responses.add((uri, entries));
  }
}

String? _domainKey(Cookie cookie) =>
    cookie.domain?.replaceFirst(RegExp(r'^\.'), '');

bool _domainMatches(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

// PersistCookieJar 4.0.9 在懒加载时转换了 Cookie 值，内部 path Map 仍保留
// JSON 解码时的 Map<String, dynamic> 类型。与库自身读取时一样使用宽类型视图。
Iterable<MapEntry<String, Map<String, dynamic>>> _storedPaths(
  Map<String, Map<String, SerializableCookie>> paths,
) => paths.cast<String, Map<String, dynamic>>().entries;

final _webVpnServicePrefix = RegExp(r'^/https?(?:-\d+)?/[^/]+');

String _cookiePath(Uri uri, Cookie cookie) {
  return cookie.path ??
      (cookie.domain != null || uri.path.isEmpty
          ? '/'
          : uri.path.substring(0, uri.path.lastIndexOf('/')));
}

Cookie _cookieForReplay(SerializableCookie entry) {
  final cookie = entry.cookie;
  final maxAge = cookie.maxAge;
  if (maxAge == null || maxAge <= 0) return cookie;
  final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  return Cookie.fromSetCookieValue(cookie.toString())
    ..maxAge = maxAge - (now - entry.createTimeStamp);
}

/// 仅清理同名、同有效域且路径有重叠的旧 scope。CAS 及其它 WebVPN 服务的
/// Cookie 可以同名，按域和路径边界保留；本响应显式发出的多个 scope 也保留。
Iterable<Cookie> _supersededCookies(
  DefaultCookieJar jar,
  Uri uri,
  List<Cookie> cookies,
) sync* {
  final updates = {
    for (final cookie in cookies)
      (_domainKey(cookie), _cookiePath(uri, cookie), cookie.name),
  };
  final fromWebVpn = uri.host == 'webvpn.zjxu.edu.cn';
  final removals = <(String?, String, String)>{};
  for (final (domain, path, name) in updates) {
    final effectiveDomain = domain ?? uri.host;
    final requestService = fromWebVpn
        ? _webVpnServicePrefix.firstMatch(path)?.group(0) ??
              _webVpnServicePrefix.firstMatch(uri.path)?.group(0)
        : null;
    for (final (scope, paths) in [
      if (effectiveDomain == uri.host) (null, jar.hostCookies[uri.host]),
      (effectiveDomain, jar.domainCookies[effectiveDomain]),
    ]) {
      if (paths == null) continue;
      for (final entry in _storedPaths(paths)) {
        final key = (scope, entry.key, name);
        final oldService = fromWebVpn
            ? _webVpnServicePrefix.firstMatch(entry.key)?.group(0)
            : null;
        if (entry.value.containsKey(name) &&
            !updates.contains(key) &&
            (oldService == null || oldService == requestService) &&
            (_pathMatches(path, entry.key) || _pathMatches(entry.key, path))) {
          removals.add(key);
        }
      }
    }
  }
  for (final (domain, path, name) in removals) {
    yield Cookie(name, '')
      ..domain = domain
      ..path = path
      ..maxAge = 0;
  }
}

bool _pathMatches(String requestPath, String cookiePath) {
  // 与 cookie_jar 的路径匹配一致：忽略大小写，尾部斜杠参与匹配边界。
  final request = requestPath.toLowerCase();
  final cookie = cookiePath.toLowerCase();
  return cookie == '/' ||
      request == cookie ||
      request.startsWith(cookie.endsWith('/') ? cookie : '$cookie/');
}
