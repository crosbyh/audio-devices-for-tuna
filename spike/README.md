# Core Audio spike

Read-only enumeration and listener-registration spike against the typed Core Audio Swift API
(`AudioHardwareSystem` / `AudioHardwareDevice`, macOS 15+). It performs no writes.

```bash
swiftc -O -o /tmp/enumerate spike/enumerate-devices.swift && /tmp/enumerate 10
```

The numeric argument is how many seconds to keep the property listeners alive; change the
output device in Control Center during that window to see `EVENT` lines.

Run on 2026-09-11 (macOS 26.6.2, Xcode 26.6) — see `docs/PLAN.md` § Discovery for the
resulting device table.

## switch-devices.swift

Switches the default output, input, and sound-effects devices to the built-in devices and
back, verifying each by readback and recording listener events, then restores the original
defaults. It changes system state for a few seconds; run it only when that is acceptable.

```bash
swiftc -O -o /tmp/switch spike/switch-devices.swift && /tmp/switch
```

Results from 2026-09-11 are in `docs/PLAN.md` § 2.
