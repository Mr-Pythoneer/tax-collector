import CommonCrypto
import Foundation

/// Only a salted PBKDF2 hash of the guardian code is ever stored.
public struct GuardianRecord: Codable, Equatable, Sendable {
    public var salt: Data
    public var hash: Data
    public var iterations: Int
    public var setAt: Date
}

public enum Guardian {
    public static let minimumLength = 6

    public static func makeRecord(code: String, iterations: Int = 200_000, now: Date = Date()) -> GuardianRecord {
        var salt = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in salt.indices { salt[i] = UInt8.random(in: .min ... .max, using: &rng) }
        let saltData = Data(salt)
        return GuardianRecord(salt: saltData, hash: derive(code: code, salt: saltData, iterations: iterations),
                              iterations: iterations, setAt: now)
    }

    public static func verify(code: String, record: GuardianRecord) -> Bool {
        let candidate = derive(code: code, salt: record.salt, iterations: record.iterations)
        guard candidate.count == record.hash.count else { return false }
        // Compare every byte so timing doesn't leak how much matched.
        var diff: UInt8 = 0
        for (a, b) in zip(candidate, record.hash) { diff |= a ^ b }
        return diff == 0
    }

    static func derive(code: String, salt: Data, iterations: Int) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let password = Array(code.utf8).map { CChar(bitPattern: $0) }
        let status = salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                password, password.count,
                saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                UInt32(iterations),
                &out, out.count)
        }
        precondition(status == kCCSuccess, "PBKDF2 failed: \(status)")
        return Data(out)
    }
}
