using System.Buffers.Binary;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ScreenHere;

/// The shared clipboard's wire format, the same on Windows and on the Mac —
/// docs/SHARED-CLIPBOARD.md is its description, and both apps check the same
/// test vectors against it.
///
/// Two devices on one network, no server in between and no account. They are
/// introduced once, by a code shown on both screens; from then on everything
/// they say to each other is encrypted with a key only the two of them have.
internal static class SyncProtocol
{
    public const string ServiceType = "_screenhere._tcp";
    /// Asked for first, so a device that was seen once can be found again at
    /// the same address without being announced. Any free port otherwise.
    public const int PreferredPort = 47583;
    public const int Version = 1;
    /// A frame is at most this long: a picture's limit, and some room.
    public const int MaxFrame = 32 * 1024 * 1024;
    public const int MaxText = 1024 * 1024;

    /// What a sealed frame carries, in its first byte.
    public enum Kind : byte { Ready = 0, Text = 1, Image = 2, Ping = 3 }

    // MARK: - Messages in the clear

    /// The messages that come before there is a key, as JSON.
    public sealed record Message
    {
        [JsonPropertyName("t")] public string Type { get; init; } = "";
        [JsonPropertyName("v")] public int? Version { get; init; }
        [JsonPropertyName("id")] public string? Id { get; init; }
        [JsonPropertyName("name")] public string? Name { get; init; }
        [JsonPropertyName("commit")] public string? Commit { get; init; }
        [JsonPropertyName("pub")] public string? Public { get; init; }
        [JsonPropertyName("nonce")] public string? Nonce { get; init; }
        [JsonPropertyName("ok")] public bool? Ok { get; init; }
    }

    private static readonly JsonSerializerOptions Json = new() { DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull };

    public static byte[] Encode(Message message) => JsonSerializer.SerializeToUtf8Bytes(message, Json);

    public static Message? Decode(byte[] frame)
    {
        try { return JsonSerializer.Deserialize<Message>(frame, Json); }
        catch (JsonException) { return null; }
    }

    // MARK: - Frames

