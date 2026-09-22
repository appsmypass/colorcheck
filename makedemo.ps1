# makedemo.ps1 - build the small MP4 files the README screenshots.
#
# Every recording on this machine is a well behaved BT.709 limited range
# capture, which is exactly the boring case. To show what a colour problem
# looks like the files have to be built on purpose, so this script generates
# them with mp4gen.ps1 and then prints what colorcheck says about each one.
#
# This is a capture aid, not a test. It ships because it is the shortest
# honest answer to "can I see the problem you are describing?".

Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $here 'mp4gen.ps1')

$out = Join-Path $env:TEMP 'colorcheck-demo'
if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
$null = New-Item -ItemType Directory -Path $out

# The classic OBS complaint. The container says limited range, the encoder
# wrote full range into the stream, and the player believes the container:
# blacks crush and highlights clip.
$null = New-SimpleMp4 -LiteralPath (Join-Path $out 'washed-out.mp4') `
    -ColrFullRange $false -VuiFullRange $true

# Recorded on an HDR display with the capture left at SDR defaults. The
# primaries say BT.2020 while the transfer and matrix still say BT.709.
$null = New-SimpleMp4 -LiteralPath (Join-Path $out 'hdr-mixup.mp4') `
    -Width 3840 -Height 2160 `
    -ColrPrimaries 9 -ColrTransfer 1 -ColrMatrix 1 `
    -VuiPrimaries 9 -VuiTransfer 1 -VuiMatrix 1

# Nothing tagged at all: no colr box, no signal type in the stream. Every
# player guesses, and they do not all guess the same way.
$null = New-SimpleMp4 -LiteralPath (Join-Path $out 'untagged.mp4') `
    -ColrKind 'none' -SignalTypePresent $false

# A 1080p capture written with a non square pixel aspect, which stretches on
# playback even though the colour tags are perfect.
$null = New-SimpleMp4 -LiteralPath (Join-Path $out 'stretched.mp4') `
    -PaspH 4 -PaspV 3

# A correct file, so the clean verdict is visible next to the broken ones.
$null = New-SimpleMp4 -LiteralPath (Join-Path $out 'good.mp4')

$tool = Join-Path $here 'colorcheck.ps1'
foreach ($f in @('washed-out.mp4', 'hdr-mixup.mp4', 'untagged.mp4', 'stretched.mp4', 'good.mp4')) {
    Write-Output ''
    Write-Output ('=============== ' + $f + ' ===============')
    & $tool -Path (Join-Path $out $f) -Explain -NoColor
    Write-Output ('(exit ' + [string]$LASTEXITCODE + ')')
}

Write-Output ''
Write-Output ('demo files are in ' + $out)
