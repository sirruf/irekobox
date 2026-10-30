import SwiftUI
import AppKit

/// App-level branding hooks.
public enum Branding {
    /// Render the logo and set it as the Dock icon (works without an asset
    /// catalog / app bundle, suitable for the SwiftPM executable).
    @MainActor
    public static func applyDockIcon() {
        // The app bundle has its own Liquid Glass icon (AppIcon.icon).
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") == nil else { return }
        let renderer = ImageRenderer(content: BrandLogo(size: 512))
        renderer.scale = 2
        if let image = renderer.nsImage {
            NSApplication.shared.applicationIconImage = image
        }
    }
}
