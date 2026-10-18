using System.Security.Cryptography;
using System.Text;

namespace TaxCore;

/// Only a salted PBKDF2 hash of the guardian code is ever stored.
public sealed class GuardianRecord
{
    public byte[] Salt { get; set; } = Array.Empty<byte>();
    public byte[] Hash { get; set; } = Array.Empty<byte>();
    public int Iterations { get; set; }
    public DateTimeOffset SetAt { get; set; }
}

/// PBKDF2-HMAC-SHA256, 200k iterations, 16-byte salt, 32-byte key — the same
/// scheme as the Mac's Sources/TaxCore/Guardian.swift, so a code set on one
/// platform verifies identically on the other.
public static class Guardian
{
    public const int MinimumLength = 6;

    public static GuardianRecord MakeRecord(string code, int iterations = 200_000, DateTimeOffset? now = null)
    {
        var salt = RandomNumberGenerator.GetBytes(16);
        return new GuardianRecord
        {
            Salt = salt,
            Hash = Derive(code, salt, iterations),
            Iterations = iterations,
            SetAt = now ?? DateTimeOffset.UtcNow,
        };
    }

    public static bool Verify(string code, GuardianRecord record)
    {
        var candidate = Derive(code, record.Salt, record.Iterations);
        // Fixed-time compare so timing doesn't leak how much matched.
        return CryptographicOperations.FixedTimeEquals(candidate, record.Hash);
    }

    public static byte[] Derive(string code, byte[] salt, int iterations) =>
        Rfc2898DeriveBytes.Pbkdf2(Encoding.UTF8.GetBytes(code), salt, iterations, HashAlgorithmName.SHA256, 32);
}
