import AppKit
import Foundation
import TunaKit

// MARK: - Shared library

/// Owns the provider, the last snapshot, the built items, change observation, and the debounced
/// rescan fan-out. Both catalogs and the actions read from it so hardware is read once per scan.
@MainActor
final class AudioDeviceLibrary {
  static let shared = AudioDeviceLibrary(provider: CoreAudioBackend())

  let provider: any AudioDeviceProviding
  let switcher: AudioSwitchingService
  private(set) var snapshot: AudioDeviceSnapshot = .empty
  private(set) var hasLoaded = false
  private(set) var lastError: Error?
  private(set) var observationError: Error?
  private(set) var visibleItems: [AudioDeviceItem] = []
  private(set) var hiddenItems: [AudioDeviceItem] = []
  private(set) var isObserving = false

  var hiddenIDsReader: () -> Set<String>
  var hiddenIDsWriter: (Set<String>) -> Void
  var routesSoundEffectsWithOutput: () -> Bool
  let debounce: Duration

  private var rescanHandlers: [String: () -> Void] = [:]
  private var refreshTask: Task<Void, Never>?

  init(
    provider: any AudioDeviceProviding,
    switcher: AudioSwitchingService? = nil,
    debounce: Duration = .milliseconds(250),
    hiddenIDsReader: @escaping () -> Set<String> = { AudioDevicesSettings.hiddenItemIDs },
    hiddenIDsWriter: @escaping (Set<String>) -> Void = { AudioDevicesSettings.setHiddenItemIDs($0) },
    routesSoundEffectsWithOutput: @escaping () -> Bool = {
      AudioDevicesSettings.routesSoundEffectsWithOutput
    }
  ) {
    self.provider = provider
    self.switcher = switcher ?? AudioSwitchingService(provider: provider)
    self.debounce = debounce
    self.hiddenIDsReader = hiddenIDsReader
    self.hiddenIDsWriter = hiddenIDsWriter
    self.routesSoundEffectsWithOutput = routesSoundEffectsWithOutput
  }

  // MARK: Scanning

  /// Reads one coherent snapshot and rebuilds every item. Read-only; never writes defaults.
  func refresh() {
    do {
      snapshot = try provider.snapshot()
      lastError = nil
    } catch {
      snapshot = .empty
      lastError = error
    }
    hasLoaded = true
    rebuildItems()
    startObservingIfNeeded()
  }

  func refreshIfNeeded() {
    if !hasLoaded { refresh() }
  }

  private func rebuildItems() {
    let hidden = hiddenIDsReader()
    var visible: [AudioDeviceItem] = []
    var hiddenBuilt: [AudioDeviceItem] = []
    for entry in snapshot.sortedEntries() {
      let id = AudioDeviceItemID.encode(role: entry.role, uid: entry.device.uid)
      let item = AudioDeviceItem(
        record: entry.device, role: entry.role, snapshot: snapshot,
        isHidden: hidden.contains(id), library: self)
      if item.isHidden { hiddenBuilt.append(item) } else { visible.append(item) }
    }
    visibleItems = visible
    hiddenItems = hiddenBuilt
  }

  // MARK: Observation and rescans

  private func startObservingIfNeeded() {
    guard !isObserving else { return }
    do {
      try provider.startObservingChanges { [weak self] in
        Task { @MainActor [weak self] in self?.scheduleRescan() }
      }
      isObserving = true
      observationError = nil
    } catch {
      observationError = error
    }
  }

  func stopObserving() {
    guard isObserving else { return }
    provider.stopObservingChanges()
    isObserving = false
  }

  /// Coalesces Core Audio event bursts, then asks Tuna to rescan every registered catalog.
  func scheduleRescan() {
    refreshTask?.cancel()
    refreshTask = Task { [weak self] in
      guard let debounce = self?.debounce else { return }
      try? await Task.sleep(for: debounce)
      guard !Task.isCancelled else { return }
      self?.requestRescan()
    }
  }

  func requestRescan() {
    for handler in rescanHandlers.values { handler() }
  }

  func setRescanHandler(_ handler: (() -> Void)?, for catalogIdentifier: String) {
    rescanHandlers[catalogIdentifier] = handler
  }

  var registeredRescanHandlerCount: Int { rescanHandlers.values.count }

  // MARK: Hiding

  func hide(itemID: String) {
    var ids = hiddenIDsReader()
    ids.insert(itemID)
    hiddenIDsWriter(ids)
    rebuildItems()
    requestRescan()
  }

  func show(itemID: String) {
    var ids = hiddenIDsReader()
    ids.remove(itemID)
    hiddenIDsWriter(ids)
    rebuildItems()
    requestRescan()
  }

  // MARK: Switching (shared by items and actions)

  func useForOutput(_ item: AudioDeviceItem) async -> ActionResult {
    await perform(item) {
      try await switcher.useForOutput(
        uid: item.uid, name: item.record.name,
        routeSoundEffects: routesSoundEffectsWithOutput())
    }
  }

