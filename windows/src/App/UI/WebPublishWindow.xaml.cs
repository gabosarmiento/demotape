using DemoTape.App.Infrastructure;
using DemoTape.ViewModels;
using Microsoft.UI.Xaml;
using Windows.Graphics;

namespace DemoTape.App.UI;

/// <summary>
/// The Web Publish window — the first complete vertical slice's view. Binds to
/// <see cref="WebPublishViewModel"/> and provides the dialog XamlRoot for notifications.
/// </summary>
public sealed partial class WebPublishWindow : Window
{
    public WebPublishViewModel ViewModel { get; }

    public WebPublishWindow(WebPublishViewModel viewModel, WindowsUserInteraction interaction)
    {
        ViewModel = viewModel;
        InitializeComponent();

        Title = "DemoTape — Web Publish";
        AppWindow.Resize(new SizeInt32(520, 440));
        Root.DataContext = ViewModel;

        // Route ViewModel notifications through this window's XamlRoot for Fluent dialogs.
        Activated += (_, _) => interaction.XamlRoot = Root.XamlRoot;

        ViewModel.LoadLatest();
    }
}
