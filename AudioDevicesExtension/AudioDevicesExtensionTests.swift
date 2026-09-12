import Foundation
import TunaKit
import XCTest

@testable import TunaAudioDevices

// MARK: - Fake provider

final class FakeAudioDeviceProvider: AudioDeviceProviding, @unchecked Sendable {
  private let lock = NSLock()
  var snapshotResult: Result<AudioDeviceSnapshot, Error>
  var defaults: [AudioDefaultRole: String] = [:]
  var setErrors: [AudioDefaultRole: Error] = [:]
  /// Roles whose sets are silently ignored (Core Audio behaviour for ineligible devices).
  var ignoredRoles: Set<AudioDefaultRole> = []
  /// Number of `currentUID` reads before a set becomes visible (0 = immediately).
  var readsUntilApplied = 0
  private var pending: [AudioDefaultRole: (uid: String, remaining: Int)] = [:]
  private(set) var setCalls: [(role: AudioDefaultRole, uid: String)] = []
  private(set) var changeHandler: (@Sendable () -> Void)?
  private(set) var startCount = 0
  private(set) var stopCount = 0
  var startError: Error?

  init(snapshot: AudioDeviceSnapshot) {
    snapshotResult = .success(snapshot)
    defaults[.input] = snapshot.currentInputUID ?? ""
    defaults[.output] = snapshot.currentOutputUID ?? ""
    defaults[.soundEffects] = snapshot.currentSoundEffectsUID ?? ""
  }

  func snapshot() throws -> AudioDeviceSnapshot {
    lock.lock(); defer { lock.unlock() }
    return try snapshotResult.get()
  }

  func currentUID(for role: AudioDefaultRole) throws -> String? {
    lock.lock(); defer { lock.unlock() }
    if var entry = pending[role] {
      entry.remaining -= 1
      if entry.remaining <= 0 {
        pending[role] = nil
        defaults[role] = entry.uid
      } else {
        pending[role] = entry
      }
    }
    return defaults[role]
  }

  func setDefault(_ role: AudioDefaultRole, uid: String) throws {
    lock.lock(); defer { lock.unlock() }
    setCalls.append((role, uid))
    if let error = setErrors[role] { throw error }
    if ignoredRoles.contains(role) { return }
    if readsUntilApplied > 0 {
      pending[role] = (uid, readsUntilApplied)
    } else {
      defaults[role] = uid
    }
  }

  func startObservingChanges(_ handler: @escaping @Sendable () -> Void) throws {
    lock.lock(); defer { lock.unlock() }
    startCount += 1
    if let startError { throw startError }
    changeHandler = handler
  }

  func stopObservingChanges() {
    lock.lock(); defer { lock.unlock() }
    stopCount += 1
    changeHandler = nil
  }

  func fireChange() {
    lock.lock()
    let handler = changeHandler
    lock.unlock()
    handler?()
  }
}

// MARK: - Fixtures (the device table from discovery on 2026-09-11)

enum Fixtures {
  static let airPodsInput = AudioDeviceRecord(
    uid: "74-3F-8E-C6-C4-A4:input", objectID: 143, name: "cPods", manufacturer: "Apple Inc.",
    modelUID: "2027 4c", transport: .bluetooth, canBeInput: true)
  static let airPodsOutput = AudioDeviceRecord(
    uid: "74-3F-8E-C6-C4-A4:output", objectID: 137, name: "cPods", manufacturer: "Apple Inc.",
    modelUID: "2027 4c", transport: .bluetooth, canBeOutput: true, canBeSoundEffects: true)
  static let builtInMic = AudioDeviceRecord(
    uid: "BuiltInMicrophoneDevice", objectID: 122, name: "MacBook Pro Microphone",
    manufacturer: "Apple Inc.", modelUID: "Digital Mic", transport: .builtIn, canBeInput: true)
  static let builtInSpeakers = AudioDeviceRecord(
    uid: "BuiltInSpeakerDevice", objectID: 115, name: "MacBook Pro Speakers",
    manufacturer: "Apple Inc.", modelUID: "Speaker", transport: .builtIn, canBeOutput: true,
    canBeSoundEffects: true)
  static let iPhoneMic = AudioDeviceRecord(
    uid: "5BF0E647-02D7-4859-9B6F-A7CF00000003", objectID: 135, name: "cPhone Microphone",
    manufacturer: "Apple Inc.", modelUID: "iPhone Mic", transport: .continuity, canBeInput: true)
  static let loopback = AudioDeviceRecord(
    uid: "com.rogueamoeba.Loopback::EA497782-AD2E-46F5-AC23-09D3121A50D5", objectID: 127,
    name: "Loopback Audio", manufacturer: "Rogue Amoeba Software, Inc.",
    modelUID: "com.rogueamoeba.ARK.driver", transport: .virtual, canBeInput: true,
    canBeOutput: true, canBeSoundEffects: true)

