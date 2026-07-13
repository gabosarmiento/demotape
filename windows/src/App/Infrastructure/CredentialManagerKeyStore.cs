using System.Runtime.InteropServices;
using System.Text;
using DemoTape.Domain.Abstractions;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Stores BYO-key API secrets in Windows Credential Manager (Generic credentials) via the Win32
/// credential API — dependency-free and works in an unpackaged desktop app. The Windows analogue
/// of the macOS Keychain wrapper. Target names are prefixed so they're easy to find/clear.
/// </summary>
public sealed class CredentialManagerKeyStore : IKeyStore
{
    private const string Prefix = "DemoTape:";

    public void Set(string account, string secret)
    {
        var blob = Encoding.UTF8.GetBytes(secret ?? "");
        var handle = GCHandle.Alloc(blob, GCHandleType.Pinned);
        try
        {
            var cred = new CREDENTIAL
            {
                Type = CRED_TYPE_GENERIC,
                TargetName = Prefix + account,
                CredentialBlob = handle.AddrOfPinnedObject(),
                CredentialBlobSize = (uint)blob.Length,
                Persist = CRED_PERSIST_LOCAL_MACHINE,
                UserName = "DemoTape",
            };
            if (!CredWrite(ref cred, 0))
                throw new InvalidOperationException($"CredWrite failed (error {Marshal.GetLastWin32Error()})");
        }
        finally { handle.Free(); }
    }

    public string? Get(string account)
    {
        if (!CredRead(Prefix + account, CRED_TYPE_GENERIC, 0, out var ptr)) return null;
        try
        {
            var cred = Marshal.PtrToStructure<CREDENTIAL>(ptr);
            if (cred.CredentialBlobSize == 0 || cred.CredentialBlob == IntPtr.Zero) return null;
            var bytes = new byte[cred.CredentialBlobSize];
            Marshal.Copy(cred.CredentialBlob, bytes, 0, bytes.Length);
            var value = Encoding.UTF8.GetString(bytes);
            return string.IsNullOrEmpty(value) ? null : value;
        }
        finally { CredFree(ptr); }
    }

    public bool Exists(string account)
    {
        if (!CredRead(Prefix + account, CRED_TYPE_GENERIC, 0, out var ptr)) return false;
        CredFree(ptr);
        return true;
    }

    public void Remove(string account) => CredDelete(Prefix + account, CRED_TYPE_GENERIC, 0);

    // ---- Win32 interop ----
    private const uint CRED_TYPE_GENERIC = 1;
    private const uint CRED_PERSIST_LOCAL_MACHINE = 2;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct CREDENTIAL
    {
        public uint Flags;
        public uint Type;
        public string TargetName;
        public string? Comment;
        public long LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;
        public string? TargetAlias;
        public string? UserName;
    }

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredWriteW")]
    private static extern bool CredWrite(ref CREDENTIAL credential, uint flags);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredReadW")]
    private static extern bool CredRead(string target, uint type, uint flags, out IntPtr credential);

    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CredDeleteW")]
    private static extern bool CredDelete(string target, uint type, uint flags);

    [DllImport("advapi32.dll")]
    private static extern void CredFree(IntPtr buffer);
}
