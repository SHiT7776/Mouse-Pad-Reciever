import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

enum AdbState { searching, missing, starting, ready }

class AdbDevice {
  AdbDevice({required this.serial, required this.state, this.model});

  final String serial;

  /// adb's state word: "device" when usable, or "unauthorized", "offline"...
  final String state;
  final String? model;

  /// True once `adb reverse` is in place, i.e. the phone can reach this PC.
  bool linked = false;
  String? problem;

  String get name => model ?? serial;
}

class AdbException implements Exception {
  AdbException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Keeps `adb reverse tcp:PORT tcp:PORT` in place for every phone plugged in
/// over USB, so the phone app can reach this PC at 127.0.0.1:PORT through the
/// cable.
///
/// Talks to the adb server's socket protocol (localhost:5037) directly instead
/// of running adb.exe for every check, which would flash console windows. The
/// server pushes device changes, so a phone is linked as soon as it's plugged
/// in.
class AdbBridge extends ChangeNotifier {
  AdbBridge({required this._port, this.serverPort = 5037});

  /// Where the adb server listens (5037 unless a test fakes it).
  final int serverPort;

  int _port;
  AdbState state = AdbState.searching;
  String? adbPath;
  List<AdbDevice> devices = const [];

  bool _started = false;
  bool _disposed = false;
  final Set<String> _linking = {};
  Timer? _retry;

  int get port => _port;
  set port(int value) {
    if (value == _port) return;
    _port = value;
    for (final d in devices) {
      d.linked = false;
    }
    _linkAll();
  }

  void start() {
    if (_started) return;
    _started = true;
    unawaited(_trackLoop());
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    super.dispose();
  }

  Future<void> _trackLoop() async {
    while (!_disposed) {
      final _AdbConnection connection;
      try {
        connection = await _AdbConnection.open(serverPort);
      } on SocketException {
        // No adb server yet: start one, then try again.
        await _startServer();
        continue;
      }
      try {
        await connection.request('host:track-devices-l');
        _setState(AdbState.ready);
        while (!_disposed) {
          _onDevices(parseDevices(await connection.readString()));
        }
      } catch (_) {
        // The adb server went away (restarted, or another tool killed it).
      } finally {
        connection.close();
      }
      devices = const [];
      _notify();
      await _sleep(const Duration(seconds: 1));
    }
  }

  Future<void> _startServer() async {
    adbPath ??= await findAdb();
    final adb = adbPath;
    if (adb == null) {
      _setState(AdbState.missing);
      await _sleep(const Duration(seconds: 3));
      return;
    }
    _setState(AdbState.starting);
    try {
      // Detached: no console window, and the server outlives this app as usual.
      await Process.start(adb, ['start-server'],
          mode: ProcessStartMode.detached);
    } on ProcessException {
      adbPath = null;
      return;
    }
    for (var i = 0; i < 30 && !_disposed; i++) {
      await _sleep(const Duration(milliseconds: 500));
      try {
        (await _AdbConnection.open(serverPort)).close();
        return;
      } on SocketException {
        // not up yet
      }
    }
  }

  void _onDevices(List<AdbDevice> fresh) {
    final previous = {for (final d in devices) d.serial: d};
    for (final d in fresh) {
      final old = previous[d.serial];
      if (old != null && old.state == d.state) {
        d.linked = old.linked;
        d.problem = old.problem;
      }
    }
    devices = fresh;
    _notify();
    _linkAll();
  }

  void _linkAll() {
    for (final d in devices) {
      if (d.state == 'device' && !d.linked && !_linking.contains(d.serial)) {
        unawaited(_link(d.serial));
      }
    }
  }

  Future<void> _link(String serial) async {
    _linking.add(serial);
    final port = _port;
    String? problem;
    try {
      await reverse(serial, port);
    } catch (e) {
      problem = '$e';
    }
    _linking.remove(serial);
    if (_disposed) return;
    for (final d in devices) {
      if (d.serial != serial || d.state != 'device') continue;
      d.linked = problem == null && port == _port;
      d.problem = problem;
    }
    if (problem != null || port != _port) {
      // The phone may still be settling in; try again shortly.
      _retry ??= Timer(const Duration(seconds: 2), () {
        _retry = null;
        _linkAll();
      });
    }
    _notify();
  }

