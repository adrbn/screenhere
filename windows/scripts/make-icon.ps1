# Draws Assets\ScreenHere.ico: the purple screen with the white pointer, the
# same shapes as the Mac icon's two layers, at the sizes Windows asks for.
Add-Type -AssemblyName System.Drawing

function Draw([int]$side) {
    $bitmap = New-Object Drawing.Bitmap $side, $side, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bitmap); $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
    $u = $side / 1024.0
    $x = 92 * $u; $y = 212 * $u; $w = 840 * $u; $h = 600 * $u; $d = 248 * $u
    $screen = New-Object Drawing.Drawing2D.GraphicsPath
    $screen.AddArc($x, $y, $d, $d, 180, 90); $screen.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $screen.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90); $screen.AddArc($x, $y + $h - $d, $d, $d, 90, 90); $screen.CloseFigure()
    $fill = New-Object Drawing.Drawing2D.LinearGradientBrush ([Drawing.PointF]::new(0, $y)), ([Drawing.PointF]::new(0, $y + $h)),
        ([Drawing.Color]::FromArgb(255, 118, 70, 238)), ([Drawing.Color]::FromArgb(255, 158, 124, 246))
    $g.FillPath($fill, $screen)

    $outline = @(@(0, 0), @(0, 75), @(19, 60), @(32, 97), @(48, 91), @(33, 55), @(56, 54))
    $height = 330 * $u; $k = $height / 97.0; $ox = 512 * $u - 28 * $k; $oy = 512 * $u - $height / 2
    $points = [Drawing.PointF[]]($outline | ForEach-Object { [Drawing.PointF]::new($ox + $_[0] * $k, $oy + $_[1] * $k) })
    $g.FillPolygon([Drawing.Brushes]::White, $points)
    $pen = New-Object Drawing.Pen ([Drawing.Color]::White), (30 * $u); $pen.LineJoin = 'Round'
    $g.DrawPolygon($pen, $points)
    $g.Dispose()
    $stream = New-Object IO.MemoryStream; $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png); $bitmap.Dispose()
    , $stream.ToArray()
}

$sizes = 256, 64, 48, 40, 32, 24, 20, 16
$pngs = $sizes | ForEach-Object { , (Draw $_) }
$out = New-Object IO.MemoryStream; $writer = New-Object IO.BinaryWriter $out
$writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $writer.Write([byte]($sizes[$i] % 256)); $writer.Write([byte]($sizes[$i] % 256)); $writer.Write([byte]0); $writer.Write([byte]0)
    $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$pngs[$i].Length); $writer.Write([uint32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $writer.Write($png) }
$target = Join-Path (Split-Path $PSScriptRoot -Parent) 'ScreenHere\Assets\ScreenHere.ico'
[IO.File]::WriteAllBytes($target, $out.ToArray())
"Wrote $target"
