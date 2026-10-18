using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace TaxCore;

/// The cryptography of the parent link, exactly as docs/parent-link-v1.md §2–§5.
/// spec/vectors/v1.json checks every piece; the Mac app and the parent web app
/// use the same vectors, so these must agree byte for byte.
public static class LinkCrypto
{
    public sealed class LinkException : Exception
    {
        public LinkException(string message) : base(message) { }
    }

    private static readonly ECCurve P256 = ECCurve.NamedCurves.nistP256;

    // MARK: Encodings

    public static string Base64Url(ReadOnlySpan<byte> data) =>
        Convert.ToBase64String(data).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    public static byte[] FromBase64Url(string text)
    {
        var s = text.Replace('-', '+').Replace('_', '/');
        switch (s.Length % 4) { case 2: s += "=="; break; case 3: s += "="; break; }
        return Convert.FromBase64String(s);
    }

    public static byte[] RandomBytes(int count) => RandomNumberGenerator.GetBytes(count);

    private static byte[] Ascii(string s) => Encoding.ASCII.GetBytes(s);
    private static byte[] Utf8(string s) => Encoding.UTF8.GetBytes(s);
    private static byte[] Cat(params byte[][] parts)
    {
        var len = parts.Sum(p => p.Length);
        var buf = new byte[len];
        var o = 0;
        foreach (var p in parts) { Buffer.BlockCopy(p, 0, buf, o, p.Length); o += p.Length; }
        return buf;
    }

    public static byte[] Sha256(ReadOnlySpan<byte> data) => SHA256.HashData(data);

