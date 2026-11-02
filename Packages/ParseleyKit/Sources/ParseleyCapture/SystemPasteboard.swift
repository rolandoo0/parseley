// Real AppKit-backed implementations. Compiled only on macOS, so the rest of this
// module (and its tests) also builds on Linux.
#if canImport(AppKit)
import AppKit

/// `Pasteboard` backed by `NSPasteboard.general` (the system clipboard).
public final class SystemPasteboard: Pasteboard {
    private let pasteboard: NSPasteboard

    public init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public var types: [String] { pasteboard.types?.map(\.rawValue) ?? [] }

    public func readString() -> String? { pasteboard.string(forType: .string) }

    public func writeString(_ string: String) {
        // clearContents() must be called before writing; it also bumps changeCount.
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

/// `FrontmostAppProvider` backed by `NSWorkspace`.
public final class WorkspaceFrontmostApp: FrontmostAppProvider {
    public init() {}
    public var frontmostBundleID: String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }
}
#endif
