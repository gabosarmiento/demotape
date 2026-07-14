# Crops a logo PNG to its opaque content (square, small margin) so it fills a tray icon.
param(
    [string]$In  = "C:\Users\coras\demotape\demotape\windows\logo\demotape_logo_source.png",
    [string]$Out = "C:\Users\coras\demotape\demotape\windows\logo\demotape_logo_cropped.png",
    [int]$Size = 512,
    [double]$MarginPct = 0.10
)
Add-Type -AssemblyName System.Drawing
$img = [System.Drawing.Bitmap]::new($In)
$minX = $img.Width; $minY = $img.Height; $maxX = 0; $maxY = 0
$step = 2   # coarse sample for speed; margin covers the small error
for ($y = 0; $y -lt $img.Height; $y += $step) {
    for ($x = 0; $x -lt $img.Width; $x += $step) {
        if ($img.GetPixel($x, $y).A -gt 16) {
            if ($x -lt $minX) { $minX = $x }; if ($x -gt $maxX) { $maxX = $x }
            if ($y -lt $minY) { $minY = $y }; if ($y -gt $maxY) { $maxY = $y }
        }
    }
}
if ($maxX -le $minX) { Write-Error "No opaque content found"; exit 1 }
$cw = $maxX - $minX + 1; $ch = $maxY - $minY + 1
$side = [Math]::Max($cw, $ch)
$margin = [int]($side * $MarginPct)
$side += $margin * 2
$cx = ($minX + $maxX) / 2; $cy = ($minY + $maxY) / 2
$srcX = [int]($cx - $side / 2); $srcY = [int]($cy - $side / 2)

$canvas = [System.Drawing.Bitmap]::new([int]$Size, [int]$Size)
$g = [System.Drawing.Graphics]::FromImage($canvas)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$destRect = [System.Drawing.Rectangle]::new(0, 0, [int]$Size, [int]$Size)
$g.DrawImage($img, $destRect, $srcX, $srcY, $side, $side, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$canvas.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$canvas.Dispose(); $img.Dispose()
Write-Output "Cropped content ${cw}x${ch} -> ${Out} (${Size}px square, margin ${MarginPct})"
