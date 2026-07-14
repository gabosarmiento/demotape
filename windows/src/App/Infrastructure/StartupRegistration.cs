using Microsoft.Win32;

namespace DemoTape.App.Infrastructure;

/// <summary>
/// Toggles "launch DemoTape at login" via the per-user Run key. The Windows analogue of the macOS
/// <c>LoginItem</c> (SMAppService). No admin rights needed; it only affects the current user.
/// </summary>
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "DemoTape";

    private static string ExePath => Environment.ProcessPath ?? "";

    public static bool IsEnabled
    {
        get
        {
            try
            {
                using var key = Registry.CurrentUser.OpenSubKey(RunKey);
                return key?.GetValue(ValueName) is string v && v.Trim('"').Equals(ExePath, StringComparison.OrdinalIgnoreCase);
            }
            catch { return false; }
        }
    }

    /// <summary>Returns true on success.</summary>
    public static bool SetEnabled(bool enabled)
    {
        try
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (key is null) return false;
            if (enabled) key.SetValue(ValueName, $"\"{ExePath}\"");
            else key.DeleteValue(ValueName, throwOnMissingValue: false);
            return true;
        }
        catch { return false; }
    }
}
