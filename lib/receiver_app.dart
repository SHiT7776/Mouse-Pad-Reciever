import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';
import 'protocol.dart';
import 'adb_bridge.dart';
import 'receiver_server.dart';
import 'receiver_settings.dart';
import 'text_focus.dart';
import 'win_input.dart';

const _platformToolsUrl =
    'https://developer.android.com/tools/releases/platform-tools';

class ReceiverApp extends StatelessWidget {
  const ReceiverApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Mouse Pad Receiver',
      debugShowCheckedModeBanner: false,
      theme: buildPadTheme(),
      home: const ReceiverHome(),
    );
  }
}

class ReceiverHome extends StatefulWidget {
  const ReceiverHome({super.key});

  @override
  State<ReceiverHome> createState() => _ReceiverHomeState();
}

class _ReceiverHomeState extends State<ReceiverHome> {
  final _input = WinInput();
  late final _server = ReceiverServer(_input, textFocus: isTextFieldFocused);
  final _adb = AdbBridge(port: defaultPort);
  ReceiverSettings? _settings;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
    // Lets the "receiving" glow fade after the phone goes quiet.
    _tick = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_server.phoneCount > 0) setState(() {});
    });
  }

  Future<void> _boot() async {
    final settings = await ReceiverSettings.load();
    _settings = settings;
    await _server.start(settings.port);
    _adb
      ..port = settings.port
      ..start();
  }

  @override
  void dispose() {
    _tick?.cancel();
    _server.dispose();
    _adb.dispose();
    _input.dispose();
    super.dispose();
  }

  Future<void> _changePort() async {
    final port = await showDialog<int>(
      context: context,
      builder: (_) => _PortDialog(initial: _server.port ?? defaultPort),
    );
    if (port == null) return;
    final settings = _settings;
    if (settings != null) {
      settings.port = port;
      await settings.save();
    }
    await _server.start(port);
    _adb.port = port;
  }

  bool get _receiving {
    final last = _server.lastInputAt;
    return _server.phoneCount > 0 &&
        last != null &&
        DateTime.now().difference(last) < const Duration(milliseconds: 1500);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PadBackground(
        child: ListenableBuilder(
          listenable: Listenable.merge([_server, _adb]),
          builder: (context, _) {
            final status = _status();
            return LayoutBuilder(
              builder: (context, box) {
                final wide = box.maxWidth >= 760;
                final hero = _StatusHero(status: status, receiving: _receiving);
                final guide = _ConnectGuide(
                  adbMissing: _adb.state == AdbState.missing,
                );
                return SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(28, 24, 28, 16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(minHeight: box.maxHeight - 40),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const _Header(),
                        const SizedBox(height: 20),
                        if (wide)
                          IntrinsicHeight(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(flex: 5, child: hero),
                                const SizedBox(width: 20),
                                Expanded(flex: 6, child: guide),
                              ],
                            ),
                          )
                        else ...[
                          hero,
                          const SizedBox(height: 20),
                          guide,
                        ],
                        const SizedBox(height: 14),
                        _Footer(
                          port: _server.port ?? defaultPort,
                          adbPath: _adb.adbPath,
                          onChangePort: _changePort,
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }

  _Status _status() {
    if (_server.error != null) {
      return _Status(
        icon: Icons.error_outline_rounded,
        color: PadColors.danger,
        title: "Can't start",
        detail: _server.error!,
      );
    }
    final linked = _adb.devices.where((d) => d.linked).firstOrNull;
    if (_server.phoneCount > 0) {
      return _Status(
        icon: Icons.check_rounded,
        color: PadColors.connected,
        title: 'Phone connected',
        detail: '${linked?.name ?? 'Your phone'} · USB cable\n'
            'Use the touchpad on your phone. Keep this window open.',
      );
    }
    switch (_adb.state) {
      case AdbState.missing:
        return const _Status(
          icon: Icons.download_rounded,
          color: PadColors.waiting,
          title: 'One thing to install',
          detail: 'USB needs Android platform-tools. See "USB cable" on the '
              'right. (Bluetooth works without it.)',
        );
      case AdbState.searching || AdbState.starting:
        return const _Status(
          icon: Icons.hourglass_top_rounded,
          color: PadColors.accent,
          title: 'Getting ready…',
          detail: 'Starting the USB connection.',
        );
      case AdbState.ready:
        break;
    }
    if (linked != null) {
      return _Status(
        icon: Icons.phone_android_rounded,
        color: PadColors.accent,
        title: 'Open Mouse Pad on your phone',
        detail: '${linked.name} is plugged in. In the app, choose USB cable.',
      );
    }
    if (_adb.devices.any((d) => d.state == 'unauthorized')) {
      return const _Status(
        icon: Icons.lock_open_rounded,
        color: PadColors.waiting,
        title: 'Tap "Allow" on your phone',
        detail: 'Your phone is asking to allow USB debugging from this PC.',
      );
    }
    if (_adb.devices.isNotEmpty) {
      return const _Status(
        icon: Icons.usb_rounded,
        color: PadColors.waiting,
        title: 'Phone not ready',
        detail: 'Unplug the cable and plug it back in.',
      );
    }
    return const _Status(
      icon: Icons.usb_rounded,
      color: PadColors.textDim,
      title: 'Plug in your phone',
      detail: 'Connect it with a USB cable, or use Bluetooth instead.',
      waiting: true,
    );
  }
}

class _Status {
  const _Status({
    required this.icon,
    required this.color,
    required this.title,
    required this.detail,
    this.waiting = false,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String detail;
  final bool waiting;
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [PadColors.accent, PadColors.teal],
            ),
          ),
          child: const Icon(Icons.touch_app_rounded, color: Colors.white),
        ),
        const SizedBox(width: 14),
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mouse Pad',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            Text('Use your phone as this PC\'s touchpad and keyboard',
                style: TextStyle(color: PadColors.textDim)),
          ],
        ),
      ],
    );
  }
}

