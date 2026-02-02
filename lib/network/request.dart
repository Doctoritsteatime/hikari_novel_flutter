import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:convert';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:enough_convert/enough_convert.dart';
import 'package:hikari_novel_flutter/models/common/wenku8_node.dart';
import 'package:hikari_novel_flutter/models/resource.dart';

import '../common/log.dart';
import '../models/common/charsets_type.dart';
import '../service/local_storage_service.dart';
import 'api.dart';

/// 网络请求
class Request {
  static const userAgent = {
    HttpHeaders.userAgentHeader:
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0",
  };

  static final _dioCookieJar = CookieJar();
  static final Dio dio = Dio(
    BaseOptions(
      headers: userAgent,
      responseType: ResponseType.bytes, //使用bytes获取原始数据，方便解码
      followRedirects: false, //使302重定向手动处理，以方便传输cookie
      validateStatus: (status) => status != null && status < 400,
    ),
  )..interceptors.add(CookieManager(_dioCookieJar));

  static String? get _cookie => LocalStorageService.instance.getCookie();

  /// Clear in-memory cookie jar used by [dio].
  ///
  /// This does NOT touch the persisted cookie stored in [LocalStorageService].
  static Future<void> clearCookieJar() async {
    try {
      _dioCookieJar.deleteAll();
    } catch (_) {
      // ignore
    }
    // Best-effort only.
  }

  /// 初始化 cookie：把本地持久化的 cookie 同步进 Dio 的 CookieJar。
  /// 这能保证首次网络请求就携带 cookie（用于登录态/签到等）。
  static Future<void> initCookie() async {
    try {
      // Clear runtime jar first, then apply persisted cookie.
      await clearCookieJar();

      final cookieStr = LocalStorageService.instance.getCookie();
      if (cookieStr == null || cookieStr.trim().isEmpty) return;

      final Wenku8Node node = LocalStorageService.instance.getWenku8Node();
      final Uri uri = Uri.parse(node.node);

      final List<Cookie> cookies = <Cookie>[];
      for (final part in cookieStr.split(';')) {
        final p = part.trim();
        if (p.isEmpty || !p.contains('=')) continue;
        final kv = p.split('=');
        final name = kv.first.trim();
        final value = kv.sublist(1).join('=').trim();
        if (name.isEmpty) continue;
        cookies.add(Cookie(name, value));
      }

      if (cookies.isNotEmpty) {
        await _dioCookieJar.saveFromResponse(uri, cookies);
      }
    } catch (_) {
      // ignore: best-effort
    }
  }

  /// Get cookies currently held in Dio cookie jar for a given URL.
  static Future<List<Cookie>> getCookiesFor(String url) async {
    try {
      return await _dioCookieJar.loadForRequest(Uri.parse(url));
    } catch (_) {
      return <Cookie>[];
    }
  }

  ///获取通用数据（如其他网站的数据，即不用wenku8的cookie）
  /// - [url] 对应网站的url
  static Future<Resource> getCommonData(String url) async {
    try {
      // If FlareSolverr is enabled, use it for the request
      if (LocalStorageService.instance.getUseFlareSolverr()) {
        final flareUrl = LocalStorageService.instance.getFlareSolverrUrl();
        if (flareUrl.trim().isNotEmpty) {
          final bytes = await _fetchViaFlareSolverr(url);
          return Success(bytes);
        }
      }

      final dio = Dio(BaseOptions(headers: userAgent));
      final response = await dio.get(url);
      return Success(response.data);
    } catch (e) {
      return Error(e.toString());
    }
  }

  ///获取wenku8数据
  /// - [url] 对应的url
  /// - [charsetsType] response解码的方式
  static Future<Resource> get(
    String url, {
    required CharsetsType charsetsType,
  }) async {
    try {
      if (!url.contains("?")) url += "?";
      switch (charsetsType) {
        case CharsetsType.gbk:
          url += "&charset=gbk";
        case CharsetsType.big5Hkscs:
          url += "&charset=big5";
      }

      Log.d("$url ${charsetsType.name}");

      // If FlareSolverr is enabled, use it to fetch the page bytes (bypass Cloudflare)
      if (LocalStorageService.instance.getUseFlareSolverr()) {
        final flareUrl = LocalStorageService.instance.getFlareSolverrUrl();
        if (flareUrl.trim().isNotEmpty) {
          final bytes = await _fetchViaFlareSolverr(url);
          String decodedHtml;
          //flaresolverr 返回的已经是utf8编码的bytes了
          decodedHtml = Utf8Decoder().convert(bytes);
          // switch (charsetsType) {
          //   case CharsetsType.gbk:
          //     decodedHtml = GbkDecoder(
          //       allowInvalid: true,
          //     ).convert(bytes as Uint8List);
          //   case CharsetsType.big5Hkscs:
          //     decodedHtml = Big5Decoder(
          //       allowInvalid: true,
          //     ).convert(bytes as Uint8List);
          // }
          final logSnippet = decodedHtml.length > 409
              ? decodedHtml.substring(0, 4096)
              : decodedHtml;
          // Log.d('Fetched via FlareSolverr, $logSnippet');
          return Success(decodedHtml);
        }
      }

      final response = await dio.get(
        url,
        options: _cookie != null
            ? Options(headers: {...dio.options.headers, "Cookie": _cookie})
            : null,
      );

      //检查是否有重定向
      final html = await _checkRedirects(response);

      String decodedHtml;
      switch (charsetsType) {
        case CharsetsType.gbk:
          decodedHtml = GbkDecoder().convert(html as Uint8List);
        case CharsetsType.big5Hkscs:
          decodedHtml = Big5Decoder().convert(html as Uint8List);
      }
      return Success(decodedHtml);
    } catch (e) {
      Log.e(e.toString());
      return Error(e.toString());
    }
  }

