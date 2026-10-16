import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mouse_pad_receiver/adb_bridge.dart';
import 'package:mouse_pad_receiver/protocol.dart';
import 'package:mouse_pad_receiver/receiver_server.dart';
import 'package:mouse_pad_receiver/win_input.dart';

class FakeInput implements InputSink {
  final log = <String>[];

  @override
  void moveBy(int dx, int dy) => log.add('move $dx $dy');
  @override
  void button(PadButton button, {required bool down}) =>
      log.add('${button.name} ${down ? 'down' : 'up'}');
  @override
  void click(PadButton button) => log.add('click ${button.name}');
  @override
  void scroll(int vertical, int horizontal) =>
      log.add('scroll $vertical $horizontal');
  @override
  void zoom(int steps) => log.add('zoom $steps');
  @override
  void typeText(String text) => log.add('type $text');
  @override
  void keyStroke(KeyStroke stroke) => log.add('key $stroke');
}

Future<void> eventually(bool Function() check,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final end = DateTime.now().add(timeout);
  while (!check()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  group('ReceiverServer', () {
    test('turns phone commands into input', () async {
      final input = FakeInput();
      final server = ReceiverServer(input, pcName: 'TEST-PC');
      addTearDown(server.dispose);
      await server.start(0);

      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort!);
      addTearDown(socket.destroy);
      final lines = StreamIterator(
          utf8.decoder.bind(socket).transform(const LineSplitter()));
      expect(await lines.moveNext(), isTrue);
      expect(lines.current, 'MOUSEPAD 1 TEST-PC');

      socket.write('m 5 -3\nc r\ns 120 0\nz 2\nt hi there\n'
          'k c u+63\nnonsense\nd l\n');
      await eventually(() => input.log.length == 7);
      expect(input.log, [
        'move 5 -3',
        'click right',
        'scroll 120 0',
        'zoom 2',
        'type hi there',
        'key k c u+63',
        'left down',
      ]);
      expect(server.phoneCount, 1);

      // Cable pulled mid-drag: the button must not stay stuck down.
      socket.destroy();
      await eventually(() => server.phoneCount == 0);
      expect(input.log.last, 'left up');
    });

    test('tells the phone when a click lands in a text box', () async {
      var textBox = true;
      final server = ReceiverServer(FakeInput(),
          pcName: 'TEST-PC', textFocus: () async => textBox);
      addTearDown(server.dispose);
      await server.start(0);

      final socket =
          await Socket.connect(InternetAddress.loopbackIPv4, server.boundPort!);
      addTearDown(socket.destroy);
      final lines = <String>[];
      utf8.decoder
          .bind(socket)
          .transform(const LineSplitter())
          .listen(lines.add);
      await eventually(() => lines.isNotEmpty); // hello

      socket.write('c l\n');
      await eventually(() => lines.contains('kbd 1'));

      textBox = false;
      socket.write('c l\n');
      await eventually(() => lines.contains('kbd 0'));
      expect(lines.where((l) => l.startsWith('kbd')), ['kbd 1', 'kbd 0'],
          reason: 'only changes are sent');
    });

    test('reports a busy port', () async {
      final squatter = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(squatter.close);
      final server = ReceiverServer(FakeInput());
      addTearDown(server.dispose);
      await server.start(squatter.port);
      expect(server.listening, isFalse);
      expect(server.error, contains('already in use'));
    });
  });

  group('AdbBridge', () {
    test('parses adb device lists', () {
      final devices = AdbBridge.parseDevices(
          'emulator-5554   device product:sdk_gphone64 model:sdk_gphone64_x86_64 '
          'device:emu64xa transport_id:1\n'
          'R58M12ABCDE     unauthorized usb:1-1 transport_id:2\n'
          '0123456789ABCD  device usb:1-2 product:panther model:Pixel_7 '
          'device:panther transport_id:3\n');
      expect(devices.map((d) => (d.serial, d.state, d.name)), [
        ('emulator-5554', 'device', 'sdk gphone64 x86 64'),
        ('R58M12ABCDE', 'unauthorized', 'R58M12ABCDE'),
        ('0123456789ABCD', 'device', 'Pixel 7'),
      ]);
      expect(AdbBridge.parseDevices(''), isEmpty);
    });

    test('links every ready phone with adb reverse', () async {
      // A fake adb server speaking the real wire format.
      final adb = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(adb.close);
      final requests = <String>[];
      String frame(String s) => '${s.length.toRadixString(16).padLeft(4, '0')}$s';
      adb.listen((s) {
        var buffer = '';
        var transport = false;
        s.listen((data) {
          buffer += latin1.decode(data);
          while (buffer.length >= 4) {
            final length = int.parse(buffer.substring(0, 4), radix: 16);
            if (buffer.length < 4 + length) return;
            final request = buffer.substring(4, 4 + length);
            buffer = buffer.substring(4 + length);
            requests.add(request);
            if (request == 'host:track-devices-l') {
              s.write('OKAY${frame('phone1\tunauthorized usb:1\n'
                  'phone2\tdevice usb:2 model:Pixel_8\n')}');
            } else if (request.startsWith('host:transport:')) {
              transport = true;
              s.write('OKAY');
            } else if (transport && request.startsWith('reverse:forward:')) {
              s.write('OKAYOKAY'); // stream opened, then the phone's answer
              unawaited(s.close());
            } else {
              s.write('FAIL${frame('unknown')}');
            }
          }
        });
      });

      final bridge = AdbBridge(port: 47474, serverPort: adb.port)..start();
      addTearDown(bridge.dispose);
      await eventually(() => bridge.devices.any((d) => d.linked));
      expect(bridge.state, AdbState.ready);
      expect(requests, [
        'host:track-devices-l',
        'host:transport:phone2',
        'reverse:forward:tcp:47474;tcp:47474',
      ]);
      final linked = bridge.devices.firstWhere((d) => d.serial == 'phone2');
      expect(linked.name, 'Pixel 8');
      expect(bridge.devices.firstWhere((d) => d.serial == 'phone1').linked,
          isFalse);
    });
  });
}
