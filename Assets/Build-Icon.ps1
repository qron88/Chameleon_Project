param(
    [Parameter(Mandatory=$true)][string]$SourceImage,
    [Parameter(Mandatory=$true)][string]$OutPng,
    [Parameter(Mandatory=$true)][string]$OutIco
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# The source is a JPEG: flat green mark on a white field, no alpha. Both the outer field and the
# negative space inside the mark (eye, mouth, swoosh) are white, so keying white to transparent is
# the faithful reading of a single-colour logo.
#
# Alpha is derived from the BLUE channel because it has the widest range between the logo colour
# (B=32) and white (B=255), so it carries the most signal - and every pixel's RGB is then forced to
# the flat logo colour. That last part matters: with uniform RGB everywhere, including in fully
# transparent pixels, any interpolation during downscaling can only blend alpha, never colour, so
# the small sizes come out with clean edges instead of the white or dark halo you normally get from
# resampling straight-alpha images.
$LOGO_R = 128; $LOGO_G = 172; $LOGO_B = 32
$WHITE_B = 255
$range = $WHITE_B - $LOGO_B

$src = New-Object System.Drawing.Bitmap $SourceImage
$w = $src.Width; $h = $src.Height

$rect = New-Object System.Drawing.Rectangle 0,0,$w,$h
$sd = $src.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$sStride = $sd.Stride
$sBytes = New-Object byte[] ($sStride * $h)
[System.Runtime.InteropServices.Marshal]::Copy($sd.Scan0, $sBytes, 0, $sBytes.Length)
$src.UnlockBits($sd)
$src.Dispose()

$master = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$md = $master.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::WriteOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$mStride = $md.Stride
$mBytes = New-Object byte[] ($mStride * $h)

for ($y = 0; $y -lt $h; $y++) {
    $sRow = $y * $sStride
    $mRow = $y * $mStride
    for ($x = 0; $x -lt $w; $x++) {
        $b = $sBytes[$sRow + $x*4]
        $a = [int][math]::Round((($WHITE_B - $b) * 255.0) / $range)
        if ($a -lt 8)   { $a = 0 }      # squash JPEG noise in the white field
        if ($a -gt 255) { $a = 255 }
        if ($a -lt 0)   { $a = 0 }
        $o = $mRow + $x*4
        $mBytes[$o]   = [byte]$LOGO_B
        $mBytes[$o+1] = [byte]$LOGO_G
        $mBytes[$o+2] = [byte]$LOGO_R
        $mBytes[$o+3] = [byte]$a
    }
}
[System.Runtime.InteropServices.Marshal]::Copy($mBytes, 0, $md.Scan0, $mBytes.Length)
$master.UnlockBits($md)

# --- Crop to the mark, then centre it on a square canvas with a small breathing margin ---------
$minX=[int]::MaxValue; $minY=[int]::MaxValue; $maxX=-1; $maxY=-1
for ($y=0; $y -lt $h; $y++) {
    $mRow = $y*$mStride
    for ($x=0; $x -lt $w; $x++) {
        if ($mBytes[$mRow + $x*4 + 3] -gt 16) {
            if ($x -lt $minX){$minX=$x}; if ($x -gt $maxX){$maxX=$x}
            if ($y -lt $minY){$minY=$y}; if ($y -gt $maxY){$maxY=$y}
        }
    }
}
$cw = $maxX-$minX+1; $ch = $maxY-$minY+1
$side = [int][math]::Ceiling([math]::Max($cw,$ch) * 1.06)   # ~3% margin each side
$square = New-Object System.Drawing.Bitmap($side, $side, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($square)
$g.Clear([System.Drawing.Color]::Transparent)
$g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$g.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$destRect = New-Object System.Drawing.Rectangle ([int](($side-$cw)/2)), ([int](($side-$ch)/2)), $cw, $ch
$srcRect  = New-Object System.Drawing.Rectangle $minX, $minY, $cw, $ch
$g.DrawImage($master, $destRect, $srcRect, [System.Drawing.GraphicsUnit]::Pixel)
$g.Dispose()
$master.Dispose()

$square.Save($OutPng, [System.Drawing.Imaging.ImageFormat]::Png)
Write-Host ("PNG written: {0}  ({1}x{1}, cropped from {2}x{3} content)" -f $OutPng, $side, $cw, $ch)

# --- Build a multi-resolution .ico -------------------------------------------------------------
# Entries up to 128 are plain 32bpp BI_RGB DIBs. Only the 256 entry is PNG-compressed, and the
# split is deliberate:
#   - As a raw DIB the 256 entry alone is 264 KB, which would embed an icon 20x larger than the
#     application binary. PNG-in-ICO is supported by the Windows shell from Vista onward and is
#     what every modern app ships, so 256 is the right place to use it.
#   - It is also the ONLY place to use it. GDI+ / System.Drawing.Icon cannot parse PNG-compressed
#     entries at all (verified: it throws on one), and the app reads its own window icon back out
#     of the .exe through that very API. Keeping every size a .NET caller might ask for as a DIB
#     means both consumers are satisfied - the shell gets a crisp 256, System.Drawing gets
#     something it can decode at every size it will realistically request.
$sizes = @(16, 20, 24, 32, 40, 48, 64, 128, 256)
$PNG_FROM = 256
$images = @()
foreach ($s in $sizes) {
    $bm = New-Object System.Drawing.Bitmap($s, $s, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $gg = [System.Drawing.Graphics]::FromImage($bm)
    $gg.Clear([System.Drawing.Color]::Transparent)
    $gg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $gg.PixelOffsetMode  = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $gg.DrawImage($square, (New-Object System.Drawing.Rectangle 0,0,$s,$s))
    $gg.Dispose()

    if ($s -ge $PNG_FROM) {
        $pms = New-Object System.IO.MemoryStream
        $bm.Save($pms, [System.Drawing.Imaging.ImageFormat]::Png)
        $images += ,@($s, $pms.ToArray())
        $pms.Dispose()
        $bm.Dispose()
        continue
    }

    $r2 = New-Object System.Drawing.Rectangle 0,0,$s,$s
    $bd = $bm.LockBits($r2, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bStride = $bd.Stride
    $raw = New-Object byte[] ($bStride * $s)
    [System.Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length)
    $bm.UnlockBits($bd)
    $bm.Dispose()

    $maskStride = [int]([math]::Floor(($s + 31) / 32) * 4)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    # BITMAPINFOHEADER - biHeight is doubled to cover the (unused) AND mask
    $bw.Write([uint32]40); $bw.Write([int32]$s); $bw.Write([int32]($s*2))
    $bw.Write([uint16]1);  $bw.Write([uint16]32); $bw.Write([uint32]0)
    $bw.Write([uint32]($s*4*$s + $maskStride*$s))
    $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    # XOR data, bottom-up
    for ($y = $s-1; $y -ge 0; $y--) { $bw.Write($raw, $y*$bStride, $s*4) }
    # AND mask: all zeros. The 32bpp alpha channel is what Windows actually uses.
    $bw.Write((New-Object byte[] ($maskStride*$s)), 0, $maskStride*$s)
    $bw.Flush()
    $images += ,@($s, $ms.ToArray())
    $bw.Dispose(); $ms.Dispose()
}

$fs = New-Object System.IO.FileStream($OutIco, [System.IO.FileMode]::Create)
$w2 = New-Object System.IO.BinaryWriter $fs
$w2.Write([uint16]0); $w2.Write([uint16]1); $w2.Write([uint16]$images.Count)   # ICONDIR
$offset = 6 + (16 * $images.Count)
foreach ($img in $images) {
    $s = $img[0]; $data = $img[1]
    $dim = if ($s -ge 256) { 0 } else { $s }    # 0 means 256 in an ICONDIRENTRY
    $w2.Write([byte]$dim); $w2.Write([byte]$dim); $w2.Write([byte]0); $w2.Write([byte]0)
    $w2.Write([uint16]1); $w2.Write([uint16]32)
    $w2.Write([uint32]$data.Length); $w2.Write([uint32]$offset)
    $offset += $data.Length
}
foreach ($img in $images) { $w2.Write($img[1], 0, $img[1].Length) }
$w2.Flush(); $w2.Dispose(); $fs.Dispose()
$square.Dispose()

Write-Host ("ICO written: {0}  ({1} sizes: {2})" -f $OutIco, $images.Count, (($sizes | ForEach-Object { "${_}x${_}" }) -join ', '))
Write-Host ("ICO size: {0} KB" -f [math]::Round((Get-Item $OutIco).Length/1KB,1))
