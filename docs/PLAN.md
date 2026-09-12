# Audio Devices for Tuna — implementation plan

Status: **design approved 2026-09-11** (answers in § 7). Implementation proceeds through the
task sequence in § 6.

Source design: `docs/source-plan-2026-09-11.md` (from OpenCloud `outbox/`). This document
records what discovery confirmed or changed, the concrete decisions for *this* repo, and the
task sequence. Where the two disagree, this file wins.

---

## 1. Environment and baselines (verified)

| Item | Value |
| --- | --- |
| Dev Mac | macOS 26.6.2, Xcode 26.6 (SDK targets macOS 26.5), Apple Silicon |
| Tuna installed | 0.98 (`/Applications/Tuna.app`) |
| TunaKit pinned in TunaExtensions checkout | 1.22.0, `upToNextMinorVersion` |
| TunaExtensions checkout | `~/repos/TunaExtensions` on branch `add-vikunja-extension` (fork `crosbyh/TunaExtensions`) |
| Prior standalone extension (template) | `~/repos/vikunja-for-tuna` — bundle `com.crosbyh.tuna.vikunja`, product `TunaVikunja`, minTuna 0.96 / minTunaKit 1.22.0 / macOS 15 |
| `SwitchAudioSource` | present at `/opt/homebrew/bin` (comparison oracle only) |
| Typed Core Audio API | `usr/lib/swift/CoreAudio.swiftmodule` — all classes `@available(macOS 15.0, *)` |

TunaKit changelog facts that matter here: `Runnable.run()` and action callbacks are async
since 1.17.0; `CatalogDeclaration` requires `presentation:` since 1.21.0; `initialGlobalScope`
exists since 1.22.0 but its purpose is to keep a source *out* of global search, and no
first-party extension uses it. A plain `.source` catalog is already globally searchable, so
this design needs no 1.22-only symbol. Floors are therefore a policy choice (Q2), not a
technical one: first-party projects declare `minTuna "0.95" / minTunaKit "1.21.0"` while
pinning 1.22.0; Vikunja declares `0.96 / 1.22.0`.

## 2. Core Audio discovery — what the spike proved

`spike/enumerate-devices.swift` (read-only) ran against this Mac. Findings:

**The typed Swift API is sufficient. No C-level HAL property access is needed.**
`AudioHardwareDevice` (via `AudioHardwareClock`/`AudioHardwareObject`) exposes everything the
source plan wanted to fetch "narrowly" from the HAL:

| Need | Typed API member |
| --- | --- |
| stable identity | `uid` (throws) |
| display name / vendor | `name`, `manufacturer`, `modelUID`, `modelName` |
| transport | `transportType: UInt32` (compare with `kAudioDeviceTransportType*`) |
| visibility / liveness | `isHidden`, `isAlive` |
| role eligibility | `canBeDefaultInputDevice`, `canBeDefaultOutputDevice`, `canBeDefaultSoundEffectsDevice` |
| current defaults | `AudioHardwareSystem.shared.defaultInputDevice` / `defaultOutputDevice` / `defaultSoundEffectsDevice` |
| setters | `setDefaultInputDevice(_:)`, `setDefaultOutputDevice(_:)`, `setDefaultSoundEffectsDevice(_:)` |
| resolve UID → live device | `AudioHardwareSystem.shared.device(forUID:)` |
| change observation | `addListener(forProperties:dispatchQueue:)` + `delegates: [PropertyListenerDelegate]` + `removeListener(forProperties:)` |
| errors | `AudioHardwareError(OSStatus)` conforms to `LocalizedError` |

Consequence: the source plan's "one audited unsafe file" for HAL reads is dropped. The
backend stays entirely on public typed API. Every getter `throws`, so the backend treats a
throwing metadata read as "exclude this device" rather than crashing a scan.

**Device table on this Mac (2026-09-11):**

| Name | UID | Transport | In | Out | FX |
| --- | --- | --- | --- | --- | --- |
| cPods (AirPods Pro) | `74-3F-8E-C6-C4-A4:input` | bluetooth | yes | no | no |
| cPods (AirPods Pro) | `74-3F-8E-C6-C4-A4:output` | bluetooth | no | yes | yes |
| MacBook Pro Microphone | `BuiltInMicrophoneDevice` | builtin | yes | no | no |
| MacBook Pro Speakers | `BuiltInSpeakerDevice` | builtin | no | yes | yes |
| cPhone Microphone (Continuity) | `5BF0E647-…` | continuity-wired | yes | no | no |
| Loopback Audio | `com.rogueamoeba.Loopback::EA49…` | virtual | yes | yes | yes |
| Microsoft Teams Audio | `MSLoopbackDriverDevice_UID` | virtual | **no** | **no** | no |