/// The big round status light.
class _StatusHero extends StatefulWidget {
  const _StatusHero({required this.status, required this.receiving});

  final _Status status;
  final bool receiving;

  @override
  State<_StatusHero> createState() => _StatusHeroState();
}

class _StatusHeroState extends State<_StatusHero>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1400))
    ..repeat(reverse: true);

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    final lively = widget.receiving || status.waiting;
    return PadCard(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 18),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedBuilder(
              animation: _pulse,
              builder: (context, child) {
                final glow = lively ? 0.25 + 0.35 * _pulse.value : 0.3;
                return Container(
                  width: 132,
                  height: 132,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(colors: [
                      status.color.withValues(alpha: 0.35),
                      status.color.withValues(alpha: 0.08),
                    ]),
                    border: Border.all(
                        color: status.color.withValues(alpha: 0.6), width: 2),
                    boxShadow: [
                      BoxShadow(
                          color: status.color.withValues(alpha: glow),
                          blurRadius: 40,
                          spreadRadius: 4),
                    ],
                  ),
                  child: child,
                );
              },
              child: Icon(status.icon, size: 56, color: status.color),
            ),
            const SizedBox(height: 22),
            Text(status.title,
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(status.detail,
                textAlign: TextAlign.center,
                style: const TextStyle(color: PadColors.textDim, height: 1.4)),
            if (widget.receiving) ...[
              const SizedBox(height: 14),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                decoration: BoxDecoration(
                  color: PadColors.connected.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(99),
                ),
                child: const Text('Receiving touches',
                    style: TextStyle(
                        color: PadColors.connected,
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5)),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ConnectGuide extends StatefulWidget {
  const _ConnectGuide({required this.adbMissing});

  final bool adbMissing;

  @override
  State<_ConnectGuide> createState() => _ConnectGuideState();
}

class _ConnectGuideState extends State<_ConnectGuide> {
  bool _bluetooth = false;

  @override
  Widget build(BuildContext context) {
    return PadCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionLabel('How to connect'),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(
                  value: false,
                  icon: Icon(Icons.usb_rounded),
                  label: Text('USB cable')),
              ButtonSegment(
                  value: true,
                  icon: Icon(Icons.bluetooth_rounded),
                  label: Text('Bluetooth')),
            ],
            selected: {_bluetooth},
            showSelectedIcon: false,
            onSelectionChanged: (s) => setState(() => _bluetooth = s.first),
          ),
          const SizedBox(height: 16),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _bluetooth
                ? const _BluetoothSteps(key: ValueKey('bt'))
                : _UsbSteps(
                    key: const ValueKey('usb'), adbMissing: widget.adbMissing),
          ),
        ],
      ),
    );
  }
}