    /// Every message, sealed or not, travels as its length and then itself.
    public static async Task WriteFrame(Stream stream, byte[] body, CancellationToken cancel)
    {
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)body.Length);
        await stream.WriteAsync(header, cancel);
        await stream.WriteAsync(body, cancel);
        await stream.FlushAsync(cancel);
    }

    public static async Task<byte[]> ReadFrame(Stream stream, CancellationToken cancel)
    {
        var header = new byte[4];
        await stream.ReadExactlyAsync(header, cancel);
        var length = BinaryPrimitives.ReadUInt32BigEndian(header);
        if (length > MaxFrame) throw new InvalidDataException("Frame too long");
        var body = new byte[length];
        await stream.ReadExactlyAsync(body, cancel);
        return body;
    }

    // MARK: - Keys

    public static ECDiffieHellman NewKey() => ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256);

    /// The public key as 0x04, X, Y: 65 bytes, the form every library reads.
    public static byte[] PublicBytes(ECDiffieHellman key)
    {
        var q = key.ExportParameters(false).Q;
        return [0x04, .. q.X!, .. q.Y!];
    }

    private static ECDiffieHellman Import(byte[] publicKey)
    {
        if (publicKey.Length != 65 || publicKey[0] != 0x04) throw new CryptographicException("Not a public key");
        return ECDiffieHellman.Create(new ECParameters
        {
            Curve = ECCurve.NamedCurves.nistP256,
            Q = new ECPoint { X = publicKey[1..33], Y = publicKey[33..65] },
        });
    }

    public static byte[] Agree(ECDiffieHellman ours, byte[] theirPublic)
    {
        using var theirs = Import(theirPublic);
        return ours.DeriveRawSecretAgreement(theirs.PublicKey);
    }

    public static byte[] RandomBytes(int count) => RandomNumberGenerator.GetBytes(count);

    // MARK: - Pairing

    /// What the device that asks to be paired sends first: a promise about a
    /// key it has not shown yet. Without it, someone in the middle could pick
    /// their own key after seeing ours, and steer the code on both screens.
    public static byte[] Commitment(byte[] publicKey, byte[] nonce) => SHA256.HashData([.. publicKey, .. nonce]);

    /// The key the two devices keep, and the six digits both show. `asking`
    /// is the device that sent the first message.
    public static (byte[] Key, string Code) Pairing(byte[] shared, byte[] askingPublic, byte[] answeringPublic,
                                                     byte[] askingNonce, byte[] answeringNonce)
    {
        var salt = SHA256.HashData([.. askingPublic, .. answeringPublic, .. askingNonce, .. answeringNonce]);
        var material = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 36, salt, Encoding.ASCII.GetBytes("ScreenHere pairing v1"));
        var digits = BinaryPrimitives.ReadUInt32BigEndian(material.AsSpan(32)) % 1_000_000;
        return (material[..32], digits.ToString("000000"));
    }

    /// "482 913", as the panel shows it.
    public static string Spaced(string code) => code.Length == 6 ? $"{code[..3]} {code[3..]}" : code;

    // MARK: - Sessions

    /// One key per direction, new for every connection: the devices' own key
    /// proves who is talking, and the keys made for this connection alone keep
    /// what was said from being read later, should that key ever leak.
    public static (byte[] ClientToServer, byte[] ServerToClient) SessionKeys(byte[] shared, byte[] pairKey,
                                                                              byte[] clientNonce, byte[] serverNonce)
    {
        byte[] material = [.. shared, .. pairKey];
        byte[] salt = [.. clientNonce, .. serverNonce];
        return (HKDF.DeriveKey(HashAlgorithmName.SHA256, material, 32, salt, Encoding.ASCII.GetBytes("ScreenHere sync v1 c2s")),
                HKDF.DeriveKey(HashAlgorithmName.SHA256, material, 32, salt, Encoding.ASCII.GetBytes("ScreenHere sync v1 s2c")));
    }

    /// One direction of a session: frames numbered from zero, each sealed
    /// under its number, so none can be replayed, dropped or reordered unseen.
    public sealed class Cipher(byte[] key) : IDisposable
    {
        private readonly AesGcm aes = new(key, 16);
        private ulong counter;

        private byte[] NextNonce()
        {
            var nonce = new byte[12];
            BinaryPrimitives.WriteUInt64BigEndian(nonce.AsSpan(4), counter++);
            return nonce;
        }

        public byte[] Seal(Kind kind, ReadOnlySpan<byte> payload)
        {
            var plain = new byte[payload.Length + 1];
            plain[0] = (byte)kind;
            payload.CopyTo(plain.AsSpan(1));
            var sealedFrame = new byte[plain.Length + 16];
            aes.Encrypt(NextNonce(), plain, sealedFrame.AsSpan(0, plain.Length), sealedFrame.AsSpan(plain.Length));
            return sealedFrame;
        }

        /// Throws when the frame was not sealed by the other end of this
        /// session, in this order.
        public (Kind Kind, byte[] Payload) Open(byte[] sealedFrame)
        {
            if (sealedFrame.Length < 17) throw new CryptographicException("Frame too short");
            var plain = new byte[sealedFrame.Length - 16];
            aes.Decrypt(NextNonce(), sealedFrame.AsSpan(0, plain.Length), sealedFrame.AsSpan(plain.Length), plain);
            return ((Kind)plain[0], plain[1..]);
        }

        public void Dispose() => aes.Dispose();
    }

    public static string Base64(byte[] bytes) => Convert.ToBase64String(bytes);

    public static byte[]? FromBase64(string? text)
    {
        try { return text == null ? null : Convert.FromBase64String(text); }
        catch (FormatException) { return null; }
    }
}