**Switching spike (`spike/switch-devices.swift`, 2026-09-11, writes then restores):**

| Step | Result |
| --- | --- |
| output → built-in speakers → back to cPods | verified on first readback, 0.7 ms / 1.4 ms; one `dOut` event each |
| input → built-in mic → back to cPods | verified, 0.2 ms / 0.4 ms; one `dIn ` event each |
| sound effects → cPods → back to speakers | verified, 0.2 ms / 0.9 ms; one `sOut` event each |
| set output to the device that is already output | readback ok, **no event fired** |
| `device(forUID:)` for an unknown UID | returns `nil` (no throw) |
| `setDefaultOutputDevice` with an input-only device | **setter does not throw**, default unchanged, no event |
| originals restored | yes |

Design consequences: readback verification can use a short budget (10 × 50 ms is generous);
the catalog must request its own rescan after a verified switch because a no-op set fires no
listener event; and role eligibility must be checked before calling a setter, with readback
timeout as the backstop, because Core Audio refuses ineligible devices silently. Events are
delivered on Core Audio's queue (or the `dispatchQueue` passed to `addListener`), so the
backend hops to the main actor before scheduling a rescan.

Deltas from the source plan's assumptions:

1. **AirPods are two Core Audio devices, not one duplex device.** macOS exposes separate
   `:input` and `:output` devices sharing a name. The `(UID, role)` identity scheme still
   holds and yields exactly two items; the "duplex split" logic is still needed for genuinely
   duplex devices such as Loopback Audio.
2. **Eligibility filtering excludes devices `SwitchAudioSource` lists.** Microsoft Teams Audio
   reports `canBeDefault* == false` for every role and will not appear. That is correct per
   the design (never offer a device Core Audio will refuse), but it must be documented so it is
   not reported as a bug.
3. **Transport classification needs Continuity Camera cases.** `kAudioDeviceTransportType
   ContinuityCaptureWired/Wireless` should label as "iPhone" rather than "Unknown".
4. **`device(forUID:)` round-trips every UID** to the same object ID, so fresh-resolve-by-UID at
   execution time is a one-liner.
5. Listener registration and delivery through the delegate path work for the device list and
   all three default-device properties (see the switching spike above).

## 3. Decisions for this repo

These follow the conventions already established by `vikunja-for-tuna` unless a question in
§ 7 changes them.

| Decision | Choice |
| --- | --- |
| Distribution | Standalone repo `crosbyh/audio-devices-for-tuna` (public, GitHub) is upstream; `scripts/sync-to-tunaextensions` copies `AudioDevicesExtension/` into the `crosbyh/TunaExtensions` fork for the store PR. Same flow as Vikunja. |
| Backend | Native typed Core Audio. No Homebrew, no `SwitchAudioSource` at runtime. |
| Extension display name | **Audio Devices** |
| Bundle ID / product / module | `com.crosbyh.tuna.audio-devices` / `TunaAudioDevices` |
| Author | Crosby Hayton |
| Floors | minTuna `0.96`, minTunaKit `1.22.0`, `MACOSX_DEPLOYMENT_TARGET 15.0` |
| Type IDs | `com.crosbyh.tuna.type.audio-output-device`, `com.crosbyh.tuna.type.audio-input-device`, both inherit `.entity` |
| Catalog IDs | `audio-devices` (`.source`, default global scope, no `initialGlobalScope:` argument like every first-party catalog), `audio-devices.browse` (`.browseRoot(contents: "audio-devices")`), `audio-devices.actions` |
| Action IDs | `use-for-output`, `use-for-input`, `use-for-sound-effects`, `hide-device`, `show-device` |
| Settings | `RouteSoundEffectsWithOutput` (`.bool`, default `true`); `HiddenDevices` (`.string`, default empty; newline-separated item IDs maintained by the hide/show actions, hand-editable) |
| Item IDs | `output:<encoded-uid>` / `input:<encoded-uid>`, reversible encoding (see § 4.3) |
| Global search | every eligible, non-hidden item |
| Combined "input & output" action | deferred (source plan § 4.2) |
| License | MIT, © 2026 Crosby Hayton |

## 4. Design packet (delta view)

The full packet is § 4 of the source plan; only the parts that changed or got concrete are
restated here.

### 4.1 Provider boundary

