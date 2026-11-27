/// URL building, validation and redaction for the AgilFrame Flutter SDK.
///
/// Security invariants (covered by `test/url_test.dart`):
///  - only `http:`/`https:` server URLs are accepted, and plain HTTP is
///    rejected outside loopback/dev hosts unless [AgilCallUrlOptions.allowInsecure]
///    is explicitly set;
///  - credentials, query strings and fragments are rejected in `serverUrl`;
///  - every user-supplied value is length-limited and control-character checked;
///  - [parseAgilCallLink] never trusts a cross-origin `server` parameter, so a
///    crafted deep link cannot redirect a join token to another host;
///  - errors and redacted URLs never contain the token.
///
/// Pure Dart: no Flutter imports, not even `package:flutter`, so it is testable
/// on any Dart VM.
library;

import 'types.dart';

/// Thrown for invalid SDK configuration before anything is loaded.
class AgilConfigException implements Exception {
  const AgilConfigException(this.message, {this.field});

  /// Human-readable, token-free message.
  final String message;

  /// Offending option name, when known (useful for form validation).
  final String? field;

  @override
  String toString() => 'AgilConfigException: $message';
}

const int _maxUrlLength = 8192;
const int _maxTokenLength = 8192;
const int _maxRoomLength = 200;
const int _maxNameLength = 120;
const int _maxTenantLength = 64;
const int _maxPathLength = 200;

/// Page path used when [AgilCallUrlOptions.widgetPath] is omitted.
const String defaultWidgetPath = 'embed.html';

/// Path component of the hosted embed page.
const String widgetHtmlPath = '/embed.html';

final RegExp _controlChars = RegExp(r'[\u0000-\u001F\u007F]');
final RegExp _trailingSlashes = RegExp(r'/+$');
final RegExp _absoluteScheme = RegExp(r'^[a-z][a-z0-9+.-]*:', caseSensitive: false);
final RegExp _tokenQueryValue = RegExp(
  r'(^|[?&\s])((?:token|identity_token|id_token|access_token|joinctoken|identitytoken)=)[^&\s#]+',
  caseSensitive: false,
);
final RegExp _jwtLike = RegExp(
  r'\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b',
);
const Set<String> _redactedQueryKeys = <String>{
  'token',
  'joinctoken',
  'identity_token',
  'identitytoken',
  'id_token',
  'access_token',
};

/// Options accepted by [buildWidgetUrl].
class AgilCallUrlOptions {
  const AgilCallUrlOptions({
    required this.serverUrl,
    required this.roomId,
    this.joinToken,
    this.tenantId = 'demo',
    this.participantName,
    this.role,
    this.language,
    this.theme,
    this.identityToken,
    this.relayOnly = false,
    this.widgetPath = defaultWidgetPath,
    this.allowInsecure = false,
  });

  /// Base REST/WS/static origin, e.g. `https://calls.example.com` (a subpath
  /// such as `https://host/calls` is preserved).
  final String serverUrl;

  /// Room id (`room`).
  final String roomId;

  /// Short-lived join token (`token`). Never log the built URL.
  final String? joinToken;

  /// Tenant (`tenant`); `demo` by default.
  final String tenantId;

  /// Display name used by the widget's join screen (`name`).
  final String? participantName;

  /// Role for anonymous joins (`role`).
  final AgilRole? role;

  /// Widget locale (`lang`).
  final AgilLanguage? language;

  /// Theme scheme only (`theme`); the full theme lives on the server.
  final AgilThemeScheme? theme;

  /// Corporate OIDC token for SSO (`identity_token`).
  final String? identityToken;

  /// Force TURN-only media (`relay=1`).
  final bool relayOnly;

  /// Page path relative to [serverUrl]; `/embed.html` is origin-root-relative.
  final String widgetPath;

  /// Allows a non-loopback `http://` URL. Development only: join tokens and
  /// media would travel in clear text.
  final bool allowInsecure;
}

