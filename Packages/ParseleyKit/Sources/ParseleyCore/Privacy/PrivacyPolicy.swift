/// Decides whether a clipboard change may be stored. Pure logic over strings, so it's
/// testable without AppKit.
public struct PrivacyPolicy: Sendable, Equatable {
    /// Pasteboard types that password managers and similar apps attach to mark data as
    /// secret or short-lived. Spec: http://nspasteboard.org
    public static let blockedPasteboardTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",   // passwords, secrets
        "org.nspasteboard.TransientType",   // temporary data the app will restore/replace
        // Legacy markers from apps that predate the nspasteboard.org convention:
        "com.agilebits.onepassword",
        "de.petermaurer.TransientPasteboardType",
        "Pasteboard generator type",
        "com.typeit4me.clipping",
        "net.antelle.keeweb",
    ]

    /// Bundle ids of apps whose copies are never stored (configured in Settings).
    public var excludedBundleIDs: Set<String>

    public init(excludedBundleIDs: Set<String> = []) {
        self.excludedBundleIDs = excludedBundleIDs
    }

    public enum Decision: Equatable, Sendable {
        case allow
        case blockedPasteboardType(String)
        case excludedApp(String)
    }

    public func evaluate(pasteboardTypes: [String], sourceBundleID: String?) -> Decision {
        if let blocked = pasteboardTypes.first(where: Self.blockedPasteboardTypes.contains) {
            return .blockedPasteboardType(blocked)
        }
        if let id = sourceBundleID, excludedBundleIDs.contains(id) {
            return .excludedApp(id)
        }
        return .allow
    }
}