```swift
protocol AudioDeviceProviding: Sendable {
  func snapshot() throws -> AudioDeviceSnapshot
  func setDefaultInput(uid: String) throws
  func setDefaultOutput(uid: String, includeSoundEffects: Bool) throws  // returns partial result
  func startObservingChanges(_ handler: @escaping @Sendable () -> Void) throws
  func stopObservingChanges()
}
```

`CoreAudioBackend` implements it with `AudioHardwareSystem.shared`. It is the only file that
imports `CoreAudio`. Readback verification lives in a role-agnostic helper: after a setter,
poll the matching `default*Device.uid` up to ~10 × 50 ms off the main actor; success only
when the observed UID equals the requested one. The test double replays scripted snapshots,
setter failures, delayed readback, and change events.

`AudioDeviceRecord` fields: `uid`, `objectID` (transient, never persisted), `name`,
`manufacturer`, `modelUID`, `transport: AudioTransport` (`builtIn, bluetooth, usb, display
(DisplayPort/HDMI), thunderbolt, airPlay, virtual, aggregate, continuity, other`),
`canBeInput`, `canBeOutput`, `canBeSoundEffects`. Snapshot also carries
`currentInputUID`, `currentOutputUID`, `currentSoundEffectsUID`.

Filtering rule: skip when `isHidden`, `!isAlive`, `uid` empty/throws, or neither role is
eligible.

### 4.2 Catalog

- `AudioDevicesCatalog` — `.source`, `initialGlobalScope: .all`, scans one snapshot and
  builds one item per eligible `(uid, role)`. Sort: current device first within role, then
  outputs before inputs, then by name (case-insensitive), then UID for determinism.
- Conforms to `RescanSchedulingCatalog`; on the first scan it starts observation once. Change
  events are debounced 250 ms with cancellation, then call the rescan handler. Observation is
  stopped in `deinit`. Scans never write.
- Browse companion `audio-devices.browse` is a `.browseRoot(contents:)` over the same catalog
  (no second hardware read). If the standard browse companion cannot group by role without
  duplicating items, ship the sorted flat list.
- **Hidden devices.** Items whose ID appears in the `HiddenDevices` setting are excluded from
  `objects`. When the hidden list is non-empty the catalog appends one
  `DeferredBrowseCatalogItem` titled "Hidden Audio Devices" (type `.searchCatalogEntry`, so it
  is navigation, not a device) whose children are the hidden items; those children accept only
  `show-device`. Hiding or showing writes the setting through `CatalogSettingStore` and calls
  `rescanHandler` so the list updates immediately. Hidden devices are never switched to
  implicitly; the setting only affects presentation.

### 4.3 Items

`AudioOutputDeviceItem` / `AudioInputDeviceItem` (both `CatalogItem` subclasses, `Runnable`):

- **ID encoding:** Core Audio UIDs on this Mac contain `:`, `-`, `.`, and `::`. Use
  `role + ":" + uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics ∪ "-._")` so
  the UID is exactly recoverable and the ID is safe in `tuna://` URLs and hotkey bindings. A
  unit test round-trips every UID from the discovery table.
- Title: device name. Detail: `Current Output · Bluetooth`, `Input · iPhone`, etc.; Bluetooth
  input adds `— microphone use may reduce playback quality`.
- Search keys: name, manufacturer, model, role words (`output speaker headphones` /
  `input microphone mic`), transport label, and `airpods` when the model UID or name matches.
- Symbols: output `speaker.wave.2.fill` (`headphones` when transport is Bluetooth), input
  `mic.fill`.
- `run()` resolves the UID against a fresh snapshot and calls the shared switching service.
  Headless eligibility is declared only after Task 6 tests pass.

### 4.4 Actions

`AudioDeviceActionsCatalog` declares, all with no target, dismiss-on-success, no ellipsis:

| ID | Title | Subject | Effect |
| --- | --- | --- | --- |
| `use-for-output` | Use for Sound Output | `.audioOutputDevice` | set output; also set sound effects when `RouteSoundEffectsWithOutput` is on and the device is eligible |
| `use-for-input` | Use for Sound Input | `.audioInputDevice` | set input |
| `use-for-sound-effects` | Use for Alert Sounds | `.audioOutputDevice` with `canBeSoundEffects` | set only the sound-effects device (the "separate alerts device" path). A later output switch overrides it while the route-with-output setting is on; the README says so |
| `hide-device` | Hide from Tuna | either device type, not hidden | append item ID to `HiddenDevices`, rescan |
| `show-device` | Show in Tuna | either device type, hidden | remove item ID from `HiddenDevices`, rescan |

