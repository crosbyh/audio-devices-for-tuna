// Task 1 spike: switch output / input / sound-effects defaults with the typed Core Audio API,
// verify by readback, observe listener events, and restore the original defaults.
import CoreAudio
import Foundation

@available(macOS 15.0, *)
final class Listener: PropertyListenerDelegate {
    var events: [String] = []
    let lock = NSLock()
    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        lock.lock(); defer { lock.unlock() }
        for p in properties {
            let s = p.mSelector
            events.append(String(format: "%c%c%c%c", s >> 24 & 0xff, s >> 16 & 0xff, s >> 8 & 0xff, s & 0xff))
        }
    }
    func drain() -> [String] { lock.lock(); defer { lock.unlock() }; let e = events; events = []; return e }
}

@available(macOS 15.0, *)
enum Role: String { case input, output, fx }

@available(macOS 15.0, *)
func currentUID(_ role: Role) throws -> String? {
    let sys = AudioHardwareSystem.shared
    switch role {
    case .input: return try sys.defaultInputDevice?.uid
    case .output: return try sys.defaultOutputDevice?.uid
    case .fx: return try sys.defaultSoundEffectsDevice?.uid
    }
}

/// Set + bounded readback. Returns (verified, elapsed ms, attempts).
@available(macOS 15.0, *)
func switchAndVerify(_ role: Role, to uid: String) throws -> (Bool, Double, Int) {
    let sys = AudioHardwareSystem.shared
    guard let device = try sys.device(forUID: uid) else { throw NSError(domain: "spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "no device for uid \(uid)"]) }
    let t0 = Date()
    switch role {
    case .input: try sys.setDefaultInputDevice(device)
    case .output: try sys.setDefaultOutputDevice(device)
    case .fx: try sys.setDefaultSoundEffectsDevice(device)
    }
    for attempt in 1...20 {
        if try currentUID(role) == uid { return (true, Date().timeIntervalSince(t0) * 1000, attempt) }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return (false, Date().timeIntervalSince(t0) * 1000, 20)
}

if #available(macOS 15.0, *) {
    let sys = AudioHardwareSystem.shared
    let listener = Listener()
    let addrs = [
        PropertyAddress(kAudioHardwarePropertyDevices),
        PropertyAddress(kAudioHardwarePropertyDefaultInputDevice),
        PropertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
        PropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice),
    ]
    sys.delegates.append(listener)
    try sys.addListener(forProperties: addrs)

    let origIn = try currentUID(.input) ?? ""
    let origOut = try currentUID(.output) ?? ""
    let origFx = try currentUID(.fx) ?? ""
    print("ORIGINAL input=\(origIn) output=\(origOut) fx=\(origFx)")

    // Pick alternates: built-in devices, which are always present.
    let altOut = "BuiltInSpeakerDevice"
    let altIn = "BuiltInMicrophoneDevice"

    func step(_ label: String, _ role: Role, _ uid: String) {
        do {
            let (ok, ms, n) = try switchAndVerify(role, to: uid)
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            print("STEP \(label): role=\(role.rawValue) uid=\(uid) verified=\(ok) readbackMs=\(String(format: "%.1f", ms)) attempts=\(n) events=\(listener.drain())")
        } catch {
            print("STEP \(label): role=\(role.rawValue) uid=\(uid) ERROR \(error.localizedDescription) events=\(listener.drain())")
        }
    }

    // 1. Output → built-in speakers, then back.
    if origOut != altOut { step("output->builtin", .output, altOut); step("output->orig", .output, origOut) }
    else { print("SKIP output: already built-in") }
    // 2. Input → built-in mic, then back.
    if origIn != altIn { step("input->builtin", .input, altIn); step("input->orig", .input, origIn) }
    else { print("SKIP input: already built-in") }
    // 3. Sound effects → current output device (if eligible), then back.
    if let outDev = try sys.device(forUID: origOut), try outDev.canBeDefaultSoundEffectsDevice, origFx != origOut {
        step("fx->output", .fx, origOut); step("fx->orig", .fx, origFx)
    } else { print("SKIP fx: output not fx-eligible or already fx") }
    // 4. No-op set of the current output: does it fire an event?
    step("output->same(noop)", .output, try currentUID(.output) ?? origOut)
    // 5. Vanished device.
    do { _ = try switchAndVerify(.output, to: "does-not-exist:output"); print("STEP vanished: unexpectedly succeeded") }
    catch { print("STEP vanished: threw as expected -> \(error.localizedDescription)") }
    // 6. Role rejection: set an input-only device as output (expect throw or readback failure).
    if let mic = try sys.device(forUID: altIn) {
        do { try sys.setDefaultOutputDevice(mic); Thread.sleep(forTimeInterval: 0.2)
             print("STEP role-reject: setter did not throw; output now=\(try currentUID(.output) ?? "nil") events=\(listener.drain())")
             if try currentUID(.output) != origOut { step("output->orig(after role test)", .output, origOut) }
        } catch { print("STEP role-reject: threw -> \(error.localizedDescription) code=\((error as? AudioHardwareError)?.error ?? 0)") }
    }
    try sys.removeListener(forProperties: addrs)
    print("FINAL input=\(try currentUID(.input) ?? "") output=\(try currentUID(.output) ?? "") fx=\(try currentUID(.fx) ?? "")")
    print("RESTORED=\(try currentUID(.input) == origIn && currentUID(.output) == origOut && currentUID(.fx) == origFx)")
}