  func useForInput(_ item: AudioDeviceItem) async -> ActionResult {
    await perform(item) { try await switcher.useForInput(uid: item.uid, name: item.record.name) }
  }

  func useForSoundEffects(_ item: AudioDeviceItem) async -> ActionResult {
    await perform(item) {
      try await switcher.useForSoundEffects(uid: item.uid, name: item.record.name)
    }
  }

  private func perform(
    _ item: AudioDeviceItem, _ operation: () async throws -> AudioSwitchResult
  ) async -> ActionResult {
    do {
      let result = try await operation()
      // A no-op set fires no Core Audio event, so refresh labels ourselves either way.
      requestRescan()
      switch result {
      case .switched, .alreadyCurrent:
        return .success
      case .switchedWithoutSoundEffects(let reason):
        return .failure(
          "Sound output is now \(item.record.name), but alert sounds did not follow: \(reason)")
      }
    } catch {
      return .failure(error.localizedDescription)
    }
  }
}

// MARK: - Source catalog (global search)

@MainActor
public final class AudioDevicesCatalog: NSObject, Catalog, RescanSchedulingCatalog {
  static let hiddenBrowseItemID = "audio-devices.hidden"

  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)? {
    didSet { library.setRescanHandler(rescanHandler, for: identifier) }
  }
  public private(set) var objects: [CatalogItem] = []

  let library: AudioDeviceLibrary

  public required convenience init(definition: CatalogDefinition) {
    self.init(identifier: definition.identifier, name: definition.name, library: .shared)
  }

  init(identifier: String, name: String = "Audio Devices", library: AudioDeviceLibrary) {
    self.identifier = identifier
    self.name = name
    self.library = library
    super.init()
  }

  public func scan() async {
    library.refresh()
    objects = Self.makeObjects(library: library)
    reportScanFinished()
  }

  static func makeObjects(library: AudioDeviceLibrary) -> [CatalogItem] {
    var items: [CatalogItem] = library.visibleItems
    if items.isEmpty {
      if let error = library.lastError {
        items.append(
          CatalogMessageItem(
            title: "Audio devices unavailable",
            message: error.localizedDescription,
            symbolName: "exclamationmark.triangle",
            tintColor: .systemOrange))
      } else if library.hiddenItems.isEmpty {
        items.append(
          CatalogMessageItem(
            title: "No audio devices",
            message: "macOS reports no device that can be used for sound output or input.",
            symbolName: "speaker.slash",
            tintColor: .secondaryLabelColor))
      }
    }
    if !library.hiddenItems.isEmpty {
      items.append(
        BrowseCatalogItem(
          title: "Hidden Audio Devices",
          id: hiddenBrowseItemID,
          detail: "Devices you hid from Tuna; use “Show in Tuna” to bring one back",
          catalogIcon: .init(symbolName: "eye.slash", color: .gray),
          childrenProvider: { [library] in library.hiddenItems }))
    }
    return items
  }
}

// MARK: - Browse companion

@MainActor
public final class AudioDevicesBrowseCatalog: NSObject, Catalog, RescanSchedulingCatalog {
  static let rootItemID = "audio-devices.browse.root"
  static let outputsItemID = "audio-devices.browse.outputs"
  static let inputsItemID = "audio-devices.browse.inputs"

  public let identifier: String
  public let name: String
  public var rescanHandler: (() -> Void)? {
    didSet { library.setRescanHandler(rescanHandler, for: identifier) }
  }
  public var objects: [CatalogItem] { [root] }

  let library: AudioDeviceLibrary
  private lazy var root = Self.makeRoot(library: library)

  public required convenience init(definition: CatalogDefinition) {
    self.init(identifier: definition.identifier, name: definition.name, library: .shared)
  }

  init(identifier: String, name: String = "Audio Devices", library: AudioDeviceLibrary) {
    self.identifier = identifier
    self.name = name
    self.library = library
    super.init()
  }

  public func scan() async {
    library.refreshIfNeeded()
    reportScanFinished()
  }

  static func makeRoot(library: AudioDeviceLibrary) -> BrowseCatalogItem {
    BrowseCatalogItem(
      title: "Audio Devices",
      id: rootItemID,
      detail: "Sound outputs and inputs available right now",
      catalogIcon: .init(symbolName: "speaker.wave.2", color: .blue),
      childrenProvider: { [library] in
        [
          BrowseCatalogItem(
            title: "Sound Output",
            id: outputsItemID,
            detail: "Speakers, headphones, and other outputs",
            catalogIcon: .init(symbolName: "speaker.wave.2", color: .blue),
            childrenProvider: { [library] in library.visibleItems.filter { $0.role == .output } }),
          BrowseCatalogItem(
            title: "Sound Input",
            id: inputsItemID,
            detail: "Microphones and other inputs",
            catalogIcon: .init(symbolName: "mic", color: .teal),
            childrenProvider: { [library] in library.visibleItems.filter { $0.role == .input } }),
        ]
      })
  }
}