  /// 检查Response包中是否要求重定向
  /// - [response] 要检查的Response包
  static Future<dynamic> _checkRedirects(Response response) async {
    // Manually follow redirects because `followRedirects` is disabled.
    // This is important for Wenku8 login: the server often sets cookies on a 302 chain.
    Response current = response;
    int hop = 0;

    while (current.statusCode != null &&
        current.statusCode! >= 300 &&
        current.statusCode! < 400 &&
        hop < 6) {
      final location = current.headers.value('location');
      if (location == null || location.trim().isEmpty) break;

      // Resolve relative redirects against the current request URI.
      final baseUri = current.realUri;
      final nextUri = baseUri.resolve(location);

      Log.d("Redirect[${hop + 1}]: $baseUri -> $nextUri");

      // IMPORTANT:
      // Do NOT manually inject Cookie header here. CookieManager will attach cookies
      // stored from previous responses automatically.
      current = await dio.getUri(
        nextUri,
        options: Options(headers: {...dio.options.headers}),
      );
      hop++;
    }

    return current.data;
  }

  /// 以post方法进行http请求
  /// body以Content-Type: application/x-www-form-urlencoded的形式进行发送
  /// - [url] 要请求的url
  /// - [data] 此post请求的body，当body中含有url编码的内容时，需要使用String类型而非Map类型！目前不知道是什么原因，可能是因为dio的二次编码？
  /// - [charsetsType] response解码的方式
  static Future<Resource> postForm(
    String url, {
    required Object? data,
    required CharsetsType charsetsType,
  }) async {
    try {
      // If FlareSolverr is enabled, forward POST to it
      if (LocalStorageService.instance.getUseFlareSolverr()) {
        final flareUrl = LocalStorageService.instance.getFlareSolverrUrl();
        if (flareUrl.trim().isNotEmpty) {
          final bytes = await _fetchViaFlareSolverr(
            url,
            isPost: true,
            postData: data?.toString(),
          );
          String decodedHtml;
          switch (charsetsType) {
            case CharsetsType.gbk:
              decodedHtml = GbkCodec().decode(bytes);
            case CharsetsType.big5Hkscs:
              decodedHtml = Big5Codec().decode(bytes);
          }
          return Success(decodedHtml);
        }
      }

      final response = await dio.post(
        url,
        data: data,
        options: _cookie != null
            ? Options(
                headers: {...dio.options.headers, "Cookie": _cookie},
                contentType: Headers
                    .formUrlEncodedContentType, //设置为application/x-www-form-urlencoded
              )
            : Options(
                contentType: Headers
                    .formUrlEncodedContentType, //设置为application/x-www-form-urlencoded
              ),
      );

      //  与 GET 一样：手动处理 302 重定向（否则可能拿不到最终 Cookie）
      final raw = await _checkRedirects(response);

      String decodedHtml;
      switch (charsetsType) {
        case CharsetsType.gbk:
          {
            decodedHtml = GbkCodec().decode(raw as Uint8List);
          }
        case CharsetsType.big5Hkscs:
          {
            decodedHtml = Big5Codec().decode(raw as Uint8List);
          }
      }
      return Success(decodedHtml);
    } catch (e) {
      Log.e(e.toString());
      return Error(e);
    }
  }