  static let all = [airPodsInput, airPodsOutput, builtInMic, builtInSpeakers, iPhoneMic, loopback]

  static func snapshot(
    devices: [AudioDeviceRecord] = all,
    input: String? = airPodsInput.uid,
    output: String? = airPodsOutput.uid,
    soundEffects: String? = builtInSpeakers.uid
  ) -> AudioDeviceSnapshot {
    AudioDeviceSnapshot(
      devices: devices, currentInputUID: input, currentOutputUID: output,
      currentSoundEffectsUID: soundEffects)
  }
}

@MainActor
private func makeLibrary(
  provider: FakeAudioDeviceProvider,
  hidden: Set<String> = [],
  routeSoundEffects: Bool = true,
  debounce: Duration = .milliseconds(20)
) -> (AudioDeviceLibrary, HiddenStore) {
  let store = HiddenStore(ids: hidden)
  let library = AudioDeviceLibrary(
    provider: provider,
    switcher: AudioSwitchingService(provider: provider, sleep: { _ in }),
    debounce: debounce,
    hiddenIDsReader: { store.ids },
    hiddenIDsWriter: { store.ids = $0 },
    routesSoundEffectsWithOutput: { routeSoundEffects })
  return (library, store)
}

final class HiddenStore: @unchecked Sendable {
  var ids: Set<String>
  init(ids: Set<String>) { self.ids = ids }
}

// MARK: - Declaration

@MainActor
final class AudioDevicesDeclarationTests: XCTestCase {
  func testDeclarationDeclaresStableIdentifiers() throws {
    let ext = try AudioDevicesExtension(bundle: Bundle(for: AudioDevicesExtension.self))
    let declaration = try XCTUnwrap(ext.declaration)
    try declaration.validate()

    XCTAssertEqual(declaration.metadata.displayName, "Audio Devices")
    XCTAssertEqual(declaration.catalogs.map(\.id), ["audio-devices", "audio-devices.browse"])
    XCTAssertEqual(declaration.catalogs[0].presentation, .source)
    XCTAssertEqual(declaration.catalogs[1].presentation, .browseRoot(contents: "audio-devices"))
    XCTAssertTrue(declaration.catalogs.allSatisfy(\.enabledByDefault))
    XCTAssertEqual(declaration.catalogs[0].initialGlobalScope, .all, "items must be in global search")
    XCTAssertEqual(declaration.catalogs[1].initialGlobalScope, .none)
    XCTAssertEqual(declaration.actionCatalogs.map(\.id), ["audio-devices.actions"])
    XCTAssertEqual(declaration.compatibility?.minTuna, "0.96")
    XCTAssertEqual(declaration.compatibility?.minTunaKit, "1.22.0")
    XCTAssertEqual(
      declaration.settings.map(\.key), ["RouteSoundEffectsWithOutput", "HiddenDevices"])
    XCTAssertEqual(declaration.settings[0].type, .bool)
    XCTAssertEqual(declaration.settings[0].defaultValue, "true")
    XCTAssertEqual(declaration.settings[1].type, .string)
    XCTAssertEqual(
      Set(declaration.typeRegistrations.map(\.typeID)), [.audioOutputDevice, .audioInputDevice])
    XCTAssertTrue(declaration.typeRegistrations.allSatisfy { $0.inheritsFrom == [.entity] })
    XCTAssertEqual(
      declaration.defaultActionRankings.map(\.typeID), [.audioOutputDevice, .audioInputDevice])
    XCTAssertEqual(
      declaration.defaultActionRankings[0].actions.map(\.actionID),
      ["use-for-output", "use-for-sound-effects", "hide-device"])
    XCTAssertEqual(
      declaration.defaultActionRankings[1].actions.map(\.actionID), ["use-for-input", "hide-device"])
    XCTAssertTrue(
      declaration.defaultActionRankings.flatMap(\.actions).allSatisfy {
        $0.catalogIdentifier == "audio-devices.actions"
      })
  }

  func testTypeIdentifiersAreStable() {
    XCTAssertEqual(TypeID.audioOutputDevice, TypeID("com.crosbyh.tuna.type.audio-output-device"))
    XCTAssertEqual(TypeID.audioInputDevice, TypeID("com.crosbyh.tuna.type.audio-input-device"))
  }
}

