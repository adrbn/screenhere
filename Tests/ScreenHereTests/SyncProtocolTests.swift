import CryptoKit
import XCTest
@testable import ScreenHere

/// The same vectors are checked by the Windows app, in SyncProtocolTests.cs:
/// two apps that both pass speak the same protocol, byte for byte.
final class SyncProtocolTests: XCTestCase {
    private func hex(_ text: String) -> Data {
        var data = Data()
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            data.append(UInt8(text[index..<next], radix: 16)!)
            index = next
        }
        return data
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private func fill(_ count: Int, _ seed: Int) -> Data {
        Data((0..<count).map { UInt8(($0 * 7 + seed) & 0xff) })
    }

    private let privateA = "a49c3dbecd71c240bbe7c0dad312d4048a861e32c9ab996faec882937030fbb6"
    private let publicA = "0417b9f2e2344fec022d31091ad47b0adc10e777152a95d0994a88e4f75b0f93728b435dbce37136df19c5a18d087b217b9d0a87727a67e2df199afadf67dc434e"
    private let privateB = "121caa8a50db1069fb17a80ac6cab7aa39276e58f6c41c5bd5746ef9ebb056ea"
    private let publicB = "044ce2288c7c249177e57275e7c3a3d0e741ecd2e6bbdf008aacddf50db80c6ca8d539331597d08b5f58f60c0118b30662916ed43f82e39a95026ce4ed2917ecac"
    private let shared = "9fa7cfdbabe04c166fe6769d107923d64cfe9b3c6beaf4eb71f286e95f061edb"
    private let pairKey = "29be0fe54a0c1c3a6c96b52cafd9dd8b3253fa6d7ef348f6a94d74930b112a2f"
    private let clientToServer = "b4b775cce8680df5e1e9dd76519da36c254f9ae4efa9a5728b29621c300d039e"
    private let serverToClient = "811da3f9faa25fbed47d77e11ddfe5023096eb7ddb3d0d9923df1503857481d8"
    private let frame0 = "051ab77e78c7b0c06a12178e8bae783629"
    private let frame1 = "f8f9fb4ab963a83e5ff65543775a0893edf7be1e70dc3cfe3072ebbe7eb6e45ad8943e5a314804f4a70048d6bd"
    private let text = "Déjà vu — blue-harbor-72"

