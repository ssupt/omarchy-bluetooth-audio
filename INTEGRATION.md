# Audio integration and connection policies

For a connected Bluetooth audio device, the panel shows the active codec next
to its battery status. The mode selector lists safe modes that the live device
supports. WirePlumber remembers the selected profile per device; a failed or
unconfirmed profile change restores the previous mode and reports the result.
During a switch, the plugin temporarily mutes affected endpoints and streams,
then restores their previous volume and mute state.

By default, connecting a device leaves audio defaults unchanged. The audio
action on its row manually makes it the default output; a microphone exposed by
the current mode becomes the default input at the same time.

Device details store one **Audio on connect** policy per device:

| Policy | Next connection |
| --- | --- |
| Manual | Keep existing output and microphone defaults |
| Output | Make this device the default output; keep the current microphone |
| Output + Microphone | Use this device for both when a microphone mode is supported |

For **Output + Microphone**, an already remembered headset mode is used once
active. If the remembered mode offers output only, the policy selects the best
supported microphone mode and persists that selection before applying defaults.
A manual mode change can take effect for the current connection; the policy
applies again on the next connection. A device with no microphone mode supplies
output only, and the details page explains the limit.

When [Advanced Audio Control](https://github.com/ssupt/omarchy-audio-control)
is enabled, the panel opens its Bluetooth settings tab from the settings button.
Renaming here updates the companion's device list. Both plugins share codec
and preferred-device choices in `audio-preferences.json`. The companion's
`default.compat` request checks a live node ID and name; the Bluetooth panel
waits for the command result and live defaults before marking a switch done.
Successful forgetting also clears saved audio routes when the companion is
available.

Connection policies live separately in `bluetooth-audio-policies.json`, an
atomic plugin-owned sidecar. This prevents a companion release that normalizes
the shared schema from erasing policy choices. Policies in older versions of
the shared file migrate automatically. Both files are optional. The writer
rejects unsupported future schemas rather than downgrading them; unavailable
saved devices or profiles fall back to live PipeWire state.

The two service branches should be released together when their shared
contract changes. Older audio companions can use the compatibility helpers.
