/// 64-bit FNV-1a hash of a string's UTF-8 bytes, as 16 hex characters.
///
/// Used only to find identical content quickly in the database (always confirmed by a
/// full string compare). Not cryptographic. Chosen over SHA-256 because CryptoKit isn't
/// available on Linux and we don't need collision resistance here.
public enum ContentHash {
    public static func of(_ string: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3   // &* = multiply with overflow wrapping
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
