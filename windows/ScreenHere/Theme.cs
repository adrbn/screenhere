using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Shapes;
using Microsoft.Win32;

namespace ScreenHere;

/// The app's colours. The violet is the one the icon is drawn in, so the panel
/// reads as ScreenHere rather than as a generic system sheet; everything else
/// follows Windows' light and dark modes.
internal static class Theme
{
    public static readonly Color Brand = Color.FromRgb(125, 79, 240);
    public static readonly Color Warning = Color.FromRgb(217, 115, 13);

    public static bool IsDark { get; private set; }

    /// Whether Windows' apps are set to dark.
    public static bool SystemIsDark => ReadPersonalize("AppsUseLightTheme") == 0;

    /// Whether the taskbar is dark, which is what the tray icon is drawn against.
    public static bool TaskbarIsDark => ReadPersonalize("SystemUsesLightTheme") == 0;

    private static int ReadPersonalize(string name)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue(name) is int value ? value : 1;
        }
        catch
        {
            return 1;
        }
    }

    public static void Apply(bool? dark = null)
    {
        IsDark = dark ?? SystemIsDark;
        var resources = Application.Current.Resources;
        var ink = IsDark ? Colors.White : Colors.Black;

        void Set(string key, Color color)
        {
            var brush = new SolidColorBrush(color);
            brush.Freeze();
            resources[key] = brush;
        }
        Color Ink(double opacity) => Color.FromArgb((byte)Math.Round(opacity * 255), ink.R, ink.G, ink.B);
        Color Tint(double opacity) => Color.FromArgb((byte)Math.Round(opacity * 255), Brand.R, Brand.G, Brand.B);

        Set("Bg", IsDark ? Color.FromRgb(39, 39, 41) : Color.FromRgb(244, 244, 246));
        Set("Card", IsDark ? Color.FromRgb(48, 48, 51) : Color.FromRgb(250, 250, 251));
        Set("WindowStroke", IsDark ? Color.FromArgb(46, 255, 255, 255) : Color.FromArgb(34, 0, 0, 0));
        Set("Primary", IsDark ? Color.FromArgb(235, 255, 255, 255) : Color.FromArgb(224, 0, 0, 0));
        Set("Secondary", Ink(IsDark ? 0.55 : 0.5));
        Set("P05", Ink(0.05));
        Set("P06", Ink(0.06));
        Set("P07", Ink(0.07));
        Set("P085", Ink(0.085));
        Set("P09", Ink(0.09));
        Set("P10", Ink(0.10));
        Set("P12", Ink(0.12));
        Set("P20", Ink(0.20));
        Set("Brand", Brand);
        Set("OnBrandInk", Colors.White);
        Set("OnBrandSoft", Color.FromArgb(191, 255, 255, 255));
        // On a dark panel the violet needs lifting to stay readable as text.
        Set("BrandText", IsDark ? Color.FromRgb(160, 124, 250) : Brand);
        Set("Brand12", Tint(IsDark ? 0.20 : 0.12));
        Set("Brand14", Tint(IsDark ? 0.24 : 0.14));
        Set("Brand20", Tint(IsDark ? 0.28 : 0.20));
        Set("Brand55", Tint(0.55));
        Set("BrandHero", Tint(IsDark ? 0.13 : 0.07));
        Set("Warning", IsDark ? Color.FromRgb(240, 150, 60) : Warning);
        Set("Danger", IsDark ? Color.FromRgb(255, 69, 58) : Color.FromRgb(255, 59, 48));
    }
}

/// The icons, from the font Windows itself draws its own with.
internal static class Glyph
{
    public const string Display = "";
    public const string Paste = "";
    public const string Copy = "";
    public const string Link = "";
    public const string History = "";
    public const string Trash = "";
    public const string Power = "";
    public const string More = "";
    public const string Download = "";
    public const string Search = "";
    public const string Warning = "";
    public const string Close = "";
    public const string Lock = "";
    public const string Globe = "";
    public const string Document = "";
    public const string Picture = "";
    public const string Folder = "";
    public const string Undo = "";
    public const string Check = "";
    public const string Enter = "";
    public const string NoResults = "";
    public const string Devices = "";

