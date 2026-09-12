# Tuna Audio Device Switcher Extension Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Add a Tuna extension that makes the Mac’s currently available audio input and output devices directly searchable and switchable, including connected Bluetooth devices such as AirPods.

**Architecture:** Implement audio enumeration, default-device switching, and change observation directly with Apple’s public Core Audio APIs inside the Swift framework. Expose one small, globally searchable catalog containing distinct input and output commands for each eligible device; make each item directly runnable and also provide explicit actions. Use stable Core Audio device UIDs for identity, never transient `AudioDeviceID` values or mutable display names.

**Tech Stack:** Swift, Core Audio (`AudioHardwareSystem`/`AudioHardwareDevice` plus narrowly scoped HAL property access where the typed macOS 15 API lacks metadata), TunaKit, XCTest, protocol-backed Core Audio test doubles, Tuna’s first-party extension build/install tooling.

---

## 1. Recommendation

Use **native Core Audio**, not a runtime Homebrew dependency.

Apple’s macOS 15 Core Audio API directly exposes:

- all audio devices currently available to the system;
- whether each device can be the default input, output, or sound-effects device;
- the current default input, output, and sound-effects devices;
- setters for all three defaults; and
- property listeners for device-list and default-device changes.

Sources:

- [AudioHardwareSystem](https://developer.apple.com/documentation/coreaudio/audiohardwaresystem)
- [AudioHardwareDevice](https://developer.apple.com/documentation/coreaudio/audiohardwaredevice)
- [AudioHardwareObject listeners](https://developer.apple.com/documentation/coreaudio/audiohardwareobject)
- [PropertyListenerDelegate](https://developer.apple.com/documentation/coreaudio/propertylistenerdelegate)

The Homebrew formula [`switchaudio-osx`](https://formulae.brew.sh/formula/switchaudio-osx) is useful as a proof of concept and a manual comparison oracle. Its `SwitchAudioSource` executable enumerates Core Audio devices and sets `kAudioHardwarePropertyDefaultInputDevice`, `kAudioHardwarePropertyDefaultOutputDevice`, or `kAudioHardwarePropertyDefaultSystemOutputDevice`. It does not provide a capability Tuna cannot access directly. Requiring it would add:

- Homebrew and formula installation as prerequisites;
- Intel/Apple Silicon path discovery;
- subprocess startup and parsing;
- another independently versioned component;
- weaker device-change observation; and
- more failure and support paths.

Tuna can execute a CLI safely through `CLIProcessRequest`, as its first-party Brew extension demonstrates, so a CLI backend is technically possible. It should be retained only as a **development comparison/fallback spike**, not the shipped v1 architecture.

## 2. Bluetooth and AirPods boundary

The extension will support AirPods and other Bluetooth headsets **when macOS exposes them as currently available Core Audio devices**. Apple’s Sound settings similarly list devices available to the Mac. Selecting a default Core Audio device is not the same as pairing or establishing an unavailable Bluetooth connection.

V1 should therefore:

1. enumerate connected/available Bluetooth audio endpoints through Core Audio;
2. identify Bluetooth transport using public Core Audio metadata when available;
3. switch connected AirPods as input or output exactly like other eligible Core Audio devices;
4. listen for device-list changes so AirPods appear quickly after opening the case or connecting;
5. verify the selected default by reading it back after the setter returns; and
6. show a clear “connect this device in Control Center first” limitation in the README and empty/error states.

V1 should **not** use private Bluetooth frameworks, automate Control Center, pair devices, or promise to force-connect disconnected AirPods. If a public, App Store-compatible API for connecting classic Bluetooth audio devices is not verified during implementation, that capability remains out of scope.

AirPods also need a UX warning: Apple documents that Bluetooth headphones use a higher-quality listening mode and a lower-quality two-way mode when their microphone is in use. Switching the default input to an AirPods microphone can therefore reduce playback quality while an app uses that microphone. See [Apple Support: reduced Bluetooth headphone sound quality](https://support.apple.com/en-us/102217).

## 3. Sources and version baseline

Reviewed 2026-09-11:

- Tuna extension docs: <https://tunaformac.com/docs/extension-development>
- Tuna supported API: <https://tunaformac.com/docs/extension-api>
- Tuna first-party authoring guide: <https://github.com/tunaformac/TunaExtensions/blob/main/docs/extension-authoring.md>
- Current first-party examples: `CleanShotExtension`, `ThingsExtension`, `RemindersExtension`, `Messages2FAExtension`, and `BrewExtension`.
- Core Audio macOS 15 typed API: Apple documentation linked above.
- `switchaudio-osx` source and MIT license: <https://github.com/deweller/switchaudio-osx>
- Homebrew formula currently packages `switchaudio-osx` 1.2.2: <https://raw.githubusercontent.com/Homebrew/homebrew-core/master/Formula/s/switchaudio-osx.rb>

The implementation must re-check the current TunaExtensions commit, every `*Extension.swift` declaration, the repository’s resolved TunaKit version, and the TunaKit changelog before scaffolding. Tentative floors are macOS 15, Tuna 0.95, and TunaKit 1.21.0, matching current first-party patterns, but only tested floors may be declared.

## 4. Product design packet — approval gate

Do not scaffold implementation until this design packet is explicitly approved. If discovery changes the catalog, item IDs, default actions, Bluetooth boundary, or dependency decision, present the delta and obtain approval again.

### 4.1 User jobs

1. Type part of an audio device name in Tuna and immediately switch the Mac’s default output.
2. Type part of a microphone name and immediately switch the Mac’s default input.
3. See which devices are current without opening System Settings.
4. Use connected AirPods for output or input.
5. Assign Tuna hotkeys/aliases to stable input/output device items.
6. Have the catalog update when USB, display, virtual, or Bluetooth audio devices appear or disappear.

### 4.2 Explicit non-goals for v1

- Pairing, connecting, or disconnecting Bluetooth devices.
- Private `IOBluetooth`/Control Center automation.
- AirPlay destination discovery beyond devices exposed by Core Audio as selectable defaults.
- Per-application routing, aggregate-device creation, sample-rate changes, channel mapping, balance, volume, or mute.
- Automatic rules such as “always prefer MacBook microphone when AirPods connect.”
- Switching both input and output in one action; this is deferred because Bluetooth microphone use has an important quality tradeoff and partial success would need rollback semantics.
- Bundling, downloading, installing, or shelling out to `SwitchAudioSource` in production.

### 4.3 Provider contract

Create a narrow `AudioDeviceProviding` boundary with operations equivalent to:

```swift
protocol AudioDeviceProviding: Sendable {
  func snapshot() throws -> AudioDeviceSnapshot
  func setDefaultInput(uid: String) throws
  func setDefaultOutput(uid: String, includeSoundEffects: Bool) throws
  func startObservingChanges(_ handler: @escaping @Sendable () -> Void) throws
  func stopObservingChanges()
}
```

`AudioDeviceSnapshot` contains:

- current eligible input and output devices;
- stable UID, current runtime object ID, display name, manufacturer/model when available;
- input/output/sound-effects eligibility;
- transport kind, including Bluetooth when publicly reported;
- current input, output, and sound-effects UIDs.

Production backend rules:

- Use `AudioHardwareSystem.shared.devices` and `canBeDefaultInputDevice` / `canBeDefaultOutputDevice` where the released SDK supports them.
- Use `setDefaultInputDevice`, `setDefaultOutputDevice`, and optionally `setDefaultSoundEffectsDevice`.
- Use public HAL properties only where required for stable UID or transport metadata; isolate unsafe property reads in one audited file.
- Exclude hidden, unknown, non-eligible, and UID-less devices rather than inventing unstable IDs.
- Never retain a runtime `AudioDeviceID` as persistent identity. Resolve the current device again from its UID at execution time because devices can disappear and reappear.
- After a set, read the default property back with a bounded retry suitable for Core Audio’s asynchronous propagation. Report success only when the requested UID is observed.
- If output succeeds but sound-effects output fails, return a partial-failure message that states output switched but alerts did not; do not pretend the operation was atomic.
- Register listeners for the device list and all three default-device properties. Debounce bursts and invoke Tuna’s `RescanSchedulingCatalog.rescanHandler`.
- Tear down listeners in `deinit`.

### 4.4 Homebrew integration decision

Three options were considered:

| Option | Benefits | Costs | Decision |
|---|---|---|---|
| Native Core Audio | No dependency, typed errors, listeners, direct UID handling, fastest execution | Requires careful HAL wrapper/testing | **Recommended and planned** |
| External `SwitchAudioSource` | Simple prototype; existing CLI and JSON output | Requires Homebrew/path/process parsing; old upstream test claims; no native observation | Development oracle only |
| Vendor/fork switchaudio source | Known MIT Core Audio implementation | Carries C code and notices; duplicates modern Apple API; maintenance burden | Reject unless native spike uncovers a blocker |

During the implementation spike, compare native enumeration and switching against:

```bash
brew install switchaudio-osx
SwitchAudioSource -a -f json -t input
SwitchAudioSource -a -f json -t output
SwitchAudioSource -c -f json -t input
SwitchAudioSource -c -f json -t output
```

These commands are manual validation aids only. The extension must pass when Homebrew and `SwitchAudioSource` are absent.

### 4.5 Catalog matrix

| Stable ID | Name | Presentation | Enabled | Initial global scope | Startup/lifecycle | Contents |
|---|---|---|---:|---|---|---|
| `audio-devices` | Audio Devices | `.source` | yes | `.all` | fast local startup scan; listener-driven rescans | One runnable item per eligible `(device UID, role)` pair |
| `audio-devices.browse` | Audio Devices | `.browseRoot(contents: "audio-devices")` | yes | root only | no separate hardware read | Browse companion for users who prefer grouped inspection |
| `audio-devices.actions` | Audio Device Actions | action catalog | n/a | n/a | no scan | Explicit input/output switching actions |

Concrete items are intentionally included in global search because the corpus is small, local, fast, and central to quick switching. Users may still change Tuna’s persisted source scope.

The browse companion should group or sort devices so that current output and input are obvious, while the source catalog remains flat for search. If Tuna’s standard browse companion cannot group without duplicating items, retain a sorted flat list in v1 rather than hand-building unnecessary hierarchy.

### 4.6 Type and item model

Register:

- `TypeID.audioOutputDevice = "com.tuna.type.audio-output-device"`, inheriting from `.entity`.
- `TypeID.audioInputDevice = "com.tuna.type.audio-input-device"`, inheriting from `.entity`.

Items:

- Output item ID: `output:<percent-encoded-or-hashed-device-uid>`.
- Input item ID: `input:<percent-encoded-or-hashed-device-uid>`.
- Prefer a reversible safe encoding of the exact UID. If hashing is required for Tuna ID constraints, use a deterministic cryptographic digest and test collision handling; never use the display name or `AudioDeviceID`.
- Title: device’s system display name.
- Detail examples:
  - `Current Output · Bluetooth`
  - `Output · USB`
  - `Current Input · Built-in`
  - `Input · Bluetooth — microphone use may reduce playback quality`
- Search keys: display name, manufacturer/model when available, `input`/`microphone` or `output`/`speaker`/`headphones`, and transport label.
- Preview symbols:
  - output: `speaker.wave.2.fill` or `headphones` for Bluetooth headphones when classification is reliable;
  - input: `mic.fill`;
  - current device: use detail/accent rather than changing stable identity.

Each item carries only immutable snapshot metadata and the stable UID. It resolves the live target through `AudioDeviceProviding` when run.

### 4.7 Action grammar and direct execution

| Stable ID | Title | Subject | Target | Policy/result |
|---|---|---|---|---|
| `use-for-output` | Use for Sound Output | `.audioOutputDevice` | none | switch output, optionally sound effects, verify readback, dismiss on success |
| `use-for-input` | Use for Sound Input | `.audioInputDevice` | none | switch input, verify readback, dismiss on success |

Direct execution:

- An output item’s `run()` performs `use-for-output`.
- An input item’s `run()` performs `use-for-input`.
- Both declare headless eligibility only after tests show UID resolution, readback verification, and user-facing failures are safe without an open Tuna window.
- Current devices remain runnable but may return a fast success/no-op after fresh readback.

Output behavior:

- Extension setting `RouteSoundEffectsWithOutput`, `.bool`, default `true`.
- When enabled, set normal output first, then sound-effects output if the device is eligible.
- Report partial failure explicitly if the main output changes but sound-effects routing does not.

Input behavior:

- On a Bluetooth input item, the detail and README warn that active microphone use may reduce headphone playback quality.
- Do not add a confirmation to every input switch; that would undermine quick switching. The warning is informational and the action remains reversible.

Default action rankings make the matching switch action first for each custom type. Do not add ellipses because neither action opens a target pane.

### 4.8 Refresh and race behavior

- Scan reads one coherent `AudioDeviceSnapshot` and replaces all items on the main actor.
- Core Audio listeners cover device-list changes and current default input/output/sound-effects changes.
- Debounce event bursts by approximately 200–300 ms before calling `rescanHandler`.
- Cancel superseded debounce tasks.
- A switch action resolves the UID against a fresh snapshot. If the device disappeared, fail with “Device is no longer available. Reconnect it and try again.”
- After successful verified switching, request a rescan so current-state labels update immediately.
- Avoid feedback loops: default-change listeners may request another rescan, but scans must never perform writes.

### 4.9 Permissions and privacy

The extension reads audio hardware metadata and changes system defaults; it does not record, capture, inspect, or transmit audio. The plan assumes this does not require microphone permission, but implementation must validate that assumption on a clean macOS account and document any actual prompt. Do not add microphone entitlements or request TCC access unless a public API genuinely requires it.

No data leaves the Mac. Logs may include device UID only at debug level if necessary; prefer device name plus sanitized Core Audio status code. Never log serial numbers or unrelated hardware metadata.

### 4.10 Error and empty states

Provide specific failures for:

- no eligible input devices;
- no eligible output devices;
- device disappeared before execution;
- device cannot become the requested default;
- Core Audio property read/write failure, including decoded `OSStatus` where possible;
- setter returned but readback never matched;
- main output switched but sound-effects output failed;
- listener registration failure, with the catalog still usable via manual rescan;
- disconnected AirPods absent from the catalog, documented as expected rather than presented as an error.

Do not show stale disconnected devices as runnable. A future “favorites/offline devices” feature would need separate semantics and a verified public connection mechanism.

### 4.11 Compatibility and acceptance criteria

1. Built-in, USB, display, virtual, and connected Bluetooth devices that Core Audio marks eligible appear in the correct role(s).
2. A duplex device such as AirPods yields separate input and output items with distinct stable IDs.
3. Running an item changes and then verifies the matching system default.
4. Output optionally changes the sound-effects device according to the setting.
5. Connecting or disconnecting AirPods triggers a debounced Tuna rescan without restarting Tuna.
6. Selecting an AirPods microphone is supported and accompanied by the documented quality warning.
7. Disconnected AirPods are not promised or shown as switchable.
8. The extension works without Homebrew or `SwitchAudioSource` installed.
9. Stable hotkeys/aliases survive restart and device reconnect because identity uses UID plus role.
10. Unit tests cover provider logic, item identity, catalog shape, listeners, actions, partial failures, and races.
11. Release build, repository tests, dev install, logs, and manual hardware tests pass.

## 5. Proposed file layout

Create on a fresh branch in `tunaformac/TunaExtensions`:

```text
AudioDevicesExtension/
├── AudioDevicesExtension.swift
├── CoreAudioBackend.swift
├── AudioDeviceModels.swift
├── AudioDeviceCatalog.swift
├── AudioDeviceItems.swift
├── AudioDeviceActionsCatalog.swift
├── AudioDevicesExtensionTests.swift
├── AudioDevicesExtension.xcodeproj/
│   ├── project.pbxproj
│   └── xcshareddata/xcschemes/AudioDevicesExtension.xcscheme
├── Info.plist
├── README.md
├── CHANGELOG.md
└── icon.png
```

Modify:

- `TunaExtensions.xcworkspace/contents.xcworkspacedata`.
- Repository README extension table if current contributor convention requires it.

Current implementation recipes:

- `CleanShotExtension/CleanShotCommandsCatalog.swift` — directly runnable local command items.
- `ThingsExtension/ThingsCatalog.swift` and `ThingsItems.swift` — small static/local item catalog and stable item model.
- `Messages2FAExtension/Messages2FACatalog.swift` — `RescanSchedulingCatalog`, debounce, and listener teardown.
- `RemindersExtension/RemindersCatalog.swift` — framework-backed local data and external-change handling.
- `BrewExtension/BrewCLI.swift` — CLI execution only for the rejected/fallback comparison path.

## 6. Step-by-step implementation plan

### Task 1: Revalidate Tuna and Core Audio APIs

**Objective:** Confirm the exact current TunaKit and macOS 15 APIs before scaffolding.

**Files:** none.

1. Create a branch named `add-audio-devices-extension` in the current TunaExtensions checkout.
2. Read every current `*Extension.swift`, current Tuna authoring skill/guide, relevant recipe files, and TunaKit changelog.
3. In a throwaway Swift/macOS spike, compile calls to `AudioHardwareSystem.shared`, device eligibility properties, default setters, and property listeners.
4. Determine which public property supplies stable device UID and transport type in the current SDK; isolate any required C HAL access.
5. Verify listener addresses for device list and all default roles.
6. Present any material design changes and obtain renewed approval.

### Task 2: Compare native behavior with macOS and SwitchAudioSource

**Objective:** Validate the native backend’s semantics on real hardware before building Tuna UI around it.

**Files:** throwaway spike only; do not copy `switchaudio-osx` code.

1. Enumerate built-in input/output devices natively.
2. Connect AirPods and confirm output/input eligibility, UID stability, transport metadata, and device-list notifications.
3. Disconnect/reconnect AirPods and confirm whether the UID remains stable while runtime object IDs may change.
4. Switch output, input, and sound-effects defaults natively and read each back.
5. Optionally install `switchaudio-osx` and compare its JSON listing/current-device output to native results.
6. Remove or disable the CLI and prove native switching still works.
7. Record actual behavior for AirPods, USB audio, display audio, and any virtual device available.

### Task 3: Add project wiring and declaration tests

**Objective:** Create a loadable extension with permanent catalog/action/type IDs.

**Files:**

- Create project, scheme, `Info.plist`, `AudioDevicesExtension.swift`, and tests.
- Modify `TunaExtensions.xcworkspace/contents.xcworkspacedata`.

1. Copy the closest current first-party project for wiring only and rename all product/module/bundle/test references.
2. Write failing declaration tests for unique IDs, `.source` plus browse companion, `.all` initial scope for the concrete local catalog, settings, type inheritance, and default rankings.
3. Implement the minimal declaration and principal class.
4. Run focused tests and Debug build.
5. Commit: `feat(audio-devices): scaffold extension declaration`.

### Task 4: Define provider models and test double

**Objective:** Establish deterministic boundaries before touching hardware APIs.

**Files:**

- Create `AudioDeviceModels.swift`.
- Add provider protocol and fake backend to tests.

1. Write tests for role eligibility, duplex devices, current-state derivation, deterministic sort, and UID/role identity.
2. Define `AudioDeviceRecord`, transport enum, snapshot, role, and typed errors.
3. Define injectable provider and observer lifecycle.
4. Implement fake snapshots, writes, failures, delayed readback, and change events.
5. Commit: `test(audio-devices): define provider contract`.

### Task 5: Implement Core Audio enumeration

**Objective:** Produce accurate snapshots using public APIs.

**Files:**

- Create `CoreAudioBackend.swift`.
- Extend tests around pure metadata conversion helpers.

1. Add failing tests for filtering hidden/ineligible/UID-less devices and classifying input/output/Bluetooth transport.
2. Implement `AudioHardwareSystem` enumeration and current-default reads.
3. Add narrowly scoped helpers for stable UID and transport only if typed properties are unavailable.
4. Convert thrown errors and `OSStatus` values into typed, user-facing failures.
5. Run unit tests and the hardware spike.
6. Commit: `feat(audio-devices): enumerate Core Audio devices`.

### Task 6: Implement verified switching

**Objective:** Change defaults safely and never report unverified success.

**Files:**

- Extend `CoreAudioBackend.swift` and tests.

1. Write failing tests for fresh UID resolution, vanished devices, role rejection, output/input setters, sound-effects setting, readback retries, timeout, and partial failure.
2. Implement input switching.
3. Implement output followed by optional sound-effects switching.
4. Add bounded asynchronous readback verification without blocking Tuna’s main actor.
5. Ensure no-op selection still confirms current state.
6. Commit: `feat(audio-devices): switch and verify default devices`.

### Task 7: Implement stable runnable items

**Objective:** Make each input/output endpoint directly executable and searchable.

**Files:**

- Create `AudioDeviceItems.swift`.
- Extend tests.

1. Write failing tests for stable IDs, duplicate names, duplex-role separation, search keys, details, symbols, current-state labels, and AirPods/Bluetooth warning copy.
2. Implement output and input items using the provider’s stable UID resolution.
3. Implement `Runnable` and declare execution policy/headless eligibility conservatively.
4. Run tests and commit: `feat(audio-devices): add runnable device items`.

### Task 8: Implement catalog and live refresh

**Objective:** Keep Tuna synchronized with Core Audio device/default changes.

**Files:**

- Create `AudioDeviceCatalog.swift`.
- Extend tests.

1. Write failing catalog tests for one item per eligible UID/role, deterministic sorting, empty states, fast startup scan, and listener installation once.
2. Write fake-observer tests for 250 ms debounce, cancellation of superseded events, rescan handler invocation, and listener teardown.
3. Implement `Catalog` plus `RescanSchedulingCatalog` using the current Tuna recipe.
4. Ensure scans are read-only and listener-triggered rescans cannot loop.
5. Commit: `feat(audio-devices): refresh on hardware changes`.

### Task 9: Implement explicit actions and rankings

**Objective:** Make action behavior inspectable and preserve Tuna action semantics.

**Files:**

- Create `AudioDeviceActionsCatalog.swift`.
- Extend declaration/action tests.

1. Write failing tests for exact subject types, predicates, titles, no target pane, policies, and default rankings.
2. Implement `use-for-output` and `use-for-input` with the same shared switching service used by runnable items.
3. Request rescan after verified success.
4. Verify current-device execution and disappearing-device failure.
5. Commit: `feat(audio-devices): add switch actions`.

### Task 10: Document privacy, Bluetooth behavior, and dependency choice

**Objective:** Make constraints explicit before distribution review.

**Files:**

- Create/update `README.md`, `CHANGELOG.md`, and approved `icon.png`.

1. Document no audio capture/transmission, expected permissions, supported device classes, and sound-effects setting.
2. Explain that AirPods must already be available/connected and that using their microphone may reduce playback quality.
3. State explicitly that Homebrew and `switchaudio-osx` are not required.
4. Document tested macOS, Tuna, TunaKit, Mac hardware, AirPods model/firmware, and other devices without serial numbers.
5. Verify icon licensing.
6. Commit: `docs(audio-devices): document Bluetooth and privacy behavior`.

### Task 11: Automated and manual validation

**Objective:** Prove correct behavior under real device changes and Tuna execution.

1. Run the focused XCTest target; expected: all AudioDevices tests pass.
2. Run `./scripts/tuna-extension build --scheme AudioDevicesExtension --release`.
3. Run `make test` and confirm repository-wide success.
4. Install with `./scripts/tuna-extension install --scheme AudioDevicesExtension --restart`.
5. Inspect `./scripts/tuna-extension logs --last 20m` for load, listener, and Core Audio failures.
6. On a clean user account, verify no microphone permission prompt occurs; if one does, investigate and update the design/docs before shipping.
7. Test built-in speakers/microphone, AirPods output, AirPods input, USB audio, display audio, and a virtual device where available.
8. Verify connect/disconnect events, duplicate device names, sleep/wake, rapid changes, device disappearance during execution, and external changes made in Control Center/System Settings.
9. Confirm output and input hotkeys/aliases remain bound after restart and AirPods reconnect.
10. Confirm the extension works with Homebrew absent.
11. Test the oldest claimed macOS/Tuna/TunaKit floors.
12. Open a TunaExtensions PR with the approved design, test evidence, privacy statement, screenshots, and known Bluetooth limitations. Packaging/upload/release remain maintainer tasks.

## 7. Test matrix

### Provider/backend

- Eligible/hidden/UID-less device filtering.
- Stable UID lookup and transient object-ID replacement.
- Input/output/sound-effects default reads.
- Setter/readback success, delay, timeout, and partial failure.
- Public transport classification.
- Listener registration/removal and event coalescing.

### Item/catalog

- Same display name with different UIDs.
- Same UID represented as distinct input/output items.
- Current device details and ordering.
- Search by name, role, manufacturer, and transport.
- Empty input/output states.
- Global scope and browse companion behavior.

### Actions/runnable behavior

- Output item invokes output only plus configured sound-effects behavior.
- Input item invokes input only.
- Wrong-role subject rejection.
- Vanished device failure.
- No unverified or premature success.
- Headless execution eligibility.

### Hardware/manual

- AirPods closed/disconnected: absent and not falsely switchable.
- AirPods connected: output and input items appear.
- AirPods microphone selection: succeeds and documented quality behavior is observable.
- External default changes update Tuna.
- USB/display/virtual device hot-plug.
- Sleep/wake and Tuna restart.

## 8. Risks and tradeoffs

1. **Core Audio typed API availability:** The convenient Swift classes require macOS 15. This matches Tuna’s stated minimum today; verify before fixing floors.
2. **UID metadata gaps:** The typed API documentation may not expose every field needed. Use public HAL properties behind one audited adapter rather than a CLI dependency.
3. **Bluetooth availability:** Core Audio can switch an available AirPods endpoint but should not be assumed to connect a dormant/disconnected one. State this clearly.
4. **Bluetooth microphone quality:** Using headset input can reduce Bluetooth playback quality. Warn without blocking quick switching.
5. **Sound-effects partial failure:** Two setters are not atomic. Verify each and report partial state.
6. **Hot-plug races:** Devices can disappear between search and execution. Resolve by UID immediately before setting and handle failure normally.
7. **TunaKit beta churn:** Revalidate current examples and pin up to the next minor.
8. **In-process native code:** Keep HAL unsafe operations small, public-API-only, tested, and free of third-party runtime dependencies.
9. **Global search clutter:** Two items per duplex device are intentional for speed. If real-world testing feels noisy, revise scope defaults before release rather than changing stable IDs later.

## 9. Open approval questions

Recommended defaults are first:

1. **Backend:** native Core Audio; no Homebrew runtime dependency.
2. **Bluetooth scope:** switch connected/available AirPods, but do not pair or force-connect disconnected devices.
3. **Global search:** include all eligible input/output items by default for one-step switching.
4. **Duplex devices:** show separate `AirPods — Input` and `AirPods — Output` items through role details/types, preserving independent actions.
5. **Sound effects:** route system alert sounds with the selected output by default, controlled by `RouteSoundEffectsWithOutput`.
6. **Combined switching:** defer “Use for Input & Output” to a later release because of Bluetooth quality warnings and rollback complexity.
7. **Distribution:** contribute to `tunaformac/TunaExtensions` rather than maintain a standalone extension.
8. **Identity:** confirm the user-visible extension name (`Audio Devices` recommended), author string, and reverse-DNS bundle identifier before scaffolding.

Implementation should begin only after these decisions are approved or revised.
