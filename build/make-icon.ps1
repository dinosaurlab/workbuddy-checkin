param(
    [string]$OutIco = ".\work\workbuddy.ico",
    [string]$PreviewPng = ""
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing

$sizes = @(16, 24, 32, 48, 64, 128, 256)

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap($size, $size, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    # black rounded square
    $d = [Math]::Max(2, [int]($size * 0.18))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, $d, $d, 180, 90)
    $path.AddArc($size - $d, 0, $d, $d, 270, 90)
    $path.AddArc($size - $d, $size - $d, $d, $d, 0, 90)
    $path.AddArc(0, $size - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $g.FillPath([System.Drawing.Brushes]::Black, $path)

    # white check mark
    $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::White, [Math]::Max(2, [int]($size * 0.16)))
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $p1 = New-Object System.Drawing.PointF([float]($size * 0.28), [float]($size * 0.52))
    $p2 = New-Object System.Drawing.PointF([float]($size * 0.44), [float]($size * 0.68))
    $p3 = New-Object System.Drawing.PointF([float]($size * 0.74), [float]($size * 0.34))
    $g.DrawLines($pen, @($p1, $p2, $p3))

    $pen.Dispose()
    $path.Dispose()
    $g.Dispose()
    return $bmp
}

function Convert-BitmapToIcoEntry([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width
    $h = $bmp.Height

    # BITMAPINFOHEADER (40 bytes), 32bpp BGRA, height = 2 * h (XOR + AND)
    $bih = New-Object byte[] 40
    [BitConverter]::GetBytes([int]40).CopyTo($bih, 0)
    [BitConverter]::GetBytes([int]$w).CopyTo($bih, 4)
    [BitConverter]::GetBytes([int]($h * 2)).CopyTo($bih, 8)
    [BitConverter]::GetBytes([int16]1).CopyTo($bih, 12)
    [BitConverter]::GetBytes([int16]32).CopyTo($bih, 14)

    $xor = New-Object byte[] ($w * $h * 4)
    for ($y = 0; $y -lt $h; $y++) {
        for ($x = 0; $x -lt $w; $x++) {
            $c = $bmp.GetPixel($x, $y)
            $idx = (($h - 1 - $y) * $w + $x) * 4
            $xor[$idx] = $c.B
            $xor[$idx + 1] = $c.G
            $xor[$idx + 2] = $c.R
            $xor[$idx + 3] = $c.A
        }
    }

    # AND mask: all zero (opaque), 1bpp rows padded to 32 bits
    $andStride = [int]([Math]::Ceiling($w / 32.0) * 4)
    $and = New-Object byte[] ($andStride * $h)

    $ms = New-Object System.IO.MemoryStream
    $ms.Write($bih, 0, $bih.Length)
    $ms.Write($xor, 0, $xor.Length)
    $ms.Write($and, 0, $and.Length)
    return ,$ms.ToArray()
}

$entries = @()
foreach ($s in $sizes) {
    $bmp = New-IconBitmap $s
    $data = Convert-BitmapToIcoEntry $bmp
    $entries += [pscustomobject]@{ Size = $s; Data = $data }
    $bmp.Dispose()
}

$count = $entries.Count
$ms = New-Object System.IO.MemoryStream
$bw = New-Object System.IO.BinaryWriter($ms)
$bw.Write([uint16]0)
$bw.Write([uint16]1)
$bw.Write([uint16]$count)

$offset = 6 + 16 * $count
foreach ($e in $entries) {
    $dim = if ($e.Size -ge 256) { 0 } else { $e.Size }
    $bw.Write([byte]$dim)
    $bw.Write([byte]$dim)
    $bw.Write([byte]0)
    $bw.Write([byte]0)
    $bw.Write([uint16]1)
    $bw.Write([uint16]32)
    $bw.Write([uint32]$e.Data.Length)
    $bw.Write([uint32]$offset)
    $offset += $e.Data.Length
}
foreach ($e in $entries) {
    $bw.Write($e.Data)
}
$bw.Flush()
$outPath = Join-Path (Resolve-Path (Split-Path $OutIco)).Path (Split-Path $OutIco -Leaf)
[System.IO.File]::WriteAllBytes($outPath, $ms.ToArray())
$bw.Dispose()
$ms.Dispose()
Write-Output "ICON_OK $outPath ($((Get-Item $outPath).Length) bytes)"
if ($PreviewPng) {
    $previewDir = Split-Path $PreviewPng
    if ($previewDir -and -not (Test-Path $previewDir)) {
        New-Item -ItemType Directory -Path $previewDir -Force | Out-Null
    }
    $bmp = New-IconBitmap 256
    $bmp.Save((Join-Path (Resolve-Path (Split-Path $PreviewPng)).Path (Split-Path $PreviewPng -Leaf)), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Output "PREVIEW_OK $PreviewPng"
}
