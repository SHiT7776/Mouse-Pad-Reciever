// Finds out whether the keyboard focus on this PC is in a box you can type
// into, using Windows UI Automation (what screen readers and the Windows touch
// keyboard use). It sees browser text boxes too, like the Google search box.
import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

final class _Guid extends Struct {
  @Uint32()
  external int data1;
  @Uint16()
  external int data2;
  @Uint16()
  external int data3;
  @Array(8)
  external Array<Uint8> data4;
}

typedef _CoInitializeExC = Int32 Function(Pointer<Void>, Uint32);
typedef _CoInitializeEx = int Function(Pointer<Void>, int);
typedef _CoCreateInstanceC = Int32 Function(Pointer<_Guid>, Pointer<Void>,
    Uint32, Pointer<_Guid>, Pointer<Pointer<Void>>);
typedef _CoCreateInstance = int Function(Pointer<_Guid>, Pointer<Void>, int,
    Pointer<_Guid>, Pointer<Pointer<Void>>);

// COM methods, called through the object's table of function pointers.
typedef _GetObjectC = Int32 Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetObject = int Function(Pointer<Void>, Pointer<Pointer<Void>>);
typedef _GetIntC = Int32 Function(Pointer<Void>, Pointer<Int32>);
typedef _GetInt = int Function(Pointer<Void>, Pointer<Int32>);
typedef _GetPropertyC = Int32 Function(Pointer<Void>, Int32, Pointer<Uint8>);
typedef _GetProperty = int Function(Pointer<Void>, int, Pointer<Uint8>);
typedef _ReleaseC = Uint32 Function(Pointer<Void>);
typedef _Release = int Function(Pointer<Void>);

const _clsidCUIAutomation = 'FF48DBA4-60EF-4201-AA87-54103EEF594E';
const _iidIUIAutomation = '30CBE57D-D9D0-452A-AB13-7AC5AC4825EE';

// Positions in the COM method tables (see UIAutomationClient.h).
const _releaseSlot = 2; // IUnknown::Release
const _getFocusedElementSlot = 8; // IUIAutomation::GetFocusedElement
const _getCurrentPropertyValueSlot = 10; // IUIAutomationElement
const _getCurrentControlTypeSlot = 21; // IUIAutomationElement

const _editControlType = 50004;
const _isValuePatternAvailable = 30043;
const _valueIsReadOnly = 30046;
const _vtBool = 11;

/// Asks on a separate thread, as UI Automation must not be called from the
/// app's own UI thread.
Future<bool> isTextFieldFocused() => Isolate.run(_probe);

bool _probe() {
  final ole32 = DynamicLibrary.open('ole32.dll');
  final oleaut32 = DynamicLibrary.open('oleaut32.dll');
  final coInitializeEx = ole32
      .lookupFunction<_CoInitializeExC, _CoInitializeEx>('CoInitializeEx');
  final coUninitialize =
      ole32.lookupFunction<Void Function(), void Function()>('CoUninitialize');
  final coCreateInstance = ole32
      .lookupFunction<_CoCreateInstanceC, _CoCreateInstance>('CoCreateInstance');
  final variantClear = oleaut32.lookupFunction<Int32 Function(Pointer<Uint8>),
      int Function(Pointer<Uint8>)>('VariantClear');

  final comReady = coInitializeEx(nullptr, 0 /* multithreaded */) >= 0;
  final arena = Arena();
  try {
    final automation = arena<Pointer<Void>>();
    if (coCreateInstance(_guid(arena, _clsidCUIAutomation), nullptr,
            1 /* in-process */, _guid(arena, _iidIUIAutomation), automation) <
        0) {
      return false;
    }
    final element = arena<Pointer<Void>>();
    final found = _method<_GetObjectC, _GetObject>(
            automation.value, _getFocusedElementSlot,
            (p) => p.asFunction())(automation.value, element) >=
        0;
    _release(automation.value);
    if (!found || element.value == nullptr) return false;

    try {
      final type = arena<Int32>();
      final typeKnown = _method<_GetIntC, _GetInt>(element.value,
              _getCurrentControlTypeSlot, (p) => p.asFunction())(
          element.value, type);
      if (typeKnown >= 0 && type.value == _editControlType) return true;

      // Search boxes and rich editors often aren't "Edit" controls, but they
      // do have a value you're allowed to change.
      bool flag(int property) {
        final variant = arena<Uint8>(24);
        final ok = _method<_GetPropertyC, _GetProperty>(element.value,
                _getCurrentPropertyValueSlot, (p) => p.asFunction())(
            element.value, property, variant);
        final value = ok >= 0 &&
            variant.cast<Uint16>().value == _vtBool &&
            (variant + 8).cast<Int16>().value != 0;
        variantClear(variant);
        return value;
      }

      return flag(_isValuePatternAvailable) && !flag(_valueIsReadOnly);
    } finally {
      _release(element.value);
    }
  } finally {
    arena.releaseAll();
    if (comReady) coUninitialize();
  }
}

F _method<N extends Function, F extends Function>(Pointer<Void> object,
    int slot, F Function(Pointer<NativeFunction<N>>) bind) {
  final table = object.cast<Pointer<Pointer<Void>>>().value;
  return bind((table + slot).value.cast<NativeFunction<N>>());
}

void _release(Pointer<Void> object) =>
    _method<_ReleaseC, _Release>(object, _releaseSlot, (p) => p.asFunction())(
        object);

Pointer<_Guid> _guid(Allocator allocator, String text) {
  final hex = text.replaceAll('-', '');
  final guid = allocator<_Guid>();
  guid.ref
    ..data1 = int.parse(hex.substring(0, 8), radix: 16)
    ..data2 = int.parse(hex.substring(8, 12), radix: 16)
    ..data3 = int.parse(hex.substring(12, 16), radix: 16);
  for (var i = 0; i < 8; i++) {
    guid.ref.data4[i] = int.parse(hex.substring(16 + 2 * i, 18 + 2 * i), radix: 16);
  }
  return guid;
}