// MARK: - Models

final class AudioDeviceModelTests: XCTestCase {
  func testEligibilityAndRoles() {
    XCTAssertEqual(Fixtures.airPodsInput.roles, [.input])
    XCTAssertEqual(Fixtures.airPodsOutput.roles, [.output])
    XCTAssertEqual(Fixtures.loopback.roles, [.output, .input])
    let teams = AudioDeviceRecord(uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio")
    XCTAssertFalse(teams.isEligible)
    XCTAssertTrue(teams.roles.isEmpty)
  }

  func testSnapshotDerivesCurrentState() {
    let snapshot = Fixtures.snapshot()
    XCTAssertTrue(snapshot.isCurrent(uid: Fixtures.airPodsOutput.uid, role: .output))
    XCTAssertFalse(snapshot.isCurrent(uid: Fixtures.airPodsOutput.uid, role: .input))
    XCTAssertTrue(snapshot.isCurrent(uid: Fixtures.airPodsInput.uid, role: .input))
    XCTAssertTrue(snapshot.isCurrentSoundEffects(uid: Fixtures.builtInSpeakers.uid))
    XCTAssertEqual(snapshot.devices(for: .output).map(\.uid).count, 3)
    XCTAssertEqual(snapshot.devices(for: .input).map(\.uid).count, 4)
    XCTAssertNil(snapshot.device(uid: "missing"))
  }

  func testSortedEntriesPutCurrentFirstOutputsBeforeInputsThenNameThenUID() {
    let dupA = AudioDeviceRecord(uid: "dup-b", name: "USB Audio", transport: .usb, canBeOutput: true)
    let dupB = AudioDeviceRecord(uid: "dup-a", name: "usb audio", transport: .usb, canBeOutput: true)
    let snapshot = Fixtures.snapshot(devices: Fixtures.all + [dupA, dupB])
    let entries = snapshot.sortedEntries()
    let outputs = entries.filter { $0.role == .output }
    let inputs = entries.filter { $0.role == .input }
    XCTAssertEqual(entries.count, outputs.count + inputs.count)
    XCTAssertEqual(entries.prefix(outputs.count).map(\.role), Array(repeating: .output, count: outputs.count))
    XCTAssertEqual(outputs.first?.device.uid, Fixtures.airPodsOutput.uid, "current output first")
    XCTAssertEqual(inputs.first?.device.uid, Fixtures.airPodsInput.uid, "current input first")
    XCTAssertEqual(
      outputs.dropFirst().map(\.device.name),
      ["Loopback Audio", "MacBook Pro Speakers", "usb audio", "USB Audio"])
    XCTAssertEqual(outputs.suffix(2).map(\.device.uid), ["dup-a", "dup-b"], "equal names sort by UID")
  }

  func testHiddenListRoundTrip() {
    XCTAssertEqual(AudioDevicesSettings.parseHiddenList(""), [])
    XCTAssertEqual(
      AudioDevicesSettings.parseHiddenList("output:a\n\n input:b ,output:c\n"),
      ["output:a", "input:b", "output:c"])
    let ids: Set<String> = ["output:b", "input:a"]
    XCTAssertEqual(AudioDevicesSettings.serializeHiddenList(ids), "input:a\noutput:b")
    XCTAssertEqual(
      AudioDevicesSettings.parseHiddenList(AudioDevicesSettings.serializeHiddenList(ids)), ids)
  }
}

// MARK: - Item identity and copy

final class AudioDeviceItemTests: XCTestCase {
  func testItemIDRoundTripsEveryKnownUID() {
    for record in Fixtures.all {
      for role in AudioDeviceRole.allCases {
        let id = AudioDeviceItemID.encode(role: role, uid: record.uid)
        XCTAssertTrue(id.hasPrefix("\(role.rawValue):"))
        XCTAssertFalse(id.contains(" "))
        XCTAssertEqual(id.filter { $0 == ":" }.count, 1, "only the role separator survives: \(id)")
        let decoded = AudioDeviceItemID.decode(id)
        XCTAssertEqual(decoded?.role, role)
        XCTAssertEqual(decoded?.uid, record.uid)
      }
    }
    XCTAssertEqual(
      AudioDeviceItemID.encode(role: .output, uid: "74-3F-8E-C6-C4-A4:output"),
      "output:74-3F-8E-C6-C4-A4%3Aoutput")
    XCTAssertNil(AudioDeviceItemID.decode("bogus:x"))
    XCTAssertNil(AudioDeviceItemID.decode("output:"))
    XCTAssertNil(AudioDeviceItemID.decode("no-separator"))
  }

