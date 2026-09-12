import CoreAudio
import Foundation

@available(macOS 15.0, *)
func transportLabel(_ t: UInt32) -> String {
    switch t {
    case kAudioDeviceTransportTypeBuiltIn: return "builtin"
    case kAudioDeviceTransportTypeBluetooth: return "bluetooth"
    case kAudioDeviceTransportTypeBluetoothLE: return "bluetoothLE"
    case kAudioDeviceTransportTypeUSB: return "usb"
    case kAudioDeviceTransportTypeDisplayPort: return "displayport"
    case kAudioDeviceTransportTypeHDMI: return "hdmi"
    case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
    case kAudioDeviceTransportTypeAirPlay: return "airplay"
    case kAudioDeviceTransportTypeVirtual: return "virtual"
    case kAudioDeviceTransportTypeAggregate: return "aggregate"
    case kAudioDeviceTransportTypeContinuityCaptureWired: return "continuity-wired"
    case kAudioDeviceTransportTypeContinuityCaptureWireless: return "continuity-wireless"
    case kAudioDeviceTransportTypePCI: return "pci"
    case kAudioDeviceTransportTypeFireWire: return "firewire"
    case kAudioDeviceTransportTypeAVB: return "avb"
    case kAudioDeviceTransportTypeUnknown: return "unknown"
    default: return "other(\(t))"
    }
}

@available(macOS 15.0, *)
final class Listener: PropertyListenerDelegate {
    func propertiesChanged(properties: [AudioObjectPropertyAddress]) {
        for p in properties { print("EVENT selector=\(String(format: "%c%c%c%c", p.mSelector >> 24 & 0xff, p.mSelector >> 16 & 0xff, p.mSelector >> 8 & 0xff, p.mSelector & 0xff))") }
    }
}

if #available(macOS 15.0, *) {
    let sys = AudioHardwareSystem.shared
    func uid(_ d: AudioHardwareDevice?) -> String { (try? d?.uid) ?? "nil" }
    print("DEFAULT input=\(uid(try sys.defaultInputDevice)) output=\(uid(try sys.defaultOutputDevice)) fx=\(uid(try sys.defaultSoundEffectsDevice))")
    for d in try sys.devices {
        let name = (try? d.name) ?? "?"
        let u = (try? d.uid) ?? "<no uid>"
        let mfr = (try? d.manufacturer) ?? ""
        let model = (try? d.modelUID) ?? ""
        let hidden = (try? d.isHidden) ?? false
        let alive = (try? d.isAlive) ?? false
        let cin = (try? d.canBeDefaultInputDevice) ?? false
        let cout = (try? d.canBeDefaultOutputDevice) ?? false
        let cfx = (try? d.canBeDefaultSoundEffectsDevice) ?? false
        let t = transportLabel((try? d.transportType) ?? 0)
        let ins = (try? d.inputStreamConfiguration.count) ?? -1
        let outs = (try? d.outputStreamConfiguration.count) ?? -1
        print("id=\(d.id) name=\"\(name)\" uid=\"\(u)\" mfr=\"\(mfr)\" model=\"\(model)\" transport=\(t) hidden=\(hidden) alive=\(alive) in=\(cin) out=\(cout) fx=\(cfx) inBufs=\(ins) outBufs=\(outs)")
        let lookup = try sys.device(forUID: u)
        if lookup?.id != d.id { print("  !! device(forUID:) mismatch: \(String(describing: lookup?.id))") }
    }
    // Listener registration check (no writes). Exit after a short window.
    let l = Listener()
    let addrs = [
        PropertyAddress(kAudioHardwarePropertyDevices),
        PropertyAddress(kAudioHardwarePropertyDefaultInputDevice),
        PropertyAddress(kAudioHardwarePropertyDefaultOutputDevice),
        PropertyAddress(kAudioHardwarePropertyDefaultSystemOutputDevice),
    ]
    sys.delegates.append(l)
    try sys.addListener(forProperties: addrs)
    print("LISTENERS registered on \(addrs.count) properties; waiting \(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "2")s for events (change output in Control Center to test)")
    let wait = Double(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "2") ?? 2
    RunLoop.main.run(until: Date().addingTimeInterval(wait))
    try sys.removeListener(forProperties: addrs)
    print("DONE")
}