  /// Proxy requests through FlareSolverr server when enabled.
  /// Returns response body as UTF-8 `Uint8List`.
  static Future<Uint8List> _fetchViaFlareSolverr(
    String url, {
    bool isPost = false,
    String? postData,
  }) async {
    final flareUrl = LocalStorageService.instance.getFlareSolverrUrl();
    if (flareUrl.trim().isEmpty)
      throw Exception('FlareSolverr URL not configured');

    final payload = <String, dynamic>{
      'cmd': isPost ? 'request.post' : 'request.get',
      'url': url,
      'maxTimeout': 60000,
    };

    // If a session ID is configured, ensure the session exists and attach it
    // to the request payload so FlareSolverr will reuse the browser instance.
    final sessionId = LocalStorageService.instance.getFlareSolverrSessionId();
    if (sessionId.trim().isNotEmpty) {
      try {
        await _ensureFlareSession(sessionId);
        payload['session'] = sessionId;
      } catch (e) {
        Log.e('Failed to ensure FlareSolverr session: $e');
      }
    }

    // Attach cookies from local storage to the FlareSolverr request so the headless
    // browser will include them when loading the page.
    final cookieStr = LocalStorageService.instance.getCookie();
    if (cookieStr != null && cookieStr.trim().isNotEmpty) {
      final List<Map<String, String>> cookies = [];
      for (final part in cookieStr.split(';')) {
        final p = part.trim();
        if (p.isEmpty || !p.contains('=')) continue;
        final kv = p.split('=');
        final name = kv.first.trim();
        final value = kv.sublist(1).join('=').trim();
        if (name.isEmpty) continue;
        cookies.add({'name': name, 'value': value});
      }
      if (cookies.isNotEmpty) payload['cookies'] = cookies;
    }

    if (isPost) {
      payload['postData'] = {
        'content': postData ?? '',
        'contentType': 'application/x-www-form-urlencoded',
      };
    }

    // Log.d('FlareSolverr request: $payload to $flareUrl');

    final resp = await dio.post(
      flareUrl,
      data: jsonEncode(payload),
      options: Options(headers: {'Content-Type': 'application/json'}),
    );

    final data = resp.data;
    Map<String, dynamic>? map;
    if (data is Map) {
      map = Map<String, dynamic>.from(data);
    } else if (data is String) {
      map = jsonDecode(data) as Map<String, dynamic>?;
    } else if (data is Uint8List || data is List<int>) {
      // Dio may return bytes depending on responseType. Decode to string then parse JSON.
      // Use allowMalformed to avoid throwing on non-UTF8 bytes (some FlareSolverr
      // responses may embed raw page bytes with other encodings inside JSON).
      final text = utf8.decode(data as List<int>, allowMalformed: true);
      map = jsonDecode(text) as Map<String, dynamic>?;
    }

    if (map == null) throw Exception('Unexpected FlareSolverr response');

    if (map['status'] != null && map['status'] == 'ok') {
      final solution = map['solution'] as Map<String, dynamic>?;
      String? bodyStr;

      if (solution != null) {
        // Common case: `solution.response` is a string containing the HTML.
        if (solution.containsKey('response')) {
          final respField = solution['response'];
          if (respField is String) {
            bodyStr = respField;
          } else if (respField is Map && respField['body'] != null) {
            bodyStr = respField['body'] as String;
          }
        }

        // Fallback: some responses put the body directly on `solution.body`.
        if (bodyStr == null && solution.containsKey('body')) {
          final b = solution['body'];
          if (b is String) bodyStr = b;
        }
      }

      if (bodyStr == null) throw Exception('FlareSolverr returned no body');

      // Try to detect whether the body is base64-encoded. If base64 decode succeeds,
      // return raw bytes; otherwise return UTF-8 bytes of the string.
      try {
        final decoded = base64Decode(bodyStr);
        return Uint8List.fromList(decoded);
      } catch (_) {
        return Uint8List.fromList(utf8.encode(bodyStr));
      }
    } else {
      throw Exception('FlareSolverr error: ${map['message'] ?? map['status']}');
    }
  }

  // Ensure a named session exists in FlareSolverr; create it if missing.
  static Future<void> _ensureFlareSession(String sessionId) async {
    final flareUrl = LocalStorageService.instance.getFlareSolverrUrl();
    try {
      final listPayload = {'cmd': 'sessions.list'};
      final resp = await dio.post(
        flareUrl,
        data: jsonEncode(listPayload),
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
      dynamic data = resp.data;
      Map<String, dynamic>? map;
      if (data is Map)
        map = Map<String, dynamic>.from(data);
      else if (data is String)
        map = jsonDecode(data) as Map<String, dynamic>?;
      else if (data is Uint8List || data is List<int>) {
        final text = utf8.decode(data as List<int>, allowMalformed: true);
        map = jsonDecode(text) as Map<String, dynamic>?;
      }

      if (map != null && map['sessions'] is List) {
        final sessions = (map['sessions'] as List)
            .map((e) => e.toString())
            .toList();
        if (sessions.contains(sessionId)) return;
      }

      // create session
      final createPayload = {'cmd': 'sessions.create', 'session': sessionId};
      await dio.post(
        flareUrl,
        data: jsonEncode(createPayload),
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
    } catch (e) {
      Log.e('FlareSolverr sessions.ensure error: $e');
      // swallow: fallback to non-session requests
    }
  }

  // Destroy a named FlareSolverr session.
  static Future<void> destroyFlareSession(String sessionId) async {
    final flareUrl = LocalStorageService.instance.getFlareSolverrUrl();
    try {
      final payload = {'cmd': 'sessions.destroy', 'session': sessionId};
      await dio.post(
        flareUrl,
        data: jsonEncode(payload),
        options: Options(headers: {'Content-Type': 'application/json'}),
      );
    } catch (e) {
      Log.e('FlareSolverr sessions.destroy error: $e');
      rethrow;
    }
  }
}