/// Validates and normalizes a server base URL.
///
/// The result has no trailing slash, no query string, no fragment, no
/// credentials and no explicit default port (`:443`/`:80`).
String normalizeServerUrl(String input) {
  final String raw = input.trim();
  if (raw.isEmpty) {
    throw const AgilConfigException('serverUrl is required', field: 'serverUrl');
  }
  if (raw.length > _maxUrlLength) {
    throw const AgilConfigException('serverUrl is too long', field: 'serverUrl');
  }
  if (_controlChars.hasMatch(raw)) {
    throw const AgilConfigException('serverUrl contains control characters', field: 'serverUrl');
  }
  final Uri? parsed = Uri.tryParse(raw);
  if (parsed == null || !parsed.hasScheme || parsed.host.isEmpty) {
    throw const AgilConfigException(
      'serverUrl must be an absolute http or https URL',
      field: 'serverUrl',
    );
  }
  final String scheme = parsed.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') {
    throw const AgilConfigException('serverUrl must use http or https', field: 'serverUrl');
  }
  if (parsed.userInfo.isNotEmpty) {
    throw const AgilConfigException(
      'serverUrl must not contain credentials',
      field: 'serverUrl',
    );
  }
  if (parsed.hasQuery || parsed.hasFragment) {
    throw const AgilConfigException(
      'serverUrl must not contain a query string or fragment',
      field: 'serverUrl',
    );
  }
  final String path = parsed.path.replaceFirst(_trailingSlashes, '');
  final String origin = _originOf(parsed);
  if (origin.isEmpty) {
    throw const AgilConfigException('serverUrl must be an absolute URL', field: 'serverUrl');
  }
  return path.isEmpty || path == '/' ? origin : '$origin$path';
}

/// Exact scheme/host/port origin of a normalized server URL.
String serverOrigin(String serverUrl) => _originOf(Uri.parse(normalizeServerUrl(serverUrl)));

/// Builds the hosted widget URL used by the WebView:
/// `https://calls.example.com/embed.html?server=…&room=…&tenant=…`.
///
/// Subpath deployments are preserved: `serverUrl: 'https://host/calls'` plus the
/// default widget path produces `https://host/calls/embed.html`. Pass
/// `widgetPath: '/embed.html'` to address the origin root explicitly.
String buildWidgetUrl(AgilCallUrlOptions options) {
  final String serverUrl = normalizeServerUrl(options.serverUrl);
  final Uri base = Uri.parse(serverUrl);
  _assertSecure(base, options.allowInsecure, 'serverUrl');

  final String roomId = _assertRoomId(options.roomId);
  final String tenantId = _assertTenant(options.tenantId);
  final String widgetPath = _assertWidgetPath(options.widgetPath);
  final String? joinToken = options.joinToken == null
      ? null
      : _assertToken(options.joinToken!, 'joinToken');
  final String? identityToken = options.identityToken == null
      ? null
      : _assertToken(options.identityToken!, 'identityToken');
  final String? participantName =
      _optionalName(options.participantName, 'participantName', _maxNameLength);

  final List<List<String>> pairs = <List<String>>[
    <String>['server', serverUrl],
    <String>['room', roomId],
    if (joinToken != null) <String>['token', joinToken],
    <String>['tenant', tenantId],
    if (options.language != null) <String>['lang', options.language!.wire],
    if (participantName != null) <String>['name', participantName],
    if (options.role != null) <String>['role', options.role!.wire],
    if (identityToken != null) <String>['identity_token', identityToken],
    if (options.theme != null) <String>['theme', options.theme!.wire],
    if (options.relayOnly) <String>['relay', '1'],
  ];

  final String path = _resolveWidgetPath(base.path, widgetPath);
  return '${_originOf(base)}$path?${_serializeQuery(pairs)}';
}

