# Builds a multi-resolution .ico (PNG-compressed frames) from a source PNG.
param(
    # Current logo source (extracted from Resources/AppIcon.icns via extract-icns.ps1).
    [string]$Source = "C:\Users\coras\demotape\demotape\windows\logo\demotape_logo_source.png",
    [string]$Out = "C:\Users\coras\demotape\demotape\windows\src\App\Assets\demotape.ico"
)
Add-Type -AssemblyName System.Drawing
$sizes = 16,20,24,32,40,48,64,128,256
$src = [System.Drawing.Image]::FromFile($Source)

$frames = @()
foreach ($s in $sizes) {
    $bmp = New-Object System.Drawing.Bitmap($s, $s)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, 0, 0, $s, $s)
    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    $frames += ,@{ Size = $s; Bytes = $ms.ToArray() }
    $ms.Dispose()
}
$src.Dispose()

$fs = [System.IO.File]::Create($Out)
$bw = New-Object System.IO.BinaryWriter($fs)
# ICONDIR
$bw.Write([UInt16]0); $bw.Write([UInt16]1); $bw.Write([UInt16]$frames.Count)
$offset = 6 + (16 * $frames.Count)
foreach ($f in $frames) {
    $dim = if ($f.Size -ge 256) { 0 } else { $f.Size }
    $bw.Write([Byte]$dim); $bw.Write([Byte]$dim)   # width, height
    $bw.Write([Byte]0); $bw.Write([Byte]0)          # colorCount, reserved
    $bw.Write([UInt16]1); $bw.Write([UInt16]32)     # planes, bitCount
    $bw.Write([UInt32]$f.Bytes.Length)              # bytesInRes
    $bw.Write([UInt32]$offset)                      # imageOffset
    $offset += $f.Bytes.Length
}
foreach ($f in $frames) { $bw.Write($f.Bytes) }
$bw.Flush(); $bw.Close(); $fs.Close()
Write-Output "Wrote $Out ($((Get-Item $Out).Length) bytes, $($frames.Count) sizes)"