    /// The pointer in the arrow's proportions, the same outline as the app
    /// icon and the tray icon: tip at the top left, y growing downwards.
    public static readonly Point[] PointerOutline =
    [
        new(0, 0), new(0, 75), new(19, 60), new(32, 97), new(48, 91), new(33, 55), new(56, 54),
    ];
    public static readonly Size PointerSize = new(56, 97);

    public static Geometry Pointer(double height)
    {
        var scale = height / PointerSize.Height;
        var figure = new PathFigure { StartPoint = Scale(PointerOutline[0]), IsClosed = true, IsFilled = true };
        foreach (var point in PointerOutline.Skip(1)) figure.Segments.Add(new LineSegment(Scale(point), true) { IsSmoothJoin = true });
        var geometry = new PathGeometry([figure]);
        geometry.Freeze();
        return geometry;

        Point Scale(Point p) => new(p.X * scale, p.Y * scale);
    }

    /// A window, drawn on a 16-unit grid: no glyph in the font says "this
    /// window" without also saying "close" or "new".
    public static readonly Geometry Window = Geometry.Parse(
        "M3.5,3 H12.5 A2,2 0 0 1 14.5,5 V11 A2,2 0 0 1 12.5,13 H3.5 A2,2 0 0 1 1.5,11 V5 A2,2 0 0 1 3.5,3 Z " +
        "M1.5,6.2 H14.5");

    /// Four corners around lines of text.
    public static readonly Geometry TextViewfinder = Geometry.Parse(
        "M2,5.5 V4 A2,2 0 0 1 4,2 H5.5 M10.5,2 H12 A2,2 0 0 1 14,4 V5.5 M14,10.5 V12 A2,2 0 0 1 12,14 H10.5 " +
        "M5.5,14 H4 A2,2 0 0 1 2,12 V10.5 M5,6 H11 M5,8 H11 M5,10 H9");
}

