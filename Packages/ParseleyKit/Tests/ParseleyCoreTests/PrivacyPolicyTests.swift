import Testing
import ParseleyCore

@Suite struct PrivacyPolicyTests {
    @Test func allowsOrdinaryText() {
        let policy = PrivacyPolicy()
        #expect(policy.evaluate(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.apple.Safari") == .allow)
    }

    @Test(arguments: ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"])
    func blocksPasswordManagerMarkers(_ marker: String) {
        let policy = PrivacyPolicy()
        let types = ["public.utf8-plain-text", marker]
        #expect(policy.evaluate(pasteboardTypes: types, sourceBundleID: nil) == .blockedPasteboardType(marker))
    }

    @Test func blocksExcludedApps() {
        let policy = PrivacyPolicy(excludedBundleIDs: ["com.example.bank"])
        #expect(policy.evaluate(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.example.bank")
                == .excludedApp("com.example.bank"))
        #expect(policy.evaluate(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: "com.example.other") == .allow)
        #expect(policy.evaluate(pasteboardTypes: ["public.utf8-plain-text"], sourceBundleID: nil) == .allow)
    }

    @Test func concealedTypeWinsOverExclusionCheck() {
        let policy = PrivacyPolicy(excludedBundleIDs: ["com.example.bank"])
        #expect(policy.evaluate(pasteboardTypes: ["org.nspasteboard.ConcealedType"], sourceBundleID: "com.example.bank")
                == .blockedPasteboardType("org.nspasteboard.ConcealedType"))
    }
}
