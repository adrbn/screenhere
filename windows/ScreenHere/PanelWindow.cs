using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Shapes;
using System.Windows.Threading;

namespace ScreenHere;

/// A fixed arrangement to show instead of the real one: documentation shots
/// only, so the pictures need no second display plugged in.
internal sealed record PanelPose(IReadOnlyList<Rect> Displays, IReadOnlyList<string> Names, Point Pointer);

/// The tray panel: the live map of the displays, one tile per shortcut, the
/// options of whatever is switched on, and a footer.
///
/// The map stays the centrepiece: the display under the pointer is filled in
/// the brand colour and a pointer tracks the real cursor, which says what the
/// app does better than a line of text. The whole tile switches its feature,
/// so four features read at a glance.
internal sealed class PanelWindow : Window
{
    private static PanelWindow? current;

    public const double PanelWidth = 320;
    private const double ShadowRoom = 24;
    /// From the edge of the screen to the panel, like Windows' own flyouts.
    private const double Gap = 12;
    /// Longest display name rendered before truncating, so the panel stays narrow.
    private const int MaxNameLength = 26;

    private readonly PanelPose? pose;
    private readonly TextBlock displayName = Ui.Text("", 14, FontWeights.SemiBold);
    private readonly Canvas map = new() { Height = 88, Margin = new Thickness(0, 10, 0, 0) };
    private readonly ContentControl destination = new() { Focusable = false };
    private readonly Grid tiles = new();
    private readonly StackPanel options = new() { Margin = new Thickness(6, 0, 6, 0) };
    private readonly ContentControl update = new() { Focusable = false };
    private readonly DispatcherTimer poll = new() { Interval = TimeSpan.FromMilliseconds(100) };
    private bool confirmingClear;
    private bool closing;
    private string held = "";
    private string? problem;
    private Func<Size, Point>? anchor;

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
        var panel = new PanelWindow(null);
        current = panel;
        var pointer = Displays.Pointer();
        var scale = display.Scale;
        // Above the tray icon that was clicked, wherever the taskbar is; in
        // the corner when it was opened some other way.
        // The room left by the taskbar, measured from the taskbar itself: one
        // that hides is showing while its icons are clicked, and the work area
        // does not count it.
        var free = display.Work;
        foreach (var bar in Native.Taskbars())
        {
            var taskbar = new Rect(bar.Left, bar.Top, bar.Width, bar.Height);
            if (!taskbar.IntersectsWith(display.Bounds) || taskbar.Width < display.Bounds.Width / 2) continue;
            var top = Math.Max(free.Top, taskbar.Top > display.Bounds.Top + display.Bounds.Height / 2 ? free.Top : taskbar.Bottom);
            var bottom = Math.Min(free.Bottom, taskbar.Top > display.Bounds.Top + display.Bounds.Height / 2 ? taskbar.Top : free.Bottom);
            if (bottom > top) free = new Rect(free.Left, top, free.Width, bottom - top);
        }
        var above = pointer.Y >= free.Top;
        var onTaskbar = !free.Contains(pointer);
        panel.anchor = size =>
        {
            var room = (ShadowRoom - Gap) * scale;
            var x = onTaskbar ? pointer.X - size.Width / 2 : free.Right - size.Width + room;
            // Hung from the edge the taskbar is on, so it grows away from it.
            var y = above ? free.Bottom - size.Height + room : free.Top - room;
            x = Math.Clamp(x, free.Left - room, Math.Max(free.Left - room, free.Right - size.Width + room));
            return new Point(x, Math.Max(y, display.Bounds.Top - room));
        };
        Ui.ShowOn(panel, display, panel.anchor, activate: true);
        panel.Rise();
    }

    public PanelWindow(PanelPose? pose)
    {
        this.pose = pose;
        Ui.Floating(this, activates: true);
        Width = PanelWidth + ShadowRoom * 2;
        SizeToContent = SizeToContent.Height;
        Content = Ui.Surface(Build(), radius: 13, margin: ShadowRoom);

        Features.Changed += Refresh;
        ClipboardController.Shared.Changed += Refresh;
        LinkPreviews.Shared.Changed += Refresh;
        SyncController.Shared.Changed += Refresh;
        Updater.Shared.Changed += RefreshUpdate;
        // The pointer moves continuously, so the map would go stale the moment
        // the panel appeared. Polling is confined to the time the panel is on
        // screen — a tray app has no business running a timer the rest of the day.
        poll.Tick += (_, _) => RefreshMap();
        Loaded += (_, _) =>
        {
            poll.Start();
            if (pose == null) Features.RefreshConflicts();
        };
        Closed += (_, _) =>
        {
            poll.Stop();
            Features.Changed -= Refresh;
            ClipboardController.Shared.Changed -= Refresh;
            LinkPreviews.Shared.Changed -= Refresh;
            SyncController.Shared.Changed -= Refresh;
            SyncController.Shared.EndPairing();
            Updater.Shared.Changed -= RefreshUpdate;
            Features.EndRecording();
            if (current == this) current = null;
            Memory.SettleSoon(3);
        };
        // Clicking anywhere else dismisses it, like any flyout.
        Deactivated += (_, _) => Dismiss();
        // The panel grows and shrinks with what is switched on; it stays
        // attached to the edge it opened from.
        SizeChanged += (_, _) =>
        {
            if (anchor == null) return;
            Ui.Move(this, anchor);
            // And once the new size has reached the window itself.
            Dispatcher.BeginInvoke(() =>
            {
                if (!closing && anchor != null) Ui.Move(this, anchor);
            }, DispatcherPriority.Loaded);
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key == System.Windows.Input.Key.Escape && Features.Recording == null) Dismiss();
        };
        Refresh();
    }

    private void Dismiss()
    {
        if (closing) return;
        closing = true;
        Tray.Shared.PanelClosedAt = DateTime.Now;
        Close();
    }

    /// Arrives from just below where it rests, the way a flyout does.
    private void Rise()
    {
        if (Content is not FrameworkElement surface) return;
        var slide = new TranslateTransform(0, 8);
        surface.RenderTransform = slide;
        slide.BeginAnimation(TranslateTransform.YProperty,
            new DoubleAnimation(8, 0, TimeSpan.FromMilliseconds(180)) { EasingFunction = new CubicEase { EasingMode = EasingMode.EaseOut } });
    }

    // MARK: - Layout

    private UIElement Build()
    {
        var root = new StackPanel { Width = PanelWidth };
        root.Children.Add(Hero());
        root.Children.Add(SectionTitle("Shortcuts"));
        tiles.Margin = new Thickness(10, 0, 10, 0);
        root.Children.Add(tiles);
        root.Children.Add(SectionTitle("Options").With(t => t.Margin = new Thickness(14, 10, 14, 6)));
        root.Children.Add(options);
        root.Children.Add(new Border { Height = 1, Margin = new Thickness(12, 6, 12, 0) }
            .With(b => b.SetResourceReference(Border.BackgroundProperty, "P10")));
        root.Children.Add(Footer());
        return root;
    }

    private static TextBlock SectionTitle(string text) =>
        Ui.Text(text, 11, FontWeights.SemiBold, "Secondary").With(t => t.Margin = new Thickness(14, 0, 14, 6));

    /// The top of the panel: which display Win+Shift+3 takes right now, where
    /// the capture goes, and the live map of the displays.
    private UIElement Hero()
    {
        var pointer = new Path { Data = Glyph.Pointer(12.5), VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(1, 1, 8, 0) };
        pointer.SetResourceReference(Shape.FillProperty, "BrandText");

        var title = new DockPanel { LastChildFill = true };
        title.Children.Add(destination.Docked(Dock.Right));
        title.Children.Add(pointer.Docked(Dock.Left));
        title.Children.Add(displayName);

        var stack = new StackPanel();
        stack.Children.Add(title);
        stack.Children.Add(map);

        var hero = new Border
        {
            Margin = new Thickness(10),
            Padding = new Thickness(12),
            CornerRadius = new CornerRadius(14),
            BorderThickness = new Thickness(1),
            Child = stack,
        };
        hero.SetResourceReference(Border.BackgroundProperty, "BrandHero");
        hero.SetResourceReference(Border.BorderBrushProperty, "Brand14");
        return hero;
    }

    private UIElement Footer()
    {
        var footer = new DockPanel { Margin = new Thickness(10, 9, 10, 9), LastChildFill = false };

        var quit = Ui.Press("Round", Ui.Icon(Glyph.Power, 12), () => ((App)Application.Current).Quit(), "Quit ScreenHere");
        quit.Margin = new Thickness(6, 0, 0, 0);
        footer.Children.Add(quit.Docked(Dock.Right));

        Button? more = null;
        more = Ui.Press("Round", Ui.Icon(Glyph.More, 13), () =>
        {
            var menu = new ContextMenu { PlacementTarget = more, Placement = PlacementMode.Top, HorizontalOffset = -150 };
            menu.Items.Add(Item("View on GitHub", () => Open("https://github.com/adrbn/screenhere")));
            menu.Items.Add(new Separator());
            menu.Items.Add(Item("Open Screenshots Folder", () => Open(Capture.Folder)));
            menu.Items.Add(Item("Hide Tray Icon", () =>
            {
                Dismiss();
                Tray.Shared.SetHidden(true);
            }));
            menu.IsOpen = true;
        }, "More");
        footer.Children.Add(more.Docked(Dock.Right));

        footer.Children.Add(update.Docked(Dock.Left));
        RefreshUpdate();
        return footer;

        static MenuItem Item(string title, Action action)
        {
            var item = new MenuItem { Header = title };
            item.Click += (_, _) => action();
            return item;
        }
    }

    private static void Open(string target)
    {
        try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { }
    }

    // MARK: - Refreshing

    private void Refresh()
    {
        RefreshDestination();
        RefreshTiles();
        RefreshOptions();
        RefreshMap();
    }

    private void RefreshDestination()
    {
        var toClipboard = Settings.Current.CapturesToClipboard;
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        label.Children.Add(Ui.Icon(toClipboard ? Glyph.Paste : Glyph.Folder, 10));
        label.Children.Add(Ui.Text(Capture.DestinationName, 10.5, FontWeights.Medium, "Secondary")
            .With(t => t.Margin = new Thickness(4, 0, 0, 0)));
        destination.Content = Ui.Press("Chip", label, () => Features.SetCapturesToClipboard(!toClipboard),
            "Where captures go. Click to switch between the Screenshots folder and the clipboard. "
            + $"{Features.Shortcut(Feature.Screen).ToClipboard.Label} always sends that one capture to the clipboard.");
    }

    /// Cheap sampling, safe to run continuously: the displays, the pointer,
    /// and a name lookup that is cached until the set of displays changes.
    private void RefreshMap()
    {
        IReadOnlyList<Rect> bounds;
        IReadOnlyList<string> names;
        Point pointer;
        if (pose != null)
        {
            (bounds, names, pointer) = (pose.Displays, pose.Names, pose.Pointer);
        }
        else
        {
            var displays = Displays.All();
            bounds = displays.Select(d => d.Bounds).ToList();
            names = displays.Select((d, i) => Displays.Name(d, i)).ToList();
            pointer = Displays.Pointer();
        }
        if (bounds.Count == 0) return;
        var active = Displays.IndexAt(pointer, bounds, 0);
        displayName.Text = ShortName(names[active], MaxNameLength);

        var canvasWidth = PanelWidth - 2 * (10 + 12 + 1);
        var fitted = DisplayMapLayout.Fit(bounds, pointer, new Size(canvasWidth, map.Height), padding: 4);
        map.Children.Clear();
        for (var i = 0; i < fitted.Rects.Count; i++) map.Children.Add(Screen(fitted.Rects[i], i == active, ShortName(names[i], 16)));

        if (fitted.Pointer is { } p)
        {
            // The same outline as the tray icon.
            var arrow = new Path { Data = Glyph.Pointer(15), StrokeThickness = 1.2, StrokeLineJoin = PenLineJoin.Round, IsHitTestVisible = false };
            arrow.SetResourceReference(Shape.FillProperty, "Primary");
            arrow.SetResourceReference(Shape.StrokeProperty, "Bg");
            Canvas.SetLeft(arrow, p.X - 1);
            Canvas.SetTop(arrow, p.Y - 1);
            map.Children.Add(arrow);
        }
    }

    private static UIElement Screen(Rect r, bool isActive, string name)
    {
        var screen = new Border
        {
            Width = Math.Max(0, r.Width),
            Height = Math.Max(0, r.Height),
            CornerRadius = new CornerRadius(6),
            BorderThickness = new Thickness(isActive ? 1.5 : 1),
            SnapsToDevicePixels = true,
        };
        screen.SetResourceReference(Border.BackgroundProperty, isActive ? "Brand20" : "P05");
        screen.SetResourceReference(Border.BorderBrushProperty, isActive ? "Brand" : "P20");
        // Only label a display that has room for it; a clipped name is worse
        // than none.
        if (r.Width >= 62 && name.Length > 0)
        {
            screen.Child = Ui.Text(name, 8.5, isActive ? FontWeights.SemiBold : FontWeights.Normal, isActive ? "BrandText" : "Secondary")
                .With(t =>
                {
                    t.VerticalAlignment = VerticalAlignment.Bottom;
                    t.HorizontalAlignment = HorizontalAlignment.Left;
                    t.Margin = new Thickness(5, 0, 5, 3);
                });
        }
        Canvas.SetLeft(screen, r.X);
        Canvas.SetTop(screen, r.Y);
        return screen;
    }

    /// Truncates long display names with an ellipsis so the panel stays narrow.
    internal static string ShortName(string name, int max)
    {
        // "Built-in Display" -> "Built-in": the word adds nothing inside a
        // rectangle that is visibly a display.
        if (name.EndsWith(" Display")) name = name[..^" Display".Length];
        return name.Length > max ? name[..(max - 1)].TrimEnd() + "…" : name;
    }

    // MARK: - Tiles

    private void RefreshTiles()
    {
        tiles.Children.Clear();
        tiles.ColumnDefinitions.Clear();
        tiles.RowDefinitions.Clear();
        tiles.ColumnDefinitions.Add(new ColumnDefinition());
        tiles.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(8) });
        tiles.ColumnDefinitions.Add(new ColumnDefinition());
        tiles.RowDefinitions.Add(new RowDefinition());
        tiles.RowDefinitions.Add(new RowDefinition { Height = new GridLength(8) });
        tiles.RowDefinitions.Add(new RowDefinition());

        var screen = Features.Shortcut(Feature.Screen).Label;
        Place(0, 0, Feature.Screen, on => Ui.Icon(Glyph.Display, 13, on), false,
            Features.IsOn(Feature.Screen) ? $"Give {screen} back to Windows" : $"Capture the screen under the pointer with {screen}");
        Place(0, 2, Feature.Window, on => Ui.Stroked(Glyph.Window, 14, on, 1.4), true,
            "Capture only the window under the pointer.");
        Place(2, 0, Feature.Text, on => Ui.Stroked(Glyph.TextViewfinder, 14, on, 1.4), false,
            "Select part of the screen and copy the text in it, recognised on this PC.");
        Place(2, 2, Feature.History, on => Ui.Icon(Glyph.Paste, 13, on), false,
            "Keep what you copy — text, images, files — on this PC, up to 100 MB of images. "
            + "Copies that password managers mark as private are skipped.");

        void Place(int row, int column, Feature feature, Func<string, UIElement> icon, bool beta, string help)
        {
            var isOn = Features.IsOn(feature);
            var owner = isOn ? Features.Conflict(feature) : null;
            var tile = Tile(icon, feature.ToString(), beta, owner != null ? $"Used by {owner}" : Features.Shortcut(feature).Label, owner != null,
                            isOn, owner != null ? $"{Features.Shortcut(feature).Label} belongs to {owner}, and ScreenHere leaves it alone. Pick another shortcut in the options below." : help,
                            () => Features.Set(feature, !isOn));
            Grid.SetRow(tile, row);
            Grid.SetColumn(tile, column);
            tiles.Children.Add(tile);
        }
    }
    private static Button Tile(Func<string, UIElement> icon, string title, bool beta, string keys, bool warning, bool isOn, string help, Action action)
    {
        var badge = new Grid { Width = 28, Height = 28 };
        var disc = new Ellipse();
        disc.SetResourceReference(Shape.FillProperty, isOn ? "Brand" : "P09");
        badge.Children.Add(disc);
        badge.Children.Add(icon(isOn ? "OnBrandInk" : "Secondary"));

        var heading = new StackPanel { Orientation = Orientation.Horizontal };
        heading.Children.Add(Ui.Text(title, 12, FontWeights.SemiBold));
        if (beta) heading.Children.Add(Ui.Beta().With(b => b.Margin = new Thickness(4, 1, 0, 0)));

        var texts = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(9, 0, 0, 0) };
        texts.Children.Add(heading);
        texts.Children.Add(Ui.Text(keys, 10.5, FontWeights.Medium, warning ? "Warning" : "Secondary").With(t => t.Margin = new Thickness(0, 1, 0, 0)));

        var content = new DockPanel();
        content.Children.Add(badge.Docked(Dock.Left));
        content.Children.Add(texts);
        return Ui.Press("Tile", content, action, help);
    }

    // MARK: - Options

    /// The settings of the features that are on, so the panel only grows with
    /// what is in use.
    private void RefreshOptions()
    {
        var settings = Settings.Current;
        var clipboard = ClipboardController.Shared;
        options.Children.Clear();

        // Every shortcut can be changed: keyboards differ, and so do the
        // shortcuts other apps got to first.
        if (Features.IsOn(Feature.Screen)) options.Children.Add(Row(Ui.Icon(Glyph.Display, 12), "Screen shortcut", trailing: Recorder(Feature.Screen)));
        if (Features.IsOn(Feature.Window)) options.Children.Add(Row(Ui.Stroked(Glyph.Window, 12.5), "Window shortcut", trailing: Recorder(Feature.Window)));
        if (Features.IsOn(Feature.Text)) options.Children.Add(Row(Ui.Stroked(Glyph.TextViewfinder, 12.5), "Text shortcut", trailing: Recorder(Feature.Text)));
        if (Features.IsOn(Feature.History)) options.Children.Add(Row(Ui.Icon(Glyph.Paste, 12), "History shortcut", trailing: Recorder(Feature.History)));
        options.Children.Add(Row(Ui.Icon(Glyph.Picture, 12), "Preview on captured screen",
            trailing: Switch(settings.PreviewOnCapturedScreen, Features.SetPreview,
                "Show a preview of each capture on the screen it came from. Click it to find the file, "
                + "drag it into another app, or flick it to the right to dismiss it.")));
        options.Children.Add(Row(Ui.Icon(Glyph.Power, 12), "Launch at login",
            trailing: Switch(LoginItem.IsEnabled, on =>
            {
                LoginItem.SetEnabled(on);
                Refresh();
            })));

        AddSharedClipboard();

        if (!clipboard.IsEnabled) return;
        options.Children.Add(Row(Ui.Icon(Glyph.Link, 12), "Link previews", beta: true,
            trailing: Switch(LinkPreviews.Shared.IsEnabled, LinkPreviews.Shared.SetEnabled,
                "Show the title and icon of copied links in the list. ScreenHere visits a link when the list "
                + "shows it, without cookies, and never one that looks private or single-use. The site sees "
                + "the visit, as it would if you opened the link.")));
        options.Children.Add(Row(Ui.Icon(Glyph.History, 12), "Show history",
            trailingText: clipboard.History.Items.Count.ToString(),
            action: () =>
            {
                Dismiss();
                HistoryWindow.Open();
            }));
        options.Children.Add(confirmingClear ? ClearQuestion() : Row(Ui.Icon(Glyph.Trash, 12), "Clear history", action: () =>
        {
            confirmingClear = true;
            RefreshOptions();
        }));
    }

    /// The clipboard shared with one other device, and the few steps that
    /// introduce the two: ask on both, pick the device, check the code.
    private void AddSharedClipboard()
    {
        var sync = SyncController.Shared;
        options.Children.Add(Row(Ui.Icon(Glyph.Devices, 12), "Shared clipboard", beta: true,
            trailing: Switch(sync.IsEnabled, sync.SetEnabled,
                "Share what you copy — text and pictures — with a Mac or PC on the same network that also runs ScreenHere. "
                + "The two talk to each other directly and encrypted; nothing goes through a server, and copies that "
                + "password managers mark as private are never sent.")));
        if (!sync.IsEnabled) return;

        if (sync.Pending is { } offer)
        {
            // Asked in place, like clearing the history.
            var question = new DockPanel { LastChildFill = false };
            question.Children.Add(Ui.Text(offer.Code.Length == 6 ? $"{offer.Code[..3]} {offer.Code[3..]}" : offer.Code, 15, FontWeights.SemiBold, "BrandText")
                .With(t => t.Margin = new Thickness(24, 0, 0, 1)).Docked(Dock.Left));
            if (offer.Confirmed)
            {
                question.Children.Add(Ui.Text($"Waiting for {ShortName(offer.Name, 18)}…", 11, null, "Secondary").Docked(Dock.Right));
            }
            else
            {
                question.Children.Add(Ui.Press("Soft", Ui.Text("Connect", 11, FontWeights.Medium, "OnBrandInk"), sync.Confirm)
                    .With(b =>
                    {
                        b.Tag = new CornerRadius(6);
                        b.Height = 22;
                        b.Padding = new Thickness(9, 0, 9, 1);
                        b.SetResourceReference(BackgroundProperty, "Brand");
                    }).Docked(Dock.Right));
                question.Children.Add(Ui.Press("Footer", "Cancel", sync.Decline).With(b => b.Margin = new Thickness(0, 0, 4, 0)).Docked(Dock.Right));
            }
            options.Children.Add(Row(Ui.Icon(Glyph.Lock, 12), $"Same code on {ShortName(offer.Name, 20)}?"));
            options.Children.Add(new Border { Height = 30, Padding = new Thickness(6, 0, 6, 0), Child = question });
            return;
        }

        if (sync.IsPairing)
        {
            var nearby = sync.Nearby;
            options.Children.Add(Row(Ui.Icon(Glyph.Search, 12), nearby.Count == 0 ? "Looking for devices…" : "Choose the device", trailing: Cancel()));
            foreach (var device in nearby)
            {
                options.Children.Add(Row(Ui.Icon(Glyph.Display, 12), ShortName(device.Name, 30), action: () => sync.Pair(device)));
            }
            if (nearby.Count == 0) options.Children.Add(Hint("Click Connect a device in ScreenHere on the other one too."));
            options.Children.Add(AddressField());
            return;
        }

        if (sync.IsPaired)
        {
            var forget = Ui.Press("Footer", "Forget", sync.Forget, "Stop sharing with this device. It would have to be connected again.");
            var state = Ui.Text(sync.IsConnected ? "Connected" : "Not in reach", 11, null, sync.IsConnected ? "BrandText" : "Secondary")
                .With(t => t.Margin = new Thickness(0, 0, 4, 0));
            var trailing = new StackPanel { Orientation = Orientation.Horizontal };
            trailing.Children.Add(state);
            trailing.Children.Add(forget);
            options.Children.Add(Row(Ui.Icon(Glyph.Display, 12), ShortName(sync.PeerName ?? "Device", 18), trailing: trailing));
        }
        else
        {
            options.Children.Add(Row(Ui.Icon(Glyph.Link, 12), "Connect a device…", action: sync.BeginPairing));
        }

        UIElement Cancel() => Ui.Press("Footer", "Cancel", sync.EndPairing);
    }

    /// For the networks where the other device never shows up by itself: it
    /// says where it is, and that is typed here.
    private FrameworkElement AddressField()
    {
        var field = new TextBox
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            FontSize = 12,
            Padding = new Thickness(0),
            VerticalContentAlignment = VerticalAlignment.Center,
        };
        field.SetResourceReference(ForegroundProperty, "Primary");
        field.SetResourceReference(TextBox.CaretBrushProperty, "Primary");
        field.SetResourceReference(TextBox.SelectionBrushProperty, "Brand");
        var placeholder = Ui.Text("Not listed? Type the address it shows", 12, null, "Secondary");
        placeholder.IsHitTestVisible = false;
        placeholder.Margin = new Thickness(2, 0, 0, 1);
        field.TextChanged += (_, _) => placeholder.Visibility = field.Text.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        field.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != System.Windows.Input.Key.Enter) return;
            e.Handled = true;
            SyncController.Shared.Pair(field.Text);
        };

        var box = new Grid { Margin = new Thickness(8, 0, 0, 0) };
        box.Children.Add(placeholder);
        box.Children.Add(field);
        var content = new DockPanel();
        content.Children.Add(new Grid { Width = 16, Children = { Ui.Icon(Glyph.Globe, 12) } }.Docked(Dock.Left));
        content.Children.Add(box);
        var row = new Border { Height = 26, Padding = new Thickness(6, 0, 6, 0), CornerRadius = new CornerRadius(6), Child = content };
        row.SetResourceReference(Border.BackgroundProperty, "P05");
        return new Border { Padding = new Thickness(0, 2, 0, 3), Child = row };
    }

    private static FrameworkElement Hint(string text) =>
        Ui.Text(text, 10.5, null, "Secondary").With(t =>
        {
            t.TextWrapping = TextWrapping.Wrap;
            t.Margin = new Thickness(30, 0, 8, 5);
        });

    /// One row of the options: fixed icon column, title, optional trailing
    /// control or hint. Rows with an action highlight on hover; rows that only
    /// host a control do not, because there is nothing to click in the row itself.
    private FrameworkElement Row(UIElement icon, string title, bool beta = false, UIElement? trailing = null,
                                        string? trailingText = null, Action? action = null)
    {
        var content = new DockPanel { LastChildFill = false };
        content.Children.Add(new Grid { Width = 16, Children = { icon } }.Docked(Dock.Left));
        content.Children.Add(Ui.Text(title, 12).With(t => t.Margin = new Thickness(8, 0, 0, 1)).Docked(Dock.Left));
        if (beta) content.Children.Add(Ui.Beta().With(b => b.Margin = new Thickness(6, 1, 0, 0)).Docked(Dock.Left));
        if (trailing != null) content.Children.Add(trailing.Docked(Dock.Right));
        if (trailingText != null) content.Children.Add(Ui.Text(trailingText, 11, null, "Secondary").Docked(Dock.Right));

        if (action != null) return Ui.Press("Row", content, action);
        return new Border { Height = 26, Padding = new Thickness(6, 0, 6, 0), Child = content };
    }

    /// The switches outlive the rows, which are rebuilt on every change: a
    /// switch that was replaced mid-slide would jump instead.
    private readonly Dictionary<string, ToggleButton> switches = new();

    private ToggleButton Switch(bool isOn, Action<bool> set, string? help = null, [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        var key = line.ToString();
        if (!switches.TryGetValue(key, out var toggle))
        {
            toggle = new ToggleButton { ToolTip = help, VerticalAlignment = VerticalAlignment.Center };
            toggle.SetResourceReference(StyleProperty, "Switch");
            var made = toggle;
            made.Click += (_, _) =>
            {
                Slide(made);
                set(made.IsChecked == true);
            };
            switches[key] = toggle;
        }
        (toggle.Parent as Panel)?.Children.Remove(toggle);
        if (toggle.IsChecked != isOn) toggle.IsChecked = isOn;
        return toggle;
    }

    /// Only a click slides the knob: the template sets where it rests, and
    /// this plays the way there.
    private static void Slide(ToggleButton toggle)
    {
        var isOn = toggle.IsChecked == true;
        var duration = TimeSpan.FromMilliseconds(160);
        var ease = new CubicEase { EasingMode = EasingMode.EaseOut };
        if (toggle.Template.FindName("Knob", toggle) is Border knob)
        {
            var shift = new TranslateTransform();
            knob.RenderTransform = shift;
            shift.BeginAnimation(TranslateTransform.XProperty, new DoubleAnimation(isOn ? -10 : 10, 0, duration) { EasingFunction = ease });
        }
        if (toggle.Template.FindName("On", toggle) is Border tint)
        {
            tint.BeginAnimation(OpacityProperty, new DoubleAnimation(isOn ? 0 : 1, isOn ? 1 : 0, duration) { FillBehavior = FillBehavior.Stop });
        }
    }

    /// Asked in place: a dialog on top of a flyout is a popup in a popup.
    private FrameworkElement ClearQuestion()
    {
        var total = ClipboardController.Shared.History.Items.Count;
        var content = new DockPanel { LastChildFill = false };
        content.Children.Add(new Grid { Width = 16, Children = { Ui.Icon(Glyph.Trash, 12, "Danger") } }.Docked(Dock.Left));
        content.Children.Add(Ui.Text(total == 1 ? "Clear the only item?" : $"Clear all {total} items?", 12)
            .With(t => t.Margin = new Thickness(8, 0, 0, 1)).Docked(Dock.Left));
        content.Children.Add(Ui.Press("Destructive", Ui.Text("Clear", 11, FontWeights.Medium, "OnBrandInk"), () =>
        {
            confirmingClear = false;
            ClipboardController.Shared.Clear();
        }).Docked(Dock.Right));
        content.Children.Add(Ui.Press("Footer", "Cancel", () =>
        {
            confirmingClear = false;
            RefreshOptions();
        }).With(b => b.Margin = new Thickness(0, 0, 4, 0)).Docked(Dock.Right));
        return new Border { Height = 26, Padding = new Thickness(6, 0, 0, 0), Child = content };
    }

    // MARK: - Recording a shortcut

    /// A shortcut, as a field: click it, press the keys you want. Esc cancels,
    /// and so does closing the panel.
    private UIElement Recorder(Feature feature)
    {
        var recording = Features.Recording == feature;
        var shortcut = Features.Shortcut(feature);
        var label = !recording ? shortcut.Label : problem ?? (held.Length == 0 ? "Type shortcut" : held);
        var text = Ui.Text(label, 11.5, FontWeights.Medium, problem != null && recording ? "Warning" : recording ? "BrandText" : "Primary");
        text.HorizontalAlignment = HorizontalAlignment.Center;

        var captures = feature is Feature.Screen or Feature.Window;
        var field = Ui.Press("Soft", text, () =>
        {
            if (Features.Recording == feature)
            {
                Features.EndRecording();
                return;
            }
            held = "";
            problem = null;
            Features.BeginRecording(feature, (key, modifiers) => OnRecorded(feature, key, modifiers));
        }, recording ? "Press the new shortcut, or Esc to cancel"
           : "Click, then press the shortcut you want." + (captures ? $" Adding {shortcut.ClipboardKey} sends the capture to the clipboard." : ""));
        field.Tag = new CornerRadius(6);
        field.MinWidth = 92;
        field.Height = 22;
        field.Padding = new Thickness(8, 0, 8, 1);
        field.BorderThickness = new Thickness(1);
        field.SetResourceReference(BackgroundProperty, recording ? "Brand12" : "P07");
        if (recording) field.SetResourceReference(BorderBrushProperty, "Brand55");
        else field.BorderBrush = Brushes.Transparent;

        var row = new StackPanel { Orientation = Orientation.Horizontal };
        var normal = KeyShortcut.Default(feature);
        if (!recording && shortcut != normal)
        {
            var reset = Ui.Press("Soft", Ui.Icon(Glyph.Undo, 10), () =>
            {
                if (Features.ResetShortcut(feature) is { } refused) Toast.Show($"{normal.Label}: {refused.ToLowerInvariant()}", Glyph.Warning);
            }, $"Back to {normal.Label}");
            reset.Width = 20;
            reset.Height = 22;
            reset.HorizontalContentAlignment = HorizontalAlignment.Center;
            row.Children.Add(reset);
        }
        row.Children.Add(field);
        return row;
    }

    private void OnRecorded(Feature feature, int key, Modifiers modifiers)
    {
        if (Features.Recording != feature) return;
        if (key == 0)
        {
            held = KeyShortcut.Describe(modifiers).TrimEnd('+');
            problem = null;
        }
        else if (key == 0x1B && modifiers == Modifiers.None)
        {
            Features.EndRecording();
            return;
        }
        else if (new KeyShortcut(key, modifiers) == Features.Shortcut(feature))
        {
            // Pressing the shortcut it already has: that is the answer, so
            // keep it and stop recording.
            Features.EndRecording();
            return;
        }
        else
        {
            problem = Features.SetShortcut(feature, new KeyShortcut(key, modifiers));
            if (problem == null) return;
        }
        RefreshOptions();
    }
    // MARK: - Updates

    /// Check for Updates, which turns into a highlighted Update button once
    /// one has been found.
    private void RefreshUpdate()
    {
        var updater = Updater.Shared;
        var available = updater.AvailableVersion;
        var label = new StackPanel { Orientation = Orientation.Horizontal };
        label.Children.Add(Ui.Icon(updater.State == Updater.Status.UpToDate ? Glyph.Check : Glyph.Download, 12,
                                   available != null ? "BrandText" : "Secondary"));
        label.Children.Add(Ui.Text(updater.State switch
        {
            Updater.Status.Checking => "Checking…",
            Updater.Status.UpToDate => "Up to date",
            Updater.Status.Installing => "Updating…",
            _ when available != null => $"Update to {available}",
            _ => "Check for Updates",
        }, 12, available != null ? FontWeights.Medium : FontWeights.Normal).With(t => t.Margin = new Thickness(6, 0, 0, 1)));
        if (available == null && updater.State == Updater.Status.Idle)
        {
            label.Children.Add(Ui.Text(Updater.CurrentVersion, 11, null, "Secondary").With(t => t.Margin = new Thickness(6, 0, 0, 0)));
        }
        var button = Ui.Press("Quiet", label, () =>
        {
            if (updater.AvailableVersion != null) updater.Install();
            else updater.Check(byUser: true);
        });
        if (available != null) button.SetResourceReference(BackgroundProperty, "Brand12");
        update.Content = button;
    }
}
