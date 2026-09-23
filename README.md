# Advanced Bluetooth Audio for Omarchy

An extension of Omarchy's native Bluetooth panel that exposes the active
PipeWire audio mode for connected headsets and speakers.

For Bluetooth audio devices, the panel shows the active codec beside battery
status. When more than one safe mode is available, the arrow on the device row
opens a keyboard- and pointer-friendly selector. Modes are labelled by their
trade-off, such as `High fidelity · AAC` or `Headset + microphone · mSBC`.

Connecting a device does not redirect audio automatically. Use the audio action
on a connected device to make it the default output; a microphone exposed by
the selected mode becomes the default input at the same time. Audio-mode choices
are remembered independently for each Bluetooth device by WirePlumber.

Devices can also opt into automatic routing for future connections. Each
device's details offer an AUDIO ON CONNECT choice: Manual (the default,
preserving the behavior above), Output, or Output + Microphone. The choice is
stored per device and applied the next time that device connects.

The Output + Microphone policy accounts for the device's remembered audio
mode. When the mode is already a headset mode, the device becomes the default
output and input once that mode is active. When the remembered mode is
output-only, connecting replaces it with the device's best microphone mode
through the same persisted selection the audio menu uses — so nothing later
restores the output-only codec behind the policy's back. The choice stays in
force while the policy is selected: picking another mode in the audio menu
works for the current session, and the next connect follows the policy again.
Devices that offer no microphone mode at all simply provide output, and the
details page says so.

Pairing and connection operations report the reason when BlueZ rejects them.
Failed device rows keep a retry action, while an active pairing attempt can be
cancelled directly from the panel.

Device rows use the device type reported by BlueZ instead of a generic
Bluetooth symbol. Open a device's details to rename it, manage trust and block
state, allow supported devices to wake the computer, inspect its MAC address,
or forget it with confirmation. Device-setting failures are reported in place;
in particular, Allow wake explains when the device or adapter lacks support.

This is the Bluetooth-panel companion to
[Advanced Audio Control](https://github.com/ssupt/omarchy-audio-control), which
provides per-application output routing and the full Devices/Bluetooth settings
window. When that companion is enabled, a settings button in this panel opens
its Bluetooth tab directly, and renaming a device here also updates the name
shown in the companion's device list.

Both plugins share codec and preferred-device choices through
`~/.config/omarchy/audio-preferences.json`. Connect policies are kept in
`~/.config/omarchy/bluetooth-audio-policies.json`, an atomic plugin-owned
sidecar, so a companion version that normalizes the shared schema cannot erase
them. Policies from older versions of the shared file are migrated
automatically. Both files are optional, and live PipeWire state is used whenever
a saved device or profile is unavailable.

More plugins by `ssupt`: [omarchy-plugins](https://github.com/ssupt/omarchy-plugins).

## Install

```bash
omarchy plugin add https://github.com/ssupt/omarchy-bluetooth-audio.git --enable
```

Enabling the plugin replaces the built-in `omarchy.bluetooth` widget in its
current bar position. Disabling or removing it restores the built-in widget.

Requires `bluetoothctl`, `busctl`, `pactl`, `jq`, `timeout`, and `flock`, all
present in a standard Omarchy installation.
The plugin includes a prebuilt x86_64 Linux Rust command service. It owns
Bluetooth actions, audio mode changes, and preference writes across bar
widgets on multiple monitors. The panel remains usable with its local helpers
if the service cannot start.

## Removing

```bash
omarchy plugin remove ssupt.bluetooth-audio
```

Removing the companion restores the built-in Bluetooth widget in its previous
bar position.

## Controls

- Click a device row to connect or disconnect it.
- Use the audio action on a connected device to make it the default audio device.
- Click the arrow on a connected audio device to choose its audio mode.
- Open the gear on any device row, or right-click the row, for device details.
- In device details, use `j`/`k`, the arrow keys, or Tab to move; press Enter
  to edit or toggle, and Escape to return.
- In device details, press Enter (or ←/→) on AUDIO ON CONNECT to step through
  Manual, Output, and Output + Microphone.
- Failed pairing or connection actions expose a retry button on the device row.
- Cancel an active pairing attempt with the row's cancel button.
- Use `j`/`k` or the arrow keys to navigate devices.
- Use `h`/`l` or Left/Right to reach the audio, details, and preferred-mode actions.
- Press `x` on a remembered device to open the Forget confirmation.
- Press Enter to activate the selected row or action, and Escape to close.

Profile changes preserve the device's previous volume and mute state. The
transition temporarily mutes affected outputs, inputs, and playback streams so
a newly created profile cannot expose a previously stored high volume or an
input before its privacy state is restored. It waits for a stable card and
endpoint inventory under the same mutation lock used by the companion plugin.
An incomplete, interrupted, unconfirmed, or state-restoration failure switches
back to the previous profile. WirePlumber stores the selected profile per device
and restores it on later connections.

## Development

```bash
cargo build --locked --release --manifest-path backend/Cargo.toml
cp backend/target/release/omarchy-bluetooth-service bin/omarchy-bluetooth-service
./test/all
omarchy-plugin-validate .
```

`Service.qml` keeps one Rust process and connect-policy engine alive across bar
widgets. `Panel.qml` owns shell integration and user actions. The device row,
details page, and glyph are separate QML components; `Model.js` contains the
pure, Node-tested projections and state helpers. The Rust process invokes the
plugin's system helpers under `scripts/` so the panel remains independent of
the audio companion.

The panel is kept as a focused clone of the current native Bluetooth widget so
it retains Omarchy's discovery, connection, and multi-monitor behavior.
