import Foundation
import TunaKit

@objc(AudioDevicesExtension)
public final class AudioDevicesExtension: Extension {
  nonisolated static let devicesCatalogIdentifier = "audio-devices"
  nonisolated static let browseCatalogIdentifier = "audio-devices.browse"
  nonisolated static let actionsCatalogIdentifier = "audio-devices.actions"

  public override var declaration: ExtensionDeclaration? {
    ExtensionDeclaration(
      metadata: ExtensionMetadata(
        displayName: "Audio Devices",
        author: "Crosby Hayton",
        description:
          "Switch the Mac's sound output, input, and alert devices, including connected AirPods, from Tuna.",
        iconName: "speaker.wave.2"
      ),
      compatibility: ExtensionDeclarationCompatibility(minTuna: "0.96", minTunaKit: "1.22.0"),
      settings: AudioDevicesSettings.definitions,
      catalogs: [
        CatalogDeclaration(
          id: Self.devicesCatalogIdentifier,
          type: AudioDevicesCatalog.self,
          name: "Audio Devices",
          presentation: .source,
          description:
            "Every sound output and input macOS can use right now. Run one to make it the default; refreshes when devices connect or disconnect.",
          enabledByDefault: true,
          initialGlobalScope: .all
        ),
        CatalogDeclaration(
          id: Self.browseCatalogIdentifier,
          type: AudioDevicesBrowseCatalog.self,
          name: "Audio Devices",
          presentation: .browseRoot(contents: Self.devicesCatalogIdentifier),
          description:
            "Every sound output and input macOS can use right now. Run one to make it the default; refreshes when devices connect or disconnect.",
          enabledByDefault: true
        ),
      ],
      actionCatalogs: [
        ActionCatalogDeclaration(
          id: Self.actionsCatalogIdentifier,
          type: AudioDeviceActionsCatalog.self,
          name: "Audio Device Actions"
        )
      ],
      typeRegistrations: [
        TypeRegistrationDefinition(
          typeID: .audioOutputDevice,
          displayName: "Audio Output Devices",
          inheritsFrom: [.entity]
        ),
        TypeRegistrationDefinition(
          typeID: .audioInputDevice,
          displayName: "Audio Input Devices",
          inheritsFrom: [.entity]
        ),
      ],
      defaultActionRankings: [
        DefaultActionRankingDefinition(
          typeID: .audioOutputDevice,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: AudioDeviceActionsCatalog.useForOutputActionID),
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: AudioDeviceActionsCatalog.useForSoundEffectsActionID),
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: AudioDeviceActionsCatalog.hideDeviceActionID),
          ]
        ),
        DefaultActionRankingDefinition(
          typeID: .audioInputDevice,
          actions: [
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: AudioDeviceActionsCatalog.useForInputActionID),
            ActionReference(
              catalogIdentifier: Self.actionsCatalogIdentifier,
              actionID: AudioDeviceActionsCatalog.hideDeviceActionID),
          ]
        ),
      ]
    )
  }
}
