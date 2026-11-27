# Write a raw image to a Windows physical disk (or a byte offset inside it).
#
# Intended for the p2-only UMS LUN (`ums 0 mmc 1:2`): Windows then sees a disk
# with no file system, so a whole-disk write needs no offline and no volume
# locking.
#
#   powershell -ExecutionPolicy Bypass -File tools\flash-part.ps1 `
#       -Image build\rootfs.img -DiskNumber 3 -Verify
#
# Requires an elevated PowerShell. The disk must have no mounted volumes: the
# script refuses to touch a disk that has partitions unless -Force is given.

param(
    [Parameter(Mandatory = $true)][string]$Image,
    [Parameter(Mandatory = $true)][int]$DiskNumber,
    [long]$OffsetBytes = 0,
    [switch]$Verify,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$CHUNK = 4MB

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'run this in an elevated PowerShell'
}
if ($OffsetBytes % 512) { throw "offset must be 512-byte aligned: $OffsetBytes" }

$img = (Resolve-Path $Image).Path
$len = (Get-Item $img).Length
if ($len % 512) { throw "image size must be a multiple of 512: $len" }

$disk = Get-Disk -Number $DiskNumber
Write-Host ("disk {0}: {1} {2} {3} bytes" -f $disk.Number, $disk.FriendlyName, $disk.BusType, $disk.Size)
if ($disk.Size -lt ($OffsetBytes + $len)) {
    throw ("disk too small: need {0} bytes at offset {1}, disk has {2}" -f $len, $OffsetBytes, $disk.Size)
}
$vols = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
        Where-Object { $_.DriveLetter -or $_.Type -ne 'Unknown' }
if ($vols -and -not $Force) {
    throw "disk $DiskNumber has partitions/mounted volumes; use the p2-only LUN or pass -Force"
}

$path = "\\.\PhysicalDrive$DiskNumber"
$diskStream = [IO.File]::Open($path, [IO.FileMode]::Open,
                              [IO.FileAccess]::ReadWrite, [IO.FileShare]::ReadWrite)
$src = [IO.File]::Open($img, [IO.FileMode]::Open,
                       [IO.FileAccess]::Read, [IO.FileShare]::Read)
try {
    if ($OffsetBytes) { [void]$diskStream.Seek($OffsetBytes, [IO.SeekOrigin]::Begin) }
    $buf = New-Object byte[] $CHUNK
    $done = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        $diskStream.Write($buf, 0, $n)
        $done += $n
        $mb = [math]::Round($done / 1MB, 1)
        $rate = if ($sw.Elapsed.TotalSeconds -gt 0) { [math]::Round($done / 1MB / $sw.Elapsed.TotalSeconds, 1) } else { 0 }
        Write-Progress -Activity 'writing' -Status "$mb MiB, $rate MiB/s" `
                       -PercentComplete ([math]::Min(100, $done * 100 / $len))
    }
    $diskStream.Flush($true)
    Write-Host ("wrote {0} bytes at offset {1} in {2:N1}s" -f $done, $OffsetBytes, $sw.Elapsed.TotalSeconds)
} finally {
    $src.Dispose()
    $diskStream.Dispose()
}

if ($Verify) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $srcHash = (Get-FileHash -Algorithm SHA256 -Path $img).Hash
    $diskStream = [IO.File]::Open($path, [IO.FileMode]::Open,
                                  [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        if ($OffsetBytes) { [void]$diskStream.Seek($OffsetBytes, [IO.SeekOrigin]::Begin) }
        $buf = New-Object byte[] $CHUNK
        $left = $len
        while ($left -gt 0) {
            $want = [math]::Min([long]$buf.Length, $left)
            $n = $diskStream.Read($buf, 0, $want)
            if ($n -le 0) { throw 'short read during verify' }
            [void]$sha.TransformBlock($buf, 0, $n, $null, 0)
            $left -= $n
        }
        [void]$sha.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $diskHash = -join ($sha.Hash | ForEach-Object { $_.ToString('x2') })
    } finally {
        $sha.Dispose()
        $diskStream.Dispose()
    }
    if ($diskHash -ne $srcHash.ToLower()) {
        throw "verify mismatch: image $srcHash disk $diskHash"
    }
    Write-Host "verify: OK ($diskHash)"
}