  func testDuplexDeviceYieldsDistinctItemsAndSameNameDifferentUIDsStayDistinct() {
    let snapshot = Fixtures.snapshot()
    let out = AudioDeviceItem(record: Fixtures.loopback, role: .output, snapshot: snapshot)
    let inp = AudioDeviceItem(record: Fixtures.loopback, role: .input, snapshot: snapshot)
    XCTAssertNotEqual(out.id, inp.id)
    XCTAssertEqual(out.typeID, .audioOutputDevice)
    XCTAssertEqual(inp.typeID, .audioInputDevice)
    let podsOut = AudioDeviceItem(record: Fixtures.airPodsOutput, role: .output, snapshot: snapshot)
    let podsIn = AudioDeviceItem(record: Fixtures.airPodsInput, role: .input, snapshot: snapshot)
    XCTAssertEqual(podsOut.title, podsIn.title)
    XCTAssertNotEqual(podsOut.id, podsIn.id)
  }

  func testDetailsSymbolsAndSearchKeys() {
    let snapshot = Fixtures.snapshot()
    let podsOut = AudioDeviceItem(record: Fixtures.airPodsOutput, role: .output, snapshot: snapshot)
    XCTAssertEqual(podsOut.detail, "Current Output · Bluetooth")
    XCTAssertEqual(podsOut.symbolName, "headphones")
    XCTAssertTrue(podsOut.isCurrent)
    XCTAssertFalse(podsOut.isCurrentSoundEffects)

    let podsIn = AudioDeviceItem(record: Fixtures.airPodsInput, role: .input, snapshot: snapshot)
    XCTAssertEqual(
      podsIn.detail, "Current Input · Bluetooth — microphone use may reduce playback quality")
    XCTAssertEqual(podsIn.symbolName, "mic.fill")
    XCTAssertTrue(podsIn.searchKeys.contains("bluetooth"))
    XCTAssertTrue(podsIn.searchKeys.contains("microphone"))

    let speakers = AudioDeviceItem(record: Fixtures.builtInSpeakers, role: .output, snapshot: snapshot)
    XCTAssertEqual(speakers.detail, "Output · Alerts · Built-in")
    XCTAssertEqual(speakers.symbolName, "speaker.wave.2.fill")
    XCTAssertTrue(speakers.isCurrentSoundEffects)
    XCTAssertEqual(
      Set(speakers.searchKeys).intersection(["MacBook Pro Speakers", "Apple Inc.", "Speaker", "Built-in", "output", "speakers", "headphones"]).count, 7)

    let phone = AudioDeviceItem(record: Fixtures.iPhoneMic, role: .input, snapshot: snapshot)
    XCTAssertEqual(phone.detail, "Input · iPhone")

    let named = AudioDeviceRecord(uid: "x", name: "Crosby’s AirPods Pro", transport: .bluetooth, canBeOutput: true)
    let namedItem = AudioDeviceItem(record: named, role: .output, snapshot: snapshot)
    XCTAssertTrue(namedItem.searchKeys.contains("airpods"))
    XCTAssertEqual(namedItem.symbolName, "headphones")

    XCTAssertEqual(podsOut.headlessEligibility, .guaranteed)
    XCTAssertEqual(podsOut.executionPolicy, .dismiss)
  }

  func testRunWithoutLibraryFailsInsteadOfPretendingSuccess() async {
    let item = AudioDeviceItem(record: Fixtures.builtInSpeakers, role: .output, snapshot: Fixtures.snapshot())
    guard case .failure = await item.run() else { return XCTFail("expected failure") }
  }
}

// MARK: - Switching service

final class AudioSwitchingServiceTests: XCTestCase {
  private func makeService(_ provider: FakeAudioDeviceProvider, attempts: Int = 3)
    -> AudioSwitchingService
  {
    AudioSwitchingService(provider: provider, readbackAttempts: attempts, sleep: { _ in })
  }