    func testBothSidesAgreeOnTheSameSecret() throws {
        let a = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(privateA))
        let b = try P256.KeyAgreement.PrivateKey(rawRepresentation: hex(privateB))
        XCTAssertEqual(hex(SyncProtocol.publicBytes(a)), publicA)
        XCTAssertEqual(hex(SyncProtocol.publicBytes(b)), publicB)
        XCTAssertEqual(hex(try SyncProtocol.agree(a, with: hex(publicB))), shared)
        XCTAssertEqual(hex(try SyncProtocol.agree(b, with: hex(publicA))), shared)
    }

    func testThePairingKeyAndCodeAreTheVectors() {
        XCTAssertEqual(hex(SyncProtocol.commitment(publicKey: hex(publicA), nonce: fill(32, 1))),
                       "ab571c768c099d280aaba0dd2615f3c5f6a7960feba6797e2f479b9350ef4a81")
        let pairing = SyncProtocol.pairing(shared: hex(shared), askingPublic: hex(publicA), answeringPublic: hex(publicB),
                                           askingNonce: fill(32, 1), answeringNonce: fill(32, 2))
        XCTAssertEqual(hex(pairing.key), pairKey)
        XCTAssertEqual(pairing.code, "482743")
        XCTAssertEqual(SyncProtocol.spaced(pairing.code), "482 743")
    }

    func testTheCodeDependsOnEveryKeyAndNonce() {
        func code(_ a: String, _ b: String, _ na: Int, _ nb: Int) -> String {
            SyncProtocol.pairing(shared: hex(shared), askingPublic: hex(a), answeringPublic: hex(b),
                                 askingNonce: fill(32, na), answeringNonce: fill(32, nb)).code
        }
        let expected = code(publicA, publicB, 1, 2)
        XCTAssertNotEqual(code(publicB, publicA, 1, 2), expected)
        XCTAssertNotEqual(code(publicA, publicB, 3, 2), expected)
        XCTAssertNotEqual(code(publicA, publicB, 1, 3), expected)
    }

    func testTheSessionKeysAreTheVectors() {
        let keys = SyncProtocol.sessionKeys(shared: hex(shared), pairKey: hex(pairKey),
                                            clientNonce: fill(32, 1), serverNonce: fill(32, 2))
        XCTAssertEqual(hex(keys.clientToServer), clientToServer)
        XCTAssertEqual(hex(keys.serverToClient), serverToClient)
    }

    func testFramesAreSealedAsTheVectors() throws {
        let cipher = SyncProtocol.Cipher(key: hex(clientToServer))
        XCTAssertEqual(hex(try cipher.seal(.ready)), frame0)
        XCTAssertEqual(hex(try cipher.seal(.text, Data(text.utf8))), frame1)
    }

    func testFramesOpenInOrderAndOnlyInOrder() throws {
        let opening = SyncProtocol.Cipher(key: hex(clientToServer))
        XCTAssertEqual(try opening.open(hex(frame0)).kind, .ready)
        let second = try opening.open(hex(frame1))
        XCTAssertEqual(second.kind, .text)
        XCTAssertEqual(String(decoding: second.payload, as: UTF8.self), text)

        let skipping = SyncProtocol.Cipher(key: hex(clientToServer))
        XCTAssertThrowsError(try skipping.open(hex(frame1)))
        let replaying = SyncProtocol.Cipher(key: hex(clientToServer))
        _ = try replaying.open(hex(frame0))
        XCTAssertThrowsError(try replaying.open(hex(frame0)))
    }

    func testATamperedFrameOrAnotherKeyIsRefused() throws {
        var tampered = hex(frame1)
        tampered[3] ^= 1
        let first = SyncProtocol.Cipher(key: hex(clientToServer))
        _ = try first.open(hex(frame0))
        XCTAssertThrowsError(try first.open(tampered))
        XCTAssertThrowsError(try SyncProtocol.Cipher(key: hex(serverToClient)).open(hex(frame0)))
        XCTAssertThrowsError(try SyncProtocol.Cipher(key: hex(clientToServer)).open(Data(count: 16)))
    }

    func testMessagesAreJSONWithShortNamesAndNothingUnset() throws {
        let encoded = SyncProtocol.encode(.init(t: "pair4", ok: true))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["t", "ok"])

        // As Windows writes it, unknown fields and all.
        let hello = try XCTUnwrap(SyncProtocol.decode(Data(#"{"t":"hello","v":1,"id":"abc","pub":"AQID","nonce":"BAUG","later":"ignored"}"#.utf8)))
        XCTAssertEqual(hello.t, "hello")
        XCTAssertEqual(hello.v, 1)
        XCTAssertEqual(hello.id, "abc")
        XCTAssertEqual(Data(base64Encoded: hello.pub ?? ""), Data([1, 2, 3]))
        XCTAssertNil(SyncProtocol.decode(Data("not json".utf8)))
    }

    func testAFrameIsItsLengthThenItself() {
        XCTAssertEqual(SyncProtocol.header(for: 3), Data([0, 0, 0, 3]))
        XCTAssertEqual(SyncProtocol.header(for: 0x0102_0304), Data([1, 2, 3, 4]))
        XCTAssertEqual(SyncProtocol.length(from: Data([0, 0, 0, 3])), 3)
        XCTAssertEqual(SyncProtocol.length(from: Data([0, 0, 1, 0])), 256)
        XCTAssertNil(SyncProtocol.length(from: Data([0x7f, 0xff, 0xff, 0xff])))
        XCTAssertNil(SyncProtocol.length(from: Data([0, 0, 3])))
    }
}