    public static byte[] Hkdf(byte[] ikm, byte[] salt, byte[] info, int count) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, count, salt, info);

    // MARK: Pairing code (§4.1)

    public const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    /// Uppercase, O→0, I and L→1, and drop anything else outside the alphabet.
    public static string NormaliseCode(string input)
    {
        var sb = new StringBuilder();
        foreach (var raw in input.ToUpperInvariant())
        {
            var c = raw == 'O' ? '0' : (raw == 'I' || raw == 'L') ? '1' : raw;
            if (Alphabet.IndexOf(c) >= 0) sb.Append(c);
        }
        return sb.ToString();
    }

    public static string NewPairingCode()
    {
        var bytes = RandomBytes(10);
        var sb = new StringBuilder(10);
        foreach (var b in bytes) sb.Append(Alphabet[b % 32]);
        return sb.ToString();
    }

    /// "ABCDE-FGHJK".
    public static string DisplayCode(string code)
    {
        var c = NormaliseCode(code);
        return c.Length == 10 ? c[..5] + "-" + c[5..] : c;
    }

    /// The server slot and the key that seals every pairing message.
    public static (string Slot, byte[] Key) Pairing(string code)
    {
        var ikm = Utf8(NormaliseCode(code));
        var salt = Ascii("tc v1 pair");
        var slot = Base64Url(Hkdf(ikm, salt, Ascii("tc v1 pair slot"), 16));
        var key = Hkdf(ikm, salt, Ascii("tc v1 pair key"), 32);
        return (slot, key);
    }

    public static byte[] PairAad(string slot) => Ascii("tc v1 pair|" + slot);
    public static byte[] CommandAad(string channel, string device) => Ascii("tc v1 cmd|" + channel + "|" + device);
    public static byte[] StateAad(string channel, string device) => Ascii("tc v1 state|" + channel + "|" + device);

    // MARK: Boxes (§2) — nonce(12) ‖ ciphertext ‖ tag(16)

    public static byte[] Seal(byte[] plaintext, byte[] key, byte[] aad, byte[]? nonce = null)
    {
        var n = nonce ?? RandomBytes(12);
        if (n.Length != 12) throw new LinkException("nonce must be 12 bytes");
        var ciphertext = new byte[plaintext.Length];
        var tag = new byte[16];
        using var gcm = new AesGcm(key, 16);
        gcm.Encrypt(n, plaintext, ciphertext, tag, aad);
        return Cat(n, ciphertext, tag);
    }

    public static byte[] Open(byte[] box, byte[] key, byte[] aad)
    {
        if (box.Length < 12 + 16) throw new LinkException("box too short");
        var n = box[..12];
        var tag = box[^16..];
        var ciphertext = box[12..^16];
        var plaintext = new byte[ciphertext.Length];
        try
        {
            using var gcm = new AesGcm(key, 16);
            gcm.Decrypt(n, ciphertext, tag, plaintext, aad);
            return plaintext;
        }
        catch (CryptographicException) { throw new LinkException("box would not open"); }
    }

    // MARK: Commit, reveal, compare (§4.2)

    public static byte[] Commitment(byte[] signKey, byte[] dhKey, byte[] nonce, byte[] tokenHash, string name) =>
        Sha256(Cat(Ascii("tc v1 commit"), signKey, dhKey, nonce, tokenHash, Utf8(name)));

    /// Six digits, "123456" (callers space it).
    public static string ComparisonCode(byte[] computerNonce, byte[] phoneNonce, byte[] computerDhKey,
                                        byte[] phoneSignKey, byte[] phoneDhKey)
    {
        var h = Sha256(Cat(Ascii("tc v1 sas"), computerNonce, phoneNonce, computerDhKey, phoneSignKey, phoneDhKey));
        uint n = ((uint)h[0] << 24) | ((uint)h[1] << 16) | ((uint)h[2] << 8) | h[3];
        return (n % 1_000_000).ToString("D6");
    }

    // MARK: Link key (§4.4)

    /// The 32-byte ECDH shared secret (the raw X coordinate).
    public static byte[] SharedSecret(ECDiffieHellman ownPrivate, byte[] peerPublicPoint)
    {
        using var peer = ImportEcdhPublic(peerPublicPoint);
        return ownPrivate.DeriveRawSecretAgreement(peer.PublicKey);
    }

    public static byte[] LinkKey(ECDiffieHellman computer, byte[] phoneDhPublic, string channel, string deviceId)
    {
        var shared = SharedSecret(computer, phoneDhPublic);
        return Hkdf(shared, FromBase64Url(channel), Ascii("tc v1 link|" + deviceId), 32);
    }

    // MARK: Signatures (§5.1) — ECDSA P-256 / SHA-256, raw r‖s

    public static bool IsValidSignature(byte[] signature, byte[] body, byte[] publicKeyPoint)
    {
        if (signature.Length != 64) return false;
        try
        {
            using var ecdsa = ImportEcdsaPublic(publicKeyPoint);
            return ecdsa.VerifyData(body, signature, HashAlgorithmName.SHA256,
                                    DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch { return false; }
    }

    public static byte[] Sign(ECDsa signingKey, byte[] body) =>
        signingKey.SignData(body, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    // MARK: Raw DEFLATE (RFC 1951, no zlib header)

    public static byte[] DeflateRaw(byte[] data)
    {
        using var ms = new MemoryStream();
        using (var ds = new DeflateStream(ms, CompressionLevel.Optimal, leaveOpen: true)) ds.Write(data, 0, data.Length);
        return ms.ToArray();
    }

    public static byte[] InflateRaw(byte[] data)
    {
        using var input = new MemoryStream(data);
        using var ds = new DeflateStream(input, CompressionMode.Decompress);
        using var ms = new MemoryStream();
        ds.CopyTo(ms);
        return ms.ToArray();
    }

    // MARK: Key import helpers

    /// 65-byte uncompressed point 04‖X(32)‖Y(32) → ECPoint.
    private static ECPoint PointFrom(byte[] uncompressed)
    {
        if (uncompressed.Length != 65 || uncompressed[0] != 0x04) throw new LinkException("not a 65-byte uncompressed point");
        return new ECPoint { X = uncompressed[1..33], Y = uncompressed[33..65] };
    }

    public static ECDsa ImportEcdsaPublic(byte[] point) =>
        ECDsa.Create(new ECParameters { Curve = P256, Q = PointFrom(point) });

    public static ECDiffieHellman ImportEcdhPublic(byte[] point) =>
        ECDiffieHellman.Create(new ECParameters { Curve = P256, Q = PointFrom(point) });

    public static ECDiffieHellman ImportEcdhPrivate(byte[] d, byte[] x, byte[] y) =>
        ECDiffieHellman.Create(new ECParameters { Curve = P256, D = d, Q = new ECPoint { X = x, Y = y } });

    public static ECDsa ImportEcdsaPrivate(byte[] d, byte[] x, byte[] y) =>
        ECDsa.Create(new ECParameters { Curve = P256, D = d, Q = new ECPoint { X = x, Y = y } });

    /// The 65-byte uncompressed public point of a private key.
    public static byte[] PublicPoint(ECParameters p)
    {
        var point = new byte[65];
        point[0] = 0x04;
        Buffer.BlockCopy(p.Q.X!, 0, point, 1, 32);
        Buffer.BlockCopy(p.Q.Y!, 0, point, 33, 32);
        return point;
    }
}
