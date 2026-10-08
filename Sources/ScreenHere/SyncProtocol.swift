import CryptoKit
import Foundation

/// The shared clipboard's wire format, the same on the Mac and on Windows —
/// docs/SHARED-CLIPBOARD.md is its description, and both apps check the same
/// test vectors against it.
///
/// Two devices on one network, no server in between and no account. They are
/// introduced once, by a code shown on both screens; from then on everything
/// they say to each other is encrypted with a key only the two of them have.
enum SyncProtocol {
    static let serviceType = "_screenhere._tcp"
    /// Asked for first, so a device that was seen once can be found again at
    /// the same address without being announced. Any free port otherwise.
    static let preferredPort: UInt16 = 47583
    static let version = 1
    /// A frame is at most this long: a picture's limit, and some room.
    static let maxFrame = 32 * 1024 * 1024
    static let maxText = 1024 * 1024

    /// What a sealed frame carries, in its first byte.
    enum Kind: UInt8 {
        case ready = 0, text = 1, image = 2, ping = 3
    }

    enum Failure: Error {
        case badFrame
        case closed
    }

    // MARK: - Messages in the clear

    /// The messages that come before there is a key, as JSON.
    struct Message: Codable, Equatable {
        var t: String
        var v: Int?
        var id: String?
        var name: String?
        var commit: String?
        var pub: String?
        var nonce: String?
        var ok: Bool?
    }

    static func encode(_ message: Message) -> Data {
        (try? JSONEncoder().encode(message)) ?? Data()
    }

    static func decode(_ frame: Data) -> Message? {
        try? JSONDecoder().decode(Message.self, from: frame)
    }

    // MARK: - Frames

    /// Every message, sealed or not, travels as its length and then itself.
    static func header(for count: Int) -> Data {
        let length = UInt32(count)
        return Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
    }

    /// Nil for a length no frame may have.
    static func length(from header: Data) -> Int? {
        let bytes = [UInt8](header)
        guard bytes.count == 4 else { return nil }
        let length = Int(bytes[0]) << 24 | Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
        return length <= maxFrame ? length : nil
    }

    // MARK: - Keys

    /// The public key as 0x04, X, Y: 65 bytes, the form every library reads.
    static func publicBytes(_ key: P256.KeyAgreement.PrivateKey) -> Data {
        key.publicKey.x963Representation
    }

    static func agree(_ ours: P256.KeyAgreement.PrivateKey, with theirPublic: Data) throws -> Data {
        let theirs = try P256.KeyAgreement.PublicKey(x963Representation: theirPublic)
        return try ours.sharedSecretFromKeyAgreement(with: theirs).withUnsafeBytes { Data($0) }
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    private static func derive(_ material: Data, salt: Data, info: String, count: Int) -> Data {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: material), salt: salt,
                               info: Data(info.utf8), outputByteCount: count)
            .withUnsafeBytes { Data($0) }
    }

    // MARK: - Pairing

    /// What the device that asks to be paired sends first: a promise about a
    /// key it has not shown yet. Without it, someone in the middle could pick
    /// their own key after seeing ours, and steer the code on both screens.
    static func commitment(publicKey: Data, nonce: Data) -> Data {
        Data(SHA256.hash(data: publicKey + nonce))
    }

    /// The key the two devices keep, and the six digits both show. `asking`
    /// is the device that sent the first message.
    static func pairing(shared: Data, askingPublic: Data, answeringPublic: Data,
                        askingNonce: Data, answeringNonce: Data) -> (key: Data, code: String) {
        let salt = Data(SHA256.hash(data: askingPublic + answeringPublic + askingNonce + answeringNonce))
        let material = [UInt8](derive(shared, salt: salt, info: "ScreenHere pairing v1", count: 36))
        let number = UInt32(material[32]) << 24 | UInt32(material[33]) << 16 | UInt32(material[34]) << 8 | UInt32(material[35])
        let digits = String(number % 1_000_000)
        let code = String(repeating: "0", count: 6 - digits.count) + digits
        return (Data(material[0..<32]), code)
    }

    /// "482 913", as the panel shows it.
    static func spaced(_ code: String) -> String {
        code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code
    }

    // MARK: - Sessions

    /// One key per direction, new for every connection: the devices' own key
    /// proves who is talking, and the keys made for this connection alone keep
    /// what was said from being read later, should that key ever leak.
    static func sessionKeys(shared: Data, pairKey: Data, clientNonce: Data,
                            serverNonce: Data) -> (clientToServer: Data, serverToClient: Data) {
        let material = shared + pairKey
        let salt = clientNonce + serverNonce
        return (derive(material, salt: salt, info: "ScreenHere sync v1 c2s", count: 32),
                derive(material, salt: salt, info: "ScreenHere sync v1 s2c", count: 32))
    }

    /// One direction of a session: frames numbered from zero, each sealed
    /// under its number, so none can be replayed, dropped or reordered unseen.
    final class Cipher {
        private let key: SymmetricKey
        private var counter: UInt64 = 0

        init(key: Data) {
            self.key = SymmetricKey(data: key)
        }

        private func nextNonce() throws -> AES.GCM.Nonce {
            var bytes = [UInt8](repeating: 0, count: 12)
            for index in 0..<8 {
                bytes[11 - index] = UInt8((counter >> (8 * UInt64(index))) & 0xff)
            }
            counter += 1
            return try AES.GCM.Nonce(data: bytes)
        }

        func seal(_ kind: Kind, _ payload: Data = Data()) throws -> Data {
            let box = try AES.GCM.seal(Data([kind.rawValue]) + payload, using: key, nonce: nextNonce())
            return box.ciphertext + box.tag
        }

        /// Throws when the frame was not sealed by the other end of this
        /// session, in this order. A kind this version does not know comes
        /// back as nil, to be passed over rather than refused.
        func open(_ frame: Data) throws -> (kind: Kind?, payload: Data) {
            let nonce = try nextNonce()
            let bytes = [UInt8](frame)
            guard bytes.count >= 17 else { throw Failure.badFrame }
            let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(bytes[0..<(bytes.count - 16)]),
                                            tag: Data(bytes[(bytes.count - 16)...]))
            let plain = [UInt8](try AES.GCM.open(box, using: key))
            guard let first = plain.first else { throw Failure.badFrame }
            return (Kind(rawValue: first), Data(plain.dropFirst()))
        }
    }
}
