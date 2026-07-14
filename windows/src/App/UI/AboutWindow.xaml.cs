using System;
using System.IO;
using System.Net.Http;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace DemoTape.App.UI;

/// <summary>
/// "About DemoTape": version + metadata, camera/mic permission status (with a shortcut into Windows
/// privacy settings), and a manual "Check for Updates" against GitHub Releases. The only network
/// call is the update check, and only when the user clicks it. Windows analogue of the macOS About.
/// </summary>
public sealed partial class AboutWindow : Window
{
    private const string Repo = "gabosarmiento/demotape";
    public const string Version = "5.2.0";
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private string? _releaseUrl;

    public AboutWindow()
    {
        InitializeComponent();
        WindowIcon.Apply(this);
        Title = "About DemoTape";

        var ico = Path.Combine(AppContext.BaseDirectory, "Assets", "trayicon.png");
        if (File.Exists(ico)) LogoImage.Source = new BitmapImage(new Uri(ico));
        VersionText.Text = $"Version {Version}";
        MetaText.Text = "Identifier: dev.demotape.app   ·   Requires Windows 10 2004+   ·   MIT License";

        MicStatus.Text = CapabilityStatus("microphone");
        CamStatus.Text = CapabilityStatus("webcam");
    }

    private static string CapabilityStatus(string capability)
    {
        try
        {
            var status = Windows.Security.Authorization.AppCapabilityAccess.AppCapability
                .Create(capability).CheckAccess();
            return status switch
            {
                Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus.Allowed => "● Granted",
                Windows.Security.Authorization.AppCapabilityAccess.AppCapabilityAccessStatus.UserPromptRequired => "○ Not requested",
                _ => "● Not granted",
            };
        }
        catch { return "—"; }
    }

    private void OnOpenMicSettings(object s, RoutedEventArgs e) => Launch("ms-settings:privacy-microphone");
    private void OnOpenCamSettings(object s, RoutedEventArgs e) => Launch("ms-settings:privacy-webcam");
    private void OnReportIssue(object s, RoutedEventArgs e) => Launch($"https://github.com/{Repo}/issues/new");
    private void OnViewRelease(object s, RoutedEventArgs e) => Launch(_releaseUrl ?? $"https://github.com/{Repo}/releases/latest");

    private async void OnCheckUpdates(object sender, RoutedEventArgs e)
    {
        UpdateButton.IsEnabled = false;
        ReleaseButton.Visibility = Visibility.Collapsed;
        UpdateStatus.Text = "Checking GitHub for the latest release…";
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"https://api.github.com/repos/{Repo}/releases/latest");
            req.Headers.TryAddWithoutValidation("Accept", "application/vnd.github+json");
            req.Headers.TryAddWithoutValidation("User-Agent", "DemoTape-Windows");
            using var resp = await Http.SendAsync(req);
            if ((int)resp.StatusCode == 404) { UpdateStatus.Text = "No published releases yet on GitHub."; return; }
            var body = await resp.Content.ReadAsStringAsync();
            using var doc = JsonDocument.Parse(body);
            var tag = doc.RootElement.TryGetProperty("tag_name", out var t) ? t.GetString() ?? "" : "";
            if (doc.RootElement.TryGetProperty("html_url", out var url)) _releaseUrl = url.GetString();
            var latest = tag.StartsWith("v") ? tag[1..] : tag;

            if (Compare(latest, Version) > 0)
            {
                UpdateStatus.Text = $"Update available: {latest} (you have {Version}).";
                ReleaseButton.Visibility = Visibility.Visible;
            }
            else UpdateStatus.Text = $"You're up to date ({Version}).";
        }
        catch (Exception ex) { UpdateStatus.Text = "Couldn't check for updates: " + ex.Message; }
        finally { UpdateButton.IsEnabled = true; }
    }

    private static int Compare(string a, string b)
    {
        var pa = a.Split('.'); var pb = b.Split('.');
        for (int i = 0; i < Math.Max(pa.Length, pb.Length); i++)
        {
            int x = i < pa.Length && int.TryParse(pa[i], out var xv) ? xv : 0;
            int y = i < pb.Length && int.TryParse(pb[i], out var yv) ? yv : 0;
            if (x != y) return x < y ? -1 : 1;
        }
        return 0;
    }

    private static void Launch(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch { }
    }
}
