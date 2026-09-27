# Development and release

Build and validate a release candidate with:

```bash
cargo build --locked --release --manifest-path backend/Cargo.toml
python3 packaging/release.py --prepare . --binary backend/target/release/omarchy-bluetooth-service
./test/all
omarchy-plugin-validate .
```

The release command atomically replaces the bundled binary and records its
source fingerprint and SHA-256 in `backend-release.json`. The suite checks both
against current plugin sources so a release cannot ship an old service with
new QML or helpers. README text, docs, and screenshots are outside that source
fingerprint.

`Service.qml` keeps the Rust process and connect-policy engine alive across bar
widgets. `Panel.qml` owns shell integration and presentation. The device row,
details page, and glyph are separate QML components; `Model.js` holds pure
projections and state helpers. The service invokes the plugin's helpers under
`scripts/` to keep the Bluetooth panel usable independently of the audio
companion.

The panel follows Omarchy's native Bluetooth widget for discovery, connection,
and multi-monitor behavior. See [Audio integration](INTEGRATION.md) for shared
preferences, policy storage, and migration.
