import Foundation
import TunaKit

// MARK: - Roles and transports

/// The two user-facing roles a device item can represent. Each eligible device yields one item
/// per role it supports, so a duplex device (e.g. Loopback Audio) appears twice.
enum AudioDeviceRole: String, Sendable, CaseIterable, Hashable {
  case output
  case input

  var noun: String {
    switch self {
    case .output: "Output"
    case .input: "Input"
    }
  }
}

/// The three system defaults Core Audio exposes. Sound effects has no item of its own; it is
/// driven by output items and the `use-for-sound-effects` action.
enum AudioDefaultRole: String, Sendable, CaseIterable, Hashable {
  case input
  case output
  case soundEffects
}

enum AudioTransport: String, Sendable, Hashable {
  case builtIn
  case bluetooth
  case usb
  case display
  case thunderbolt
  case airPlay
  case virtual
  case aggregate
  case continuity
  case other

  /// Short label shown in item details and used as a search key.
  var label: String {
    switch self {
    case .builtIn: "Built-in"
    case .bluetooth: "Bluetooth"
    case .usb: "USB"
    case .display: "Display"
    case .thunderbolt: "Thunderbolt"
    case .airPlay: "AirPlay"
    case .virtual: "Virtual"
    case .aggregate: "Aggregate"
    case .continuity: "iPhone"
    case .other: "Other"
    }
  }
}

// MARK: - Records and snapshots

/// Immutable description of one Core Audio device at scan time. `objectID` is the transient
/// `AudioObjectID` and must never be used as identity; `uid` is the stable key.
struct AudioDeviceRecord: Sendable, Hashable {
  let uid: String
  let objectID: UInt32
  let name: String
  let manufacturer: String?
  let modelUID: String?
  let transport: AudioTransport
  let canBeInput: Bool
  let canBeOutput: Bool
  let canBeSoundEffects: Bool

  init(
    uid: String,
    objectID: UInt32 = 0,
    name: String,
    manufacturer: String? = nil,
    modelUID: String? = nil,
    transport: AudioTransport = .other,
    canBeInput: Bool = false,
    canBeOutput: Bool = false,
    canBeSoundEffects: Bool = false
  ) {
    self.uid = uid
    self.objectID = objectID
    self.name = name
    self.manufacturer = manufacturer
    self.modelUID = modelUID
    self.transport = transport
    self.canBeInput = canBeInput
    self.canBeOutput = canBeOutput
    self.canBeSoundEffects = canBeSoundEffects
  }

  /// A device is eligible when it can become at least one system default.
  var isEligible: Bool { canBeInput || canBeOutput }

  func supports(_ role: AudioDeviceRole) -> Bool {
    switch role {
    case .input: canBeInput
    case .output: canBeOutput
    }
  }

  /// Roles this device yields items for, in presentation order (output before input).
  var roles: [AudioDeviceRole] {
    AudioDeviceRole.allCases.filter(supports)
  }

  var isBluetooth: Bool { transport == .bluetooth }

  /// True for Apple AirPods, which warrant a headphones symbol and an "airpods" search key.
  var looksLikeAirPods: Bool {
    name.range(of: "airpods", options: .caseInsensitive) != nil
      || (modelUID?.range(of: "airpods", options: .caseInsensitive) != nil)
  }
}

/// One coherent read of the audio system: every eligible device plus the current defaults.
struct AudioDeviceSnapshot: Sendable, Equatable {
  let devices: [AudioDeviceRecord]
  let currentInputUID: String?
  let currentOutputUID: String?
  let currentSoundEffectsUID: String?

  init(
    devices: [AudioDeviceRecord],
    currentInputUID: String? = nil,
    currentOutputUID: String? = nil,
    currentSoundEffectsUID: String? = nil
  ) {
    self.devices = devices
    self.currentInputUID = currentInputUID
    self.currentOutputUID = currentOutputUID
    self.currentSoundEffectsUID = currentSoundEffectsUID
  }

  static let empty = AudioDeviceSnapshot(devices: [])

  func device(uid: String) -> AudioDeviceRecord? {
    devices.first { $0.uid == uid }
  }

  func devices(for role: AudioDeviceRole) -> [AudioDeviceRecord] {
    devices.filter { $0.supports(role) }
  }

  func currentUID(for role: AudioDefaultRole) -> String? {
    switch role {
    case .input: currentInputUID
    case .output: currentOutputUID
    case .soundEffects: currentSoundEffectsUID
    }
  }

  func isCurrent(uid: String, role: AudioDeviceRole) -> Bool {
    switch role {
    case .input: currentInputUID == uid
    case .output: currentOutputUID == uid
    }
  }

  func isCurrentSoundEffects(uid: String) -> Bool {
    currentSoundEffectsUID == uid
  }

