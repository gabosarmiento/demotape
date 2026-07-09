using Microsoft.UI.Input;
using Microsoft.UI.Xaml.Controls;

namespace DemoTape.App.UI;

/// <summary>
/// A Grid region that shows the four-way "move" cursor, used for the draggable zones of the control
/// bar (the left grip and the empty area on the right). Pointer handling that starts the window
/// move is wired up by the host window.
/// </summary>
public sealed class DragArea : Grid
{
    public DragArea()
    {
        ProtectedCursor = InputSystemCursor.Create(InputSystemCursorShape.SizeAll);
    }
}
