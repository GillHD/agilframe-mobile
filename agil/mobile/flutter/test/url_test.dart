import 'package:flutter_test/flutter_test.dart';

import 'package:agil_calls/src/types.dart';
import 'package:agil_calls/src/url.dart';

void main() {
  group('normalizeServerUrl', () {
    test('normalizes scheme/host, trailing slash and default port', () {
      expect(normalizeServerUrl('  HTTPS://Calls.Example.com/  '), 'https://calls.example.com');
      expect(normalizeServerUrl('https://calls.example.com:443/calls/'), 'https://calls.example.com/calls');
      expect(normalizeServerUrl('http://localhost:8787/'), 'http://localhost:8787');
      expect(normalizeServerUrl('https://host:8443/calls'), 'https://host:8443/calls');
    });

    test('rejects unsafe or malformed server URLs', () {
      expect(() => normalizeServerUrl(''), throwsA(isA<AgilConfigException>()));
      expect(() => normalizeServerUrl('   '), throwsA(isA<AgilConfigException>()));
      expect(() => normalizeServerUrl('calls.example.com'), throwsA(isA<AgilConfigException>()));
      expect(() => normalizeServerUrl('javascript:alert(1)'), throwsA(isA<AgilConfigException>()));
      expect(() => normalizeServerUrl('file:///etc/passwd'), throwsA(isA<AgilConfigException>()));
      expect(
        () => normalizeServerUrl('https://user:pass@calls.example.com'),
        throwsA(isA<AgilConfigException>()),
      );
      expect(
        () => normalizeServerUrl('https://calls.example.com?token=leak'),
        throwsA(isA<AgilConfigException>()),
      );
      expect(
        () => normalizeServerUrl('https://calls.example.com#frag'),
        throwsA(isA<AgilConfigException>()),
      );
      expect(
        () => normalizeServerUrl('https://calls.example.com/\u0000'),
        throwsA(isA<AgilConfigException>()),
      );
    });
  });

  group('buildWidgetUrl', () {
    test('builds the documented /embed.html URL', () {
      final String url = buildWidgetUrl(
        const AgilCallUrlOptions(
          serverUrl: 'https://calls.example.com',
          roomId: 'daily-sync',
          joinToken: 'join-token',
          tenantId: 'acme',
          participantName: 'Анна',
          language: AgilLanguage.ru,
          theme: AgilThemeScheme.dark,
          role: AgilRole.guest,
          relayOnly: true,
        ),
      );
      expect(url, startsWith('https://calls.example.com/embed.html?'));
      expect(url, contains('server=https%3A%2F%2Fcalls.example.com'));
      expect(url, contains('room=daily-sync'));
      expect(url, contains('token=join-token'));
      expect(url, contains('tenant=acme'));
      expect(url, contains('lang=ru'));
      expect(url, contains('theme=dark'));
      expect(url, contains('role=guest'));
      expect(url, contains('relay=1'));
      expect(url, isNot(contains('name=Анна')));
      expect(Uri.parse(url).queryParameters['name'], 'Анна');
    });

    test('preserves a subpath deployment', () {
      final String url = buildWidgetUrl(
        const AgilCallUrlOptions(serverUrl: 'https://host/calls', roomId: 'r'),
      );
      expect(url, startsWith('https://host/calls/embed.html?'));
    });

    test('supports an origin-root-relative widgetPath', () {
      final String url = buildWidgetUrl(
        const AgilCallUrlOptions(
          serverUrl: 'https://host/calls',
          roomId: 'r',
          widgetPath: '/embed.html',
        ),
      );
      expect(url, startsWith('https://host/embed.html?'));
    });

    test('defaults tenant to demo and omits optional params', () {
      final Uri uri = Uri.parse(
        buildWidgetUrl(const AgilCallUrlOptions(serverUrl: 'https://host', roomId: 'r')),
      );
      expect(uri.queryParameters['tenant'], 'demo');
      expect(uri.queryParameters.containsKey('token'), isFalse);
      expect(uri.queryParameters.containsKey('name'), isFalse);
      expect(uri.queryParameters.containsKey('theme'), isFalse);
      expect(uri.queryParameters.containsKey('relay'), isFalse);
    });

    test('rejects widgetPath traversal and absolute URLs', () {
      for (final String path in <String>['../embed.html', 'a/../embed.html', './embed.html', 'https://evil.example/x', '//evil.example/x', 'embed.html?x=1', r'calls\embed.html']) {
        expect(
          () => buildWidgetUrl(
            AgilCallUrlOptions(serverUrl: 'https://host', roomId: 'r', widgetPath: path),
          ),
          throwsA(isA<AgilConfigException>()),
          reason: path,
        );
      }
    });

    test('requires https outside dev hosts', () {
      expect(
        () => buildWidgetUrl(
          const AgilCallUrlOptions(serverUrl: 'http://calls.example.com', roomId: 'r'),
        ),
        throwsA(isA<AgilConfigException>()),
      );
      expect(
        buildWidgetUrl(const AgilCallUrlOptions(serverUrl: 'http://localhost:8787', roomId: 'r')),
        startsWith('http://localhost:8787/embed.html?'),
      );
      expect(
        buildWidgetUrl(const AgilCallUrlOptions(serverUrl: 'http://10.0.2.2:8787', roomId: 'r')),
        startsWith('http://10.0.2.2:8787/embed.html?'),
      );
      expect(
        buildWidgetUrl(
          const AgilCallUrlOptions(
            serverUrl: 'http://calls.example.com',
            roomId: 'r',
            allowInsecure: true,
          ),
        ),
        startsWith('http://calls.example.com/embed.html?'),
      );
    });

    test('validates room and token without leaking the token', () {
      expect(
        () => buildWidgetUrl(const AgilCallUrlOptions(serverUrl: 'https://host', roomId: '')),
        throwsA(isA<AgilConfigException>()),
      );
      try {
        buildWidgetUrl(
          const AgilCallUrlOptions(
            serverUrl: 'https://host',
            roomId: 'r',
            joinToken: 'secret token with spaces',
          ),
        );
        fail('expected AgilConfigException');
      } on AgilConfigException catch (error) {
        expect(error.message, isNot(contains('secret')));
        expect(error.field, 'joinToken');
      }
    });
  });

  group('parseAgilCallLink', () {
    test('round-trips a built embed URL', () {
      final String url = buildWidgetUrl(
        const AgilCallUrlOptions(
          serverUrl: 'https://host/calls',
          roomId: 'team sync',
          joinToken: 'token-1',
          tenantId: 'acme',
          participantName: 'Анна & Co',
          language: AgilLanguage.en,
          theme: AgilThemeScheme.light,
          role: AgilRole.host,
          identityToken: 'id-token',
          relayOnly: true,
        ),
      );
      final AgilCallLink? link = parseAgilCallLink(url);
      expect(link, isNotNull);
      expect(link!.kind, 'embed');
      expect(link.serverUrl, 'https://host/calls');
      expect(link.roomId, 'team sync');
      expect(link.joinToken, 'token-1');
      expect(link.tenantId, 'acme');
      expect(link.participantName, 'Анна & Co');
      expect(link.language, AgilLanguage.en);
      expect(link.theme, AgilThemeScheme.light);
      expect(link.role, AgilRole.host);
      expect(link.identityToken, 'id-token');
      expect(link.relayOnly, isTrue);
    });

    test('rejects a server parameter that points to another origin', () {
      const String evil =
          'https://calls.corp/embed.html?server=https%3A%2F%2Fevil.example&room=r&token=secret';
      expect(parseAgilCallLink(evil), isNull);
    });

    test('rejects non-embed paths, unsafe schemes and missing room', () {
      expect(parseAgilCallLink('https://host/other.html?room=r'), isNull);
      expect(parseAgilCallLink('javascript:alert(1)'), isNull);
      expect(parseAgilCallLink('file:///etc/passwd'), isNull);
      expect(parseAgilCallLink('https://host/embed.html'), isNull);
      expect(parseAgilCallLink('https://host/embed.html?room='), isNull);
      expect(parseAgilCallLink('https://host/embed.html?room=r&token=a%20b'), isNull);
    });

    test('honours the origin allowlist for http(s) links', () {
      final String url = buildWidgetUrl(
        const AgilCallUrlOptions(serverUrl: 'https://host', roomId: 'r'),
      );
      expect(parseAgilCallLink(url, allowedOrigins: <String>['https://host']), isNotNull);
      expect(parseAgilCallLink(url, allowedOrigins: <String>['https://other']), isNull);
    });

    test('parses custom-scheme deep links only with trusted origins', () {
      const String link = 'agilcalls://call?server=https%3A%2F%2Fhost&room=r&token=t&tenant=acme';
      expect(parseAgilCallLink(link), isNull);
      final AgilCallLink? parsed =
          parseAgilCallLink(link, allowedOrigins: <String>['https://host']);
      expect(parsed, isNotNull);
      expect(parsed!.kind, 'deep-link');
      expect(parsed.serverUrl, 'https://host');
      expect(parsed.roomId, 'r');
      expect(parsed.joinToken, 't');
      expect(parseAgilCallLink(link, allowedOrigins: <String>['https://evil.example']), isNull);
      expect(
        parseAgilCallLink(
          'agilcalls://call?server=https%3A%2F%2Fhost&room=r',
          allowedOrigins: <String>['https://host'],
          allowedSchemes: <String>['myapp'],
        ),
        isNull,
      );
    });

    test('rejects http links for public hosts', () {
      expect(parseAgilCallLink('http://calls.example.com/embed.html?room=r'), isNull);
      expect(parseAgilCallLink('http://localhost:8787/embed.html?room=r'), isNotNull);
    });
  });

  group('navigation and redaction', () {
    test('isAllowedNavigation allows the widget origin and extra origins', () {
      expect(
        isAllowedNavigation('https://host/calls/embed.html?room=r', serverUrl: 'https://host/calls'),
        isTrue,
      );
      expect(
        isAllowedNavigation('https://host/other', serverUrl: 'https://host', allowedOrigins: <String>['https://host']),
        isTrue,
      );
      expect(
        isAllowedNavigation('https://idp.example/login', serverUrl: 'https://host', allowedOrigins: <String>['https://idp.example']),
        isTrue,
      );
      expect(isAllowedNavigation('https://evil.example/', serverUrl: 'https://host'), isFalse);
      expect(isAllowedNavigation('javascript:alert(1)', serverUrl: 'https://host'), isFalse);
      expect(isAllowedNavigation('file:///etc/passwd', serverUrl: 'https://host'), isFalse);
      expect(isAllowedNavigation('intent://scan', serverUrl: 'https://host'), isFalse);
      expect(isAllowedNavigation('about:blank', serverUrl: 'https://host'), isTrue);
      expect(isAllowedNavigation('', serverUrl: 'https://host'), isFalse);
    });

    test('redactCallUrl masks tokens but keeps the room', () {
      final String redacted = redactCallUrl(
        'https://host/embed.html?server=https%3A%2F%2Fhost&room=r&token=secret&identity_token=id&access_token=access',
      );
      expect(redacted, isNot(contains('secret')));
      expect(redacted, isNot(contains('id=')));
      expect(redacted, isNot(contains('access=')));
      expect(redacted, contains('room=r'));
      expect(redacted, contains('token=redacted'));
      expect(redacted, contains('identity_token=redacted'));
      expect(redacted, contains('access_token=redacted'));
    });

    test('redactSecrets masks current token values and access_token', () {
      final String redacted = redactSecrets(
        'failed token=SECRET-CALL URL https://host/cb?access_token=OTHER',
        <String>['SECRET-CALL', 'OTHER'],
      );
      expect(redacted, isNot(contains('SECRET-CALL')));
      expect(redacted, isNot(contains('OTHER')));
      expect(redacted, contains('[redacted]'));
    });

    test('redactTokenText masks JWT-looking strings and bare tokens', () {
      const String text =
          'failed for token=abc.def and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.signature123';
      final String redacted = redactTokenText(text);
      expect(redacted, isNot(contains('abc.def')));
      expect(redacted, isNot(contains('eyJhbGciOiJIUzI1NiJ9')));
      expect(redacted, contains('redacted'));
    });
  });
}
