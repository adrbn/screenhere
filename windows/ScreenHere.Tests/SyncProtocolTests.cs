using System.IO;
using System.Security.Cryptography;
using System.Text;

namespace ScreenHere.Tests;

/// The same vectors are checked by the Mac app, in SyncProtocolTests.swift:
/// two apps that both pass speak the same protocol, byte for byte.
public class SyncProtocolTests
{
    private static byte[] Hex(string hex) => Convert.FromHexString(hex);
    private static string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();
    private static byte[] Fill(int count, int seed) => Enumerable.Range(0, count).Select(i => (byte)(i * 7 + seed)).ToArray();

    private const string PrivateA = "a49c3dbecd71c240bbe7c0dad312d4048a861e32c9ab996faec882937030fbb6";
    private const string PublicA = "0417b9f2e2344fec022d31091ad47b0adc10e777152a95d0994a88e4f75b0f93728b435dbce37136df19c5a18d087b217b9d0a87727a67e2df199afadf67dc434e";
    private const string PrivateB = "121caa8a50db1069fb17a80ac6cab7aa39276e58f6c41c5bd5746ef9ebb056ea";
    private const string PublicB = "044ce2288c7c249177e57275e7c3a3d0e741ecd2e6bbdf008aacddf50db80c6ca8d539331597d08b5f58f60c0118b30662916ed43f82e39a95026ce4ed2917ecac";
    private const string Shared = "9fa7cfdbabe04c166fe6769d107923d64cfe9b3c6beaf4eb71f286e95f061edb";
    private const string PairKey = "29be0fe54a0c1c3a6c96b52cafd9dd8b3253fa6d7ef348f6a94d74930b112a2f";
    private const string ClientToServer = "b4b775cce8680df5e1e9dd76519da36c254f9ae4efa9a5728b29621c300d039e";
    private const string ServerToClient = "811da3f9faa25fbed47d77e11ddfe5023096eb7ddb3d0d9923df1503857481d8";
    private const string Frame0 = "051ab77e78c7b0c06a12178e8bae783629";
    private const string Frame1 = "f8f9fb4ab963a83e5ff65543775a0893edf7be1e70dc3cfe3072ebbe7eb6e45ad8943e5a314804f4a70048d6bd";
    private const string Text = "Déjà vu — blue-harbor-72";