/// Parses an `https://…/embed.html?…` URL or an `agilcalls://call?…` deep link
/// into a call description. Returns `null` for malformed or unsafe links.
///
/// For http(s) links the `server` parameter must match the link's own origin and
/// path prefix. This prevents
/// `https://calls.corp/embed.html?server=https://evil.example&token=…` from
/// sending a join token to an attacker-controlled host.
///
/// For custom schemes [allowedOrigins] is the only trust anchor: always pass
/// the list of trusted server origins (empty list means same-origin only and is
/// rejected for custom schemes).
AgilCallLink? parseAgilCallLink(
  String input, {
  List<String> allowedOrigins = const <String>[],
  List<String> allowedSchemes = const <String>['agilcalls'],
  bool allowInsecure = false,
}) {
  final String raw = input.trim();
  if (raw.isEmpty || raw.length > _maxUrlLength) return null;
  if (_controlChars.hasMatch(raw)) return null;
  final Uri? parsed = Uri.tryParse(raw);
  if (parsed == null || !parsed.hasScheme || parsed.userInfo.isNotEmpty) return null;

  final String scheme = parsed.scheme.toLowerCase();
  final bool isHttp = scheme == 'https' || scheme == 'http';
  final List<String> customSchemes = <String>[
    for (final String value in allowedSchemes)
      value.trim().toLowerCase().replaceAll(':', ''),
  ];
  final bool isCustom = !isHttp && customSchemes.contains(scheme);
  if (!isHttp && !isCustom) return null;

  Map<String, List<String>> params;
  try {
    params = parsed.queryParametersAll;
  } catch (_) {
    return null;
  }

  String kind;
  String expectedServer;
  final String? serverParam = _firstParam(params, <String>['server', 'serverUrl']);

  if (isHttp) {
    if (!parsed.path.toLowerCase().endsWith(widgetHtmlPath)) return null;
    final String basePath =
        parsed.path.substring(0, parsed.path.length - widgetHtmlPath.length);
    try {
      expectedServer = normalizeServerUrl('${_originOf(parsed)}$basePath');
    } catch (_) {
      return null;
    }
    kind = 'embed';
    if (!_originAllowed(_originOf(parsed), allowedOrigins, allowEmpty: true)) return null;
  } else {
    if (serverParam == null) return null;
    // A custom scheme is only reachable by an attacker-supplied link, so it
    // requires an explicit trust anchor. Empty list = nothing is trusted.
    if (allowedOrigins.isEmpty) return null;
    try {
      expectedServer = normalizeServerUrl(serverParam);
    } catch (_) {
      return null;
    }
    kind = 'deep-link';
    if (!_originAllowed(_originOf(Uri.parse(expectedServer)), allowedOrigins)) {
      return null;
    }
  }

  try {
    _assertSecure(Uri.parse(expectedServer), allowInsecure, 'serverUrl');
  } catch (_) {
    return null;
  }

  if (serverParam != null) {
    final String normalized;
    try {
      normalized = normalizeServerUrl(serverParam);
    } catch (_) {
      return null;
    }
    if (kind == 'embed' && normalized != expectedServer) return null;
    expectedServer = normalized;
  }

  final String? roomValue = _firstParam(params, <String>['room', 'roomId']);
  if (roomValue == null) return null;

  try {
    final String roomId = _assertRoomId(roomValue);
    final String? joinToken = _optionalToken(
      _firstParam(params, <String>['token', 'joinToken']),
      'joinToken',
    );
    final String? identityToken = _optionalToken(
      _firstParam(params, <String>['identity_token', 'identityToken', 'id_token']),
      'identityToken',
    );
    final String? tenantId =
        _optionalName(_firstParam(params, <String>['tenant', 'tenantId']), 'tenantId', _maxTenantLength);
    final String? participantName = _optionalName(
      _firstParam(params, <String>['name', 'participantName']),
      'participantName',
      _maxNameLength,
    );
    final AgilLanguage? language =
        AgilLanguage.tryParse(_firstParam(params, <String>['lang', 'language']));
    final AgilThemeScheme? theme =
        AgilThemeScheme.tryParse(_firstParam(params, <String>['theme']));
    final AgilRole? role = AgilRole.tryParse(_firstParam(params, <String>['role']));
    final String? relay = _firstParam(params, <String>['relay']);

    return AgilCallLink(
      kind: kind,
      serverUrl: expectedServer,
      roomId: roomId,
      joinToken: joinToken,
      tenantId: tenantId,
      participantName: participantName,
      language: language,
      theme: theme,
      role: role,
      identityToken: identityToken,
      relayOnly: relay == '1' || relay == 'true',
    );
  } on AgilConfigException {
    return null;
  }
}

