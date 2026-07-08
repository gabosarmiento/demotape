using CommunityToolkit.Mvvm.ComponentModel;

namespace DemoTape.ViewModels;

/// <summary>A selectable web-publish quality tier (e.g. 540p) with a bound checkbox state.</summary>
public sealed partial class TierSelection : ObservableObject
{
    public int Height { get; }
    public string Label => $"{Height}p";

    [ObservableProperty]
    private bool _isSelected;

    public event EventHandler? SelectionChanged;

    public TierSelection(int height, bool isSelected)
    {
        Height = height;
        _isSelected = isSelected;
    }

    partial void OnIsSelectedChanged(bool value) => SelectionChanged?.Invoke(this, EventArgs.Empty);
}
