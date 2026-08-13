using DemoTape.Domain.Abstractions;
using DemoTape.Domain.Settings;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace DemoTape.App.UI;

/// <summary>
/// A single explainer card shown in the <see cref="FeatureCardsWindow"/>.
/// </summary>
public sealed record FeatureCard(string Id, string Title, string Body, string Icon)
{
    /// <summary>The four built-in first-run explainer cards, in display order.</summary>
    public static readonly IReadOnlyList<FeatureCard> All = new[]
    {
        new FeatureCard(
            Id:    "output-formats",
            Title: "Output formats",
            Body:  "DemoTape exports to tiered web MP4s, GIF, and social aspect ratios via Web Export.",
            Icon:  ""),   // Segoe MDL2: Share

        new FeatureCard(
            Id:    "teleprompter",
            Title: "Teleprompter",
            Body:  "Keep your script on screen while recording — excluded from the capture.",
            Icon:  ""),   // Segoe MDL2: ReadingMode

        new FeatureCard(
            Id:    "share-for-ai",
            Title: "Share for AI",
            Body:  "Drop your recording in your coding agent's context to narrate, caption, or reframe it.",
            Icon:  ""),   // Segoe MDL2: Robot / Comment

        new FeatureCard(
            Id:    "control-surface",
            Title: "Control surface",
            Body:  "Control DemoTape from your agent or terminal via the demotape:// URL scheme.",
            Icon:  ""),   // Segoe MDL2: Code
    };
}

/// <summary>
/// Shows a paged set of first-run explainer cards (2nd–4th launch). Each card can be dismissed
/// individually with "Got it" or globally suppressed with "Don't show again". Dismissed card IDs
/// are persisted in <see cref="AppSettings.DismissedCards"/>.
/// </summary>
public sealed partial class FeatureCardsWindow : Window
{
    private readonly ISettingsStore _settingsStore;
    private readonly IReadOnlyList<FeatureCard> _cards;

    public FeatureCardsWindow(ISettingsStore settingsStore, IReadOnlyList<FeatureCard> cards)
    {
        _settingsStore = settingsStore;
        _cards = cards;
        InitializeComponent();
        WindowIcon.Apply(this);
        Title = "DemoTape — Quick tips";

        foreach (var card in _cards)
            CardFlipView.Items.Add(card);

        ConfigureWindow();
    }

    private void ConfigureWindow()
    {
        var hwnd = WindowNative.GetWindowHandle(this);
        var id = Microsoft.UI.Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);

        if (appWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = false;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
        }

        const int w = 560, h = 420;
        appWindow.Resize(new SizeInt32(w, h));
        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var wa = area.WorkArea;
        appWindow.Move(new PointInt32(wa.X + (wa.Width - w) / 2, wa.Y + (wa.Height - h) / 2));
    }

    private void OnGotIt(object sender, RoutedEventArgs e)
    {
        // Mark the currently visible card as dismissed.
        if (CardFlipView.SelectedItem is FeatureCard current)
            DismissCard(current.Id);

        bool dontShow = DontShowToggle.IsOn;

        if (dontShow)
        {
            // Dismiss all remaining cards at once.
            foreach (var card in _cards)
                DismissCard(card.Id);
            Close();
            return;
        }

        // Advance to the next undismissed card, or close if all done.
        int next = CardFlipView.SelectedIndex + 1;
        if (next < CardFlipView.Items.Count)
        {
            CardFlipView.SelectedIndex = next;
            DontShowToggle.IsOn = false;
        }
        else
        {
            Close();
        }
    }

    private void DismissCard(string id)
    {
        var s = _settingsStore.Load();
        if (!s.DismissedCards.Contains(id))
        {
            s.DismissedCards.Add(id);
            _settingsStore.Save(s);
        }
    }
}