class _UsbSteps extends StatelessWidget {
  const _UsbSteps({super.key, required this.adbMissing});

  final bool adbMissing;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StepRow(1,
            'On the phone, turn on USB debugging: Settings › About phone › tap '
            '"Build number" (Xiaomi: "OS version") 7 times, then Developer '
            'options › USB debugging.'),
        const StepRow(2,
            'Plug the phone into this PC and tap "Allow" on the phone.'),
        const StepRow(3,
            'Open Mouse Pad on the phone and choose USB cable. Keep this '
            'window open.'),
        if (adbMissing) ...[
          const SizedBox(height: 4),
          const Text(
              'This PC also needs Android platform-tools (free from Google). '
              'Unzip it next to this app, or install Android Studio.',
              style: TextStyle(color: PadColors.waiting)),
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            onPressed: () => Process.start('explorer.exe', [_platformToolsUrl],
                mode: ProcessStartMode.detached),
            icon: const Icon(Icons.open_in_new_rounded, size: 18),
            label: const Text('Get platform-tools'),
          ),
        ],
      ],
    );
  }
}

class _BluetoothSteps extends StatelessWidget {
  const _BluetoothSteps({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const StepRow(1,
            'Open Mouse Pad on the phone, choose Bluetooth, tap "Choose PC" '
            'and then "Make phone visible".'),
        const StepRow(2,
            'On this PC, open Bluetooth settings › Add device › Bluetooth, and '
            'pick your phone.'),
        const StepRow(3,
            'Confirm the code on both. From then on the phone connects by '
            'itself.'),
        const SizedBox(height: 4),
        FilledButton.icon(
          onPressed: () => Process.start(
              'explorer.exe', ['ms-settings:bluetooth'],
              mode: ProcessStartMode.detached),
          icon: const Icon(Icons.bluetooth_rounded, size: 18),
          label: const Text('Open Bluetooth settings'),
        ),
        const SizedBox(height: 12),
        const Text(
            'Bluetooth doesn\'t need this window: Windows sees the phone as a '
            'touchpad and keyboard. Needs Android 9 or newer.',
            style: TextStyle(color: PadColors.textDim, fontSize: 12.5)),
      ],
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.port,
    required this.adbPath,
    required this.onChangePort,
  });

  final int port;
  final String? adbPath;
  final VoidCallback onChangePort;

  @override
  Widget build(BuildContext context) {
    const style = TextStyle(color: PadColors.textDim, fontSize: 12);
    return Row(
      children: [
        Tooltip(
          message: adbPath == null ? 'adb not found' : 'adb: $adbPath',
          child: const Icon(Icons.info_outline_rounded,
              size: 16, color: PadColors.textDim),
        ),
        const SizedBox(width: 6),
        Text('USB port $port', style: style),
        TextButton(onPressed: onChangePort, child: const Text('Change')),
      ],
    );
  }
}

class _PortDialog extends StatefulWidget {
  const _PortDialog({required this.initial});

  final int initial;

  @override
  State<_PortDialog> createState() => _PortDialogState();
}

class _PortDialogState extends State<_PortDialog> {
  late final _controller = TextEditingController(text: '${widget.initial}');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    final port = int.tryParse(_controller.text.trim());
    if (port == null || port < 1024 || port > 65535) {
      setState(() => _error = 'Use a number from 1024 to 65535');
      return;
    }
    Navigator.pop(context, port);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('USB port'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        onSubmitted: (_) => _save(),
        decoration: InputDecoration(
          errorText: _error,
          helperText: 'Set the same port in the phone app\'s settings.',
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel')),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }
}