  func testOutputSwitchRoutesSoundEffectsWhenEnabled() async throws {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let result = try await makeService(provider).useForOutput(
      uid: Fixtures.builtInSpeakers.uid, name: "MacBook Pro Speakers", routeSoundEffects: true)
    XCTAssertEqual(result, .switched)
    XCTAssertEqual(provider.setCalls.map(\.role), [.output])
    XCTAssertEqual(try provider.currentUID(for: .output), Fixtures.builtInSpeakers.uid)
    XCTAssertEqual(try provider.currentUID(for: .soundEffects), Fixtures.builtInSpeakers.uid, "already alerts device: no second write")

    let toPods = try await makeService(provider).useForOutput(
      uid: Fixtures.airPodsOutput.uid, name: "cPods", routeSoundEffects: true)
    XCTAssertEqual(toPods, .switched)
    XCTAssertEqual(provider.setCalls.map(\.role), [.output, .output, .soundEffects])
    XCTAssertEqual(try provider.currentUID(for: .soundEffects), Fixtures.airPodsOutput.uid)
  }

  func testOutputSwitchLeavesSoundEffectsAloneWhenDisabled() async throws {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let result = try await makeService(provider).useForOutput(
      uid: Fixtures.loopback.uid, name: "Loopback Audio", routeSoundEffects: false)
    XCTAssertEqual(result, .switched)
    XCTAssertEqual(provider.setCalls.map(\.role), [.output])
    XCTAssertEqual(try provider.currentUID(for: .soundEffects), Fixtures.builtInSpeakers.uid)
  }

  func testAlreadyCurrentIsANoOpWithoutWrites() async throws {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let result = try await makeService(provider).useForInput(
      uid: Fixtures.airPodsInput.uid, name: "cPods")
    XCTAssertEqual(result, .alreadyCurrent)
    XCTAssertTrue(provider.setCalls.isEmpty)
  }

  func testVanishedDeviceFails() async {
    let provider = FakeAudioDeviceProvider(
      snapshot: Fixtures.snapshot(devices: [Fixtures.builtInMic, Fixtures.builtInSpeakers]))
    do {
      _ = try await makeService(provider).useForOutput(
        uid: Fixtures.airPodsOutput.uid, name: "cPods", routeSoundEffects: true)
      XCTFail("expected failure")
    } catch let error as AudioSwitchError {
      XCTAssertEqual(error, .deviceUnavailable(name: "cPods"))
      XCTAssertEqual(error.localizedDescription, "cPods is no longer available. Reconnect it and try again")
    } catch { XCTFail("unexpected \(error)") }
    XCTAssertTrue(provider.setCalls.isEmpty)
  }

  func testRoleRejectionHappensBeforeAnyWrite() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    do {
      _ = try await makeService(provider).useForInput(
        uid: Fixtures.builtInSpeakers.uid, name: "MacBook Pro Speakers")
      XCTFail("expected failure")
    } catch let error as AudioSwitchError {
      XCTAssertEqual(error, .roleNotSupported(name: "MacBook Pro Speakers", role: .input))
    } catch { XCTFail("unexpected \(error)") }
    do {
      _ = try await makeService(provider).useForSoundEffects(
        uid: Fixtures.builtInMic.uid, name: "MacBook Pro Microphone")
      XCTFail("expected failure")
    } catch let error as AudioSwitchError {
      XCTAssertEqual(error, .roleNotSupported(name: "MacBook Pro Microphone", role: .soundEffects))
    } catch { XCTFail("unexpected \(error)") }
    XCTAssertTrue(provider.setCalls.isEmpty)
  }

  func testDelayedReadbackIsRetriedThenVerified() async throws {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    provider.readsUntilApplied = 2
    let result = try await makeService(provider, attempts: 3).useForInput(
      uid: Fixtures.builtInMic.uid, name: "MacBook Pro Microphone")
    XCTAssertEqual(result, .switched)
  }

  func testSilentlyIgnoredSetTimesOutInsteadOfSucceeding() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    provider.ignoredRoles = [.input]
    do {
      _ = try await makeService(provider, attempts: 2).useForInput(
        uid: Fixtures.builtInMic.uid, name: "MacBook Pro Microphone")
      XCTFail("expected timeout")
    } catch let error as AudioSwitchError {
      XCTAssertEqual(error, .verificationTimedOut(name: "MacBook Pro Microphone", role: .input))
    } catch { XCTFail("unexpected \(error)") }
  }

  func testSoundEffectsFailureAfterOutputSuccessIsPartial() async throws {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    provider.setErrors[.soundEffects] = AudioSwitchError.coreAudio(operation: "set the alert sounds device", status: -50)
    let result = try await makeService(provider).useForOutput(
      uid: Fixtures.loopback.uid, name: "Loopback Audio", routeSoundEffects: true)
    guard case .switchedWithoutSoundEffects(let reason) = result else {
      return XCTFail("expected partial failure, got \(result)")
    }
    XCTAssertTrue(reason.contains("error -50"))
    XCTAssertEqual(try provider.currentUID(for: .output), Fixtures.loopback.uid)
    XCTAssertEqual(try provider.currentUID(for: .soundEffects), Fixtures.builtInSpeakers.uid)
  }

  func testCoreAudioSetterErrorPropagates() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    provider.setErrors[.output] = AudioSwitchError.coreAudio(operation: "set the sound output device", status: 1852797029)
    do {
      _ = try await makeService(provider).useForOutput(
        uid: Fixtures.builtInSpeakers.uid, name: "MacBook Pro Speakers", routeSoundEffects: true)
      XCTFail("expected failure")
    } catch let error as AudioSwitchError {
      XCTAssertEqual(error, .coreAudio(operation: "set the sound output device", status: 1852797029))
    } catch { XCTFail("unexpected \(error)") }
  }
}

