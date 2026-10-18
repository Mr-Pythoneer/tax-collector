import CryptoKit
import Foundation

/// The cryptography of the parent link, exactly as docs/parent-link-v1.md §2–§5 has it.
/// spec/vectors/v1.json checks every piece; the parent app and the Windows version use the same vectors.
public enum LinkCrypto {
    public enum Failure: Error, Equatable {
        case badBox
        case badKey
    }

    // MARK: Encodings

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func fromBase64url(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }

    public static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func ascii(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Pairing code (§4.1)

    public static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// Uppercase, O→0, I and L→1, and drop anything else outside the alphabet.
    public static func normaliseCode(_ input: String) -> String {
        String(input.uppercased().compactMap { c -> Character? in
            let mapped: Character = c == "O" ? "0" : (c == "I" || c == "L") ? "1" : c
            return alphabet.contains(mapped) ? mapped : nil
        })
    }

    /// 10 characters, about 50 bits.
    public static func newPairingCode() -> String {
        String(randomBytes(10).map { alphabet[Int($0) % 32] })
    }

    /// "ABCDE-FGHJK".
    public static func displayCode(_ code: String) -> String {
        let c = normaliseCode(code)
        guard c.count == 10 else { return c }
        return String(c.prefix(5)) + "-" + String(c.suffix(5))
    }

    public static func hkdf(_ ikm: Data, salt: Data, info: Data, count: Int) -> Data {
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt, info: info,
                                         outputByteCount: count)
        return key.withUnsafeBytes { Data($0) }
    }

    /// The server slot and the key that seals every pairing message.
    public static func pairing(code: String) -> (slot: String, key: SymmetricKey) {
        let ikm = Data(normaliseCode(code).utf8)
        let salt = ascii("tc v1 pair")
        let slot = base64url(hkdf(ikm, salt: salt, info: ascii("tc v1 pair slot"), count: 16))
        let key = hkdf(ikm, salt: salt, info: ascii("tc v1 pair key"), count: 32)
        return (slot, SymmetricKey(data: key))
    }

    public static func pairAAD(slot: String) -> Data { ascii("tc v1 pair|" + slot) }
    public static func commandAAD(channel: String, device: String) -> Data { ascii("tc v1 cmd|" + channel + "|" + device) }
    public static func stateAAD(channel: String, device: String) -> Data { ascii("tc v1 state|" + channel + "|" + device) }

    // MARK: Boxes (§2)

    /// nonce(12) ‖ ciphertext ‖ tag(16). Pass a nonce only in tests.
    public static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data, nonce: Data? = nil) throws -> Data {
        let n = try nonce.map { try AES.GCM.Nonce(data: $0) } ?? AES.GCM.Nonce()
        guard let combined = try AES.GCM.seal(plaintext, using: key, nonce: n, authenticating: aad).combined else {
            throw Failure.badBox
        }
        return combined
    }

    public static func open(_ box: Data, key: SymmetricKey, aad: Data) throws -> Data {
        do {
            return try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: key, authenticating: aad)
        } catch {
            throw Failure.badBox
        }
    }

    // MARK: Commit, reveal, compare (§4.2)

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    public static func commitment(signKey: Data, dhKey: Data, nonce: Data, tokenHash: Data, name: String) -> Data {
        sha256(ascii("tc v1 commit") + signKey + dhKey + nonce + tokenHash + Data(name.utf8))
    }

    /// Six digits, shown as "123 456".
    public static func comparisonCode(computerNonce: Data, phoneNonce: Data, computerDhKey: Data,
                                      phoneSignKey: Data, phoneDhKey: Data) -> String {
        let h = sha256(ascii("tc v1 sas") + computerNonce + phoneNonce + computerDhKey + phoneSignKey + phoneDhKey)
        let n = h.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let digits = String(n % 1_000_000)
        return String(repeating: "0", count: 6 - digits.count) + digits
    }

    // MARK: Link key (§4.4) and signatures (§5.1)

    public static func linkKey(computer: P256.KeyAgreement.PrivateKey, phoneDhKey: Data, channel: String,
                               deviceID: String) throws -> SymmetricKey {
        guard let phone = try? P256.KeyAgreement.PublicKey(x963Representation: phoneDhKey),
              let salt = fromBase64url(channel) else { throw Failure.badKey }
        let shared = try computer.sharedSecretFromKeyAgreement(with: phone)
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: ascii("tc v1 link|" + deviceID),
                                              outputByteCount: 32)
    }

    /// ECDSA P-256 with SHA-256 over exactly these bytes; the signature is raw r‖s.
    public static func isValidSignature(_ signature: Data, of body: Data, by publicKey: Data) -> Bool {
        guard signature.count == 64,
              let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
              let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
        return key.isValidSignature(sig, for: body)
    }

    // MARK: Raw DEFLATE (Apple's "zlib" is RFC 1951 with no header)

    public static func deflateRaw(_ data: Data) -> Data? {
        try? (data as NSData).compressed(using: .zlib) as Data
    }

    public static func inflateRaw(_ data: Data) -> Data? {
        try? (data as NSData).decompressed(using: .zlib) as Data
    }
}