  /// Stable presentation order: current device first within each role, outputs before inputs,
  /// then by name (case-insensitive), then by UID so equal names stay deterministic.
  func sortedEntries() -> [(device: AudioDeviceRecord, role: AudioDeviceRole)] {
    var entries: [(device: AudioDeviceRecord, role: AudioDeviceRole)] = []
    for role in AudioDeviceRole.allCases {
      let forRole = devices(for: role).sorted { lhs, rhs in
        let lhsCurrent = isCurrent(uid: lhs.uid, role: role)
        let rhsCurrent = isCurrent(uid: rhs.uid, role: role)
        if lhsCurrent != rhsCurrent { return lhsCurrent }
        let byName = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return lhs.uid < rhs.uid
      }
      entries.append(contentsOf: forRole.map { (device: $0, role: role) })
    }
    return entries
  }
}

// MARK: - Provider boundary

/// The only seam between the extension and Core Audio. `CoreAudioBackend` is the production
/// implementation; tests inject a fake. Setters are primitive (no verification); the
/// `AudioSwitchingService` owns resolve → set → read back.
protocol AudioDeviceProviding: AnyObject, Sendable {
  func snapshot() throws -> AudioDeviceSnapshot
  func currentUID(for role: AudioDefaultRole) throws -> String?
  func setDefault(_ role: AudioDefaultRole, uid: String) throws
  /// Registers listeners for the device list and all three defaults. The handler may be
  /// called on any thread and may be called in bursts; callers debounce.
  func startObservingChanges(_ handler: @escaping @Sendable () -> Void) throws
  func stopObservingChanges()
}

// MARK: - Errors and results

enum AudioSwitchError: Error, Equatable, LocalizedError {
  case noEligibleDevices(AudioDeviceRole)
  case deviceUnavailable(name: String)
  case roleNotSupported(name: String, role: AudioDefaultRole)
  case coreAudio(operation: String, status: Int32)
  case verificationTimedOut(name: String, role: AudioDefaultRole)
  case observationFailed(String)

  var errorDescription: String? {
    switch self {
    case .noEligibleDevices(let role):
      "No audio \(role.rawValue) devices are available"
    case .deviceUnavailable(let name):
      "\(name) is no longer available. Reconnect it and try again"
    case .roleNotSupported(let name, let role):
      "\(name) cannot be used for \(Self.describe(role))"
    case .coreAudio(let operation, let status):
      "Core Audio failed to \(operation) (error \(status))"
    case .verificationTimedOut(let name, let role):
      "macOS did not switch \(Self.describe(role)) to \(name)"
    case .observationFailed(let detail):
      "Audio device changes will not refresh automatically: \(detail)"
    }
  }

  static func describe(_ role: AudioDefaultRole) -> String {
    switch role {
    case .input: "sound input"
    case .output: "sound output"
    case .soundEffects: "alert sounds"
    }
  }
}

/// Outcome of a verified switch. `switchedWithoutSoundEffects` is the documented partial
/// failure: the main output changed but alerts did not follow.
enum AudioSwitchResult: Sendable, Equatable {
  case switched
  case alreadyCurrent
  case switchedWithoutSoundEffects(reason: String)
}

// MARK: - Type identifiers

extension TypeID {
  static let audioOutputDevice = TypeID("com.crosbyh.tuna.type.audio-output-device")
  static let audioInputDevice = TypeID("com.crosbyh.tuna.type.audio-input-device")

  static func audioDevice(for role: AudioDeviceRole) -> TypeID {
    switch role {
    case .output: .audioOutputDevice
    case .input: .audioInputDevice
    }
  }
}

// MARK: - Settings

enum AudioDevicesSettings {
  static let routeSoundEffectsWithOutput = CatalogSettingDefinition(
    key: "RouteSoundEffectsWithOutput",
    type: .bool,
    label: "Route alert sounds with output",
    defaultValue: "true",
    description:
      "When on, choosing a sound output also makes it the alert-sounds device. Turn off to pick a separate alerts device with “Use for Alert Sounds”."
  )

  static let hiddenDevices = CatalogSettingDefinition(
    key: "HiddenDevices",
    type: .string,
    label: "Hidden devices",
    defaultValue: "",
    description:
      "Device item IDs kept out of Tuna, one per line. Prefer the “Hide from Tuna” and “Show in Tuna” actions over editing this by hand."
  )

  static let definitions = [routeSoundEffectsWithOutput, hiddenDevices]

  static var store: CatalogSettingStore {
    CatalogSettingStore(catalogIdentifier: extensionIdentifier)
  }

  static var routesSoundEffectsWithOutput: Bool {
    store.boolValue(for: routeSoundEffectsWithOutput)
  }

  static var hiddenItemIDs: Set<String> {
    parseHiddenList(store.stringValue(for: hiddenDevices))
  }

  static func setHiddenItemIDs(_ ids: Set<String>) {
    store.setStringValue(serializeHiddenList(ids), for: hiddenDevices)
  }

  /// Newline-separated (commas tolerated), trimmed, blank lines dropped.
  static func parseHiddenList(_ raw: String) -> Set<String> {
    let parts = raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
    return Set(
      parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
  }

  static func serializeHiddenList(_ ids: Set<String>) -> String {
    ids.sorted().joined(separator: "\n")
  }

  static let extensionIdentifier: String = {
    let bundle = Bundle(for: AudioDevicesExtension.self)
    return bundle.bundleIdentifier
      ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "TunaAudioDevices")
  }()
}