/// Navigation guard for the WebView.
///
/// Allows `about:blank`/`about:srcdoc`, the widget origin and explicit extra
/// origins; everything else (`javascript:`, `file:`, `intent:`, other hosts) is
/// blocked.
bool isAllowedNavigation(
  String url, {
  required String serverUrl,
  List<String> allowedOrigins = const <String>[],
}) {
  final String value = url.trim();
  if (value.isEmpty) return false;
  final String lower = value.toLowerCase();
  if (lower == 'about:blank' || lower == 'about:srcdoc') return true;
  if (_controlChars.hasMatch(value)) return false;
  final Uri? parsed = Uri.tryParse(value);
  if (parsed == null || parsed.userInfo.isNotEmpty) return false;
  final String scheme = parsed.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') return false;
  final String origin = _originOf(parsed);
  if (origin.isEmpty) return false;
  try {
    final Uri server = Uri.parse(normalizeServerUrl(serverUrl));
    if (_originOf(server) == origin) return true;
  } on AgilConfigException {
    return false;
  }
  return _originAllowed(origin, allowedOrigins);
}

/// Masks JWT-looking strings and token query parameters in free-form text.
String redactTokenText(String text) {
  return text
      .replaceAllMapped(_tokenQueryValue, (Match match) {
        final String prefix = '${match[1]}${match[2]}';
        // Preserve an already-masked known secret instead of replacing the
        // visible `[redacted]` marker with the generic `redacted` value.
        final String value = match[0]!.substring(prefix.length);
        return '$prefix${value == '[redacted]' ? value : 'redacted'}';
      })
      .replaceAll(_jwtLike, 'redacted');
}

/// Masks token-shaped text plus known secret values (the current join and
/// identity tokens) from an untrusted widget message.
String redactSecrets(String text, [List<String> secrets = const <String>[]]) {
  // Mask known secrets first: token-shaped keys would otherwise replace the
  // value with the generic `redacted` before the `[redacted]` marker is applied.
  String redacted = text;
  for (final String secret in secrets) {
    if (secret.length < 4) continue;
    redacted = redacted.replaceAll(secret, '[redacted]');
  }
  return redactTokenText(redacted);
}

/// URL-safe for logs/errors: strips credentials and masks token parameters.
String redactCallUrl(String input) {
  final String raw = input.trim();
  if (raw.isEmpty) return '';
  final Uri? parsed = Uri.tryParse(raw);
  if (parsed == null || !parsed.hasScheme) return redactTokenText(raw);
  final List<List<String>> pairs = <List<String>>[];
  try {
    parsed.queryParametersAll.forEach((String key, List<String> values) {
      for (final String value in values) {
        pairs.add(<String>[
          key,
          _redactedQueryKeys.contains(key.toLowerCase()) ? 'redacted' : value,
        ]);
      }
    });
  } catch (_) {
    return redactTokenText(raw);
  }
  final StringBuffer buffer = StringBuffer()
    ..write(parsed.scheme)
    ..write('://')
    ..write(parsed.authority)
    ..write(parsed.path);
  if (pairs.isNotEmpty) {
    buffer
      ..write('?')
      ..write(_serializeQuery(pairs));
  }
  if (parsed.hasFragment) {
    buffer
      ..write('#')
      ..write(parsed.fragment);
  }
  return redactTokenText(buffer.toString());
}

String _originOf(Uri uri) {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme.isEmpty || uri.host.isEmpty) return '';
  String authority = uri.authority;
  final int? port = uri.hasPort ? uri.port : null;
  if (port != null) {
    final int? defaultPort = scheme == 'https' ? 443 : (scheme == 'http' ? 80 : null);
    if (defaultPort != null && port == defaultPort) {
      authority = authority.substring(0, authority.length - ':$port'.length);
    }
  }
  return '$scheme://$authority';
}

String? _normalizeOrigin(String value) {
  final Uri? parsed = Uri.tryParse(value.trim());
  if (parsed == null) return null;
  final String scheme = parsed.scheme.toLowerCase();
  if (scheme != 'https' && scheme != 'http') return null;
  final String origin = _originOf(parsed);
  return origin.isEmpty ? null : origin;
}

bool _originAllowed(
  String origin,
  List<String> allowedOrigins, {
  bool allowEmpty = false,
}) {
  // An empty allowlist means "no extra origins"; callers that verify the widget
  // origin themselves may opt into [allowEmpty] (embed links do: the `server`
  // parameter equality check is the trust anchor there).
  if (allowedOrigins.isEmpty) {
    return allowEmpty;
  }
  for (final String entry in allowedOrigins) {
    if (_normalizeOrigin(entry) == origin) return true;
  }
  return false;
}