// MARK: - Library and catalogs

@MainActor
final class AudioDevicesCatalogTests: XCTestCase {
  func testScanBuildsOneItemPerEligibleUIDAndRole() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let (library, _) = makeLibrary(provider: provider)
    let catalog = AudioDevicesCatalog(identifier: "audio-devices", library: library)
    await catalog.scan()

    let items = catalog.objects.compactMap { $0 as? AudioDeviceItem }
    XCTAssertEqual(items.count, 7, "3 outputs + 4 inputs")
    XCTAssertEqual(Set(items.map(\.id)).count, 7)
    XCTAssertEqual(items.filter { $0.role == .output }.count, 3)
    XCTAssertEqual(items.first?.id, AudioDeviceItemID.encode(role: .output, uid: Fixtures.airPodsOutput.uid))
    XCTAssertEqual(catalog.objects.count, 7, "no hidden node when nothing is hidden")
    XCTAssertEqual(provider.startCount, 1)
    XCTAssertTrue(library.isObserving)

    await catalog.scan()
    XCTAssertEqual(provider.startCount, 1, "listeners are installed once")
  }

  func testEmptyAndErrorStates() async {
    let empty = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot(devices: []))
    let (emptyLibrary, _) = makeLibrary(provider: empty)
    let emptyCatalog = AudioDevicesCatalog(identifier: "audio-devices", library: emptyLibrary)
    await emptyCatalog.scan()
    XCTAssertEqual(emptyCatalog.objects.count, 1)
    XCTAssertEqual((emptyCatalog.objects.first as? CatalogMessageItem)?.title, "No audio devices")

    let failing = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    failing.snapshotResult = .failure(AudioSwitchError.coreAudio(operation: "list audio devices", status: -1))
    let (failingLibrary, _) = makeLibrary(provider: failing)
    let failingCatalog = AudioDevicesCatalog(identifier: "audio-devices", library: failingLibrary)
    await failingCatalog.scan()
    let message = failingCatalog.objects.first as? CatalogMessageItem
    XCTAssertEqual(message?.title, "Audio devices unavailable")
    XCTAssertNotNil(failingLibrary.lastError)
  }

  func testHiddenDevicesLeaveSearchAndReturnViaShow() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let hiddenID = AudioDeviceItemID.encode(role: .input, uid: Fixtures.loopback.uid)
    let (library, store) = makeLibrary(provider: provider, hidden: [hiddenID])
    let catalog = AudioDevicesCatalog(identifier: "audio-devices", library: library)
    var rescans = 0
    catalog.rescanHandler = { rescans += 1 }
    await catalog.scan()

    XCTAssertEqual(catalog.objects.compactMap { $0 as? AudioDeviceItem }.count, 6)
    let node = try? XCTUnwrap(catalog.objects.last as? BrowseCatalogItem)
    XCTAssertEqual(node?.id, "audio-devices.hidden")
    XCTAssertEqual(node?.typeID, .searchCatalogEntry)
    let hidden = node?.hierarchyChildren().compactMap { $0 as? AudioDeviceItem } ?? []
    XCTAssertEqual(hidden.map(\.id), [hiddenID])
    XCTAssertTrue(hidden[0].isHidden)

    library.show(itemID: hiddenID)
    XCTAssertEqual(store.ids, [])
    XCTAssertEqual(rescans, 1)
    XCTAssertEqual(library.visibleItems.count, 7)

    library.hide(itemID: hidden[0].id)
    XCTAssertEqual(store.ids, [hiddenID])
    XCTAssertEqual(rescans, 2)
    XCTAssertEqual(library.hiddenItems.map(\.id), [hiddenID])
  }

  func testChangeEventsAreDebouncedIntoOneRescan() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let (library, _) = makeLibrary(provider: provider, debounce: .milliseconds(30))
    let catalog = AudioDevicesCatalog(identifier: "audio-devices", library: library)
    let browse = AudioDevicesBrowseCatalog(identifier: "audio-devices.browse", library: library)
    var catalogRescans = 0
    var browseRescans = 0
    catalog.rescanHandler = { catalogRescans += 1 }
    browse.rescanHandler = { browseRescans += 1 }
    await catalog.scan()

    provider.fireChange()
    provider.fireChange()
    provider.fireChange()
    try? await Task.sleep(for: .milliseconds(120))
    XCTAssertEqual(catalogRescans, 1)
    XCTAssertEqual(browseRescans, 1)

    library.stopObserving()
    XCTAssertEqual(provider.stopCount, 1)
    XCTAssertFalse(library.isObserving)
  }

  func testObservationFailureKeepsCatalogUsable() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    provider.startError = AudioSwitchError.observationFailed("Core Audio error 1852797029")
    let (library, _) = makeLibrary(provider: provider)
    let catalog = AudioDevicesCatalog(identifier: "audio-devices", library: library)
    await catalog.scan()
    XCTAssertEqual(catalog.objects.compactMap { $0 as? AudioDeviceItem }.count, 7)
    XCTAssertFalse(library.isObserving)
    XCTAssertNotNil(library.observationError)
  }

  func testBrowseCompanionGroupsByRoleWithoutASecondHardwareRead() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let (library, _) = makeLibrary(provider: provider)
    let source = AudioDevicesCatalog(identifier: "audio-devices", library: library)
    let browse = AudioDevicesBrowseCatalog(identifier: "audio-devices.browse", library: library)
    await source.scan()
    await browse.scan()

    let root = try? XCTUnwrap(browse.objects.first as? BrowseCatalogItem)
    XCTAssertEqual(root?.typeID, .searchCatalogEntry)
    let groups = root?.hierarchyChildren().compactMap { $0 as? BrowseCatalogItem } ?? []
    XCTAssertEqual(groups.map(\.title), ["Sound Output", "Sound Input"])
    XCTAssertEqual(groups[0].hierarchyChildren().count, 3)
    XCTAssertEqual(groups[1].hierarchyChildren().count, 4)
    XCTAssertEqual((groups[0].hierarchyChildren().first as? AudioDeviceItem)?.isCurrent, true)
  }

  func testRunOnItemSwitchesAndRequestsRescan() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let (library, _) = makeLibrary(provider: provider)
    let catalog = AudioDevicesCatalog(identifier: "audio-devices", library: library)
    var rescans = 0
    catalog.rescanHandler = { rescans += 1 }
    await catalog.scan()
    let speakers = try? XCTUnwrap(
      catalog.objects.compactMap { $0 as? AudioDeviceItem }.first {
        $0.uid == Fixtures.builtInSpeakers.uid && $0.role == .output
      })
    let result = await speakers?.run()
    guard case .success = result else { return XCTFail("expected success, got \(String(describing: result))") }
    XCTAssertEqual(try provider.currentUID(for: .output), Fixtures.builtInSpeakers.uid)
    XCTAssertEqual(rescans, 1)

    let pods = catalog.objects.compactMap { $0 as? AudioDeviceItem }.first { $0.uid == Fixtures.airPodsInput.uid }
    guard case .success = await pods!.run() else { return XCTFail("no-op on current input should succeed") }
    XCTAssertEqual(rescans, 2)
  }

  func testPartialSoundEffectsFailureSurfacesAsFailureMessage() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    provider.setErrors[.soundEffects] = AudioSwitchError.coreAudio(operation: "set the alert sounds device", status: -50)
    let (library, _) = makeLibrary(provider: provider)
    let item = AudioDeviceItem(record: Fixtures.loopback, role: .output, snapshot: Fixtures.snapshot(), library: library)
    guard case .failure(let message) = await item.run() else { return XCTFail("expected failure") }
    XCTAssertEqual(message, "Sound output is now Loopback Audio, but alert sounds did not follow: Core Audio failed to set the alert sounds device (error -50)")
  }
}

