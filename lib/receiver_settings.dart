import 'dart:convert';
import 'dart:io';

import 'protocol.dart';

/// Remembers the receiver's port in %APPDATA%\MousePad\receiver.json.
class ReceiverSettings {
  ReceiverSettings._(this._file, this.port);

  final File? _file;
  int port;

  static Future<ReceiverSettings> load() async {
    final appData = Platform.environment['APPDATA'];
    final file =
        appData == null ? null : File('$appData\\MousePad\\receiver.json');
    var port = defaultPort;
    try {
      if (file != null && await file.exists()) {
        final json = jsonDecode(await file.readAsString());
        if (json is Map && json['port'] is int) port = json['port'] as int;
      }
    } on Exception {
      // Unreadable settings: fall back to the default port.
    }
    return ReceiverSettings._(file, port);
  }

  Future<void> save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({'port': port}));
    } on Exception {
      // Not worth bothering the user about; the port still works this session.
    }
  }
}
