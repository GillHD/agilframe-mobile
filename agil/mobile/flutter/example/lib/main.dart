// Example app for the `agil_calls` Flutter SDK.
//
// Run the AgilFrame server locally and start this app:
//   cd packages/flutter/example
//   flutter pub get
//   flutter run
//
// The default server URL points at a local dev server. In production always
// use HTTPS and mint short-lived join tokens on your backend
// (`POST /v1/rooms/:roomId/join`); never ship an admin API key in the app.
import 'dart:async';

import 'package:agil_calls/agil_calls.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  runApp(const AgilCallsExampleApp());
}

ThemeData _shellTheme(Brightness brightness) =>
    ThemeData(colorSchemeSeed: const Color(0xFF0B5FFF), brightness: brightness);

SystemUiOverlayStyle _systemBars(Brightness brightness, Color surface) {
  final Brightness icons = brightness == Brightness.dark ? Brightness.light : Brightness.dark;
  return SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarBrightness: brightness,
    statusBarIconBrightness: icons,
    systemNavigationBarColor: surface,
    systemNavigationBarDividerColor: surface,
    systemNavigationBarIconBrightness: icons,
    systemNavigationBarContrastEnforced: false,
  );
}

enum _CallCommand { microphone, camera, chat, theme }

class AgilCallsExampleApp extends StatelessWidget {
  const AgilCallsExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AgilFrame — Flutter',
      debugShowCheckedModeBanner: false,
      theme: _shellTheme(Brightness.light),
      darkTheme: _shellTheme(Brightness.dark),
      home: const CallScreen(),
    );
  }
}

class CallScreen extends StatefulWidget {
  const CallScreen({super.key});

  @override
  State<CallScreen> createState() => _CallScreenState();
}

class _CallScreenState extends State<CallScreen> {
  final TextEditingController _server = TextEditingController(text: 'http://localhost:8787');
  final TextEditingController _room = TextEditingController(text: 'demo');
  final TextEditingController _token = TextEditingController();
  final TextEditingController _name = TextEditingController(text: 'Flutter');
  final AgilCallController _call = AgilCallController();
  final List<String> _log = <String>[];

  bool _inCall = false;
  bool? _dark;
  bool _joined = false;
  bool _requestingMedia = false;
  Completer<void>? _pendingLeave;
  AgilThemeScheme _initialCallTheme = AgilThemeScheme.auto;

  @override
  void dispose() {
    _server.dispose();
    _room.dispose();
    _token.dispose();
    _name.dispose();
    super.dispose();
  }

  void _append(String line) {
    if (!mounted) return;
    final String time = DateTime.now().toIso8601String().substring(11, 19);
    setState(() {
      _log.insert(0, '$time  $line');
      if (_log.length > 40) _log.removeRange(40, _log.length);
    });
  }

  void _handleEvent(AgilCallEvent event) {
    switch (event) {
      case AgilReadyEvent(capabilities: final capabilities):
        _append('ready media=${capabilities.media} blur=${capabilities.blur}');
      case AgilJoinedEvent():
        _joined = true;
        _append('joined');
      case AgilLeftEvent():
        _joined = false;
        final Completer<void>? pending = _pendingLeave;
        if (pending != null && !pending.isCompleted) pending.complete();
        _append('left');
      case AgilChatEvent(message: final message):
        _append('chat ${message.participantName ?? 'guest'}: ${message.text}');
      case AgilErrorEvent(error: final error):
        _append('widget error ${error.code.wire}: ${error.message}');
      case AgilStateEvent(state: final state):
        _append('state ${state.phase ?? '-'} peers=${state.participants ?? 0}');
      case AgilMinimizedEvent(minimized: final minimized):
        _append('minimized=$minimized');
      case AgilFullscreenEvent(fullscreen: final fullscreen):
        _append('fullscreen=$fullscreen');
      case AgilGenericEvent(name: final name):
        _append('event $name');
    }
  }

  void _handleError(AgilCallError error) {
    _append('error ${error.code.wire}${error.fatal ? ' (fatal)' : ''}: ${error.message}');
  }

