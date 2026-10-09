using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace ScreenHere;

/// Win+Shift+8: the clipboard history as a floating list on the screen under
/// the pointer. Type to filter, arrows to choose, Enter to copy, Esc to close.
///
/// When it closes, the app the user was in gets the keyboard back, so Ctrl+V
/// pastes there straight away.
internal sealed class HistoryWindow : Window
{
    private static HistoryWindow? current;

    public const double ListWidth = 540;
    public const double ListHeight = 420;
    private const double ShadowRoom = 28;
    /// How long the list takes to fade away.
    public const double FadeOutSeconds = 0.2;

    private readonly ClipboardController clipboard = ClipboardController.Shared;
    private readonly LinkPreviews links = LinkPreviews.Shared;
    private readonly FileThumbnails filePictures = FileThumbnails.Shared;

    private readonly TextBox search = new();
    private readonly TextBlock placeholder = Ui.Text("Search clipboard history", 17, null, "Secondary");
    private readonly StackPanel list = new() { Margin = new Thickness(6) };
    private readonly ScrollViewer scroller = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Focusable = false };
    private readonly ContentControl body = new() { Focusable = false };
    private readonly ContentControl footer = new() { Focusable = false };
    private readonly List<Row> rows = [];
    private IReadOnlyList<ClipItem> results = [];
    private int selection;
    /// The footer is asking whether to clear everything.
    private bool confirmingClear;
    private bool closing;
    private bool dragging;
    /// Where the pointer last was, so a list scrolling under a still pointer
    /// does not count as hovering.
    private Point lastPointer;
    /// The window that had the keyboard before the list took it.
    private IntPtr previous;

    public static bool IsOpen => current != null;

    public static void Toggle()
    {
        if (current != null) current.Dismiss();
        else Open();
    }

    public static void Open()
    {
        current?.Dismiss();
        if (Displays.UnderPointer() is not { } display) return;
        var window = new HistoryWindow { previous = Native.GetForegroundWindow() };
        current = window;
        // Upper-middle, where a launcher sits: the eye goes there first.
        Ui.ShowOn(window, display, size => new Point(
            display.Work.X + (display.Work.Width - size.Width) / 2,
            display.Work.Y + display.Work.Height * 0.38 - size.Height / 2), activate: true);
        window.search.Focus();
        Keyboard.Focus(window.search);
        // A click anywhere else closes it, whether or not Windows gave it the
        // keyboard to lose.
        Hotkeys.WatchClicks(window.ClickedAt);
        // Should Windows have refused it the keyboard, Esc still closes it.
        Hotkeys.OnEscape = () =>
        {
            if (window.IsActive) window.Cancel();
            else window.Dismiss();
        };
    }

    public HistoryWindow()
    {
        Ui.Floating(this, activates: true);
        Width = ListWidth + ShadowRoom * 2;
        Height = ListHeight + ShadowRoom * 2;
        Content = Ui.Surface(Build(), radius: 14, margin: ShadowRoom, shadow: 0.4);
        lastPointer = Displays.Pointer();

        clipboard.Changed += Reload;
        links.Changed += Reload;
        filePictures.Changed += Reload;
        Closed += (_, _) =>
        {
            clipboard.Changed -= Reload;
            links.Changed -= Reload;
            filePictures.Changed -= Reload;
            if (current == this)
            {
                current = null;
                Hotkeys.OnEscape = null;
            }
            Memory.SettleSoon(3);
        };
        // Clicking anywhere else dismisses it, like any transient chooser —
        // but not while a picture is being dragged out into another app.
        Deactivated += (_, _) =>
        {
            if (!dragging) Dismiss();
        };
        PreviewKeyDown += OnKey;
        Reload();
    }

    private void Dismiss(bool giveKeyboardBack = false)
    {
        if (closing) return;
        closing = true;
        // Gone as far as the app is concerned, at once: the shortcut can open
        // a new list, and Esc is everyone's again, while this one fades.
        if (current == this)
        {
            current = null;
            Hotkeys.OnEscape = null;
            Hotkeys.WatchClicks(null);
        }
        IsHitTestVisible = false;
        if (giveKeyboardBack && previous != IntPtr.Zero && Native.IsWindow(previous)) Native.SetForegroundWindow(previous);

        // It leaves the way a panel does on the Mac, where the system fades
        // it out: opacity only, nothing moves, a fifth of a second.
        var fade = new DoubleAnimation(0, TimeSpan.FromSeconds(FadeOutSeconds))
        {
            EasingFunction = new QuadraticEase { EasingMode = EasingMode.EaseInOut },
        };
        fade.Completed += (_, _) => Close();
        BeginAnimation(OpacityProperty, fade);
    }

    /// A mouse button went down at this point of the screen. Outside the list
    /// — its shadow is outside too — that closes it.
    private void ClickedAt(int x, int y)
    {
        if (closing || dragging) return;
        var handle = new System.Windows.Interop.WindowInteropHelper(this).Handle;
        if (handle == IntPtr.Zero || !Native.GetWindowRect(handle, out var frame)) return;
        var shadow = (int)(ShadowRoom * VisualTreeHelper.GetDpi(this).DpiScaleX);
        var inside = x >= frame.Left + shadow && x < frame.Right - shadow && y >= frame.Top + shadow && y < frame.Bottom - shadow;
        if (!inside) Dismiss();
    }

    // MARK: - Layout

    private UIElement Build()
    {
        search.Background = Brushes.Transparent;
        search.BorderThickness = new Thickness(0);
        search.FontSize = 17;
        search.Padding = new Thickness(0);
        search.VerticalContentAlignment = VerticalAlignment.Center;
        search.SetResourceReference(ForegroundProperty, "Primary");
        search.SetResourceReference(TextBox.CaretBrushProperty, "Primary");
        search.SetResourceReference(TextBox.SelectionBrushProperty, "Brand");
        search.TextChanged += (_, _) =>
        {
            placeholder.Visibility = search.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
            selection = 0;
            Reload();
            Reveal();
        };
        placeholder.IsHitTestVisible = false;
        placeholder.Margin = new Thickness(2, 0, 0, 0);

        var field = new Grid { Margin = new Thickness(10, 0, 10, 1) };
        field.Children.Add(placeholder);
        field.Children.Add(search);

        var top = new DockPanel { Height = 50, Margin = new Thickness(16, 0, 16, 0) };
        top.Children.Add(Ui.Icon(Glyph.Search, 15).Docked(Dock.Left));
        top.Children.Add(Ui.ShortcutChip(Features.Shortcut(Feature.History).Label).Docked(Dock.Right));
        top.Children.Add(field);

        scroller.Content = list;
        footer.Height = 34;
        footer.Margin = new Thickness(16, 0, 8, 0);

        var root = new DockPanel { Width = ListWidth - 2, Height = ListHeight - 2 };
        root.Children.Add(top.Docked(Dock.Top));
        root.Children.Add(Divider().Docked(Dock.Top));
        root.Children.Add(footer.Docked(Dock.Bottom));
        root.Children.Add(Divider().Docked(Dock.Bottom));
        root.Children.Add(body);
        return root;
    }

    private static Border Divider() =>
        new Border { Height = 1 }.With(b => b.SetResourceReference(Border.BackgroundProperty, "P10"));

    private void Reload()
    {
        results = clipboard.History.Matching(search.Text);
        selection = Math.Clamp(selection, 0, Math.Max(0, results.Count - 1));
        if (clipboard.History.Items.Count == 0) confirmingClear = false;

        rows.Clear();
        list.Children.Clear();
        for (var index = 0; index < results.Count; index++)
        {
            var row = MakeRow(results[index], index);
            rows.Add(row);
            list.Children.Add(row.View);
        }
        body.Content = results.Count == 0 ? EmptyState() : scroller;
        RefreshFooter();
    }

    private UIElement EmptyState()
    {
        var searching = search.Text.Length > 0;
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(Ui.Icon(searching ? Glyph.NoResults : Glyph.Paste, 26));
        stack.Children.Add(Ui.Text(searching ? "No matches" : "Nothing copied yet", 13, FontWeights.Medium, "Secondary")
            .With(t => (t.Margin, t.HorizontalAlignment) = (new Thickness(0, 8, 0, 0), HorizontalAlignment.Center)));
        if (!searching)
        {
            stack.Children.Add(Ui.Text("Copy something anywhere and it shows up here.", 11, null, "Secondary")
                .With(t => (t.Margin, t.HorizontalAlignment) = (new Thickness(0, 5, 0, 0), HorizontalAlignment.Center)));
        }
        return stack;
    }

    private void RefreshFooter()
    {
        var bar = new DockPanel { LastChildFill = false };
        if (confirmingClear)
        {
            // Asked in place: a dialog would take the keyboard away from the
            // list, which closes it.
            var total = clipboard.History.Items.Count;
            bar.Children.Add(Ui.Icon(Glyph.Trash, 12, "Danger").Docked(Dock.Left));
            bar.Children.Add(Ui.Text(total == 1 ? "Clear the only item from this PC?" : $"Clear all {total} items from this PC?", 11)
                .With(t => t.Margin = new Thickness(8, 0, 0, 0)).Docked(Dock.Left));
            bar.Children.Add(Ui.Press("Destructive", Ui.Text("Clear", 11, FontWeights.Medium, "OnBrandInk"), () =>
            {
                confirmingClear = false;
                selection = 0;
                clipboard.Clear();
                search.Focus();
            }).Docked(Dock.Right));
            bar.Children.Add(Ui.Press("Footer", "Cancel", Cancel).With(b => b.Margin = new Thickness(0, 0, 4, 0)).Docked(Dock.Right));
        }
        else
        {
            bar.Children.Add(Hint("↵", "Copy").Docked(Dock.Left));
            bar.Children.Add(Hint("↑↓", "Choose").Docked(Dock.Left));
            bar.Children.Add(Hint("esc", "Close").Docked(Dock.Left));
            if (clipboard.History.Items.Count > 0)
            {
                var label = new StackPanel { Orientation = Orientation.Horizontal };
                label.Children.Add(Ui.Icon(Glyph.Trash, 10, null));
                label.Children.Add(new TextBlock { Text = "Clear…", Margin = new Thickness(4, 0, 0, 1) });
                bar.Children.Add(Ui.Press("Footer", label, () =>
                {
                    confirmingClear = true;
                    RefreshFooter();
                }, "Delete everything in the clipboard history").Docked(Dock.Right));
            }
            bar.Children.Add(Ui.Text(results.Count == 1 ? "1 item" : $"{results.Count} items", 11, null, "Secondary")
                .With(t => t.Margin = new Thickness(0, 0, 6, 0)).Docked(Dock.Right));
        }
        footer.Content = bar;

        static UIElement Hint(string key, string label)
        {
            var hint = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 14, 0) };
            hint.Children.Add(Ui.Text(key, 10, FontWeights.SemiBold, "Secondary"));
            hint.Children.Add(Ui.Text(label, 11, null, "Secondary").With(t => t.Margin = new Thickness(4, 0, 0, 0)));
            return hint;
        }
    }

    // MARK: - Keyboard

    private void OnKey(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Up: MoveSelection(-1); break;
            case Key.Down: MoveSelection(1); break;
            case Key.PageUp: MoveSelection(-6); break;
            case Key.PageDown: MoveSelection(6); break;
            // Enter copies — and never confirms clearing everything.
            case Key.Enter when !confirmingClear: Choose(selection); break;
            case Key.Enter: break;
            default: return;
        }
        e.Handled = true;
    }

    private void MoveSelection(int delta)
    {
        if (results.Count == 0) return;
        Select(Math.Clamp(selection + delta, 0, results.Count - 1));
        Reveal();
    }

    /// Escape backs out of the question first, then closes the list.
    private void Cancel()
    {
        if (confirmingClear)
        {
            confirmingClear = false;
            RefreshFooter();
            search.Focus();
        }
        else
        {
            Dismiss(giveKeyboardBack: true);
        }
    }

    private void Select(int index)
    {
        if (index == selection || index < 0 || index >= rows.Count) return;
        if (selection < rows.Count) rows[selection].SetSelected(false);
        selection = index;
        rows[selection].SetSelected(true);
    }

    /// Only what the keyboard or the filter selected is scrolled to. Hovering
    /// already put the pointer on the row; moving the list under it would take
    /// it away again.
    private void Reveal()
    {
        if (selection < rows.Count) rows[selection].View.BringIntoView();
    }

    // MARK: - Actions

    private void Choose(int index)
    {
        if (index < 0 || index >= results.Count) return;
        var item = results[index];
        var copied = clipboard.Copy(item);
        Dismiss(giveKeyboardBack: true);
        if (copied) Toast.Show("Copied — paste with Ctrl+V", Glyph.Paste);
        else Toast.Show(item.Files == null ? "That image is no longer on this PC" : "That file is no longer on this PC", Glyph.Warning);
    }

    private void Save(ClipItem item)
    {
        if (item.Image == null) return;
        if (clipboard.SaveToDownloads(item.Image) != null) Toast.Show("Saved to Downloads", Glyph.Download);
        else Toast.Show("That image is no longer on this PC", Glyph.Warning);
    }

    /// Lifts a picture or a file out of the list and into another app.
    private void DragOut(UIElement source, string path)
    {
        dragging = true;
        try
        {
            DragDrop.DoDragDrop(source, new DataObject(DataFormats.FileDrop, new[] { path }), DragDropEffects.Copy);
        }
        finally
        {
            dragging = false;
            if (!IsActive) Dismiss();
        }
    }

    // MARK: - Rows

    private sealed class Row(FrameworkElement view, Action<bool> setSelected)
    {
        public FrameworkElement View { get; } = view;
        public void SetSelected(bool selected) => setSelected(selected);
    }

    private Row MakeRow(ClipItem item, int index)
    {
        var link = links.IsEnabled ? CopiedLink.From(item.Text) : null;
        var preview = link != null ? links.Preview(link) : null;
        var firstFile = item.Files?.FirstOrDefault();
        // None of the copied files is on this PC any more.
        var missing = !filePictures.Posed && item.Files != null && item.Files.All(f => !f.Exists);

        FrameworkElement? lead = null;
        TextBlock? leadGlyph = null;
        if (item.Image != null)
        {
            clipboard.WantCaption(item.Image);
            lead = PictureTile(clipboard.Thumbnail(item.Image), fill: true, Glyph.Picture, clipboard.FilePath(item.Image));
        }
        else if (firstFile != null)
        {
            filePictures.Want(firstFile);
            lead = PictureTile(filePictures.Thumbnail(firstFile), fill: false, Glyph.Document, missing ? null : firstFile.Path);
            lead.Opacity = missing ? 0.4 : 1;
        }
        else if (link != null)
        {
            links.Want(link);
            lead = LinkTile(preview?.Icon, link.MayVisit, out leadGlyph);
        }

        // A link reads as its page's title once there is one, and as its
        // address without the scheme until then.
        var titleText = link != null ? preview?.Title ?? link.Display : RowTitle(item);
        var subtitleText = Subtitle(item, DateTime.Now);
        if (missing) subtitleText = $"Missing · {subtitleText}";
        else if (link != null && preview?.Title != null) subtitleText = $"{link.Host} · {subtitleText}";

        var title = Ui.Text(titleText, 13).With(t =>
        {
            t.TextWrapping = TextWrapping.Wrap;
            t.LineHeight = 17;
            t.MaxHeight = 34;
        });
        var subtitle = Ui.Text(subtitleText, 10.5, null, "Secondary").With(t => t.Margin = new Thickness(0, 3, 0, 0));
        var texts = new StackPanel { VerticalAlignment = lead == null ? VerticalAlignment.Top : VerticalAlignment.Center };
        texts.Children.Add(title);
        texts.Children.Add(subtitle);
        // A file that has moved is still listed — the disk it was on may come
        // back — but it reads as out of reach.
        texts.Opacity = missing ? 0.5 : 1;

        // Always here, even unseen: buttons that appear with the selection
        // would narrow the text, rewrap it, and push every row below.
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(6, 0, 0, 0) };
        if (item.Image != null)
        {
            buttons.Children.Add(Ui.Press("OnBrand", Ui.Icon(Glyph.Download, 10, null), () => Save(item), "Save a copy in Downloads"));
        }
        buttons.Children.Add(Ui.Press("OnBrand", Ui.Icon(Glyph.Close, 8.5, null), () =>
        {
            clipboard.Remove(item);
            search.Focus();
        }, "Remove from history").With(b => b.Margin = new Thickness(2, 0, 0, 0)));

        var content = new DockPanel();
        if (lead != null) content.Children.Add(lead.With(l => l.Margin = new Thickness(0, 0, 10, 0)).Docked(Dock.Left));
        content.Children.Add(buttons.Docked(Dock.Right));
        content.Children.Add(texts);

        var surface = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 7, 10, 7),
            Margin = new Thickness(0, 0, 0, 2),
            Background = Brushes.Transparent,
            Child = content,
        };

        void SetSelected(bool selected)
        {
            if (selected) surface.SetResourceReference(Border.BackgroundProperty, "Brand");
            else surface.Background = Brushes.Transparent;
            title.SetResourceReference(TextBlock.ForegroundProperty, selected ? "OnBrandInk" : "Primary");
            subtitle.SetResourceReference(TextBlock.ForegroundProperty, selected ? "OnBrandSoft" : "Secondary");
            leadGlyph?.SetResourceReference(TextBlock.ForegroundProperty, selected ? "OnBrandSoft" : "Secondary");
            buttons.Opacity = selected ? 1 : 0;
            buttons.IsHitTestVisible = selected;
        }
        SetSelected(index == selection);

        surface.MouseMove += (_, _) =>
        {
            var pointer = Displays.Pointer();
            if (pointer == lastPointer) return;
            lastPointer = pointer;
            Select(index);
        };
        surface.MouseLeftButtonUp += (_, e) =>
        {
            if (e.Handled) return;
            Choose(index);
        };
        return new Row(surface, SetSelected);
    }

    /// A picture's row leads with the picture: "Image" alone says nothing
    /// about which one. A file's leads with Explorer's picture of it — the
    /// first page of a PDF, the photo itself — or its type's icon. Either can
    /// be dragged out into any app, since what the row points at is a real file.
    private FrameworkElement PictureTile(BitmapSource? picture, bool fill, string fallback, string? path)
    {
        var tile = new Border { Width = 44, Height = 44, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
        tile.SetResourceReference(Border.BackgroundProperty, "P06");
        // Kept: a white screenshot would otherwise bleed into the panel.
        tile.SetResourceReference(Border.BorderBrushProperty, "P12");
        if (picture == null)
        {
            tile.Child = Ui.Icon(fallback, 16);
        }
        else if (fill)
        {
            // The tile is square and always full — a picture fitted inside it
            // would leave bands of empty space on every shape but one.
            tile.Background = new ImageBrush(picture) { Stretch = Stretch.UniformToFill };
        }
        else
        {
            tile.Child = new Image { Source = picture, Stretch = Stretch.Uniform, Margin = new Thickness(3) }
                .With(i => RenderOptions.SetBitmapScalingMode(i, BitmapScalingMode.HighQuality));
        }
        if (path == null) return tile;

        Point? pressedAt = null;
        tile.MouseLeftButtonDown += (_, e) => pressedAt = e.GetPosition(tile);
        tile.MouseLeave += (_, _) => pressedAt = null;
        tile.MouseMove += (_, e) =>
        {
            if (pressedAt is not { } from || e.LeftButton != MouseButtonState.Pressed) return;
            var now = e.GetPosition(tile);
            if (Math.Abs(now.X - from.X) < 5 && Math.Abs(now.Y - from.Y) < 5) return;
            pressedAt = null;
            DragOut(tile, path);
        };
        return tile;
    }

    /// A link's row leads with its site's icon — a globe until there is one,
    /// and a lock for a link that looked private or single-use and was left
    /// unvisited.
    private static FrameworkElement LinkTile(BitmapSource? icon, bool visited, out TextBlock? glyph)
    {
        glyph = null;
        var tile = new Border { Width = 28, Height = 28, CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
        tile.SetResourceReference(Border.BackgroundProperty, "P06");
        tile.SetResourceReference(Border.BorderBrushProperty, "P12");
        if (icon != null)
        {
            tile.Child = new Image { Source = icon, Width = 18, Height = 18, Stretch = Stretch.Uniform }
                .With(i => RenderOptions.SetBitmapScalingMode(i, BitmapScalingMode.HighQuality));
        }
        else
        {
            tile.Child = glyph = Ui.Icon(visited ? Glyph.Globe : Glyph.Lock, 12);
            if (!visited) tile.ToolTip = "Not visited: this link is unencrypted, or looks private or single-use";
        }
        return tile;
    }

    /// Runs of whitespace collapse so a copied paragraph previews as text, not
    /// as a column of blank lines. A picture is titled by what was read in it,
    /// which is how a screenshot of a page is told apart from the next one.
    internal static string RowTitle(ClipItem item)
    {
        if (item.Text is { } text)
        {
            // The row shows two lines; the rest of a long copy is not laid out.
            var shown = text.Length > 400 ? text[..400] : text;
            return string.Join(" ", shown.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        }
        if (item.Image is { } image) return image.CaptionLine ?? "Image";
        var files = item.Files!;
        return files.Count == 1 ? files[0].Name : $"{files[0].Name} + {files.Count - 1} more";
    }

    internal static string Subtitle(ClipItem item, DateTime now)
    {
        var parts = new[]
        {
            item.Image is { } image ? $"{image.Width} × {image.Height}" : null,
            item.Files?.FirstOrDefault()?.Folder,
            item.Source,
            RelativeTime.Describe(item.Date, now),
        };
        return string.Join(" · ", parts.Where(p => !string.IsNullOrEmpty(p)));
    }
}
