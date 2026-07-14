# Extracts the largest PNG frame from a macOS .icns into a PNG (for building the Windows icon).
param(
    [string]$Icns = "C:\Users\coras\demotape\demotape\Resources\AppIcon.icns",
    [string]$Out  = "C:\Users\coras\demotape\demotape\windows\logo\demotape_logo_source.png"
)
Add-Type -AssemblyName System.Drawing
$bytes = [System.IO.File]::ReadAllBytes($Icns)
$sig = 0x89,0x50,0x4E,0x47   # PNG signature start

function IndexOf($hay, $needle, $start) {
    for ($i = $start; $i -le $hay.Length - $needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) { if ($hay[$i+$j] -ne $needle[$j]) { $match = $false; break } }
        if ($match) { return $i }
    }
    return -1
}

$iendMarker = 0x49,0x45,0x4E,0x44  # "IEND"
$best = $null; $bestW = 0; $pos = 0
while ($true) {
    $s = IndexOf $bytes $sig $pos
    if ($s -lt 0) { break }
    $e = IndexOf $bytes $iendMarker $s
    if ($e -lt 0) { break }
    $end = $e + 8   # IEND + 4-byte CRC
    $len = $end - $s
    $slice = New-Object byte[] $len
    [Array]::Copy($bytes, $s, $slice, 0, $len)
    try {
        $ms = New-Object System.IO.MemoryStream(,$slice)
        $img = [System.Drawing.Image]::FromStream($ms)
        if ($img.Width -gt $bestW) { $bestW = $img.Width; $best = $slice }
        $img.Dispose(); $ms.Dispose()
    } catch {}
    $pos = $end
}
if ($null -eq $best) { Write-Error "No PNG frames found in $Icns"; exit 1 }
[System.IO.File]::WriteAllBytes($Out, $best)
Write-Output "Wrote $Out ($bestW px, $($best.Length) bytes)"