Switch actions call the same `AudioSwitchingService` the items' `run()` uses. Default action
rankings put the matching switch action first per type, then alerts (output only), then
hide. Failure messages come from one `AudioSwitchError` enum (no eligible devices, device
vanished, role rejected, Core Audio `OSStatus`, readback timeout, partial sound-effects
failure, listener failure). Output item detail gains `· Alerts` when the device is also the
current sound-effects device.

### 4.5 TunaKit recipe notes (verified against the 1.22.0 interface and first-party sources)

- **Declaration:** `ExtensionDeclaration(metadata:compatibility:settings:catalogs:actionCatalogs:
  typeRegistrations:defaultActionRankings:)` exactly as `VikunjaExtension.swift`. Principal
  class is `@objc(AudioDevicesExtension) public final class AudioDevicesExtension: Extension`;
  `Info.plist` `NSPrincipalClass` is `$(PRODUCT_MODULE_NAME).AudioDevicesExtension`.
- **Catalog:** `@MainActor public final class AudioDevicesCatalog: NSObject, Catalog,
  RescanSchedulingCatalog` with `identifier`, `name`, `objects`, `required init(definition:)`,
  `func scan() async` ending in `reportScanFinished()`, and `public var rescanHandler:
  (() -> Void)?`. Debounce exactly like `Messages2FACatalog.scheduleRefresh()`: cancel the
  previous `Task`, `Task.sleep(for: .milliseconds(250))`, check `Task.isCancelled`, call
  `rescanHandler?()`. Core Audio delegate callbacks hop to the main actor before scheduling.
  A designated `init(identifier:name:provider:)` takes the injected provider; the required
  convenience init passes `CoreAudioBackend()`.
- **Items:** subclass `CatalogEntity` and conform to `Runnable` (the `ObsidianDailyNoteItem`
  shape), not `CommandItem`, because `detail`/`preview` must reflect current state and the
  item must carry the UID. Set `typeID` in `init`; override `detail`, `searchKeys`,
  `preview(maxDimension:)` returning `.systemSymbol(name, tintColor:)`, and
  `placeholderPreview`. Declare `headlessEligibility` (`.guaranteed` or `.requiresInterface`)
  and `executionPolicy = .dismiss`; `run() async -> ActionResult`.
- **Actions:** `PredicateAwareAction(id:title:) { subject, _ in … }` then set
  `supportedSubjectTypes`, `subjectPredicate`, `systemSymbolName`, `executionPolicy`.
  `targetRequirement` stays `.none`. Failures are `.failure("Short imperative sentence")`;
  thrown errors become `.failure(error.localizedDescription)`. Use `subjectPredicate` to hide
  the switch action on the already-current device if that reads better in testing.
- **Setting:** `CatalogSettingDefinition(key: "RouteSoundEffectsWithOutput", type: .bool,
  label:, defaultValue: "true", description:)`; read with `CatalogSettingStore(
  catalogIdentifier: <bundle identifier>).boolValue(for:)`.
- **Types:** `TypeRegistrationDefinition(typeID:displayName:inheritsFrom: [.entity])`.
  TunaKit also ships a built-in `.device` type; its generic actions are unknown, so stay on
  `.entity` unless testing shows `.device` adds something useful.
- **Tests:** XCTest only, `@testable import TunaAudioDevices`, `@MainActor` on catalog tests,
  inline `CatalogDefinition(identifier:name:enabledByDefault:settings: [])` fixtures, and a
  declaration test that calls `try declaration.validate()`.
- **Rule from the authoring skill:** never return `.success` before the work is verified.
  Readback verification is awaited inside `run()` and the action callbacks.

## 5. Repository layout (standalone, mirrors vikunja-for-tuna)

```text
audio-switcher-for-tuna/
├── AudioDevicesExtension/
│   ├── AudioDevicesExtension.swift          # declaration, principal class, TypeID ext
│   ├── AudioDeviceModels.swift              # records, snapshot, transport, errors, provider protocol
│   ├── CoreAudioBackend.swift               # only file importing CoreAudio
│   ├── AudioSwitchingService.swift          # resolve → set → verify → partial-failure reporting
│   ├── AudioDevicesCatalog.swift            # scan, sort, rescan scheduling, debounce
│   ├── AudioDeviceItems.swift               # item classes, ID codec, detail/search-key copy
│   ├── AudioDeviceActionsCatalog.swift
│   ├── AudioDevicesExtensionTests.swift     # + FakeAudioDeviceProvider
│   ├── AudioDevicesExtension.xcodeproj/
│   ├── Info.plist
│   └── icon.png
├── docs/PLAN.md, docs/source-plan-2026-09-11.md
├── spike/                                   # throwaway Core Audio evidence, not built
├── scripts/                                 # copied from vikunja-for-tuna, renamed
├── media/screenshots/
├── Makefile, README.md, CHANGELOG.md, LICENSE
```

