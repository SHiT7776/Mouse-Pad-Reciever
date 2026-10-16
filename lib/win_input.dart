// Injects mouse and keyboard input on Windows through user32's SendInput.
import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

import 'protocol.dart';

/// What the receiver needs from the OS; a fake stands in for it in tests.
abstract interface class InputSink {
  void moveBy(int dx, int dy);
  void button(PadButton button, {required bool down});
  void click(PadButton button);
  void scroll(int vertical, int horizontal);
  void zoom(int steps);
  void typeText(String text);
  void keyStroke(KeyStroke stroke);
}

final class _Point extends Struct {
  @Int32()
  external int x;
  @Int32()
  external int y;
}

final class _MouseInput extends Struct {
  @Int32()
  external int dx;
  @Int32()
  external int dy;
  @Uint32()
  external int mouseData;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

final class _KeybdInput extends Struct {
  @Uint16()
  external int wVk;
  @Uint16()
  external int wScan;
  @Uint32()
  external int dwFlags;
  @Uint32()
  external int time;
  @IntPtr()
  external int dwExtraInfo;
}

final class _InputUnion extends Union {
  external _MouseInput mi;
  external _KeybdInput ki;
}

final class _Input extends Struct {
  @Uint32()
  external int type;
  external _InputUnion u;
}

const _inputMouse = 0;
const _inputKeyboard = 1;

const _mouseMove = 0x0001;
const _mouseLeftDown = 0x0002;
const _mouseLeftUp = 0x0004;
const _mouseRightDown = 0x0008;
const _mouseRightUp = 0x0010;
const _mouseMiddleDown = 0x0020;
const _mouseMiddleUp = 0x0040;
const _mouseWheel = 0x0800;
const _mouseHWheel = 0x1000;
const _mouseVirtualDesk = 0x4000;
const _mouseAbsolute = 0x8000;

const _keyExtended = 0x0001;
const _keyUp = 0x0002;
const _keyUnicode = 0x0004;

const _smXVirtualScreen = 76;
const _smYVirtualScreen = 77;
const _smCxVirtualScreen = 78;
const _smCyVirtualScreen = 79;

const _vkShift = 0x10;
const _vkControl = 0x11;
const _vkMenu = 0x12;
const _vkLWin = 0x5B;

/// Keys that need KEYEVENTF_EXTENDEDKEY, or Windows treats them as their
/// numpad twins (which breaks things like Shift+Arrow selection).
const _extendedVks = {
  0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, // PgUp..Down arrow
  0x2D, 0x2E, 0x5B, 0x5C, 0x5D, // Insert, Delete, Win, Apps
};

final _user32 = DynamicLibrary.open('user32.dll');
final _sendInput = _user32.lookupFunction<
    Uint32 Function(Uint32, Pointer<_Input>, Int32),
    int Function(int, Pointer<_Input>, int)>('SendInput');
final _getCursorPos = _user32.lookupFunction<Int32 Function(Pointer<_Point>),
    int Function(Pointer<_Point>)>('GetCursorPos');
final _getSystemMetrics = _user32
    .lookupFunction<Int32 Function(Int32), int Function(int)>('GetSystemMetrics');
final _vkKeyScanW = _user32
    .lookupFunction<Int16 Function(Uint16), int Function(int)>('VkKeyScanW');
final _mapVirtualKeyW = _user32.lookupFunction<Uint32 Function(Uint32, Uint32),
    int Function(int, int)>('MapVirtualKeyW');

class WinInput implements InputSink {
  WinInput() : _point = calloc<_Point>() {
    _grow(32);
  }

  final Pointer<_Point> _point;
  Pointer<_Input> _buffer = nullptr;
  int _capacity = 0;
  int _count = 0;

  void dispose() {
    calloc.free(_point);
    calloc.free(_buffer);
  }

  /// Moves to an exact pixel with an absolute move, so Windows' pointer speed
  /// and acceleration settings don't change how fast the phone feels.
  @override
  void moveBy(int dx, int dy) {
    if (_getCursorPos(_point) == 0) return;
    final left = _getSystemMetrics(_smXVirtualScreen);
    final top = _getSystemMetrics(_smYVirtualScreen);
    final width = _getSystemMetrics(_smCxVirtualScreen);
    final height = _getSystemMetrics(_smCyVirtualScreen);
    if (width <= 0 || height <= 0) return;
    final x = (_point.ref.x + dx).clamp(left, left + width - 1);
    final y = (_point.ref.y + dy).clamp(top, top + height - 1);
    _addMouse(
      dx: toAbsolute(x - left, width),
      dy: toAbsolute(y - top, height),
      flags: _mouseMove | _mouseAbsolute | _mouseVirtualDesk,
    );
    _flush();
  }

  /// Maps a pixel offset to SendInput's 0..65535 range so that it lands on
  /// exactly that pixel (Windows maps back with floor(n * size / 65536)).
  static int toAbsolute(int offset, int size) =>
      math.min(65535, offset * 65536 ~/ size + 1);

  @override
  void button(PadButton button, {required bool down}) {
    _addMouse(flags: _buttonFlag(button, down: down));
    _flush();
  }

  @override
  void click(PadButton button) {
    _addMouse(flags: _buttonFlag(button, down: true));
    _addMouse(flags: _buttonFlag(button, down: false));
    _flush();
  }

