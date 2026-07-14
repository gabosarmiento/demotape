namespace DemoTape.Domain.Abstractions;

/// <summary>
/// Secure store for bring-your-own-key API secrets. The Windows analogue of the macOS Keychain
/// wrapper: keys never touch settings JSON or disk in the clear — the implementation keeps them in
/// Windows Credential Manager. Read only when an AI feature is actually used.
/// </summary>
public interface IKeyStore
{
    /// <summary>Stores (or overwrites) the secret for <paramref name="account"/>.</summary>
    void Set(string account, string secret);

    /// <summary>Returns the secret, or null if none is stored.</summary>
    string? Get(string account);

    /// <summary>Whether a secret exists, without decrypting it (safe for UI gating).</summary>
    bool Exists(string account);

    /// <summary>Removes the stored secret (no-op if absent).</summary>
    void Remove(string account);
}