    private static ECDiffieHellman Key(string d, string q)
    {
        var point = Hex(q);
        return ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256, D = Hex(d),
            Q = new ECPoint { X = point[1..33], Y = point[33..65] },
        });
    }

    [Fact]
    public void BothSidesAgreeOnTheSameSecret()
    {
        using var a = Key(PrivateA, PublicA);
        using var b = Key(PrivateB, PublicB);
        Assert.Equal(PublicA, Hex(SyncProtocol.PublicBytes(a)));
        Assert.Equal(Shared, Hex(SyncProtocol.Agree(a, Hex(PublicB))));
        Assert.Equal(Shared, Hex(SyncProtocol.Agree(b, Hex(PublicA))));
    }

    [Fact]
    public void ThePairingKeyAndCodeAreTheVectors()
    {
        Assert.Equal("ab571c768c099d280aaba0dd2615f3c5f6a7960feba6797e2f479b9350ef4a81", Hex(SyncProtocol.Commitment(Hex(PublicA), Fill(32, 1))));
        var (key, code) = SyncProtocol.Pairing(Hex(Shared), Hex(PublicA), Hex(PublicB), Fill(32, 1), Fill(32, 2));
        Assert.Equal(PairKey, Hex(key));
        Assert.Equal("482743", code);
        Assert.Equal("482 743", SyncProtocol.Spaced(code));
    }

    [Fact]
    public void TheCodeDependsOnEveryKeyAndNonce()
    {
        var code = SyncProtocol.Pairing(Hex(Shared), Hex(PublicA), Hex(PublicB), Fill(32, 1), Fill(32, 2)).Code;
        Assert.NotEqual(code, SyncProtocol.Pairing(Hex(Shared), Hex(PublicB), Hex(PublicA), Fill(32, 1), Fill(32, 2)).Code);
        Assert.NotEqual(code, SyncProtocol.Pairing(Hex(Shared), Hex(PublicA), Hex(PublicB), Fill(32, 3), Fill(32, 2)).Code);
        Assert.NotEqual(code, SyncProtocol.Pairing(Hex(Shared), Hex(PublicA), Hex(PublicB), Fill(32, 1), Fill(32, 3)).Code);
    }

    [Fact]
    public void TheSessionKeysAreTheVectors()
    {
        var (toServer, toClient) = SyncProtocol.SessionKeys(Hex(Shared), Hex(PairKey), Fill(32, 1), Fill(32, 2));
        Assert.Equal(ClientToServer, Hex(toServer));
        Assert.Equal(ServerToClient, Hex(toClient));
    }

    [Fact]
    public void FramesAreSealedAsTheVectors()
    {
        using var cipher = new SyncProtocol.Cipher(Hex(ClientToServer));
        Assert.Equal(Frame0, Hex(cipher.Seal(SyncProtocol.Kind.Ready, [])));
        Assert.Equal(Frame1, Hex(cipher.Seal(SyncProtocol.Kind.Text, Encoding.UTF8.GetBytes(Text))));
    }

    [Fact]
    public void FramesOpenInOrderAndOnlyInOrder()
    {
        using var opening = new SyncProtocol.Cipher(Hex(ClientToServer));
        Assert.Equal(SyncProtocol.Kind.Ready, opening.Open(Hex(Frame0)).Kind);
        var (kind, payload) = opening.Open(Hex(Frame1));
        Assert.Equal(SyncProtocol.Kind.Text, kind);
        Assert.Equal(Text, Encoding.UTF8.GetString(payload));

        using var skipping = new SyncProtocol.Cipher(Hex(ClientToServer));
        Assert.ThrowsAny<CryptographicException>(() => skipping.Open(Hex(Frame1)));
        using var replaying = new SyncProtocol.Cipher(Hex(ClientToServer));
        replaying.Open(Hex(Frame0));
        Assert.ThrowsAny<CryptographicException>(() => replaying.Open(Hex(Frame0)));
    }

    [Fact]
    public void ATamperedFrameOrAnotherKeyIsRefused()
    {
        var tampered = Hex(Frame1);
        tampered[3] ^= 1;
        using var first = new SyncProtocol.Cipher(Hex(ClientToServer));
        first.Open(Hex(Frame0));
        Assert.ThrowsAny<CryptographicException>(() => first.Open(tampered));
        using var other = new SyncProtocol.Cipher(Hex(ServerToClient));
        Assert.ThrowsAny<CryptographicException>(() => other.Open(Hex(Frame0)));
        using var shortFrame = new SyncProtocol.Cipher(Hex(ClientToServer));
        Assert.ThrowsAny<CryptographicException>(() => shortFrame.Open(new byte[16]));
    }

    [Fact]
    public void MessagesAreJsonWithShortNamesAndNothingUnset()
    {
        var bytes = SyncProtocol.Encode(new() { Type = "pair4", Ok = true });
        Assert.Equal("""{"t":"pair4","ok":true}""", Encoding.UTF8.GetString(bytes));
        var hello = SyncProtocol.Decode(Encoding.UTF8.GetBytes("""{"t":"hello","v":1,"id":"abc","pub":"AQID","nonce":"BAUG","later":"ignored"}"""));
        Assert.Equal(("hello", 1, "abc"), (hello!.Type, hello.Version, hello.Id));
        Assert.Equal(new byte[] { 1, 2, 3 }, SyncProtocol.FromBase64(hello.Public));
        Assert.Null(SyncProtocol.Decode(Encoding.UTF8.GetBytes("not json")));
        Assert.Null(SyncProtocol.FromBase64("not base64!"));
    }

    [Fact]
    public async Task AFrameIsItsLengthThenItself()
    {
        using var stream = new MemoryStream();
        await SyncProtocol.WriteFrame(stream, [1, 2, 3], CancellationToken.None);
        Assert.Equal(new byte[] { 0, 0, 0, 3, 1, 2, 3 }, stream.ToArray());
        stream.Position = 0;
        Assert.Equal(new byte[] { 1, 2, 3 }, await SyncProtocol.ReadFrame(stream, CancellationToken.None));

        using var tooLong = new MemoryStream([0x7f, 0xff, 0xff, 0xff, 0]);
        await Assert.ThrowsAsync<InvalidDataException>(() => SyncProtocol.ReadFrame(tooLong, CancellationToken.None));
        using var cutShort = new MemoryStream([0, 0, 0, 9, 1, 2]);
        await Assert.ThrowsAsync<EndOfStreamException>(() => SyncProtocol.ReadFrame(cutShort, CancellationToken.None));
    }
}