  @override
  void scroll(int vertical, int horizontal) {
    if (vertical != 0) _addMouse(flags: _mouseWheel, data: vertical);
    if (horizontal != 0) _addMouse(flags: _mouseHWheel, data: horizontal);
    _flush();
  }

  /// Ctrl + wheel, which is what Windows itself does for a touchpad pinch.
  @override
  void zoom(int steps) {
    _addVk(_vkControl, up: false);
    _addMouse(flags: _mouseWheel, data: steps * 120);
    _addVk(_vkControl, up: true);
    _flush();
  }

  /// Types any Unicode text, independent of the PC's keyboard layout.
  @override
  void typeText(String text) {
    for (final unit in text.codeUnits) {
      _addKey(scan: unit, flags: _keyUnicode);
      _addKey(scan: unit, flags: _keyUnicode | _keyUp);
    }
    _flush();
  }

  @override
  void keyStroke(KeyStroke stroke) {
    final modifiers = {...stroke.modifiers};
    int? vk;
    final key = stroke.key;
    final cp = stroke.codePoint;
    if (key != null) {
      vk = _vkFor(key);
    } else if (cp != null) {
      final scan = cp <= 0xFFFF ? _vkKeyScanW(cp) : -1;
      if (scan == -1) {
        // Not on this keyboard layout, so it can't be part of a shortcut.
        typeText(String.fromCharCode(cp));
        return;
      }
      vk = scan & 0xFF;
      final shiftState = scan >> 8 & 0xFF;
      if (shiftState & 1 != 0) modifiers.add(Modifier.shift);
      if (shiftState & 2 != 0) modifiers.add(Modifier.ctrl);
      if (shiftState & 4 != 0) modifiers.add(Modifier.alt);
    }
    final held = [
      for (final m in Modifier.values)
        if (modifiers.contains(m)) _modifierVk(m),
    ];
    for (final m in held) {
      _addVk(m, up: false);
    }
    if (vk != null) {
      _addVk(vk, up: false);
      _addVk(vk, up: true);
    }
    for (final m in held.reversed) {
      _addVk(m, up: true);
    }
    _flush();
  }

  static int _buttonFlag(PadButton button, {required bool down}) =>
      switch (button) {
        PadButton.left => down ? _mouseLeftDown : _mouseLeftUp,
        PadButton.right => down ? _mouseRightDown : _mouseRightUp,
        PadButton.middle => down ? _mouseMiddleDown : _mouseMiddleUp,
      };

  static int _modifierVk(Modifier m) => switch (m) {
        Modifier.ctrl => _vkControl,
        Modifier.shift => _vkShift,
        Modifier.alt => _vkMenu,
        Modifier.win => _vkLWin,
      };

  static int _vkFor(PadKey key) => switch (key) {
        PadKey.enter => 0x0D,
        PadKey.backspace => 0x08,
        PadKey.tab => 0x09,
        PadKey.escape => 0x1B,
        PadKey.delete => 0x2E,
        PadKey.insert => 0x2D,
        PadKey.left => 0x25,
        PadKey.up => 0x26,
        PadKey.right => 0x27,
        PadKey.down => 0x28,
        PadKey.home => 0x24,
        PadKey.end => 0x23,
        PadKey.pageUp => 0x21,
        PadKey.pageDown => 0x22,
        PadKey.space => 0x20,
        PadKey.f1 => 0x70,
        PadKey.f2 => 0x71,
        PadKey.f3 => 0x72,
        PadKey.f4 => 0x73,
        PadKey.f5 => 0x74,
        PadKey.f6 => 0x75,
        PadKey.f7 => 0x76,
        PadKey.f8 => 0x77,
        PadKey.f9 => 0x78,
        PadKey.f10 => 0x79,
        PadKey.f11 => 0x7A,
        PadKey.f12 => 0x7B,
      };

  void _addMouse({int dx = 0, int dy = 0, int data = 0, required int flags}) {
    final input = _next()..type = _inputMouse;
    input.u.mi
      ..dx = dx
      ..dy = dy
      ..mouseData = data & 0xFFFFFFFF
      ..dwFlags = flags
      ..time = 0
      ..dwExtraInfo = 0;
  }

  void _addVk(int vk, {required bool up}) {
    _addKey(
      vk: vk,
      scan: _mapVirtualKeyW(vk, 0),
      flags: (up ? _keyUp : 0) | (_extendedVks.contains(vk) ? _keyExtended : 0),
    );
  }

  void _addKey({int vk = 0, required int scan, required int flags}) {
    final input = _next()..type = _inputKeyboard;
    input.u.ki
      ..wVk = vk
      ..wScan = scan
      ..dwFlags = flags
      ..time = 0
      ..dwExtraInfo = 0;
  }

  _Input _next() {
    if (_count == _capacity) _grow(_capacity * 2);
    return (_buffer + _count++).ref;
  }

  void _grow(int capacity) {
    final bigger = calloc<_Input>(capacity);
    for (var i = 0; i < _count; i++) {
      (bigger + i).ref = (_buffer + i).ref;
    }
    if (_buffer != nullptr) calloc.free(_buffer);
    _buffer = bigger;
    _capacity = capacity;
  }

  void _flush() {
    if (_count > 0) _sendInput(_count, _buffer, sizeOf<_Input>());
    _count = 0;
  }
}
