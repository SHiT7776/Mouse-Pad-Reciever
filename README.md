# Mouse Pad Receiver

The Windows companion for the **[Mouse Pad](https://github.com/SHiT7776/Mouse-Pad)**
phone app. It turns the phone's touches into real mouse and keyboard input on
your PC when the phone is connected with a **USB cable**. Built with Flutter.

You only need it for USB. In Bluetooth mode the phone acts as a Bluetooth mouse
and keyboard, and Windows needs nothing extra.

## Install

Requirements:

- Windows 10 or 11
- [Flutter](https://docs.flutter.dev/get-started/install) with Windows desktop
  support (Visual Studio "Desktop development with C++")
- adb from [Android SDK Platform-Tools](https://developer.android.com/tools/releases/platform-tools)
  (Android Studio already includes it)

Build and install for your user (no admin needed). This adds Start menu and
desktop shortcuts, and an entry in Settings › Apps to uninstall it:

```
powershell -ExecutionPolicy Bypass -File tool\install_receiver.ps1 -Build
```

To build by hand, keep `--no-tree-shake-icons`: without it, the current Flutter
version drops the icons from the Windows build.

```
flutter build windows --release --no-tree-shake-icons
```

## Use

1. On the phone, turn on **USB debugging** (Settings › About phone › tap
   "Build number" 7 times, then Developer options › USB debugging).
2. Open **Mouse Pad Receiver** on the PC and leave it open.
3. Plug the phone in and tap **Allow** on the phone.
4. In the Mouse Pad app choose **USB cable**, then tap **Touchpad**.

The window shows whether the phone is connected, plus how to connect over USB
or Bluetooth.

## How it works

- The receiver keeps `adb reverse tcp:47474 tcp:47474` in place for every phone
  plugged in, so the phone reaches the PC through the cable. It talks to the adb
  server directly instead of running adb.exe over and over.
- It listens on 127.0.0.1 only, so nothing on your network can connect to it.
- Pointer, clicks, scrolling and typing are injected with Windows `SendInput`.
  Typing uses Unicode, so any character works.
- After a click from the phone it asks Windows UI Automation whether a text box
  has focus, and tells the phone to pop its keyboard up or down.

The port can be changed at the bottom of the window. Use the same port in the
phone app's settings.

## Development

```
flutter analyze
flutter test
```

`lib/protocol.dart` is the message format shared with the Mouse Pad app. If you
change it, change it in both repos.
