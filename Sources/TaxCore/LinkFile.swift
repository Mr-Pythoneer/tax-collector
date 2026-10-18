import CryptoKit
import Foundation

/// What this computer keeps about its parent link: docs/parent-link-v1.md §9. Saved as parent-link.json (0600).
public struct LinkFile: Codable, Equatable, Sendable {
    public var serverURL: String
    public var setupCode: String
    public var channel: String
    /// base64url of the 32-byte computer token. The server only knows its hash.
    public var computerToken: String
    /// base64url of the computer's long-term P-256 key-agreement private key.
    public var computerKey: String
    public var devices: [LinkedDevice]
    public var lastCounter: [String: Int64]
    /// For "the latest issued wins": when each setting was last changed, in ms.
    public var settingTimes: [String: Int64]
    public var stateSeq: Int64
    public var results: [CommandResult]

    public init(serverURL: String, setupCode: String, channel: String = LinkCrypto.base64url(LinkCrypto.randomBytes(16)),
                computerToken: String = LinkCrypto.base64url(LinkCrypto.randomBytes(32)),
                computerKey: String = LinkCrypto.base64url(P256.KeyAgreement.PrivateKey().rawRepresentation)) {
        self.serverURL = serverURL
        self.setupCode = setupCode
        self.channel = channel
        self.computerToken = computerToken
        self.computerKey = computerKey
        devices = []
        lastCounter = [:]
        settingTimes = [:]
        stateSeq = 0
        results = []
    }

    public var privateKey: P256.KeyAgreement.PrivateKey? {
        LinkCrypto.fromBase64url(computerKey).flatMap { try? P256.KeyAgreement.PrivateKey(rawRepresentation: $0) }
    }

    public var tokenHash: String {
        LinkCrypto.base64url(LinkCrypto.sha256(LinkCrypto.fromBase64url(computerToken) ?? Data()))
    }

    public mutating func record(_ result: CommandResult) {
        results.append(result)
        if results.count > 50 { results.removeFirst(results.count - 50) }
    }
}

/// One paired parent phone.
public struct LinkedDevice: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// base64url, 65-byte P-256 public keys.
    public var signKey: String
    public var dhKey: String
    public var tokenHash: String
    /// base64url of the 32-byte AES key this phone and the computer share.
    public var linkKey: String
    public var pairedAt: Int64

    public init(id: String, name: String, signKey: String, dhKey: String, tokenHash: String, linkKey: String, pairedAt: Int64) {
        self.id = id
        self.name = name
        self.signKey = signKey
        self.dhKey = dhKey
        self.tokenHash = tokenHash
        self.linkKey = linkKey
        self.pairedAt = pairedAt
    }

    public var key: SymmetricKey? { LinkCrypto.fromBase64url(linkKey).map { SymmetricKey(data: $0) } }
    public var signKeyData: Data? { LinkCrypto.fromBase64url(signKey) }
}