  /// Same as `adb -s <serial> reverse tcp:<port> tcp:<port>`.
  Future<void> reverse(String serial, int port) async {
    final connection = await _AdbConnection.open(serverPort);
    try {
      await connection.request('host:transport:$serial');
      await connection.request('reverse:forward:tcp:$port;tcp:$port');
      await connection.expectOkay(); // the phone's answer
    } finally {
      connection.close();
    }
  }

  /// Parses `adb devices -l` style output.
  static List<AdbDevice> parseDevices(String text) {
    final result = <AdbDevice>[];
    for (final line in const LineSplitter().convert(text)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      String? model;
      for (final part in parts.skip(2)) {
        if (part.startsWith('model:')) {
          model = part.substring(6).replaceAll('_', ' ');
        }
      }
      result.add(AdbDevice(serial: parts[0], state: parts[1], model: model));
    }
    return result;
  }

  /// Looks for adb.exe where Android Studio, the SDK installers and people
  /// usually put it.
  static Future<String?> findAdb() async {
    final env = Platform.environment;
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final candidates = [
      for (final key in ['ANDROID_HOME', 'ANDROID_SDK_ROOT'])
        if (env[key] != null) '${env[key]}\\platform-tools\\adb.exe',
      if (env['LOCALAPPDATA'] != null)
        '${env['LOCALAPPDATA']}\\Android\\Sdk\\platform-tools\\adb.exe',
      '$exeDir\\platform-tools\\adb.exe',
      '$exeDir\\adb.exe',
      for (final dir in (env['PATH'] ?? '').split(';'))
        if (dir.trim().isNotEmpty) '${dir.trim()}\\adb.exe',
    ];
    for (final path in candidates) {
      if (await File(path).exists()) return path;
    }
    return null;
  }

  void _setState(AdbState value) {
    if (state == value) return;
    state = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _sleep(Duration d) => Future<void>.delayed(d);
}

/// One request/response conversation with the adb server.
class _AdbConnection {
  _AdbConnection._(this._socket) {
    _subscription = _socket.listen(
      (data) {
        _buffer.addAll(data);
        _wake();
      },
      onDone: _closed,
      onError: (Object _) => _closed(),
      cancelOnError: true,
    );
  }

  static Future<_AdbConnection> open(int port) async => _AdbConnection._(
        await Socket.connect(InternetAddress.loopbackIPv4, port,
            timeout: const Duration(seconds: 2)),
      );

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<int> _buffer = [];
  Completer<void>? _waiter;
  bool _done = false;

  void _closed() {
    _done = true;
    _wake();
  }

  void _wake() {
    final waiter = _waiter;
    _waiter = null;
    waiter?.complete();
  }

  Future<List<int>> _read(int count) async {
    while (_buffer.length < count) {
      if (_done) throw AdbException('adb closed the connection');
      await (_waiter = Completer<void>()).future;
    }
    final bytes = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return bytes;
  }

  /// Sends a length-prefixed service request and waits for OKAY.
  Future<void> request(String service) async {
    final body = utf8.encode(service);
    _socket
      ..add(ascii.encode(body.length.toRadixString(16).padLeft(4, '0')))
      ..add(body);
    await _socket.flush();
    await expectOkay();
  }

  Future<void> expectOkay() async {
    final status = ascii.decode(await _read(4), allowInvalid: true);
    if (status == 'OKAY') return;
    if (status == 'FAIL') throw AdbException(await readString());
    throw AdbException('unexpected reply from adb: $status');
  }

  Future<String> readString() async {
    final length = int.tryParse(
        ascii.decode(await _read(4), allowInvalid: true),
        radix: 16);
    if (length == null) throw AdbException('bad length from adb');
    return utf8.decode(await _read(length), allowMalformed: true);
  }

  void close() {
    unawaited(_subscription.cancel());
    _socket.destroy();
  }
}
