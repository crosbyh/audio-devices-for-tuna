# Audio Devices for Tuna

A [Tuna](https://tunaformac.com) extension that puts every sound output and input your Mac
can use right now, including connected AirPods, into the launcher as runnable items. Type part
of a device name, press Return, and it becomes the system default. Built on Apple's public
Core Audio API; no Homebrew, no `SwitchAudioSource`.

Requires Tuna 0.96 or later (TunaKit 1.22.0) and macOS 15.

## What it adds

**Source (Settings → Sources → Audio Devices)**

| Catalog | ID | What it does |
| --- | --- | --- |
| Audio Devices | `audio-devices` | One item per device and role. A device that can be both an input and an output (Loopback Audio, for example) appears twice; AirPods appear twice because macOS exposes their microphone and speakers as separate devices. Running an output item makes it the sound output, running an input item makes it the sound input. The current device sorts first in each role and is labelled `Current Output` / `Current Input`; the alerts device is labelled `Alerts`. |
| Audio Devices (browse) | `audio-devices.browse` | Tab → **Browse** groups the same items as Sound Output and Sound Input. |

**Actions (`audio-devices.actions`)**

| Action | Applies to | Effect |
| --- | --- | --- |
| Use for Sound Output | an output item | Sets the default output. When *Route alert sounds with output* is on (the default) and the device can play alerts, alert sounds follow. Default action (Return). |
| Use for Sound Input | an input item | Sets the default input. Default action (Return). |
| Use for Alert Sounds | an output item that can play alerts | Sets only the alert-sounds device, for a separate alerts device. A later output switch overrides it while *Route alert sounds with output* is on. |
| Hide from Tuna | any device item | Removes the item from search and browse. Hidden devices stay reachable under **Hidden Audio Devices** in the source. |
| Show in Tuna | a hidden device item | Brings it back. |

Every switch is verified: the extension reads the default back after setting it and reports
failure if macOS did not actually switch. Nothing is reported as done before it is.

## Settings

| Setting | Key | Default |
| --- | --- | --- |
| Route alert sounds with output | `RouteSoundEffectsWithOutput` | on |
| Hidden devices | `HiddenDevices` | empty; item IDs, one per line, maintained by the hide/show actions |

## Global search

Tuna keeps extension sources out of global search until you opt them in (as of Tuna 0.98 the
declared `initialGlobalScope: .all` is not honoured for a developer-loaded extension). To make
device names match from the root of the launcher: **Settings → Sources → Audio Devices → In
global search → All**. Until then the items are reachable through Browse.

## Bluetooth and AirPods

- AirPods and other Bluetooth headsets appear as soon as macOS lists them as connected audio
  devices (open the case or connect them in Control Center first). The extension does not
  pair or force-connect anything; a disconnected headset is simply absent.
- Using a Bluetooth headset's microphone puts it in its lower-quality two-way mode, so
  playback quality can drop while an app uses the mic. Input items for Bluetooth devices say
  so in their detail text. See
  [Apple's note on reduced Bluetooth headphone sound quality](https://support.apple.com/en-us/102217).

## What is excluded

Only devices Core Audio reports as able to become a default are listed. Virtual devices that
refuse every role (Microsoft Teams Audio, for one) are left out on purpose, even though other
tools list them; choosing them would silently fail.

## Privacy

The extension reads audio device metadata and reads and sets the three system defaults
(input, output, alert sounds). It never records, captures, inspects, or transmits audio, needs
no microphone permission, and sends nothing off the Mac. It registers Core Audio listeners so
Tuna refreshes when devices connect, disconnect, or are switched elsewhere; those listeners are
read-only.

## Development

```bash
make build            # Debug build
make test             # unit tests (29, against a fake Core Audio provider)
make install-restart  # install into ~/Library/Application Support/Tuna/ExtensionsDev and restart Tuna
make logs             # last 20 minutes of Tuna extension logs
make package          # Release build + dist/store/*.tunaextension
```

`spike/` holds the throwaway Core Audio spikes used during design (see `docs/PLAN.md`); they
are not part of the build. `./scripts/screenshot-tuna NAME [DELAY]` captures the launcher
window for screenshots. `./scripts/sync-to-tunaextensions [path]` copies the extension into a
[TunaExtensions](https://github.com/tunaformac/TunaExtensions) checkout for the store pull
request.

## Releasing to the Tuna store

Store extensions ship from the TunaExtensions repository, so this repo is upstream and
`AudioDevicesExtension/` is copied over for each release:

1. Bump `CFBundleShortVersionString` / `CFBundleVersion` in `Info.plist` and add a
   `CHANGELOG.md` entry.
2. `./scripts/sync-to-tunaextensions ../TunaExtensions` (a clone of your fork on a feature
   branch). The script swaps the signing team to the upstream one; the per-extension
   `README.md` in TunaExtensions is maintained by hand.
3. In that checkout: `./scripts/tuna-extension build --scheme AudioDevicesExtension --release`,
   `make test`, commit, push, and open or update the pull request.

The scripts are adapted from tunaformac/TunaExtensions (MIT, see
`scripts/LICENSE-TunaExtensions`). Building needs Xcode 16+, `rg`, and network access for the
TunaKit binary package. For non-interactive signing pass `TUNA_DEVELOPMENT_TEAM` and
`TUNA_CODE_SIGN_IDENTITY`.

## Stable identifiers

Catalog, action, item, type, and setting IDs are public API (hotkeys, rankings, `tuna://`
URLs). Do not rename: `audio-devices`, `audio-devices.browse`, `audio-devices.actions`,
`use-for-output`, `use-for-input`, `use-for-sound-effects`, `hide-device`, `show-device`,
`com.crosbyh.tuna.type.audio-output-device`, `com.crosbyh.tuna.type.audio-input-device`,
settings `RouteSoundEffectsWithOutput` and `HiddenDevices`. Item IDs are
`output:<uid>` / `input:<uid>` with the Core Audio UID percent-encoded, so they survive
reconnects and restarts.

## License

MIT. See `LICENSE`.
