import 'package:flutter_test/flutter_test.dart';
import 'package:mouse_pad_receiver/protocol.dart';

void main() {
  test('every command survives encode and parse', () {
    const commands = <PadCommand>[
      MoveCommand(-5, 12),
      ButtonCommand(PadButton.left, down: true),
      ButtonCommand(PadButton.middle, down: false),
      ClickCommand(PadButton.right),
      ScrollCommand(240, -60),
      ZoomCommand(-2),
      TextCommand('Hello, mundo ñ 👋'),
      KeyCommand(KeyStroke.key(PadKey.enter)),
      KeyCommand(KeyStroke.char(0x63, modifiers: {Modifier.ctrl})),
      KeyCommand(
          KeyStroke.key(PadKey.left, modifiers: {Modifier.win, Modifier.ctrl})),
      KeyCommand(KeyStroke.modifiersOnly({Modifier.win})),
    ];
    for (final command in commands) {
      expect(PadCommand.parse(command.encode())?.encode(), command.encode());
    }
  });

  test('the wire format is easy to read', () {
    expect(const MoveCommand(3, -4).encode(), 'm 3 -4');
    expect(const ClickCommand(PadButton.left).encode(), 'c l');
    expect(const KeyCommand(KeyStroke.key(PadKey.enter)).encode(), 'k - enter');
    expect(
        const KeyCommand(KeyStroke.char(0x63, modifiers: {Modifier.ctrl}))
            .encode(),
        'k c u+63');
    expect(const KeyCommand(KeyStroke.modifiersOnly({Modifier.win})).encode(),
        'k w none');
  });

  test('text keeps its spaces but not line breaks', () {
    final parsed = PadCommand.parse(const TextCommand(' a  b\nc').encode());
    expect((parsed! as TextCommand).text, ' a  b c');
  });

  test('malformed lines are ignored', () {
    for (final line in [
      '', 'x', 'm 1', 'm a b', 'mm 1 2', 'm 1 2 3', 'd q', 'c', 't', 'z 0',
      'z x', 'k', 'k c', 'k q enter', 'k - nope', 'k - u+zz', 'k - none', //
    ]) {
      expect(PadCommand.parse(line), isNull, reason: '"$line"');
    }
  });

  test('huge values are clamped', () {
    final move = PadCommand.parse('m 999999 -999999')! as MoveCommand;
    expect((move.dx, move.dy), (maxMove, -maxMove));
    final zoom = PadCommand.parse('z 1000')! as ZoomCommand;
    expect(zoom.steps, maxZoom);
  });

  test('hello line carries the PC name', () {
    expect(parseHello(helloLine('DESKTOP 7')), 'DESKTOP 7');
    expect(parseHello('HELLO 1 PC'), isNull);
  });
}