// MARK: - Actions

@MainActor
final class AudioDeviceActionsCatalogTests: XCTestCase {
  func testActionGrammar() {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let (library, _) = makeLibrary(provider: provider)
    let catalog = AudioDeviceActionsCatalog(identifier: "audio-devices.actions", library: library)
    let actions = catalog.actions
    XCTAssertEqual(
      actions.map(\.id), ["use-for-output", "use-for-input", "use-for-sound-effects", "hide-device", "show-device"])
    XCTAssertEqual(
      actions.map(\.title),
      ["Use for Sound Output", "Use for Sound Input", "Use for Alert Sounds", "Hide from Tuna", "Show in Tuna"])
    XCTAssertTrue(actions.allSatisfy { $0.targetRequirement == .none })
    XCTAssertTrue(actions.allSatisfy { $0.executionPolicy == .dismiss })
    XCTAssertTrue(actions.allSatisfy { !$0.title.hasSuffix("...") && !$0.title.hasSuffix("…") })
    XCTAssertEqual(actions[0].supportedSubjectTypes, [.audioOutputDevice])
    XCTAssertEqual(actions[1].supportedSubjectTypes, [.audioInputDevice])
    XCTAssertEqual(actions[2].supportedSubjectTypes, [.audioOutputDevice])
    XCTAssertEqual(actions[3].supportedSubjectTypes, [.audioOutputDevice, .audioInputDevice])
    XCTAssertEqual(actions[0].headlessEligibility, .guaranteed)
    XCTAssertEqual(actions[1].headlessEligibility, .guaranteed)
    XCTAssertEqual(actions[2].headlessEligibility, .guaranteed)

    let snapshot = Fixtures.snapshot()
    let output = AudioDeviceItem(record: Fixtures.airPodsOutput, role: .output, snapshot: snapshot)
    let input = AudioDeviceItem(record: Fixtures.airPodsInput, role: .input, snapshot: snapshot)
    let noAlerts = AudioDeviceItem(
      record: AudioDeviceRecord(uid: "x", name: "No Alerts", canBeOutput: true), role: .output, snapshot: snapshot)
    let hidden = AudioDeviceItem(record: Fixtures.builtInMic, role: .input, snapshot: snapshot, isHidden: true)
    let predicates = actions.compactMap { ($0 as? PredicateAwareAction)?.subjectPredicate }
    XCTAssertEqual(predicates.count, 5)
    XCTAssertEqual(predicates.map { $0(output) }, [true, false, true, true, false])
    XCTAssertEqual(predicates.map { $0(input) }, [false, true, false, true, false])
    XCTAssertEqual(predicates.map { $0(noAlerts) }, [true, false, false, true, false])
    XCTAssertEqual(predicates.map { $0(hidden) }, [false, true, false, false, true])
  }

