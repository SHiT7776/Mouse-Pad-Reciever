import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'protocol.dart';
import 'win_input.dart';

/// Accepts the phone's connection (arriving through the `adb reverse` tunnel)
/// and turns its commands into real mouse and keyboard input.
///
/// Listens on loopback only: nothing on the network can reach it, only the
/// USB tunnel and programs on this PC.
class ReceiverServer extends ChangeNotifier {
  ReceiverServer(this._input, {String? pcName, this.textFocus})
      : _pcName = pcName ?? Platform.localHostname;

  final InputSink _input;
  final String _pcName;

  /// Tells whether a text box has keyboard focus, so the phone keyboard can
  /// pop up by itself. Checked shortly after the phone clicks or presses keys.
  final Future<bool> Function()? textFocus;

  ServerSocket? _server;
  final List<_Phone> _phones = [];
  Timer? _activityTimer;
  Timer? _focusSoon, _focusLater;
  bool? _textFocused;
  bool _disposed = false;

  int? port;
  String? error;

  /// Last time a command arrived, for the "receiving input" indicator.
  DateTime? lastInputAt;

  int get phoneCount => _phones.length;
  bool get listening => _server != null;

  /// The port actually bound (differs from [port] when started with 0).
  int? get boundPort => _server?.port;

  Future<void> start(int port) async {
    await stop();
    this.port = port;
    try {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      _server = server;
      error = null;
      server.listen(_accept, onError: (Object _) {});
    } on SocketException {
      error = 'Port $port is already in use. Is another Mouse Pad Receiver '
          'open?';
    }
    _notify();
  }

  Future<void> stop() async {
    final server = _server;
    _server = null;
    for (final phone in [..._phones]) {
      _drop(phone);
    }
    await server?.close();
  }

  @override
  void dispose() {
    _disposed = true;
    _activityTimer?.cancel();
    _focusSoon?.cancel();
    _focusLater?.cancel();
    unawaited(stop());
    super.dispose();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void _accept(Socket socket) {
    socket.setOption(SocketOption.tcpNoDelay, true);
    // Write errors also surface here; without a handler they'd crash the app.
    unawaited(socket.done.catchError((Object _) {}));
    final phone = _Phone(socket);
    _phones.add(phone);
    _textFocused = null; // tell the new phone on the next check
    socket.add(utf8.encode('${helloLine(_pcName)}\n'));
    phone.subscription = const Utf8Decoder(allowMalformed: true)
        .bind(socket)
        .transform(const LineSplitter())
        .listen(
          (line) => _handle(phone, line),
          onDone: () => _drop(phone),
          onError: (Object _) => _drop(phone),
          cancelOnError: true,
        );
    _notify();
  }

  void _handle(_Phone phone, String line) {
    final command = PadCommand.parse(line);
    if (command == null) return;
    switch (command) {
      case MoveCommand(:final dx, :final dy):
        _input.moveBy(dx, dy);
      case ButtonCommand(:final button, :final down):
        down ? phone.held.add(button) : phone.held.remove(button);
        _input.button(button, down: down);
        if (!down) _watchFocus();
      case ClickCommand(:final button):
        _input.click(button);
        _watchFocus();
      case ScrollCommand(:final vertical, :final horizontal):
        _input.scroll(vertical, horizontal);
      case ZoomCommand(:final steps):
        _input.zoom(steps);
      case TextCommand(:final text):
        _input.typeText(text);
      case KeyCommand(:final stroke):
        _input.keyStroke(stroke);
        _watchFocus(); // Tab, Enter, Win... can move the focus too
    }
    lastInputAt = DateTime.now();
    // Moves arrive ~100 times a second; refresh the UI a few times a second.
    _activityTimer ??= Timer(const Duration(milliseconds: 250), () {
      _activityTimer = null;
      _notify();
    });
  }

  void _watchFocus() {
    if (textFocus == null) return;
    // Apps take a moment to move the focus after a click, so look twice.
    _focusSoon?.cancel();
    _focusLater?.cancel();
    _focusSoon = Timer(const Duration(milliseconds: 250), _checkFocus);
    _focusLater = Timer(const Duration(milliseconds: 900), _checkFocus);
  }

  Future<void> _checkFocus() async {
    final probe = textFocus;
    if (probe == null || _phones.isEmpty) return;
    final bool focused;
    try {
      focused = await probe();
    } on Object {
      return;
    }
    if (_disposed || focused == _textFocused) return;
    _textFocused = focused;
    final line = utf8.encode('${keyboardHintLine(textFocused: focused)}\n');
    for (final phone in _phones) {
      try {
        phone.socket.add(line);
      } on Object {
        // That phone is going away; _drop() handles it.
      }
    }
  }

  void _drop(_Phone phone) {
    if (!_phones.remove(phone)) return;
    // Never leave a button stuck down if the cable is pulled mid-drag.
    for (final button in phone.held) {
      _input.button(button, down: false);
    }
    phone.held.clear();
    unawaited(phone.subscription?.cancel());
    phone.socket.destroy();
    _notify();
  }
}

class _Phone {
  _Phone(this.socket);
  final Socket socket;
  final Set<PadButton> held = {};
  StreamSubscription<String>? subscription;
}
