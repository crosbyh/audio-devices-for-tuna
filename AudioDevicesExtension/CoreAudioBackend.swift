import CoreAudio
import Foundation

/// Production `AudioDeviceProviding` built on the typed Core Audio API (macOS 15+). This is the
/// only file that imports CoreAudio. It never records or captures audio; it reads device
/// metadata, reads and sets the three system defaults, and listens for changes.
final class CoreAudioBackend: AudioDeviceProviding, @unchecked Sendable {
  private let system: AudioHardwareSystem
  private let listenerQueue = DispatchQueue(label: "com.crosbyh.tuna.audio-devices.listener")
  private let lock = NSLock()
  private var delegate: ChangeDelegate?

  init(system: AudioHardwareSystem = .shared) {
    self.system = system
  }

  deinit {
    stopObservingChanges()
  }

  // MARK: Enumeration

  func snapshot() throws -> AudioDeviceSnapshot {
    let devices: [AudioHardwareDevice]
    do {
      devices = try system.devices
    } catch let error as AudioHardwareError {
      throw AudioSwitchError.coreAudio(operation: "list audio devices", status: error.error)
    }
    return AudioDeviceSnapshot(
      devices: devices.compactMap(Self.record(for:)),
      currentInputUID: try? currentUID(for: .input),
      currentOutputUID: try? currentUID(for: .output),
      currentSoundEffectsUID: try? currentUID(for: .soundEffects)
    )
  }

  /// Converts one Core Audio device into a record, or `nil` when the device is hidden, dead,
  /// UID-less, or unable to become any default. Metadata reads that throw exclude the device
  /// rather than failing the scan.
  static func record(for device: AudioHardwareDevice) -> AudioDeviceRecord? {
    guard let uid = try? device.uid, !uid.isEmpty else { return nil }
    if (try? device.isHidden) == true { return nil }
    if (try? device.isAlive) == false { return nil }
    let canBeInput = (try? device.canBeDefaultInputDevice) ?? false
    let canBeOutput = (try? device.canBeDefaultOutputDevice) ?? false
    guard canBeInput || canBeOutput else { return nil }
    let name = ((try? device.name) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return AudioDeviceRecord(
      uid: uid,
      objectID: device.id,
      name: name.isEmpty ? uid : name,
      manufacturer: Self.nonEmpty(try? device.manufacturer),
      modelUID: Self.nonEmpty(try? device.modelUID),
      transport: transport(for: (try? device.transportType) ?? kAudioDeviceTransportTypeUnknown),
      canBeInput: canBeInput,
      canBeOutput: canBeOutput,
      canBeSoundEffects: (try? device.canBeDefaultSoundEffectsDevice) ?? false
    )
  }

  static func transport(for raw: UInt32) -> AudioTransport {
    switch raw {
    case kAudioDeviceTransportTypeBuiltIn: .builtIn
    case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: .bluetooth
    case kAudioDeviceTransportTypeUSB: .usb
    case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI: .display
    case kAudioDeviceTransportTypeThunderbolt: .thunderbolt
    case kAudioDeviceTransportTypeAirPlay: .airPlay
    case kAudioDeviceTransportTypeVirtual: .virtual
    case kAudioDeviceTransportTypeAggregate: .aggregate
    case kAudioDeviceTransportTypeContinuityCaptureWired,
      kAudioDeviceTransportTypeContinuityCaptureWireless:
      .continuity
    default: .other
    }
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty
    else { return nil }
    return value
  }

  // MARK: Defaults

  func currentUID(for role: AudioDefaultRole) throws -> String? {
    do {
      switch role {
      case .input: return try system.defaultInputDevice?.uid
      case .output: return try system.defaultOutputDevice?.uid
      case .soundEffects: return try system.defaultSoundEffectsDevice?.uid
      }
    } catch let error as AudioHardwareError {
      throw AudioSwitchError.coreAudio(
        operation: "read the \(AudioSwitchError.describe(role)) device", status: error.error)
    }
  }

  func setDefault(_ role: AudioDefaultRole, uid: String) throws {
    let device: AudioHardwareDevice?
    do {
      device = try system.device(forUID: uid)
    } catch let error as AudioHardwareError {
      throw AudioSwitchError.coreAudio(operation: "look up the device", status: error.error)
    }
    guard let device else { throw AudioSwitchError.deviceUnavailable(name: uid) }
    do {
      switch role {
      case .input: try system.setDefaultInputDevice(device)
      case .output: try system.setDefaultOutputDevice(device)
      case .soundEffects: try system.setDefaultSoundEffectsDevice(device)
      }
    } catch let error as AudioHardwareError {
      throw AudioSwitchError.coreAudio(
        operation: "set the \(AudioSwitchError.describe(role)) device", status: error.error)
    }
  }

  // MARK: Observation

  private static let observedProperties: [AudioObjectPropertyAddress] = [
    PropertyAddress(kAudioHardwarePropertyDevices),
    PropertyAddress(kAudioHardwarePropertyDefaultInputDevice),
    PropertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
    PropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice),
  ]

  func startObservingChanges(_ handler: @escaping @Sendable () -> Void) throws {
    stopObservingChanges()
    let delegate = ChangeDelegate(handler: handler)
    lock.lock()
    system.delegates.append(delegate)
    self.delegate = delegate
    lock.unlock()
    do {
      try system.addListener(forProperties: Self.observedProperties, dispatchQueue: listenerQueue)
    } catch {
      stopObservingChanges()
      let status = (error as? AudioHardwareError)?.error
      throw AudioSwitchError.observationFailed(
        status.map { "Core Audio error \($0)" } ?? error.localizedDescription)
    }
  }

  func stopObservingChanges() {
    lock.lock()
    guard let delegate else {
      lock.unlock()
      return
    }
    self.delegate = nil
    system.delegates.removeAll { ($0 as AnyObject) === delegate }
    lock.unlock()
    try? system.removeListener(forProperties: Self.observedProperties, dispatchQueue: listenerQueue)
  }
}

private final class ChangeDelegate: PropertyListenerDelegate {
  let handler: @Sendable () -> Void

  init(handler: @escaping @Sendable () -> Void) {
    self.handler = handler
  }

  func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
    handler()
  }
}
