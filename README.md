# Audio Devices for Tuna

A [Tuna](https://tunaformac.com) extension that lists the Mac's available audio input and
output devices (including connected AirPods) as searchable, directly runnable items, so you can
switch the system default from the launcher without opening System Settings.

Status: design approved, implementation in progress. See `docs/PLAN.md`.

Built on the public typed Core Audio API (macOS 15+); no Homebrew or `SwitchAudioSource`
dependency. Requires Tuna 0.96 or later (TunaKit 1.22.0).

## Development

```bash
make build            # Debug build
make test             # unit tests
make install-restart  # install into ~/Library/Application Support/Tuna/ExtensionsDev and restart Tuna
make logs             # last 20 minutes of Tuna extension logs
make package          # Release build + dist/store/*.tunaextension
```

## License

MIT. See `LICENSE`.
