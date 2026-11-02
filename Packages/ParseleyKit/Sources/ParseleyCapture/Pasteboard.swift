/// The few clipboard operations Parseley needs, abstracted so the capture logic can be
/// unit-tested with a fake instead of the real system clipboard.
public protocol Pasteboard: AnyObject {
    /// Increments every time any app writes to the clipboard. Reading it is cheap, which
    /// is why we can poll it twice a second. (macOS has no "clipboard changed" event.)
    var changeCount: Int { get }
    /// Type identifiers present on the current clipboard item, e.g. "public.utf8-plain-text",
    /// "org.nspasteboard.ConcealedType".
    var types: [String] { get }
    /// The current plain-text contents, if any.
    func readString() -> String?
    /// Replaces the clipboard contents with `string`. Bumps `changeCount`.
    func writeString(_ string: String)
}

/// Who is frontmost right now (approximates "the app the copy came from").
public protocol FrontmostAppProvider: AnyObject {
    var frontmostBundleID: String? { get }
}
