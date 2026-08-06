import AppKit

/// The image EasyDMG shows at the top of its alerts and permission windows.
///
/// macOS falls back to the app icon whenever an alert has no icon of its own,
/// so every dialog looked the same whether it set one or not. This exists to
/// make that a decision instead of an accident: point `resourceName` at a
/// different bundled `.icns` and every alert follows, without touching the app
/// icon itself.
///
/// Two things worth knowing before swapping the artwork:
/// - Alert icons render around 64pt, so fine detail disappears.
/// - `.critical` alerts composite a caution badge over whatever is supplied.
///   `showBlockedAppQuarantineDialog` is the only one that uses that style.
enum AlertIcon {
    /// Currently the app icon artwork, so the override is invisible today.
    private static let resourceName = "wizardhamster"

    /// Loaded once and reused. `nil` when the resource is missing, which is the
    /// signal to let macOS supply its own default.
    static let image: NSImage? = Bundle.main
        .path(forResource: resourceName, ofType: "icns")
        .flatMap { NSImage(contentsOfFile: $0) }
}