  func testActionsSwitchThroughTheSharedService() async {
    let provider = FakeAudioDeviceProvider(snapshot: Fixtures.snapshot())
    let (library, store) = makeLibrary(provider: provider, routeSoundEffects: false)
    let catalog = AudioDeviceActionsCatalog(identifier: "audio-devices.actions", library: library)
    let snapshot = Fixtures.snapshot()
    let speakers = AudioDeviceItem(record: Fixtures.builtInSpeakers, role: .output, snapshot: snapshot, library: library)
    let mic = AudioDeviceItem(record: Fixtures.builtInMic, role: .input, snapshot: snapshot, library: library)
    let byID = Dictionary(uniqueKeysWithValues: catalog.actions.map { ($0.id, $0) })

    guard case .success = await byID["use-for-output"]!.callback(speakers, nil) else { return XCTFail() }
    XCTAssertEqual(try provider.currentUID(for: .output), Fixtures.builtInSpeakers.uid)
    XCTAssertEqual(provider.setCalls.map(\.role), [.output], "route-with-output is off")

    guard case .success = await byID["use-for-input"]!.callback(mic, nil) else { return XCTFail() }
    XCTAssertEqual(try provider.currentUID(for: .input), Fixtures.builtInMic.uid)

    let pods = AudioDeviceItem(record: Fixtures.airPodsOutput, role: .output, snapshot: snapshot, library: library)
    guard case .success = await byID["use-for-sound-effects"]!.callback(pods, nil) else { return XCTFail() }
    XCTAssertEqual(try provider.currentUID(for: .soundEffects), Fixtures.airPodsOutput.uid)
    XCTAssertEqual(try provider.currentUID(for: .output), Fixtures.builtInSpeakers.uid, "alerts-only switch leaves output alone")

    guard case .failure = await byID["use-for-output"]!.callback(mic, nil) else { return XCTFail("wrong-role subject must fail") }

    guard case .success = await byID["hide-device"]!.callback(mic, nil) else { return XCTFail() }
    XCTAssertEqual(store.ids, [mic.id])
    guard case .success = await byID["show-device"]!.callback(mic, nil) else { return XCTFail() }
    XCTAssertEqual(store.ids, [])
  }
}
