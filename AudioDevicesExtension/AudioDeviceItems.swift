import AppKit
import Foundation
import TunaKit

// MARK: - Stable item identity

/// `role:<percent-encoded UID>`. The encoding is reversible so the exact Core Audio UID can be
/// recovered, and the result is safe in hotkey bindings and `tuna://` URLs.
enum AudioDeviceItemID {
  private static let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._"))

  static func encode(role: AudioDeviceRole, uid: String) -> String {
    "\(role.rawValue):\(uid.addingPercentEncoding(withAllowedCharacters: allowed) ?? uid)"
  }

  static func decode(_ id: String) -> (role: AudioDeviceRole, uid: String)? {
    guard let separator = id.firstIndex(of: ":"),
      let role = AudioDeviceRole(rawValue: String(id[..<separator])),
      let uid = String(id[id.index(after: separator)...]).removingPercentEncoding,
      !uid.isEmpty
    else { return nil }
    return (role, uid)
  }
}

// MARK: - Copy

enum AudioDeviceCopy {
  static let bluetoothInputWarning = "microphone use may reduce playback quality"

  static func detail(
    record: AudioDeviceRecord, role: AudioDeviceRole, isCurrent: Bool, isCurrentSoundEffects: Bool
  ) -> String {
    var parts = [isCurrent ? "Current \(role.noun)" : role.noun]
    if role == .output, isCurrentSoundEffects { parts.append("Alerts") }
    parts.append(record.transport.label)
    var detail = parts.joined(separator: " · ")
    if role == .input, record.isBluetooth { detail += " — \(bluetoothInputWarning)" }
    return detail
  }

  static func searchKeys(record: AudioDeviceRecord, role: AudioDeviceRole) -> [String] {
    var keys = [record.name]
    if let manufacturer = record.manufacturer { keys.append(manufacturer) }
    if let model = record.modelUID { keys.append(model) }
    keys.append(record.transport.label)
    switch role {
    case .output: keys += ["output", "speaker", "speakers", "headphones"]
    case .input: keys += ["input", "microphone", "mic"]
    }
    if record.looksLikeAirPods { keys.append("airpods") }
    if record.isBluetooth { keys.append("bluetooth") }
    return keys
  }

  static func symbolName(record: AudioDeviceRecord, role: AudioDeviceRole) -> String {
    switch role {
    case .input: "mic.fill"
    case .output: (record.isBluetooth || record.looksLikeAirPods) ? "headphones" : "speaker.wave.2.fill"
    }
  }
}

// MARK: - Runnable device item

/// One `(device UID, role)` pair. Carries only immutable snapshot metadata; `run()` resolves the
/// live device through the library's switching service at execution time.
final class AudioDeviceItem: CatalogEntity, Runnable, @unchecked Sendable {
  let record: AudioDeviceRecord
  let role: AudioDeviceRole
  let isCurrent: Bool
  let isCurrentSoundEffects: Bool
  let isHidden: Bool
  private let library: AudioDeviceLibrary?

  init(
    record: AudioDeviceRecord,
    role: AudioDeviceRole,
    snapshot: AudioDeviceSnapshot,
    isHidden: Bool = false,
    library: AudioDeviceLibrary? = nil
  ) {
    self.record = record
    self.role = role
    self.isCurrent = snapshot.isCurrent(uid: record.uid, role: role)
    self.isCurrentSoundEffects = role == .output && snapshot.isCurrentSoundEffects(uid: record.uid)
    self.isHidden = isHidden
    self.library = library
    super.init(id: AudioDeviceItemID.encode(role: role, uid: record.uid), title: record.name, path: nil)
    typeID = .audioDevice(for: role)
  }

  var uid: String { record.uid }

  override var detail: String? {
    AudioDeviceCopy.detail(
      record: record, role: role, isCurrent: isCurrent, isCurrentSoundEffects: isCurrentSoundEffects)
  }

  override var searchKeys: [String] {
    AudioDeviceCopy.searchKeys(record: record, role: role)
  }

  var symbolName: String { AudioDeviceCopy.symbolName(record: record, role: role) }

  override func preview(maxDimension: CGFloat) -> CatalogItemPreview {
    .systemSymbol(symbolName, tintColor: isCurrent ? .controlAccentColor : .secondaryLabelColor)
  }

  override func placeholderPreview(maxDimension: CGFloat) -> CatalogItemPreview {
    preview(maxDimension: maxDimension)
  }

  // Switching is verified by readback before `.success` is returned and needs no UI, so the
  // item is safe to run from a hotkey with Tuna hidden.
  let headlessEligibility: CommandHeadlessEligibility = .guaranteed
  let executionPolicy: CommandExecutionPolicy = .dismiss

  func run() async -> ActionResult {
    guard let library else { return .failure("Audio Devices is not loaded") }
    switch role {
    case .output: return await library.useForOutput(self)
    case .input: return await library.useForInput(self)
    }
  }
}
