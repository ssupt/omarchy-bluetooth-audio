# Advanced Bluetooth Audio for Omarchy

Advanced Bluetooth Audio adds headset modes and per-device audio preferences to
Omarchy's Bluetooth panel.

See the active codec, choose between supported playback and microphone modes,
and decide what each device should do when it connects: leave your defaults
unchanged, become the output, or become both output and microphone.

Pairing failures include their reason and a retry action. Device details
provide rename, trust, block, supported wake controls, and confirmed forgetting.
It works independently. [Advanced Audio Control](https://github.com/ssupt/omarchy-audio-control)
adds application routing and shared audio integration.

## What it adds to Omarchy

Compared with the [stock Omarchy Quattro Bluetooth panel](https://github.com/omacom/omarchy/blob/c5b4db77d68e7fbce5cf11120712ea322557e967/shell/plugins/panels/bluetooth/Panel.qml),
checked **27 September 2026**:

| Stock panel | Advanced Bluetooth Audio adds |
| --- | --- |
| Device list, pairing, connection, and battery | Active codec and a selector for supported playback or headset modes |
| Selects the audio output after connecting a device from the panel | Per-device **Audio on connect** choices: Manual, Output, or Output + Microphone |
| Basic device actions | Failure reasons and retry, device details, and confirmed forgetting |

For example, keep a headset in a high-fidelity playback mode for music, then
select a headset-and-microphone mode for a call. Choose **Output** for a headset
that should play audio on reconnect while your desk microphone stays the default.
Choose **Output + Microphone** when the headset should handle both sides of a
call. A device without a microphone mode provides output only.

## Screenshots

<table>
  <tr><th>Supported audio modes</th><th>Audio on connect</th></tr>
  <tr>
    <td valign="top"><a href="screenshot-mode-selector.png"><img src="screenshot-mode-selector.png" width="346" alt="Connected headset with open mode selector, including high-fidelity playback and headset microphone modes"></a></td>
    <td valign="top"><a href="screenshot-audio-on-connect.png"><img src="screenshot-audio-on-connect.png" width="346" alt="Device details with Manual, Output and Output plus Microphone choices"></a></td>
  </tr>
</table>

## Controls

- Click a device row to connect or disconnect it. Click the audio action on a
  connected device to make it the default output; if its current mode exposes a
  microphone, that becomes the default input too.
- Click the arrow on a connected audio device to choose a supported mode. The
  menu describes the trade-off, such as **High fidelity · AAC** or
  **Headset + microphone · mSBC**. The selected mode is remembered per device.
- Open the gear on a device row, or right-click it, for device details. Under
  **Audio on connect**, choose **Manual** (the default), **Output**, or
  **Output + Microphone** for future connections.
- Retry a failed pairing or connection from its row. Cancel an active pairing
  attempt with the row's cancel button. Forgetting asks for confirmation.

The panel also supports keyboard navigation: `j`/`k` or Up/Down moves among
devices, `h`/`l` or Left/Right reaches row actions, Enter activates the selected
action, `x` opens Forget, and Escape closes. In device details, use Tab or arrow
keys to move among controls and Enter to edit or toggle them.

## Install

```bash
omarchy plugin add https://github.com/ssupt/omarchy-bluetooth-audio.git --enable
```

Enabling the plugin replaces the built-in `omarchy.bluetooth` widget in its
current bar position. Disabling or removing it restores the built-in widget.

```bash
omarchy plugin remove ssupt.bluetooth-audio
```

Requires `bluetoothctl`, `busctl`, `pactl`, `jq`, `timeout`, and `flock`, which
are part of a standard Omarchy installation. A prebuilt x86_64 Linux command
service ships with the plugin.

## Service architecture

Quickshell/QML draws the panel. A shared Rust service owns device actions,
their results, and saved choices across bar widgets on multiple monitors. An
action can finish after its panel closes; the service retains its outcome and
shows confirmed success or a useful failure when a panel returns. Audio mode
changes protect the old volume and mute state while the device switches modes.

With Advanced Audio Control installed, default-device changes wait for that
service's confirmed result and the live audio state. The panel can still use
its local helpers when the Bluetooth service is unavailable.

See [development and release](DEVELOPMENT.md) for builds and packaged
source checks, and [Audio integration](INTEGRATION.md) for policy, storage,
and companion details.

More plugins by `ssupt`: [omarchy-plugins](https://github.com/ssupt/omarchy-plugins).
