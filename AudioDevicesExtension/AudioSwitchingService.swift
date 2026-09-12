import Foundation

/// Resolve → set → verify. Never reports success until the requested UID is read back as the
/// current default. Shared by runnable items and the explicit actions.
final class AudioSwitchingService: Sendable {
  typealias Sleeper = @Sendable (Duration) async -> Void

  let provider: any AudioDeviceProviding
  let readbackAttempts: Int
  let readbackInterval: Duration
  private let sleep: Sleeper

  init(
    provider: any AudioDeviceProviding,
    readbackAttempts: Int = 10,
    readbackInterval: Duration = .milliseconds(50),
    sleep: @escaping Sleeper = { try? await Task.sleep(for: $0) }
  ) {
    self.provider = provider
    self.readbackAttempts = max(1, readbackAttempts)
    self.readbackInterval = readbackInterval
    self.sleep = sleep
  }

  /// Switches sound output and, when `routeSoundEffects` is on and the device allows it, alert
  /// sounds. A sound-effects failure after a successful output switch is reported as
  /// `.switchedWithoutSoundEffects`, never as a plain success.
  func useForOutput(uid: String, name: String, routeSoundEffects: Bool) async throws
    -> AudioSwitchResult
  {
    let device = try resolve(uid: uid, name: name, role: .output)
    let outputChanged = try await setAndVerify(.output, device: device)
    guard routeSoundEffects, device.canBeSoundEffects else {
      return outputChanged ? .switched : .alreadyCurrent
    }
    do {
      let effectsChanged = try await setAndVerify(.soundEffects, device: device)
      return (outputChanged || effectsChanged) ? .switched : .alreadyCurrent
    } catch {
      return .switchedWithoutSoundEffects(reason: error.localizedDescription)
    }
  }

  func useForInput(uid: String, name: String) async throws -> AudioSwitchResult {
    let device = try resolve(uid: uid, name: name, role: .input)
    return try await setAndVerify(.input, device: device) ? .switched : .alreadyCurrent
  }

  func useForSoundEffects(uid: String, name: String) async throws -> AudioSwitchResult {
    let device = try resolve(uid: uid, name: name, role: .soundEffects)
    return try await setAndVerify(.soundEffects, device: device) ? .switched : .alreadyCurrent
  }

  // MARK: Internals

  /// Looks the device up in a fresh snapshot so a device that vanished since the scan fails
  /// cleanly, and rejects roles Core Audio would silently ignore.
  private func resolve(uid: String, name: String, role: AudioDefaultRole) throws
    -> AudioDeviceRecord
  {
    let snapshot = try provider.snapshot()
    guard let device = snapshot.device(uid: uid) else {
      throw AudioSwitchError.deviceUnavailable(name: name)
    }
    let supported: Bool
    switch role {
    case .input: supported = device.canBeInput
    case .output: supported = device.canBeOutput
    case .soundEffects: supported = device.canBeSoundEffects
    }
    guard supported else { throw AudioSwitchError.roleNotSupported(name: device.name, role: role) }
    return device
  }

  /// Returns `false` when the device was already current (no write performed), `true` after a
  /// verified change. Throws `verificationTimedOut` if readback never matches.
  private func setAndVerify(_ role: AudioDefaultRole, device: AudioDeviceRecord) async throws
    -> Bool
  {
    if try provider.currentUID(for: role) == device.uid { return false }
    try provider.setDefault(role, uid: device.uid)
    for attempt in 0..<readbackAttempts {
      if try provider.currentUID(for: role) == device.uid { return true }
      if attempt < readbackAttempts - 1 { await sleep(readbackInterval) }
    }
    throw AudioSwitchError.verificationTimedOut(name: device.name, role: role)
  }
}
