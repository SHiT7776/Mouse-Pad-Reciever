/// The small text protocol the phone uses to drive the PC receiver over USB.
///
/// One command per line, UTF-8, so it is easy to read in a debugger:
///
///     PC -> phone, once right after connecting:
///       MOUSEPAD 1 <pc name>
///     PC -> phone, whenever it changes:
///       kbd 1 / kbd 0     a text box on the PC got / lost keyboard focus
///     phone -> PC:
///       m <dx> <dy>       move the pointer by dx, dy screen pixels
///       d <b> / u <b>     press / release mouse button b (l, r or m)
///       c <b>             click mouse button b
///       s <v> <h>         scroll: 120 = one wheel notch, +v = up, +h = right
///       z <steps>         pinch zoom (Ctrl + wheel), + = zoom in
///       t <text>          type text (everything up to the end of the line)
///       k <mods> <key>    press a key, e.g. "k - enter", "k c u+63" (Ctrl+C)
library;

/// TCP port used on both ends of the `adb reverse` tunnel.
const int defaultPort = 47474;

const String helloWord = 'MOUSEPAD';
const int protocolVersion = 1;

/// Largest pointer jump / scroll / zoom step accepted in a single command.
const int maxMove = 10000;
const int maxScroll = 12000;
const int maxZoom = 50;

enum PadButton {
  left('l'),
  right('r'),
  middle('m');

  const PadButton(this.wire);
  final String wire;

  static PadButton? fromWire(String s) {
    for (final b in values) {
      if (b.wire == s) return b;
    }
    return null;
  }
}

enum Modifier {
  ctrl('c'),
  shift('s'),
  alt('a'),
  win('w');

  const Modifier(this.wire);
  final String wire;
}

enum PadKey {
  enter('enter'),
  backspace('backspace'),
  tab('tab'),
  escape('esc'),
  delete('delete'),
  insert('insert'),
  left('left'),
  right('right'),
  up('up'),
  down('down'),
  home('home'),
  end('end'),
  pageUp('pgup'),
  pageDown('pgdn'),
  space('space'),
  f1('f1'),
  f2('f2'),
  f3('f3'),
  f4('f4'),
  f5('f5'),
  f6('f6'),
  f7('f7'),
  f8('f8'),
  f9('f9'),
  f10('f10'),
  f11('f11'),
  f12('f12');

  const PadKey(this.wire);
  final String wire;

  static PadKey? fromWire(String s) {
    for (final k in values) {
      if (k.wire == s) return k;
    }
    return null;
  }
}

/// One key press: a named key, a character, or just modifiers (e.g. Win alone
/// opens the Start menu). Modifiers are held around the key.
class KeyStroke {
  const KeyStroke.key(PadKey this.key, {this.modifiers = const {}})
      : codePoint = null;
  const KeyStroke.char(int this.codePoint, {this.modifiers = const {}})
      : key = null;
  const KeyStroke.modifiersOnly(this.modifiers)
      : key = null,
        codePoint = null;

  final PadKey? key;
  final int? codePoint;
  final Set<Modifier> modifiers;

  @override
  String toString() => KeyCommand(this).encode();
}

sealed class PadCommand {
  const PadCommand();

  String encode();

  /// Parses one line; returns null for anything malformed.
  static PadCommand? parse(String line) {
    if (line.isEmpty || (line.length > 1 && line[1] != ' ')) return null;
    final rest = line.length > 2 ? line.substring(2) : '';
    switch (line[0]) {
      case 'm':
        final n = _ints(rest);
        if (n == null) return null;
        return MoveCommand(
            n.$1.clamp(-maxMove, maxMove), n.$2.clamp(-maxMove, maxMove));
      case 's':
        final n = _ints(rest);
        if (n == null) return null;
        return ScrollCommand(n.$1.clamp(-maxScroll, maxScroll),
            n.$2.clamp(-maxScroll, maxScroll));
      case 'z':
        final steps = int.tryParse(rest);
        return steps == null || steps == 0
            ? null
            : ZoomCommand(steps.clamp(-maxZoom, maxZoom));
      case 'd' || 'u':
        final b = PadButton.fromWire(rest);
        return b == null ? null : ButtonCommand(b, down: line[0] == 'd');
      case 'c':
        final b = PadButton.fromWire(rest);
        return b == null ? null : ClickCommand(b);
      case 't':
        return rest.isEmpty ? null : TextCommand(rest);
      case 'k':
        return _parseKey(rest);
    }
    return null;
  }

