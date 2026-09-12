import Foundation
import TunaKit

@MainActor
public final class AudioDeviceActionsCatalog: NSObject, ActionCatalog {
  nonisolated static let useForOutputActionID = "use-for-output"
  nonisolated static let useForInputActionID = "use-for-input"
  nonisolated static let useForSoundEffectsActionID = "use-for-sound-effects"
  nonisolated static let hideDeviceActionID = "hide-device"
  nonisolated static let showDeviceActionID = "show-device"

  public let identifier: String
  public let name: String
  public private(set) lazy var actions: [CatalogAction] = Self.makeActions(library: library)

  let library: AudioDeviceLibrary

  public required convenience init(definition: ActionCatalogDefinition) {
    self.init(identifier: definition.identifier, name: definition.name, library: .shared)
  }

  init(identifier: String, name: String = "Audio Device Actions", library: AudioDeviceLibrary) {
    self.identifier = identifier
    self.name = name
    self.library = library
    super.init()
  }

  static func makeActions(library: AudioDeviceLibrary) -> [CatalogAction] {
    let useForOutput = PredicateAwareAction(
      id: useForOutputActionID, title: "Use for Sound Output", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? AudioDeviceItem, item.role == .output else {
        return .failure("Choose a sound output device")
      }
      return await library.useForOutput(item)
    }
    useForOutput.supportedSubjectTypes = [.audioOutputDevice]
    useForOutput.subjectPredicate = { ($0 as? AudioDeviceItem)?.role == .output }
    useForOutput.systemSymbolName = "speaker.wave.2"
    useForOutput.executionPolicy = .dismiss

    let useForInput = PredicateAwareAction(
      id: useForInputActionID, title: "Use for Sound Input", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? AudioDeviceItem, item.role == .input else {
        return .failure("Choose a sound input device")
      }
      return await library.useForInput(item)
    }
    useForInput.supportedSubjectTypes = [.audioInputDevice]
    useForInput.subjectPredicate = { ($0 as? AudioDeviceItem)?.role == .input }
    useForInput.systemSymbolName = "mic"
    useForInput.executionPolicy = .dismiss

    let useForSoundEffects = PredicateAwareAction(
      id: useForSoundEffectsActionID, title: "Use for Alert Sounds", headlessEligibility: .guaranteed
    ) { subject, _ in
      guard let item = subject as? AudioDeviceItem, item.role == .output,
        item.record.canBeSoundEffects
      else {
        return .failure("Choose a sound output device that can play alerts")
      }
      return await library.useForSoundEffects(item)
    }
    useForSoundEffects.supportedSubjectTypes = [.audioOutputDevice]
    useForSoundEffects.subjectPredicate = { subject in
      guard let item = subject as? AudioDeviceItem else { return false }
      return item.role == .output && item.record.canBeSoundEffects
    }
    useForSoundEffects.systemSymbolName = "bell"
    useForSoundEffects.executionPolicy = .dismiss

    let hide = PredicateAwareAction(id: hideDeviceActionID, title: "Hide from Tuna") {
      subject, _ in
      guard let item = subject as? AudioDeviceItem else { return .failure("Choose an audio device") }
      library.hide(itemID: item.id)
      return .success
    }
    hide.supportedSubjectTypes = [.audioOutputDevice, .audioInputDevice]
    hide.subjectPredicate = { ($0 as? AudioDeviceItem).map { !$0.isHidden } ?? false }
    hide.systemSymbolName = "eye.slash"
    hide.executionPolicy = .dismiss

    let show = PredicateAwareAction(id: showDeviceActionID, title: "Show in Tuna") { subject, _ in
      guard let item = subject as? AudioDeviceItem else { return .failure("Choose an audio device") }
      library.show(itemID: item.id)
      return .success
    }
    show.supportedSubjectTypes = [.audioOutputDevice, .audioInputDevice]
    show.subjectPredicate = { ($0 as? AudioDeviceItem)?.isHidden ?? false }
    show.systemSymbolName = "eye"
    show.executionPolicy = .dismiss

    return [useForOutput, useForInput, useForSoundEffects, hide, show]
  }
}