bool _isDevHost(String host) {
  final String value = host.toLowerCase().replaceAll('[', '').replaceAll(']', '');
  return value == 'localhost' ||
      value == '127.0.0.1' ||
      value == '::1' ||
      value == '10.0.2.2';
}

void _assertSecure(Uri uri, bool allowInsecure, String field) {
  final String scheme = uri.scheme.toLowerCase();
  if (scheme == 'https') return;
  if (allowInsecure || _isDevHost(uri.host)) return;
  throw AgilConfigException(
    '$field must use https (pass allowInsecure: true only for local development)',
    field: field,
  );
}

String _assertRoomId(String value) {
  final String room = value.trim();
  if (room.isEmpty) {
    throw const AgilConfigException('roomId is required', field: 'roomId');
  }
  if (room.length > _maxRoomLength) {
    throw const AgilConfigException('roomId is too long', field: 'roomId');
  }
  if (_controlChars.hasMatch(room)) {
    throw const AgilConfigException('roomId contains control characters', field: 'roomId');
  }
  return room;
}

String _assertToken(String value, String field) {
  if (value.isEmpty) {
    throw AgilConfigException('$field must not be empty', field: field);
  }
  if (value.length > _maxTokenLength) {
    throw AgilConfigException('$field is too long', field: field);
  }
  if (_controlChars.hasMatch(value) || RegExp(r'\s').hasMatch(value)) {
    throw AgilConfigException(
      '$field must not contain whitespace or control characters',
      field: field,
    );
  }
  return value;
}

String? _optionalToken(String? value, String field) =>
    value == null ? null : _assertToken(value, field);

String? _optionalName(String? value, String field, int maxLength) {
  if (value == null) return null;
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  if (trimmed.length > maxLength) {
    throw AgilConfigException('$field is too long', field: field);
  }
  if (_controlChars.hasMatch(trimmed)) {
    throw AgilConfigException('$field contains control characters', field: field);
  }
  return trimmed;
}

String _assertTenant(String value) => _optionalName(value, 'tenantId', _maxTenantLength) ?? 'demo';

String _assertWidgetPath(String value) {
  final String raw = _optionalName(value, 'widgetPath', _maxPathLength) ?? defaultWidgetPath;
  if (raw.contains('\\')) {
    throw const AgilConfigException('widgetPath must use forward slashes', field: 'widgetPath');
  }
  if (raw.contains('?') || raw.contains('#')) {
    throw const AgilConfigException(
      'widgetPath must not contain a query string or fragment',
      field: 'widgetPath',
    );
  }
  if (raw.startsWith('//')) {
    throw const AgilConfigException('widgetPath must be a relative path', field: 'widgetPath');
  }
  if (_absoluteScheme.hasMatch(raw)) {
    throw const AgilConfigException('widgetPath must not be an absolute URL', field: 'widgetPath');
  }
  for (final String segment in raw.split('/')) {
    if (segment == '..' || segment == '.') {
      throw const AgilConfigException(
        'widgetPath must not contain "." or ".." segments',
        field: 'widgetPath',
      );
    }
  }
  return raw;
}

String _resolveWidgetPath(String basePath, String widgetPath) {
  if (widgetPath.startsWith('/')) return widgetPath;
  final String base = basePath.replaceFirst(_trailingSlashes, '');
  return '$base/$widgetPath';
}

String _serializeQuery(List<List<String>> pairs) {
  final StringBuffer buffer = StringBuffer();
  for (final List<String> pair in pairs) {
    if (buffer.isNotEmpty) buffer.write('&');
    buffer
      ..write(Uri.encodeQueryComponent(pair[0]))
      ..write('=')
      ..write(Uri.encodeQueryComponent(pair[1]));
  }
  return buffer.toString();
}

String? _firstParam(Map<String, List<String>> params, List<String> names) {
  for (final String name in names) {
    final List<String>? values = params[name];
    if (values != null && values.isNotEmpty) {
      final String value = values.first;
      if (value.trim().isNotEmpty) return value;
    }
  }
  return null;
}