  static (int, int)? _ints(String s) {
    final parts = s.split(' ');
    if (parts.length != 2) return null;
    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    return a == null || b == null ? null : (a, b);
  }

  static KeyCommand? _parseKey(String s) {
    final parts = s.split(' ');
    if (parts.length != 2) return null;
    final modifiers = <Modifier>{};
    if (parts[0] != '-') {
      for (final ch in parts[0].split('')) {
        final m = Modifier.values.where((m) => m.wire == ch).firstOrNull;
        if (m == null) return null;
        modifiers.add(m);
      }
    }
    final token = parts[1];
    if (token == 'none') {
      return modifiers.isEmpty
          ? null
          : KeyCommand(KeyStroke.modifiersOnly(modifiers));
    }
    if (token.startsWith('u+')) {
      final cp = int.tryParse(token.substring(2), radix: 16);
      if (cp == null || cp <= 0 || cp > 0x10FFFF) return null;
      return KeyCommand(KeyStroke.char(cp, modifiers: modifiers));
    }
    final key = PadKey.fromWire(token);
    return key == null
        ? null
        : KeyCommand(KeyStroke.key(key, modifiers: modifiers));
  }
}

final class MoveCommand extends PadCommand {
  const MoveCommand(this.dx, this.dy);
  final int dx, dy;
  @override
  String encode() => 'm $dx $dy';
}

final class ButtonCommand extends PadCommand {
  const ButtonCommand(this.button, {required this.down});
  final PadButton button;
  final bool down;
  @override
  String encode() => '${down ? 'd' : 'u'} ${button.wire}';
}

final class ClickCommand extends PadCommand {
  const ClickCommand(this.button);
  final PadButton button;
  @override
  String encode() => 'c ${button.wire}';
}

final class ScrollCommand extends PadCommand {
  const ScrollCommand(this.vertical, this.horizontal);
  final int vertical, horizontal;
  @override
  String encode() => 's $vertical $horizontal';
}

final class ZoomCommand extends PadCommand {
  const ZoomCommand(this.steps);
  final int steps;
  @override
  String encode() => 'z $steps';
}

final class TextCommand extends PadCommand {
  const TextCommand(this.text);
  final String text;

  /// Line breaks would end the command early; the phone sends Enter as a key.
  @override
  String encode() => 't ${text.replaceAll(RegExp('[\r\n]'), ' ')}';
}

final class KeyCommand extends PadCommand {
  const KeyCommand(this.stroke);
  final KeyStroke stroke;

  @override
  String encode() {
    final mods = Modifier.values
        .where(stroke.modifiers.contains)
        .map((m) => m.wire)
        .join();
    final key = stroke.key;
    final cp = stroke.codePoint;
    final token = key != null
        ? key.wire
        : cp != null
            ? 'u+${cp.toRadixString(16)}'
            : 'none';
    return 'k ${mods.isEmpty ? '-' : mods} $token';
  }
}

String helloLine(String pcName) => '$helloWord $protocolVersion $pcName';

String keyboardHintLine({required bool textFocused}) =>
    'kbd ${textFocused ? 1 : 0}';

/// Whether a text box on the PC has focus, or null if [line] isn't a hint.
bool? parseKeyboardHint(String line) => switch (line) {
      'kbd 1' => true,
      'kbd 0' => false,
      _ => null,
    };

/// Returns the PC name from a hello line, or null if [line] isn't one.
String? parseHello(String line) {
  final parts = line.split(' ');
  if (parts.length < 2 || parts[0] != helloWord) return null;
  return parts.length > 2 ? parts.sublist(2).join(' ') : 'PC';
}