  Future<void> _prepareAndroidMedia() async {
    setState(() => _requestingMedia = true);
    final bool granted = await _call.requestAndroidMediaPermissions();
    if (!mounted) return;
    setState(() => _requestingMedia = false);
    if (!granted) _append('Камера или микрофон недоступны. Можно войти в режиме «Только слушать».');
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData baseTheme = Theme.of(context);
    final bool? darkOverride = _inCall ? _dark : null;
    final ThemeData theme = darkOverride == null
        ? baseTheme
        : _shellTheme(darkOverride ? Brightness.dark : Brightness.light);
    final SystemUiOverlayStyle bars = _systemBars(theme.brightness, theme.colorScheme.surface);
    final Widget content = Scaffold(
      backgroundColor: theme.colorScheme.surface,
      appBar: AppBar(
        systemOverlayStyle: bars,
        title: const Text('AgilFrame — Flutter example'),
        actions: <Widget>[
          if (_inCall)
            PopupMenuButton<_CallCommand>(
              tooltip: 'Управление звонком',
              onSelected: _runCallCommand,
              itemBuilder: (_) => const <PopupMenuEntry<_CallCommand>>[
                PopupMenuItem(value: _CallCommand.microphone, child: Text('Микрофон')),
                PopupMenuItem(value: _CallCommand.camera, child: Text('Камера')),
                PopupMenuItem(value: _CallCommand.chat, child: Text('Чат')),
                PopupMenuItem(value: _CallCommand.theme, child: Text('Сменить тему')),
              ],
            ),
          if (_inCall)
            IconButton(
              tooltip: 'Leave and close the WebView',
              onPressed: _pendingLeave == null ? _closeCall : null,
              icon: const Icon(Icons.close),
            ),
        ],
      ),
      body: _inCall ? _buildCall(theme.colorScheme.surface) : SafeArea(top: false, child: _buildForm()),
    );
    return Theme(
      data: theme,
      child: AnnotatedRegion<SystemUiOverlayStyle>(value: bars, child: content),
    );
  }

  Future<void> _closeCall() async {
    if (_joined) {
      final Completer<void> pending = Completer<void>();
      setState(() => _pendingLeave = pending);
      _call.leave();
      await pending.future.timeout(const Duration(seconds: 4), onTimeout: () {});
    }
    if (!mounted) return;
    setState(() {
      _joined = false;
      _pendingLeave = null;
      _inCall = false;
    });
  }

  Widget _buildCall(Color surface) {
    return AgilCall(
      serverUrl: _server.text.trim(),
      roomId: _room.text.trim(),
      joinToken: _token.text.trim().isEmpty ? null : _token.text.trim(),
      participantName: _name.text.trim().isEmpty ? null : _name.text.trim(),
      theme: _initialCallTheme,
      backgroundColor: surface,
      language: AgilLanguage.ru,
      controller: _call,
      safeArea: true,
      onEvent: _handleEvent,
      onError: _handleError,
      onExternalLink: (String url) => _append('blocked external link: $url'),
    );
  }

  void _runCallCommand(_CallCommand command) {
    switch (command) {
      case _CallCommand.microphone:
        _call.toggleMute();
      case _CallCommand.camera:
        _call.toggleCamera();
      case _CallCommand.chat:
        _call.toggleChat();
      case _CallCommand.theme:
        final bool nextDark = !(_dark ?? (Theme.of(context).brightness == Brightness.dark));
        setState(() => _dark = nextDark);
        _call.setTheme(nextDark ? AgilThemeScheme.dark : AgilThemeScheme.light);
    }
  }

  Widget _buildForm() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        const Text(
          'Hosted WebView: медиа, чат и темы выполняет виджет на сервере AgilFrame. '
          'Токен выпускайте на своём backend и не логируйте.',
          style: TextStyle(fontSize: 14),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _server,
          decoration: const InputDecoration(
            labelText: 'serverUrl',
            helperText: 'HTTPS; http разрешён только для localhost/10.0.2.2',
            border: OutlineInputBorder(),
          ),
          keyboardType: TextInputType.url,
          autocorrect: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _room,
          decoration: const InputDecoration(labelText: 'roomId', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _token,
          decoration: const InputDecoration(
            labelText: 'joinToken (необязательно)',
            helperText: 'Без токена виджет покажет свой экран входа',
            border: OutlineInputBorder(),
          ),
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'participantName', border: OutlineInputBorder()),
        ),
        const SizedBox(height: 16),
        if (defaultTargetPlatform == TargetPlatform.android && !kIsWeb)
          OutlinedButton.icon(
            icon: const Icon(Icons.mic),
            label: const Text('Разрешить камеру и микрофон'),
            onPressed: _requestingMedia ? null : _prepareAndroidMedia,
          ),
        FilledButton.icon(
          icon: const Icon(Icons.video_call),
          label: const Text('Открыть звонок'),
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(52),
            textStyle: const TextStyle(fontSize: 16),
          ),
          onPressed: _requestingMedia ? null : () {
            FocusScope.of(context).unfocus();
            if (_server.text.trim().isEmpty || _room.text.trim().isEmpty) {
              _append('serverUrl и roomId обязательны');
              return;
            }
            setState(() {
              final bool? dark = _dark;
              _initialCallTheme = dark == null
                  ? AgilThemeScheme.auto
                  : dark ? AgilThemeScheme.dark : AgilThemeScheme.light;
              _inCall = true;
            });
          },
        ),
        const SizedBox(height: 24),
        Row(
          children: <Widget>[
            const Text('События', style: TextStyle(fontWeight: FontWeight.w600)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(_log.clear),
              child: const Text('Очистить'),
            ),
          ],
        ),
        if (_log.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text('Пока пусто', style: TextStyle(color: Color(0xFF64748B))),
          )
        else
          for (final String line in _log)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                line,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
      ],
    );
  }
}