/// The few shapes every ScreenHere window is built from.
internal static class Ui
{
    public static TextBlock Text(string text, double size, FontWeight? weight = null, string brush = "Primary")
    {
        var block = new TextBlock
        {
            Text = text,
            FontSize = size,
            FontWeight = weight ?? FontWeights.Normal,
            VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis,
        };
        block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    public static TextBlock Icon(string glyph, double size, string? brush = "Secondary")
    {
        var block = new TextBlock
        {
            Text = glyph,
            FontSize = size,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
        };
        block.SetResourceReference(TextBlock.FontFamilyProperty, "IconFont");
        if (brush != null) block.SetResourceReference(TextBlock.ForegroundProperty, brush);
        return block;
    }

    /// One of the hand-drawn icons, stroked like the font's.
    public static Path Stroked(Geometry geometry, double size, string? brush = "Secondary", double thickness = 1.25)
    {
        var path = new Path
        {
            Data = geometry,
            Width = 16,
            Height = 16,
            StrokeThickness = thickness,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            LayoutTransform = new ScaleTransform(size / 16, size / 16),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            SnapsToDevicePixels = false,
        };
        if (brush != null) path.SetResourceReference(Shape.StrokeProperty, brush);
        return path;
    }

    public static Border Beta()
    {
        var text = Text("BETA", 8, FontWeights.Bold, "BrandText");
        var chip = new Border
        {
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(4, 1, 4, 1.5),
            Child = text,
            VerticalAlignment = VerticalAlignment.Center,
        };
        chip.SetResourceReference(Border.BackgroundProperty, "Brand14");
        return chip;
    }

    /// A shortcut, as a keycap.
    public static Border ShortcutChip(string keys)
    {
        var chip = new Border
        {
            CornerRadius = new CornerRadius(4),
            Padding = new Thickness(5, 1.5, 5, 1.5),
            BorderThickness = new Thickness(1),
            Child = Text(keys, 11, FontWeights.Medium),
            VerticalAlignment = VerticalAlignment.Center,
        };
        chip.SetResourceReference(Border.BackgroundProperty, "P07");
        chip.SetResourceReference(Border.BorderBrushProperty, "P09");
        return chip;
    }

    public static T With<T>(this T element, Action<T> configure)
    {
        configure(element);
        return element;
    }

    public static T Docked<T>(this T element, Dock side) where T : UIElement
    {
        DockPanel.SetDock(element, side);
        return element;
    }

    public static Button Press(string style, object content, Action action, string? help = null)
    {
        var button = new Button { Content = content, ToolTip = help };
        button.SetResourceReference(FrameworkElement.StyleProperty, style);
        button.Click += (_, _) => action();
        return button;
    }

    /// A borderless, see-through window that draws its own rounded surface.
    public static void Floating(Window window, bool activates)
    {
        window.WindowStyle = WindowStyle.None;
        window.AllowsTransparency = true;
        window.Background = Brushes.Transparent;
        window.ResizeMode = ResizeMode.NoResize;
        window.ShowInTaskbar = false;
        window.Topmost = true;
        window.ShowActivated = activates;
        window.UseLayoutRounding = true;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.SetResourceReference(Control.FontFamilyProperty, "UiFont");
        // Snapped to the pixel grid, as Windows' own text is. The README's
        // pictures are drawn at twice the size, where snapping would show.
        if (!Shots.IsRunning) TextOptions.SetTextFormattingMode(window, TextFormattingMode.Display);
        window.SourceInitialized += (_, _) =>
        {
            var styles = Native.WS_EX_TOOLWINDOW | (activates ? 0 : Native.WS_EX_NOACTIVATE);
            Native.AddExStyle(new WindowInteropHelper(window).Handle, styles);
        };
    }

    /// The rounded surface and its shadow. The shadow is a sibling, not an
    /// effect on the surface: an effect would blur everything drawn inside.
    public static Grid Surface(UIElement content, double radius, string background = "Bg", double margin = 24, double shadow = 0.34)
    {
        var grid = new Grid { Margin = new Thickness(margin) };
        var cast = new Border
        {
            CornerRadius = new CornerRadius(radius),
            Effect = new DropShadowEffect { BlurRadius = margin, ShadowDepth = margin / 4, Direction = 270, Opacity = shadow, Color = Colors.Black },
        };
        cast.SetResourceReference(Border.BackgroundProperty, background);
        var surface = new Border
        {
            CornerRadius = new CornerRadius(radius),
            BorderThickness = new Thickness(1),
            Child = content,
        };
        surface.SetResourceReference(Border.BackgroundProperty, background);
        surface.SetResourceReference(Border.BorderBrushProperty, "WindowStroke");
        grid.Children.Add(cast);
        grid.Children.Add(surface);
        return grid;
    }

    /// Shows `window` on `display`, wherever `origin` puts it once its real
    /// size is known — in real pixels, so a display at another scale is no
    /// special case.
    public static void ShowOn(Window window, DisplayInfo display, Func<Size, Point> origin, bool activate)
    {
        var handle = new WindowInteropHelper(window).EnsureHandle();
        // On the right display first, so the window is laid out at its scale.
        Native.SetWindowPos(handle, IntPtr.Zero, (int)display.Work.X + 8, (int)display.Work.Y + 8, 0, 0,
                            Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
        window.Opacity = 0;
        window.Show();
        window.UpdateLayout();
        Move(window, origin);
        if (activate)
        {
            Native.TakeForeground(handle);
            window.Activate();
        }
        window.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(120)));
    }

    public static void Move(Window window, Func<Size, Point> origin)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero || !Native.GetWindowRect(handle, out var rect)) return;
        var point = origin(new Size(rect.Width, rect.Height));
        Native.SetWindowPos(handle, IntPtr.Zero, (int)Math.Round(point.X), (int)Math.Round(point.Y), 0, 0,
                            Native.SWP_NOSIZE | Native.SWP_NOZORDER | Native.SWP_NOACTIVATE);
    }

    public static void FadeOut(Window window, double seconds, Action? then = null)
    {
        var fade = new DoubleAnimation(0, TimeSpan.FromSeconds(seconds));
        fade.Completed += (_, _) =>
        {
            window.Close();
            then?.Invoke();
        };
        window.BeginAnimation(UIElement.OpacityProperty, fade);
    }
}