The Xcode project is cloned from `VikunjaExtension.xcodeproj` (same author, team, TunaKit
pin, test target shape) and renamed; connection/API machinery is removed. `CoreAudio.framework`
links implicitly via `import CoreAudio`; no entitlements or usage strings are added.

## 6. Task sequence

Each task ends with a green `make test` and one commit. Tests are written before the code they
cover.

| # | Task | Output | Commit |
| --- | --- | --- | --- |
| 0 | ✅ `git init`, LICENSE, `.gitignore`, copy/rename scripts + Makefile from vikunja-for-tuna, GitHub repo | tooling in place | `chore: bootstrap repo from vikunja-for-tuna tooling` |
| 1 | ✅ Write spike: switch output/input/sound-effects natively, read back, confirm delegate events fire (done; AirPods UID stability across disconnect/reconnect and the `SwitchAudioSource` comparison are folded into Task 10 manual validation) | `spike/` notes in § 2 | `docs: record native switching spike results` |
| 2 | Clone + rename Xcode project, `Info.plist`, principal class, declaration; declaration tests (IDs, presentations, scope, settings, types, rankings, floors) | loads in Tuna, `make test` green | `feat: scaffold Audio Devices extension declaration` |
| 3 | Models, provider protocol, `FakeAudioDeviceProvider`; tests for eligibility, duplex split, current-state derivation, sort | | `test: define provider contract and fake backend` |
| 4 | `CoreAudioBackend` enumeration + defaults read; transport mapping + filtering tests on pure helpers | | `feat: enumerate Core Audio devices` |
| 5 | `AudioSwitchingService` + backend setters with bounded readback (output, input, sound-effects-only); tests for vanished device, role rejection, timeout, sound-effects partial failure, no-op on current | | `feat: switch and verify default devices` |
| 6 | Items + ID codec; tests for round-trip IDs, duplicate names, role separation, search keys, details (incl. `· Alerts`), symbols, Bluetooth copy; decide headless eligibility | | `feat: add runnable device items` |
| 7 | Catalog + rescan scheduling + debounce + hidden-device filtering and "Hidden Audio Devices" browse entry; tests with fake observer (250 ms, cancellation, single listener install, teardown) and hidden-list parsing | live refresh in Tuna | `feat: refresh on hardware changes` |
| 8 | Actions catalog + rankings (switch, alerts, hide/show); tests for subject types/predicates, no target, policies, failure copy, setting writes | | `feat: add device actions` |
| 9 | README (setup, privacy, Bluetooth limits, Teams-Audio exclusion, sound-effects setting), CHANGELOG 0.1, icon, screenshots | | `docs: document privacy and Bluetooth behavior` |
| 10 | Manual matrix (§ 7 of source plan) on this Mac: built-in, AirPods in/out, iPhone mic, Loopback, connect/disconnect, external changes, sleep/wake, hotkey survival; clean-account TCC check | evidence in README | `chore: record manual validation` |
| 11 | `sync-to-tunaextensions`, Release build + `make test` in the fork, open PR | store PR | — |

Estimated effort: tasks 0–2 half a day; 3–8 two to three days including hardware iteration;
9–11 one day.

## 7. Decisions (answered 2026-09-11)

1. **Naming.** Display name **Audio Devices**, bundle `com.crosbyh.tuna.audio-devices`, module
   `TunaAudioDevices`, folder `AudioDevicesExtension/`; repo renamed to
   `audio-devices-for-tuna` to match.
2. **Floors.** Tuna 0.96 / TunaKit 1.22.0 / macOS 15.0 (as Vikunja).
3. **Sound effects.** Route alerts with output by default (`RouteSoundEffectsWithOutput` on),
   and allow a separate alerts device via the `use-for-sound-effects` action.
4. **Global search.** All eligible items by default, with per-device hiding through the
   `hide-device` / `show-device` actions backed by the `HiddenDevices` setting (TunaKit
   settings are static declarations, so a dynamic per-device toggle has to be an action plus a
   list-valued setting rather than one checkbox per device).
5. **Distribution.** Standalone repo synced into the TunaExtensions fork, as Vikunja.
6. **Host.** GitHub, `crosbyh/audio-devices-for-tuna`, public like `vikunja-for-tuna`.
7. **Spike writes.** Approved to run unattended; the spike restores the original defaults.
