using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Data;

namespace DemoTape.App.UI;

/// <summary>
/// Converts a <see cref="bool"/> to <see cref="Visibility"/> (true → Visible). Needed because the
/// ViewModels live in a WinUI-free library and can't expose <c>Visibility</c> directly, and
/// x:Bind has no implicit bool→Visibility conversion.
/// </summary>
public sealed class BoolToVisibilityConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, string language)
        => value is true ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, string language)
        => value is Visibility.Visible;
}
