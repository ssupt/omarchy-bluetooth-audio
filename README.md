# Advanced Bluetooth Audio for Omarchy

An extension of Omarchy's native Bluetooth panel that exposes the active
PipeWire audio mode for connected headsets and speakers.

For Bluetooth audio devices, the panel shows the active codec beside battery
status. When more than one safe mode is available, the arrow on the device row
opens a keyboard- and pointer-friendly selector. Modes are labelled by their
trade-off, such as `High fidelity · AAC` or `Headset + microphone · mSBC`.

This is the Bluetooth-panel companion to
[Advanced Audio Control](https://github.com/ssupt/omarchy-audio-control), which
provides per-application output routing and the full Devices/Bluetooth settings
window.

## Install

```bash
omarchy plugin add https://github.com/ssupt/omarchy-bluetooth-audio.git --enable
```

Enabling the plugin replaces the built-in `omarchy.bluetooth` widget in its
current bar position. Disabling or removing it restores the built-in widget.

Requires `pactl`, `jq`, and `timeout`, all present in a standard Omarchy
installation.

## Removing

```bash
omarchy plugin remove ssupt.bluetooth-audio
```

Removing the companion restores the built-in Bluetooth widget in its previous
bar position.

## Controls

- Click a device row to connect or disconnect it.
- Click the arrow on a connected audio device to choose its audio mode.
- Use `j`/`k` or the arrow keys to navigate devices.
- Use `h`/`l` or Left/Right to reach the audio-mode and forget actions.
- Press Enter to activate the selected row or action, and Escape to close.

Profile changes preserve the device's previous volume and mute state. The
transition temporarily mutes affected outputs and streams so a newly created
profile cannot expose a previously stored high volume.

## Development

```bash
./test/all
omarchy-plugin-validate .
```

The panel is kept as a focused clone of the current native Bluetooth widget so
it retains Omarchy's discovery, connection, and multi-monitor behavior.
