<#
    colorcheck - why does this recording look washed out?

    Reads the colour tags out of an MP4/MOV container and out of the H.264 /
    H.265 bitstream headers, compares them, and explains the mismatch in the
    words you would actually use to describe the symptom.

    No dependencies. Nothing is written. Windows PowerShell 5.1 and later.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string] $Path,

    [switch] $Json,
    [switch] $Recurse,
    [string] $Filter,
    [switch] $Quiet,
    [switch] $Explain,
    [switch] $NoColor,
    [switch] $Version,
    [switch] $Help
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$script:ToolName    = 'colorcheck'
$script:ToolVersion = '1.0.0'

# ---------------------------------------------------------------------------
# Tagged errors.
#
# Every parse failure is wrapped so the caller can tell "this file is not an
# MP4" from "this script has a bug". An untagged exception escaping to the top
# level is a bug and is reported as one.
# ---------------------------------------------------------------------------

function New-ParseError {
    param(
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][string] $Message
    )
    return "colorcheck/$Stage" + ': ' + $Message
}

function Tag-Error {
    param(
        [Parameter(Mandatory = $true)][string] $Stage,
        [Parameter(Mandatory = $true)][scriptblock] $Body
    )
    try {
        return & $Body
    } catch {
        $msg = $_.Exception.Message
        if ($msg -like 'colorcheck/*') { throw $msg }
        throw (New-ParseError -Stage $Stage -Message $msg)
    }
}

# ---------------------------------------------------------------------------
# Big-endian readers.
#
# The whole ISO base media file format is big endian. PowerShell's
# [BitConverter] is little endian on every platform this runs on, so these are
# written out by hand rather than reversing arrays, which allocates.
# ---------------------------------------------------------------------------

function Read-UInt16BE {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset
    )
    if ($Offset -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative offset $Offset") }
    if ($Offset + 2 -gt $Bytes.Length) {
        throw (New-ParseError -Stage 'read' -Message "want 2 bytes at $Offset, have $($Bytes.Length)")
    }
    return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]
}

function Read-UInt24BE {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset
    )
    if ($Offset -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative offset $Offset") }
    if ($Offset + 3 -gt $Bytes.Length) {
        throw (New-ParseError -Stage 'read' -Message "want 3 bytes at $Offset, have $($Bytes.Length)")
    }
    return ([int]$Bytes[$Offset] -shl 16) -bor ([int]$Bytes[$Offset + 1] -shl 8) -bor [int]$Bytes[$Offset + 2]
}

function Read-UInt32BE {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset
    )
    if ($Offset -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative offset $Offset") }
    if ($Offset + 4 -gt $Bytes.Length) {
        throw (New-ParseError -Stage 'read' -Message "want 4 bytes at $Offset, have $($Bytes.Length)")
    }
    # Built as [uint32] because a 32 bit box size with the high bit set is a
    # perfectly ordinary 3 GB movie, and [int] would make it negative.
    $v = [uint32]0
    $v = $v -bor ([uint32]$Bytes[$Offset] -shl 24)
    $v = $v -bor ([uint32]$Bytes[$Offset + 1] -shl 16)
    $v = $v -bor ([uint32]$Bytes[$Offset + 2] -shl 8)
    $v = $v -bor ([uint32]$Bytes[$Offset + 3])
    return $v
}

function Read-UInt64BE {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset
    )
    if ($Offset -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative offset $Offset") }
    if ($Offset + 8 -gt $Bytes.Length) {
        throw (New-ParseError -Stage 'read' -Message "want 8 bytes at $Offset, have $($Bytes.Length)")
    }
    $hi = Read-UInt32BE -Bytes $Bytes -Offset $Offset
    $lo = Read-UInt32BE -Bytes $Bytes -Offset ($Offset + 4)
    return ([uint64]$hi -shl 32) -bor [uint64]$lo
}

function Read-FourCC {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset
    )
    if ($Offset -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative offset $Offset") }
    if ($Offset + 4 -gt $Bytes.Length) {
        throw (New-ParseError -Stage 'read' -Message "want 4 bytes at $Offset, have $($Bytes.Length)")
    }
    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt 4; $i++) {
        $b = $Bytes[$Offset + $i]
        # A four character code is nominally printable ASCII. Anything outside
        # that range is shown as a dot so a corrupt header cannot inject
        # control characters into the terminal.
        if ($b -ge 32 -and $b -le 126) {
            [void]$sb.Append([char]$b)
        } else {
            [void]$sb.Append('.')
        }
    }
    return $sb.ToString()
}

# ---------------------------------------------------------------------------
# Box walking.
#
# An ISO base media file is a flat list of boxes; container boxes hold more
# boxes. A box is a 32 bit size, a four character type, then the payload.
# Size 1 means the real size is a 64 bit value that follows the type. Size 0
# means "to the end of the file", which is legal and is what a still-recording
# file looks like.
# ---------------------------------------------------------------------------

function Read-BoxHeader {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][long] $Limit
    )

    if ($Offset + 8 -gt $Limit) {
        throw (New-ParseError -Stage 'box' -Message "truncated box header at $Offset")
    }

    $size = [uint64](Read-UInt32BE -Bytes $Bytes -Offset $Offset)
    $type = Read-FourCC -Bytes $Bytes -Offset ($Offset + 4)
    $header = 8

    if ($size -eq 1) {
        if ($Offset + 16 -gt $Limit) {
            throw (New-ParseError -Stage 'box' -Message "truncated 64 bit size for '$type' at $Offset")
        }
        $size = Read-UInt64BE -Bytes $Bytes -Offset ($Offset + 8)
        $header = 16
        if ($size -lt [uint64]16) {
            throw (New-ParseError -Stage 'box' -Message "64 bit box '$type' at $Offset declares $size bytes, below its own 16 byte header")
        }
    } elseif ($size -eq 0) {
        # Extends to the end of the enclosing range.
        $size = [uint64]($Limit - $Offset)
        if ($size -lt [uint64]8) {
            throw (New-ParseError -Stage 'box' -Message "open ended box '$type' at $Offset has no room for its header")
        }
    } elseif ($size -lt [uint64]8) {
        throw (New-ParseError -Stage 'box' -Message "box '$type' at $Offset declares $size bytes, below its own 8 byte header")
    }

    if ([uint64]$Offset + $size -gt [uint64]$Limit) {
        throw (New-ParseError -Stage 'box' -Message "box '$type' at $Offset runs $size bytes past the end of its parent")
    }

    return [pscustomobject]@{
        Type        = $type
        Offset      = $Offset
        Size        = [long]$size
        HeaderSize  = $header
        BodyOffset  = $Offset + $header
        BodySize    = [long]$size - $header
        End         = $Offset + [long]$size
    }
}

function Get-ChildBoxes {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][long] $Limit
    )

    $out = New-Object System.Collections.ArrayList
    $p = $Offset
    while ($p + 8 -le $Limit) {
        $h = Read-BoxHeader -Bytes $Bytes -Offset $p -Limit $Limit
        [void]$out.Add($h)
        if ($h.Size -le 0) {
            # Cannot happen given the header checks, but a zero step here would
            # spin forever, so it is asserted rather than assumed.
            throw (New-ParseError -Stage 'box' -Message "box '$($h.Type)' at $p made no progress")
        }
        $p = $h.End
    }
    return @($out.ToArray())
}

function Find-ChildBox {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][long] $Limit,
        [Parameter(Mandatory = $true)][string] $Type
    )
    foreach ($b in (Get-ChildBoxes -Bytes $Bytes -Offset $Offset -Limit $Limit)) {
        if ($b.Type -ceq $Type) { return $b }
    }
    return $null
}

function Find-ChildBoxes {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)][int] $Offset,
        [Parameter(Mandatory = $true)][long] $Limit,
        [Parameter(Mandatory = $true)][string] $Type
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($b in (Get-ChildBoxes -Bytes $Bytes -Offset $Offset -Limit $Limit)) {
        if ($b.Type -ceq $Type) { [void]$out.Add($b) }
    }
    return @($out.ToArray())
}

function Read-FileBytes {
    param(
        [Parameter(Mandatory = $true)][string] $LiteralPath
    )

    $fi = New-Object System.IO.FileInfo($LiteralPath)
    if (-not $fi.Exists) {
        throw (New-ParseError -Stage 'open' -Message "no such file")
    }
    if ($fi.Length -eq 0) {
        throw (New-ParseError -Stage 'open' -Message "file is empty")
    }
    if ($fi.Length -lt 16) {
        throw (New-ParseError -Stage 'open' -Message "file is $($fi.Length) bytes, too small to be an MP4")
    }

    # The colour tags all live in moov, which is either near the front (a
    # faststart file) or at the very end (what a recorder writes). Reading the
    # whole file would mean pulling gigabytes of frame data off the disk to
    # read a 19 byte box, so the file is opened once and seeked instead.
    return $fi
}

# ---------------------------------------------------------------------------
# Locating moov without reading the file.
#
# A 40 GB capture holds its colour tags in a moov box of a few hundred
# kilobytes. Reading the whole file to find them would take minutes and
# achieve nothing, so the top level boxes are walked by seek: read 16 bytes,
# learn the size, jump.
# ---------------------------------------------------------------------------

function Read-At {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream,
        [Parameter(Mandatory = $true)][long] $Position,
        [Parameter(Mandatory = $true)][int] $Count
    )
    if ($Count -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative count $Count") }
    if ($Count -eq 0) { return (New-Object byte[] 0) }
    if ($Position -lt 0) { throw (New-ParseError -Stage 'read' -Message "negative position $Position") }
    if ($Position -ge $Stream.Length) {
        throw (New-ParseError -Stage 'read' -Message "seek to $Position is past the end of a $($Stream.Length) byte file")
    }

    [void]$Stream.Seek($Position, [System.IO.SeekOrigin]::Begin)
    $buf = New-Object byte[] $Count
    $got = 0
    while ($got -lt $Count) {
        # A single Read is allowed to return fewer bytes than asked for. On a
        # local disk it rarely does, which is exactly why the short read is the
        # bug that survives testing, so it is looped here.
        $n = $Stream.Read($buf, $got, $Count - $got)
        if ($n -le 0) { break }
        $got += $n
    }
    if ($got -lt $Count) {
        throw (New-ParseError -Stage 'read' -Message "wanted $Count bytes at $Position, got $got")
    }
    return $buf
}

function Get-TopLevelBoxes {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream
    )

    $len  = $Stream.Length
    $out  = New-Object System.Collections.ArrayList
    $pos  = [long]0
    $seen = 0

    while ($pos + 8 -le $len) {
        $head = Read-At -Stream $Stream -Position $pos -Count ([int][Math]::Min([long]16, $len - $pos))
        if ($head.Length -lt 8) { break }

        $size   = [uint64](Read-UInt32BE -Bytes $head -Offset 0)
        $type   = Read-FourCC -Bytes $head -Offset 4
        $header = 8

        if ($size -eq 1) {
            if ($head.Length -lt 16) {
                throw (New-ParseError -Stage 'box' -Message "truncated 64 bit size for '$type' at $pos")
            }
            $size = Read-UInt64BE -Bytes $head -Offset 8
            $header = 16
            if ($size -lt [uint64]16) {
                throw (New-ParseError -Stage 'box' -Message "64 bit box '$type' at $pos declares $size bytes")
            }
        } elseif ($size -eq 0) {
            $size = [uint64]($len - $pos)
        } elseif ($size -lt [uint64]8) {
            throw (New-ParseError -Stage 'box' -Message "box '$type' at $pos declares $size bytes, below its own header")
        }

        $end = [long]$pos + [long]$size
        if ($end -gt $len) {
            # A file still being written by the recorder has a final box that
            # claims more than exists. That is worth saying out loud rather
            # than treating as corruption.
            $end = $len
            [void]$out.Add([pscustomobject]@{
                Type = $type; Offset = $pos; Size = [long]($len - $pos)
                HeaderSize = $header; BodyOffset = [long]$pos + $header
                BodySize = [long]($len - $pos) - $header; End = $len; Truncated = $true
            })
            break
        }

        [void]$out.Add([pscustomobject]@{
            Type = $type; Offset = $pos; Size = [long]$size
            HeaderSize = $header; BodyOffset = [long]$pos + $header
            BodySize = [long]$size - $header; End = $end; Truncated = $false
        })

        $pos = $end
        $seen++
        if ($seen -gt 4096) {
            throw (New-ParseError -Stage 'box' -Message "more than 4096 top level boxes; this is not a sane MP4")
        }
    }

    return @($out.ToArray())
}

function Get-MoovBody {
    param(
        [Parameter(Mandatory = $true)][System.IO.FileStream] $Stream
    )

    $top = Get-TopLevelBoxes -Stream $Stream
    if (@($top).Count -eq 0) {
        throw (New-ParseError -Stage 'container' -Message "no boxes at all; not an MP4 or MOV")
    }

    $brand = $null
    $ftyp  = $null
    foreach ($b in $top) { if ($b.Type -ceq 'ftyp') { $ftyp = $b; break } }
    if ($null -ne $ftyp -and $ftyp.BodySize -ge 4) {
        $fb = Read-At -Stream $Stream -Position $ftyp.BodyOffset -Count 4
        $brand = Read-FourCC -Bytes $fb -Offset 0
    }

    $moov = $null
    foreach ($b in $top) { if ($b.Type -ceq 'moov') { $moov = $b; break } }
    if ($null -eq $moov) {
        $types = (@($top) | ForEach-Object { $_.Type }) -join ', '
        throw (New-ParseError -Stage 'container' -Message "no moov box (top level boxes: $types). A file still being recorded has no moov until it is stopped.")
    }
    if ($moov.Truncated) {
        throw (New-ParseError -Stage 'container' -Message "the moov box is cut off; the file is incomplete")
    }
    if ($moov.BodySize -le 0) {
        throw (New-ParseError -Stage 'container' -Message "the moov box is empty")
    }
    if ($moov.BodySize -gt 268435456) {
        throw (New-ParseError -Stage 'container' -Message "the moov box claims $($moov.BodySize) bytes, which is not credible")
    }

    return [pscustomobject]@{
        Bytes      = (Read-At -Stream $Stream -Position $moov.BodyOffset -Count ([int]$moov.BodySize))
        Brand      = $brand
        MoovOffset = $moov.Offset
        MoovSize   = $moov.Size
        TopLevel   = $top
        FileSize   = $Stream.Length
    }
}

# ---------------------------------------------------------------------------
# Finding the video sample entry.
#
# moov -> trak -> mdia -> hdlr picks out the video track, and
# mdia -> minf -> stbl -> stsd holds the sample entry that describes how the
# pictures are coded. The colour tags hang off that entry as child boxes.
# ---------------------------------------------------------------------------

# A VisualSampleEntry is a SampleEntry (6 reserved + 2 data reference index)
# followed by 70 bytes of fixed fields, and only then do child boxes start.
# Getting this constant wrong is the classic way to "find" a colr box that is
# really part of the compressor name string.
$script:VisualSampleEntryHeader = 78

function Get-HandlerType {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $MdiaBox
    )
    $hdlr = Find-ChildBox -Bytes $Bytes -Offset $MdiaBox.BodyOffset -Limit $MdiaBox.End -Type 'hdlr'
    if ($null -eq $hdlr) { return $null }
    if ($hdlr.BodySize -lt 12) { return $null }
    return Read-FourCC -Bytes $Bytes -Offset ($hdlr.BodyOffset + 8)
}

function Get-TrackId {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $TrakBox
    )
    $tkhd = Find-ChildBox -Bytes $Bytes -Offset $TrakBox.BodyOffset -Limit $TrakBox.End -Type 'tkhd'
    if ($null -eq $tkhd) { return 0 }
    if ($tkhd.BodySize -lt 4) { return 0 }
    $version = $Bytes[$tkhd.BodyOffset]
    # Version 1 widened creation time, modification time and duration from 32
    # to 64 bits, which moves track_id by 8 bytes. Assuming version 0 reports
    # the wrong track on anything recorded past 2038 or written by a tool that
    # just always writes version 1.
    if ($version -eq 1) {
        if ($tkhd.BodySize -lt 28) { return 0 }
        return [long](Read-UInt32BE -Bytes $Bytes -Offset ($tkhd.BodyOffset + 20))
    }
    if ($tkhd.BodySize -lt 16) { return 0 }
    return [long](Read-UInt32BE -Bytes $Bytes -Offset ($tkhd.BodyOffset + 12))
}

function Get-VideoSampleEntries {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )

    $limit   = [long]$Bytes.Length
    $entries = New-Object System.Collections.ArrayList

    foreach ($trak in (Find-ChildBoxes -Bytes $Bytes -Offset 0 -Limit $limit -Type 'trak')) {

        $mdia = Find-ChildBox -Bytes $Bytes -Offset $trak.BodyOffset -Limit $trak.End -Type 'mdia'
        if ($null -eq $mdia) { continue }

        $handler = Get-HandlerType -Bytes $Bytes -MdiaBox $mdia
        if ($handler -cne 'vide') { continue }

        $minf = Find-ChildBox -Bytes $Bytes -Offset $mdia.BodyOffset -Limit $mdia.End -Type 'minf'
        if ($null -eq $minf) { continue }
        $stbl = Find-ChildBox -Bytes $Bytes -Offset $minf.BodyOffset -Limit $minf.End -Type 'stbl'
        if ($null -eq $stbl) { continue }
        $stsd = Find-ChildBox -Bytes $Bytes -Offset $stbl.BodyOffset -Limit $stbl.End -Type 'stsd'
        if ($null -eq $stsd) { continue }
        if ($stsd.BodySize -lt 8) { continue }

        $count = Read-UInt32BE -Bytes $Bytes -Offset ($stsd.BodyOffset + 4)
        if ($count -eq 0) { continue }
        if ($count -gt 256) {
            throw (New-ParseError -Stage 'stsd' -Message "sample description count of $count is not credible")
        }

        $p = $stsd.BodyOffset + 8
        for ($i = 0; $i -lt [int]$count; $i++) {
            if ($p + 8 -gt $stsd.End) { break }
            $se = Read-BoxHeader -Bytes $Bytes -Offset $p -Limit $stsd.End

            if ($se.BodySize -ge $script:VisualSampleEntryHeader) {
                $w = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 24)
                $h = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 26)
                $depth = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 74)

                [void]$entries.Add([pscustomobject]@{
                    Format        = $se.Type
                    TrackId       = (Get-TrackId -Bytes $Bytes -TrakBox $trak)
                    Width         = $w
                    Height        = $h
                    Depth         = $depth
                    ChildOffset   = $se.BodyOffset + $script:VisualSampleEntryHeader
                    ChildLimit    = $se.End
                    EntryIndex    = $i
                })
            }
            $p = $se.End
        }
    }

    return @($entries.ToArray())
}

# ---------------------------------------------------------------------------
# What the numbers mean.
#
# Primaries, transfer and matrix are three independent code points defined by
# ITU-T H.273. Players do not agree on what to do when they are missing, which
# is the whole reason this tool exists.
# ---------------------------------------------------------------------------

$script:PrimariesNames = @{
    1  = 'BT.709'
    2  = 'unspecified'
    4  = 'BT.470 System M'
    5  = 'BT.601 625 line (BT.470BG)'
    6  = 'BT.601 525 line (SMPTE 170M)'
    7  = 'SMPTE 240M'
    8  = 'Generic film'
    9  = 'BT.2020'
    10 = 'SMPTE ST 428'
    11 = 'DCI-P3'
    12 = 'Display P3'
    22 = 'EBU Tech 3213-E'
}

$script:TransferNames = @{
    1  = 'BT.709'
    2  = 'unspecified'
    4  = 'gamma 2.2'
    5  = 'gamma 2.8'
    6  = 'BT.601'
    7  = 'SMPTE 240M'
    8  = 'linear'
    9  = 'log 100:1'
    10 = 'log 316:1'
    11 = 'IEC 61966-2-4'
    12 = 'BT.1361'
    13 = 'sRGB'
    14 = 'BT.2020 10 bit'
    15 = 'BT.2020 12 bit'
    16 = 'PQ (SMPTE ST 2084)'
    17 = 'SMPTE ST 428'
    18 = 'HLG (ARIB STD-B67)'
}

$script:MatrixNames = @{
    0  = 'identity (RGB)'
    1  = 'BT.709'
    2  = 'unspecified'
    3  = 'reserved'
    4  = 'FCC 73.682'
    5  = 'BT.601 625 line (BT.470BG)'
    6  = 'BT.601 525 line (SMPTE 170M)'
    7  = 'SMPTE 240M'
    8  = 'YCgCo'
    9  = 'BT.2020 non-constant luminance'
    10 = 'BT.2020 constant luminance'
    11 = 'SMPTE ST 2085'
    12 = 'chromaticity-derived non-constant'
    13 = 'chromaticity-derived constant'
    14 = 'ICtCp'
}

function Get-CodeName {
    param(
        [Parameter(Mandatory = $true)][hashtable] $Table,
        [Parameter(Mandatory = $true)][int] $Code
    )
    if ($Table.ContainsKey($Code)) { return $Table[$Code] }
    return "unknown ($Code)"
}

function Test-IsHdrTransfer {
    param([Parameter(Mandatory = $true)][int] $Transfer)
    # Only PQ and HLG mean HDR. BT.2020 primaries alone do not: plenty of SDR
    # files carry wide primaries with an ordinary gamma curve.
    return ($Transfer -eq 16 -or $Transfer -eq 18)
}

# ---------------------------------------------------------------------------
# The colr box and its neighbours.
# ---------------------------------------------------------------------------

function Parse-Colr {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $Box
    )

    if ($Box.BodySize -lt 4) {
        throw (New-ParseError -Stage 'colr' -Message "colr box holds only $($Box.BodySize) bytes")
    }

    $kind = Read-FourCC -Bytes $Bytes -Offset $Box.BodyOffset

    if ($kind -ceq 'nclx' -or $kind -ceq 'nclc') {
        if ($Box.BodySize -lt 10) {
            throw (New-ParseError -Stage 'colr' -Message "'$kind' colr box needs 10 bytes, has $($Box.BodySize)")
        }
        $prim = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 4)
        $tran = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 6)
        $matx = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 8)

        # nclc is the QuickTime spelling and has no range flag at all, so the
        # range is genuinely unknown rather than limited. Reporting it as
        # limited would invent information the file does not carry.
        $full = $null
        if ($kind -ceq 'nclx') {
            if ($Box.BodySize -lt 11) {
                throw (New-ParseError -Stage 'colr' -Message "'nclx' colr box is missing its range byte")
            }
            $rangeByte = $Bytes[$Box.BodyOffset + 10]
            $full = (($rangeByte -band 0x80) -ne 0)
        }

        return [pscustomobject]@{
            Kind       = $kind
            Primaries  = [int]$prim
            Transfer   = [int]$tran
            Matrix     = [int]$matx
            FullRange  = $full
            IccBytes   = 0
        }
    }

    if ($kind -ceq 'rICC' -or $kind -ceq 'prof') {
        return [pscustomobject]@{
            Kind       = $kind
            Primaries  = $null
            Transfer   = $null
            Matrix     = $null
            FullRange  = $null
            IccBytes   = [int]($Box.BodySize - 4)
        }
    }

    throw (New-ParseError -Stage 'colr' -Message "unrecognised colour type '$kind'")
}

function Parse-Pasp {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $Box
    )
    if ($Box.BodySize -lt 8) {
        throw (New-ParseError -Stage 'pasp' -Message "pasp box holds only $($Box.BodySize) bytes")
    }
    $h = Read-UInt32BE -Bytes $Bytes -Offset $Box.BodyOffset
    $v = Read-UInt32BE -Bytes $Bytes -Offset ($Box.BodyOffset + 4)
    return [pscustomobject]@{ HSpacing = [long]$h; VSpacing = [long]$v }
}

# ---------------------------------------------------------------------------
# Bitstream reading.
#
# The colour tags in the container can be absent or wrong. The ones the
# decoder actually obeys live inside the sequence parameter set, which is a
# bit-packed structure with variable length integers, so it has to be read a
# bit at a time.
# ---------------------------------------------------------------------------

function Remove-EmulationPrevention {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )
    # Inside a NAL unit the byte sequence 00 00 03 is an escape: the 03 was
    # inserted by the encoder so the payload could never contain a start code,
    # and it must come out before the bits mean anything. Skipping this step
    # gives you a parser that works until it silently does not.
    $out = New-Object System.Collections.Generic.List[byte]
    $zeros = 0
    for ($i = 0; $i -lt $Bytes.Length; $i++) {
        $b = $Bytes[$i]
        if ($zeros -ge 2 -and $b -eq 3) {
            $zeros = 0
            continue
        }
        [void]$out.Add($b)
        if ($b -eq 0) { $zeros++ } else { $zeros = 0 }
    }
    return $out.ToArray()
}

function New-BitReader {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes
    )
    return [pscustomobject]@{
        Bytes    = $Bytes
        BitPos   = 0
        TotalBits = $Bytes.Length * 8
    }
}

function Read-Bit {
    param([Parameter(Mandatory = $true)] $Reader)
    if ($Reader.BitPos -ge $Reader.TotalBits) {
        throw (New-ParseError -Stage 'sps' -Message "ran off the end of the parameter set after $($Reader.BitPos) bits")
    }
    # -shr 3 rather than [int]($BitPos / 8): PowerShell's [int] cast rounds to
    # nearest, so [int](5 / 8) is 1, not 0, and the reader silently skips into
    # the wrong byte for five bit positions out of every eight.
    $byte = $Reader.Bytes[($Reader.BitPos -shr 3)]
    $shift = 7 - ($Reader.BitPos -band 7)
    $Reader.BitPos = $Reader.BitPos + 1
    return ([int]$byte -shr $shift) -band 1
}

function Read-Bits {
    param(
        [Parameter(Mandatory = $true)] $Reader,
        [Parameter(Mandatory = $true)][int] $Count
    )
    if ($Count -lt 0) { throw (New-ParseError -Stage 'sps' -Message "negative bit count $Count") }
    if ($Count -eq 0) { return 0 }
    if ($Count -gt 32) { throw (New-ParseError -Stage 'sps' -Message "refusing to read $Count bits into a 32 bit value") }
    $v = [uint32]0
    for ($i = 0; $i -lt $Count; $i++) {
        $v = ($v -shl 1) -bor [uint32](Read-Bit -Reader $Reader)
    }
    return [long]$v
}

function Skip-Bits {
    param(
        [Parameter(Mandatory = $true)] $Reader,
        [Parameter(Mandatory = $true)][int] $Count
    )
    if ($Count -lt 0) { throw (New-ParseError -Stage 'sps' -Message "negative skip $Count") }
    if ($Reader.BitPos + $Count -gt $Reader.TotalBits) {
        throw (New-ParseError -Stage 'sps' -Message "skipping $Count bits runs past the end of the parameter set")
    }
    $Reader.BitPos = $Reader.BitPos + $Count
}

function Read-Ue {
    param([Parameter(Mandatory = $true)] $Reader)
    # Exponential Golomb: count the leading zeros, then read that many more
    # bits. The value is (1 << n) - 1 + suffix.
    $leadingZeros = 0
    while ($true) {
        $b = Read-Bit -Reader $Reader
        if ($b -eq 1) { break }
        $leadingZeros++
        if ($leadingZeros -gt 32) {
            throw (New-ParseError -Stage 'sps' -Message "exp-Golomb code with more than 32 leading zeros; the stream is not aligned")
        }
    }
    if ($leadingZeros -eq 0) { return [long]0 }
    $suffix = Read-Bits -Reader $Reader -Count $leadingZeros
    return [long]((([long]1 -shl $leadingZeros) - 1) + $suffix)
}

function Read-Se {
    param([Parameter(Mandatory = $true)] $Reader)
    $k = Read-Ue -Reader $Reader
    if (($k % 2) -eq 0) {
        # Even codes map to negative values, odd to positive, and zero maps to
        # zero. Getting the sign backwards here is invisible on most files
        # because the fields it affects are usually zero.
        return [long](-1 * ($k / 2))
    }
    return [long](($k + 1) / 2)
}

function Skip-ScalingListAvc {
    param(
        [Parameter(Mandatory = $true)] $Reader,
        [Parameter(Mandatory = $true)][int] $Size
    )
    $lastScale = 8
    $nextScale = 8
    for ($j = 0; $j -lt $Size; $j++) {
        if ($nextScale -ne 0) {
            $delta = Read-Se -Reader $Reader
            $nextScale = [int]((($lastScale + $delta + 256) % 256))
        }
        if ($nextScale -ne 0) { $lastScale = $nextScale }
    }
}

# ---------------------------------------------------------------------------
# H.264 sequence parameter set.
# ---------------------------------------------------------------------------

# High profiles carry chroma format and scaling lists that the baseline
# profiles do not. Reading a High profile SPS with the baseline layout walks
# the bit position past the fields that matter and produces plausible
# nonsense, so the profile list is explicit.
$script:AvcHighProfiles = @(100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135)

function New-AbsentVui {
    # A stream that carries no VUI block and a stream that carries one without
    # a video_signal_type say exactly the same thing about colour: nothing. One
    # shape for both keeps every caller from having to test for null as well as
    # for the flag, which is the kind of split that quietly grows a bug.
    return [pscustomobject]@{
        Present     = $false
        Block       = $false
        VideoFormat = $null
        FullRange   = $null
        Primaries   = $null
        Transfer    = $null
        Matrix      = $null
        AspectIdc   = $null
        SarWidth    = $null
        SarHeight   = $null
        Overscan    = $null
    }
}

function Read-VuiVideoSignalType {
    param([Parameter(Mandatory = $true)] $Reader)

    $aspectPresent = Read-Bit -Reader $Reader
    $sarWidth = $null
    $sarHeight = $null
    $aspectIdc = $null
    if ($aspectPresent -eq 1) {
        $aspectIdc = Read-Bits -Reader $Reader -Count 8
        if ($aspectIdc -eq 255) {
            $sarWidth  = Read-Bits -Reader $Reader -Count 16
            $sarHeight = Read-Bits -Reader $Reader -Count 16
        }
    }

    $overscanPresent = Read-Bit -Reader $Reader
    $overscan = $null
    if ($overscanPresent -eq 1) {
        $overscan = ((Read-Bit -Reader $Reader) -eq 1)
    }

    $signalPresent = Read-Bit -Reader $Reader
    if ($signalPresent -ne 1) {
        return [pscustomobject]@{
            Present     = $false
            Block       = $true
            VideoFormat = $null
            FullRange   = $null
            Primaries   = $null
            Transfer    = $null
            Matrix      = $null
            AspectIdc   = $aspectIdc
            SarWidth    = $sarWidth
            SarHeight   = $sarHeight
            Overscan    = $overscan
        }
    }

    $videoFormat = Read-Bits -Reader $Reader -Count 3
    $fullRange   = ((Read-Bit -Reader $Reader) -eq 1)
    $colourPresent = Read-Bit -Reader $Reader

    $prim = $null; $tran = $null; $matx = $null
    if ($colourPresent -eq 1) {
        $prim = Read-Bits -Reader $Reader -Count 8
        $tran = Read-Bits -Reader $Reader -Count 8
        $matx = Read-Bits -Reader $Reader -Count 8
    }

    return [pscustomobject]@{
        Present     = $true
        Block       = $true
        VideoFormat = [int]$videoFormat
        FullRange   = $fullRange
        Primaries   = $(if ($null -eq $prim) { $null } else { [int]$prim })
        Transfer    = $(if ($null -eq $tran) { $null } else { [int]$tran })
        Matrix      = $(if ($null -eq $matx) { $null } else { [int]$matx })
        AspectIdc   = $aspectIdc
        SarWidth    = $sarWidth
        SarHeight   = $sarHeight
        Overscan    = $overscan
    }
}

function Parse-SpsAvc {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Nal
    )

    return Tag-Error -Stage 'sps' -Body {
        if ($Nal.Length -lt 4) {
            throw (New-ParseError -Stage 'sps' -Message "SPS is $($Nal.Length) bytes, too short to hold a profile")
        }

        # Byte 0 is the NAL header: forbidden_zero_bit, nal_ref_idc, nal_unit_type.
        $nalType = [int]$Nal[0] -band 0x1F
        if ($nalType -ne 7) {
            throw (New-ParseError -Stage 'sps' -Message "expected NAL type 7 (SPS), found $nalType")
        }

        $rbsp = Remove-EmulationPrevention -Bytes $Nal[1..($Nal.Length - 1)]
        $r = New-BitReader -Bytes $rbsp

        $profileIdc = Read-Bits -Reader $r -Count 8
        $constraintFlags = Read-Bits -Reader $r -Count 8
        $levelIdc = Read-Bits -Reader $r -Count 8
        [void](Read-Ue -Reader $r)   # seq_parameter_set_id

        $chromaFormat = 1
        $bitDepthLuma = 8
        $bitDepthChroma = 8
        if ($script:AvcHighProfiles -contains [int]$profileIdc) {
            $chromaFormat = [int](Read-Ue -Reader $r)
            if ($chromaFormat -eq 3) { [void](Read-Bit -Reader $r) }  # separate_colour_plane_flag
            $bitDepthLuma = [int](Read-Ue -Reader $r) + 8
            $bitDepthChroma = [int](Read-Ue -Reader $r) + 8
            [void](Read-Bit -Reader $r)                                # qpprime_y_zero_transform_bypass_flag
            $scalingPresent = Read-Bit -Reader $r
            if ($scalingPresent -eq 1) {
                $lists = $(if ($chromaFormat -ne 3) { 8 } else { 12 })
                for ($i = 0; $i -lt $lists; $i++) {
                    if ((Read-Bit -Reader $r) -eq 1) {
                        $size = $(if ($i -lt 6) { 16 } else { 64 })
                        Skip-ScalingListAvc -Reader $r -Size $size
                    }
                }
            }
        }

        [void](Read-Ue -Reader $r)   # log2_max_frame_num_minus4
        $pocType = [int](Read-Ue -Reader $r)
        if ($pocType -eq 0) {
            [void](Read-Ue -Reader $r)
        } elseif ($pocType -eq 1) {
            [void](Read-Bit -Reader $r)
            [void](Read-Se -Reader $r)
            [void](Read-Se -Reader $r)
            $cycle = [int](Read-Ue -Reader $r)
            if ($cycle -gt 255) {
                throw (New-ParseError -Stage 'sps' -Message "num_ref_frames_in_pic_order_cnt_cycle of $cycle is out of range")
            }
            for ($i = 0; $i -lt $cycle; $i++) { [void](Read-Se -Reader $r) }
        } elseif ($pocType -ne 2) {
            throw (New-ParseError -Stage 'sps' -Message "pic_order_cnt_type $pocType is not defined")
        }

        [void](Read-Ue -Reader $r)   # max_num_ref_frames
        [void](Read-Bit -Reader $r)  # gaps_in_frame_num_value_allowed_flag

        $widthMbs   = [int](Read-Ue -Reader $r) + 1
        $heightUnits = [int](Read-Ue -Reader $r) + 1
        $frameMbsOnly = Read-Bit -Reader $r
        if ($frameMbsOnly -ne 1) { [void](Read-Bit -Reader $r) }  # mb_adaptive_frame_field_flag
        [void](Read-Bit -Reader $r)                                # direct_8x8_inference_flag

        $cropLeft = 0; $cropRight = 0; $cropTop = 0; $cropBottom = 0
        if ((Read-Bit -Reader $r) -eq 1) {
            $cropLeft   = [int](Read-Ue -Reader $r)
            $cropRight  = [int](Read-Ue -Reader $r)
            $cropTop    = [int](Read-Ue -Reader $r)
            $cropBottom = [int](Read-Ue -Reader $r)
        }

        # Crop offsets are counted in chroma samples, so 4:2:0 doubles them
        # horizontally and, for progressive video, vertically too. This is why
        # a 1080p stream is coded as 1088 lines and cropped back to 1080.
        $subWidthC  = $(if ($chromaFormat -eq 3) { 1 } elseif ($chromaFormat -eq 0) { 1 } else { 2 })
        $subHeightC = $(if ($chromaFormat -eq 1) { 2 } else { 1 })
        $heightMult = $(if ($frameMbsOnly -eq 1) { 1 } else { 2 })

        $width  = ($widthMbs * 16) - ($subWidthC * ($cropLeft + $cropRight))
        $height = ($heightUnits * 16 * $heightMult) - ($subHeightC * $heightMult * ($cropTop + $cropBottom))

        $vui = New-AbsentVui
        if ((Read-Bit -Reader $r) -eq 1) {
            $vui = Read-VuiVideoSignalType -Reader $r
        }

        return [pscustomobject]@{
            Codec          = 'H.264'
            ProfileIdc     = [int]$profileIdc
            LevelIdc       = [int]$levelIdc
            ConstraintFlags = [int]$constraintFlags
            ChromaFormat   = $chromaFormat
            BitDepthLuma   = $bitDepthLuma
            BitDepthChroma = $bitDepthChroma
            Width          = $width
            Height         = $height
            Vui            = $vui
        }
    }
}

# ---------------------------------------------------------------------------
# H.265 sequence parameter set.
#
# Longer than the H.264 one because everything before the VUI has to be walked
# exactly, including the short term reference picture sets, which are variable
# length and depend on each other.
# ---------------------------------------------------------------------------

function Skip-ProfileTierLevel {
    param(
        [Parameter(Mandatory = $true)] $Reader,
        [Parameter(Mandatory = $true)][int] $MaxSubLayersMinus1
    )

    # general_profile_space(2) tier(1) profile_idc(5) compatibility(32)
    # progressive(1) interlaced(1) non_packed(1) frame_only(1) reserved(43+1)
    Skip-Bits -Reader $Reader -Count 8
    $profileIdc = $null
    $compat = Read-Bits -Reader $Reader -Count 32
    Skip-Bits -Reader $Reader -Count 4
    Skip-Bits -Reader $Reader -Count 22
    Skip-Bits -Reader $Reader -Count 22
    $levelIdc = Read-Bits -Reader $Reader -Count 8

    if ($MaxSubLayersMinus1 -lt 0 -or $MaxSubLayersMinus1 -gt 7) {
        throw (New-ParseError -Stage 'sps' -Message "sps_max_sub_layers_minus1 of $MaxSubLayersMinus1 is out of range")
    }

    $profilePresent = New-Object 'System.Collections.Generic.List[int]'
    $levelPresent   = New-Object 'System.Collections.Generic.List[int]'
    for ($i = 0; $i -lt $MaxSubLayersMinus1; $i++) {
        [void]$profilePresent.Add([int](Read-Bit -Reader $Reader))
        [void]$levelPresent.Add([int](Read-Bit -Reader $Reader))
    }
    if ($MaxSubLayersMinus1 -gt 0) {
        for ($i = $MaxSubLayersMinus1; $i -lt 8; $i++) { Skip-Bits -Reader $Reader -Count 2 }
    }
    for ($i = 0; $i -lt $MaxSubLayersMinus1; $i++) {
        if ($profilePresent[$i] -eq 1) { Skip-Bits -Reader $Reader -Count 88 }
        if ($levelPresent[$i] -eq 1)   { Skip-Bits -Reader $Reader -Count 8 }
    }

    return [pscustomobject]@{ LevelIdc = [int]$levelIdc; Compatibility = $compat }
}

function Skip-ShortTermRefPicSet {
    param(
        [Parameter(Mandatory = $true)] $Reader,
        [Parameter(Mandatory = $true)][int] $Index,
        [Parameter(Mandatory = $true)][int] $NumSets,
        [Parameter(Mandatory = $true)] $NumDeltaPocs
    )

    $interPredict = 0
    if ($Index -ne 0) { $interPredict = Read-Bit -Reader $Reader }

    if ($interPredict -eq 1) {
        $deltaIdx = 1
        if ($Index -eq $NumSets) { $deltaIdx = [int](Read-Ue -Reader $Reader) + 1 }
        [void](Read-Bit -Reader $Reader)   # delta_rps_sign
        [void](Read-Ue -Reader $Reader)    # abs_delta_rps_minus1

        $refIdx = $Index - $deltaIdx
        if ($refIdx -lt 0 -or $refIdx -ge $NumDeltaPocs.Count) {
            throw (New-ParseError -Stage 'sps' -Message "short term ref pic set $Index refers to set $refIdx, which does not exist")
        }
        $refCount = [int]$NumDeltaPocs[$refIdx]
        $derived = 0
        for ($j = 0; $j -le $refCount; $j++) {
            $used = Read-Bit -Reader $Reader
            $useDelta = 1
            if ($used -ne 1) { $useDelta = Read-Bit -Reader $Reader }
            if ($used -eq 1 -or $useDelta -eq 1) { $derived++ }
        }
        return $derived
    }

    $neg = [int](Read-Ue -Reader $Reader)
    $pos = [int](Read-Ue -Reader $Reader)
    if ($neg -lt 0 -or $pos -lt 0 -or $neg -gt 65535 -or $pos -gt 65535) {
        throw (New-ParseError -Stage 'sps' -Message "short term ref pic set $Index declares $neg negative and $pos positive pictures")
    }
    for ($i = 0; $i -lt $neg; $i++) { [void](Read-Ue -Reader $Reader); [void](Read-Bit -Reader $Reader) }
    for ($i = 0; $i -lt $pos; $i++) { [void](Read-Ue -Reader $Reader); [void](Read-Bit -Reader $Reader) }
    return ($neg + $pos)
}

function Parse-SpsHevc {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Nal
    )

    return Tag-Error -Stage 'sps' -Body {
        if ($Nal.Length -lt 5) {
            throw (New-ParseError -Stage 'sps' -Message "SPS is $($Nal.Length) bytes, too short")
        }

        # The H.265 NAL header is two bytes, not one, and the type sits in bits
        # 1 to 6 of the first byte rather than the low five bits.
        $nalType = ([int]$Nal[0] -shr 1) -band 0x3F
        if ($nalType -ne 33) {
            throw (New-ParseError -Stage 'sps' -Message "expected NAL type 33 (SPS), found $nalType")
        }

        $rbsp = Remove-EmulationPrevention -Bytes $Nal[2..($Nal.Length - 1)]
        $r = New-BitReader -Bytes $rbsp

        [void](Read-Bits -Reader $r -Count 4)                # sps_video_parameter_set_id
        $maxSubMinus1 = [int](Read-Bits -Reader $r -Count 3)
        [void](Read-Bit -Reader $r)                          # sps_temporal_id_nesting_flag

        $ptl = Skip-ProfileTierLevel -Reader $r -MaxSubLayersMinus1 $maxSubMinus1

        [void](Read-Ue -Reader $r)                           # sps_seq_parameter_set_id
        $chromaFormat = [int](Read-Ue -Reader $r)
        if ($chromaFormat -eq 3) { [void](Read-Bit -Reader $r) }

        $width  = [int](Read-Ue -Reader $r)
        $height = [int](Read-Ue -Reader $r)

        if ((Read-Bit -Reader $r) -eq 1) {
            $cl = [int](Read-Ue -Reader $r); $cr = [int](Read-Ue -Reader $r)
            $ct = [int](Read-Ue -Reader $r); $cb = [int](Read-Ue -Reader $r)
            $subW = $(if ($chromaFormat -eq 1 -or $chromaFormat -eq 2) { 2 } else { 1 })
            $subH = $(if ($chromaFormat -eq 1) { 2 } else { 1 })
            $width  = $width  - ($subW * ($cl + $cr))
            $height = $height - ($subH * ($ct + $cb))
        }

        $bitDepthLuma   = [int](Read-Ue -Reader $r) + 8
        $bitDepthChroma = [int](Read-Ue -Reader $r) + 8
        $log2MaxPocLsb  = [int](Read-Ue -Reader $r) + 4

        $subLayerOrdering = Read-Bit -Reader $r
        $start = $(if ($subLayerOrdering -eq 1) { 0 } else { $maxSubMinus1 })
        for ($i = $start; $i -le $maxSubMinus1; $i++) {
            [void](Read-Ue -Reader $r); [void](Read-Ue -Reader $r); [void](Read-Ue -Reader $r)
        }

        [void](Read-Ue -Reader $r)   # log2_min_luma_coding_block_size_minus3
        [void](Read-Ue -Reader $r)   # log2_diff_max_min_luma_coding_block_size
        [void](Read-Ue -Reader $r)   # log2_min_luma_transform_block_size_minus2
        [void](Read-Ue -Reader $r)   # log2_diff_max_min_luma_transform_block_size
        [void](Read-Ue -Reader $r)   # max_transform_hierarchy_depth_inter
        [void](Read-Ue -Reader $r)   # max_transform_hierarchy_depth_intra

        if ((Read-Bit -Reader $r) -eq 1) {                   # scaling_list_enabled_flag
            if ((Read-Bit -Reader $r) -eq 1) {               # sps_scaling_list_data_present_flag
                for ($sizeId = 0; $sizeId -lt 4; $sizeId++) {
                    $matrixCount = $(if ($sizeId -eq 3) { 2 } else { 6 })
                    for ($matrixId = 0; $matrixId -lt $matrixCount; $matrixId++) {
                        if ((Read-Bit -Reader $r) -eq 0) {
                            [void](Read-Ue -Reader $r)       # scaling_list_pred_matrix_id_delta
                        } else {
                            $coefNum = [Math]::Min(64, (1 -shl (4 + ($sizeId -shl 1))))
                            if ($sizeId -gt 1) { [void](Read-Se -Reader $r) }
                            for ($k = 0; $k -lt $coefNum; $k++) { [void](Read-Se -Reader $r) }
                        }
                    }
                }
            }
        }

        [void](Read-Bit -Reader $r)  # amp_enabled_flag
        [void](Read-Bit -Reader $r)  # sample_adaptive_offset_enabled_flag

        if ((Read-Bit -Reader $r) -eq 1) {                   # pcm_enabled_flag
            Skip-Bits -Reader $r -Count 8
            [void](Read-Ue -Reader $r)
            [void](Read-Ue -Reader $r)
            [void](Read-Bit -Reader $r)
        }

        $numSets = [int](Read-Ue -Reader $r)
        if ($numSets -lt 0 -or $numSets -gt 64) {
            throw (New-ParseError -Stage 'sps' -Message "num_short_term_ref_pic_sets of $numSets is out of range")
        }
        $deltas = New-Object 'System.Collections.Generic.List[int]'
        for ($i = 0; $i -lt $numSets; $i++) {
            $n = Skip-ShortTermRefPicSet -Reader $r -Index $i -NumSets $numSets -NumDeltaPocs $deltas
            [void]$deltas.Add([int]$n)
        }

        if ((Read-Bit -Reader $r) -eq 1) {                   # long_term_ref_pics_present_flag
            $numLt = [int](Read-Ue -Reader $r)
            if ($numLt -lt 0 -or $numLt -gt 64) {
                throw (New-ParseError -Stage 'sps' -Message "num_long_term_ref_pics_sps of $numLt is out of range")
            }
            for ($i = 0; $i -lt $numLt; $i++) {
                Skip-Bits -Reader $r -Count $log2MaxPocLsb
                [void](Read-Bit -Reader $r)
            }
        }

        [void](Read-Bit -Reader $r)  # sps_temporal_mvp_enabled_flag
        [void](Read-Bit -Reader $r)  # strong_intra_smoothing_enabled_flag

        $vui = New-AbsentVui
        if ((Read-Bit -Reader $r) -eq 1) {
            $vui = Read-VuiVideoSignalType -Reader $r
        }

        return [pscustomobject]@{
            Codec          = 'H.265'
            ProfileIdc     = $null
            LevelIdc       = [int]$ptl.LevelIdc
            ConstraintFlags = 0
            ChromaFormat   = $chromaFormat
            BitDepthLuma   = $bitDepthLuma
            BitDepthChroma = $bitDepthChroma
            Width          = $width
            Height         = $height
            Vui            = $vui
        }
    }
}

# ---------------------------------------------------------------------------
# Digging the parameter sets out of the sample entry.
# ---------------------------------------------------------------------------

function Get-SpsFromAvcC {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $Box
    )

    if ($Box.BodySize -lt 7) {
        throw (New-ParseError -Stage 'avcC' -Message "avcC box holds only $($Box.BodySize) bytes")
    }
    $o = $Box.BodyOffset
    $version = $Bytes[$o]
    if ($version -ne 1) {
        throw (New-ParseError -Stage 'avcC' -Message "avcC configuration version $version is not 1")
    }
    $count = [int]$Bytes[$o + 5] -band 0x1F
    if ($count -eq 0) {
        throw (New-ParseError -Stage 'avcC' -Message "avcC declares no sequence parameter sets")
    }

    $p = $o + 6
    for ($i = 0; $i -lt $count; $i++) {
        if ($p + 2 -gt $Box.End) {
            throw (New-ParseError -Stage 'avcC' -Message "SPS length field $i runs past the end of the avcC box")
        }
        $len = Read-UInt16BE -Bytes $Bytes -Offset $p
        $p += 2
        if ($len -eq 0) {
            throw (New-ParseError -Stage 'avcC' -Message "SPS $i has zero length")
        }
        if ($p + $len -gt $Box.End) {
            throw (New-ParseError -Stage 'avcC' -Message "SPS $i claims $len bytes but only $($Box.End - $p) remain")
        }
        # The first parameter set is the one the decoder starts with, and any
        # later ones describe alternative sequences that a recording does not
        # use. Taking the first is correct and taking the last is not.
        return @($Bytes[$p..($p + $len - 1)])
    }
    throw (New-ParseError -Stage 'avcC' -Message "no usable sequence parameter set")
}

function Get-SpsFromHvcC {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $Box
    )

    if ($Box.BodySize -lt 23) {
        throw (New-ParseError -Stage 'hvcC' -Message "hvcC box holds only $($Box.BodySize) bytes")
    }
    $o = $Box.BodyOffset
    $version = $Bytes[$o]
    if ($version -ne 1) {
        throw (New-ParseError -Stage 'hvcC' -Message "hvcC configuration version $version is not 1")
    }

    $numArrays = [int]$Bytes[$o + 22]
    $p = $o + 23
    for ($a = 0; $a -lt $numArrays; $a++) {
        if ($p + 3 -gt $Box.End) {
            throw (New-ParseError -Stage 'hvcC' -Message "NAL array $a header runs past the end of the hvcC box")
        }
        $nalType = [int]$Bytes[$p] -band 0x3F
        $numNalus = Read-UInt16BE -Bytes $Bytes -Offset ($p + 1)
        $p += 3
        for ($n = 0; $n -lt $numNalus; $n++) {
            if ($p + 2 -gt $Box.End) {
                throw (New-ParseError -Stage 'hvcC' -Message "NAL length field runs past the end of the hvcC box")
            }
            $len = Read-UInt16BE -Bytes $Bytes -Offset $p
            $p += 2
            if ($len -eq 0) {
                throw (New-ParseError -Stage 'hvcC' -Message "NAL unit in array $a has zero length")
            }
            if ($p + $len -gt $Box.End) {
                throw (New-ParseError -Stage 'hvcC' -Message "NAL unit claims $len bytes but only $($Box.End - $p) remain")
            }
            if ($nalType -eq 33) {
                return @($Bytes[$p..($p + $len - 1)])
            }
            $p += $len
        }
    }
    throw (New-ParseError -Stage 'hvcC' -Message "hvcC carries no sequence parameter set")
}

$script:AvcFormats  = @('avc1', 'avc2', 'avc3', 'avc4', 'dva1', 'dvav')
$script:HevcFormats = @('hvc1', 'hev1', 'dvh1', 'dvhe')

function Get-BitstreamInfo {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $Entry
    )

    $children = Get-ChildBoxes -Bytes $Bytes -Offset $Entry.ChildOffset -Limit $Entry.ChildLimit

    if ($script:AvcFormats -contains $Entry.Format) {
        foreach ($c in $children) {
            if ($c.Type -ceq 'avcC') {
                $nal = Get-SpsFromAvcC -Bytes $Bytes -Box $c
                return Parse-SpsAvc -Nal $nal
            }
        }
        throw (New-ParseError -Stage 'avcC' -Message "'$($Entry.Format)' sample entry has no avcC configuration box")
    }

    if ($script:HevcFormats -contains $Entry.Format) {
        foreach ($c in $children) {
            if ($c.Type -ceq 'hvcC') {
                $nal = Get-SpsFromHvcC -Bytes $Bytes -Box $c
                return Parse-SpsHevc -Nal $nal
            }
        }
        throw (New-ParseError -Stage 'hvcC' -Message "'$($Entry.Format)' sample entry has no hvcC configuration box")
    }

    # AV1, VP9, ProRes and friends carry their colour information in formats
    # this tool does not read. Saying so is more useful than guessing.
    return $null
}

# ---------------------------------------------------------------------------
# Working out what is actually wrong.
#
# Each finding names the symptom in the words someone would use to complain
# about it, then the setting that caused it. A code that no player disagrees
# about is not a finding, however unusual it looks.
# ---------------------------------------------------------------------------

function New-Finding {
    param(
        [Parameter(Mandatory = $true)][string] $Code,
        [Parameter(Mandatory = $true)][ValidateSet('problem', 'warning', 'note')][string] $Severity,
        [Parameter(Mandatory = $true)][string] $Title,
        [Parameter(Mandatory = $true)][string] $Detail,
        [string] $Fix = ''
    )
    return [pscustomobject]@{
        Code     = $Code
        Severity = $Severity
        Title    = $Title
        Detail   = $Detail
        Fix      = $Fix
    }
}

function Get-ExpectedMatrixForHeight {
    param([Parameter(Mandatory = $true)][int] $Height)
    # This is the rule every player falls back on when the file says nothing:
    # standard definition is BT.601, anything larger is BT.709. It is a guess,
    # and it is the guess that makes untagged HD footage look wrong when an
    # editor assumes otherwise.
    if ($Height -le 0)   { return 0 }
    if ($Height -le 576) { return 6 }
    return 1
}

function Get-RangeWord {
    param($FullRange)
    if ($null -eq $FullRange) { return 'unknown' }
    if ($FullRange) { return 'full (0-255)' }
    return 'limited (16-235)'
}

function Get-ColourFindings {
    param(
        [Parameter(Mandatory = $true)] $Track
    )

    $f = New-Object System.Collections.ArrayList

    $colr = $Track.Colr
    $vui  = $null
    if ($null -ne $Track.Bitstream -and $null -ne $Track.Bitstream.Vui) { $vui = $Track.Bitstream.Vui }

    $vuiHasColour = ($null -ne $vui -and $vui.Present -and $null -ne $vui.Primaries)
    $colrHasCodes = ($null -ne $colr -and $null -ne $colr.Primaries)

    # --- conflicts between the two places the same fact is stored -----------

    if ($colrHasCodes -and $vuiHasColour) {
        if ($colr.Matrix -ne $vui.Matrix) {
            [void]$f.Add((New-Finding -Code 'MATRIX_CONFLICT' -Severity 'problem' `
                -Title 'the container and the video stream disagree about the colour matrix' `
                -Detail ("The colr box says " + (Get-CodeName -Table $script:MatrixNames -Code $colr.Matrix) +
                         " and the bitstream says " + (Get-CodeName -Table $script:MatrixNames -Code $vui.Matrix) +
                         ". Players that trust the container and players that trust the stream will show different colours for the same file.") `
                -Fix 'Remux with a tool that writes both, or re-encode so only one answer exists.'))
        }
        if ($colr.Primaries -ne $vui.Primaries) {
            [void]$f.Add((New-Finding -Code 'PRIMARIES_CONFLICT' -Severity 'problem' `
                -Title 'the container and the video stream disagree about the colour primaries' `
                -Detail ("The colr box says " + (Get-CodeName -Table $script:PrimariesNames -Code $colr.Primaries) +
                         " and the bitstream says " + (Get-CodeName -Table $script:PrimariesNames -Code $vui.Primaries) + ".") `
                -Fix 'Remux or re-encode so the two agree.'))
        }
        if ($colr.Transfer -ne $vui.Transfer) {
            [void]$f.Add((New-Finding -Code 'TRANSFER_CONFLICT' -Severity 'problem' `
                -Title 'the container and the video stream disagree about the transfer curve' `
                -Detail ("The colr box says " + (Get-CodeName -Table $script:TransferNames -Code $colr.Transfer) +
                         " and the bitstream says " + (Get-CodeName -Table $script:TransferNames -Code $vui.Transfer) +
                         ". This is the difference between a picture that looks right and one that looks flat or crushed.") `
                -Fix 'Remux or re-encode so the two agree.'))
        }
    }

    if ($null -ne $colr -and $null -ne $colr.FullRange -and $null -ne $vui -and $vui.Present -and $null -ne $vui.FullRange) {
        if ($colr.FullRange -ne $vui.FullRange) {
            [void]$f.Add((New-Finding -Code 'RANGE_CONFLICT' -Severity 'problem' `
                -Title 'the container and the video stream disagree about the colour range' `
                -Detail ("The colr box says " + (Get-RangeWord $colr.FullRange) + " and the bitstream says " +
                         (Get-RangeWord $vui.FullRange) +
                         ". One of your players will show washed out blacks and the other will crush them, from the same file.") `
                -Fix 'Pick one. In OBS, Settings > Advanced > Color Range, then re-record; remuxing does not always rewrite both.'))
        }
    }

    # --- the file simply does not say --------------------------------------

    $effMatrix = $null
    if ($colrHasCodes) { $effMatrix = $colr.Matrix } elseif ($vuiHasColour) { $effMatrix = $vui.Matrix }

    if (-not $colrHasCodes -and -not $vuiHasColour) {
        $guess = Get-ExpectedMatrixForHeight -Height $Track.Height
        [void]$f.Add((New-Finding -Code 'NO_TAGS' -Severity 'problem' `
            -Title 'the file carries no colour tags at all' `
            -Detail ("Neither the container nor the video stream says which colour space this is, so every player guesses. " +
                     "At " + $Track.Height + " lines most will assume " + (Get-CodeName -Table $script:MatrixNames -Code $guess) +
                     ", and any that assume otherwise will shift your skin tones.") `
            -Fix 'Re-encode with explicit colour tags, or remux with a tool that writes a colr box.'))
    } elseif ($null -ne $effMatrix -and $effMatrix -eq 2) {
        [void]$f.Add((New-Finding -Code 'MATRIX_UNSPECIFIED' -Severity 'warning' `
            -Title 'the colour matrix is tagged "unspecified"' `
            -Detail ("Code 2 means the file declines to say. It is not the same as a missing tag, but it has the same effect: " +
                     "the player guesses, usually from the frame height.") `
            -Fix 'Re-encode with an explicit matrix.'))
    }

    if (-not $colrHasCodes -and $vuiHasColour) {
        [void]$f.Add((New-Finding -Code 'NO_COLR_BOX' -Severity 'warning' `
            -Title 'the colour tags are in the video stream but not in the container' `
            -Detail ('The bitstream carries a full colour description, but there is no colr box in the sample entry. ' +
                     'Editors that read only the container - which is most of them, because it is cheap - will guess instead.') `
            -Fix 'Remux so a colr box is written alongside the stream tags.'))
    }

    if ($colrHasCodes -and -not $vuiHasColour) {
        [void]$f.Add((New-Finding -Code 'NO_VUI' -Severity 'note' `
            -Title 'the colour tags are in the container but not in the video stream' `
            -Detail ('The colr box carries a colour description but the bitstream does not. Anything that reads the raw ' +
                     'elementary stream, after the container has been thrown away, has nothing to go on.') `
            -Fix 'Harmless for normal playback; matters if the stream is ever extracted without the container.'))
    }

    return @($f.ToArray())
}

function Get-ConsistencyFindings {
    param(
        [Parameter(Mandatory = $true)] $Track
    )

    $f = New-Object System.Collections.ArrayList

    $colr = $Track.Colr
    $vui  = $null
    if ($null -ne $Track.Bitstream -and $null -ne $Track.Bitstream.Vui) { $vui = $Track.Bitstream.Vui }

    # The effective value is what a well behaved player uses: the container
    # wins where it speaks, because that is what the specification says, and
    # it is also what the common players do.
    $matrix = $null; $primaries = $null; $transfer = $null; $fullRange = $null
    if ($null -ne $vui -and $vui.Present) {
        $matrix = $vui.Matrix; $primaries = $vui.Primaries; $transfer = $vui.Transfer
        $fullRange = $vui.FullRange
    }
    if ($null -ne $colr -and $null -ne $colr.Primaries) {
        $matrix = $colr.Matrix; $primaries = $colr.Primaries; $transfer = $colr.Transfer
    }
    if ($null -ne $colr -and $null -ne $colr.FullRange) { $fullRange = $colr.FullRange }

    $height = [int]$Track.Height

    if ($null -ne $matrix -and $matrix -ne 2 -and $height -gt 0) {
        $expected = Get-ExpectedMatrixForHeight -Height $height
        if (($matrix -eq 5 -or $matrix -eq 6) -and $expected -eq 1) {
            [void]$f.Add((New-Finding -Code 'SD_MATRIX_ON_HD' -Severity 'problem' `
                -Title 'high definition video tagged with the standard definition colour matrix' `
                -Detail ("This is " + $Track.Width + "x" + $height + " but the matrix is " +
                         (Get-CodeName -Table $script:MatrixNames -Code $matrix) +
                         ", which belongs to standard definition. Players that honour the tag will render greens and skin tones " +
                         "visibly off; players that ignore it and assume BT.709 will look right. That is why it looks fine in one " +
                         "app and wrong in another.") `
                -Fix 'Set the encoder to BT.709 and re-record, or re-tag the file without re-encoding.'))
        } elseif ($matrix -eq 1 -and $expected -eq 6) {
            [void]$f.Add((New-Finding -Code 'HD_MATRIX_ON_SD' -Severity 'warning' `
                -Title 'standard definition video tagged with the high definition colour matrix' `
                -Detail ("This is " + $Track.Width + "x" + $height + " tagged BT.709. It may well be correct, but the fallback " +
                         "guess at this size is BT.601, so anything that ignores the tag will shift the colours.") `
                -Fix 'Leave it if the footage really was shot as BT.709; otherwise re-tag.'))
        }
    }

    if ($null -ne $matrix -and $matrix -eq 0) {
        [void]$f.Add((New-Finding -Code 'MATRIX_IDENTITY' -Severity 'note' `
            -Title 'the video is tagged as RGB rather than YUV' `
            -Detail ('Matrix code 0 means no colour conversion is applied at all. It is correct for screen capture encoded ' +
                     'in RGB, and wrong for anything that came out of a camera.') `
            -Fix ''))
    }

    if ($null -ne $fullRange -and $fullRange -eq $true) {
        $codec = 'the video'
        if ($null -ne $Track.Bitstream) { $codec = $Track.Bitstream.Codec }
        [void]$f.Add((New-Finding -Code 'FULL_RANGE' -Severity 'warning' `
            -Title 'the video is tagged full range (0-255)' `
            -Detail ("Full range keeps a little more shadow detail, and it is the setting most likely to make a recording " +
                     "look wrong somewhere else. Plenty of editors and hardware players clamp " + $codec +
                     " to 16-235 regardless of the tag, which crushes the blacks and clips the highlights.") `
            -Fix 'If a clip looks contrasty in an editor but fine in a browser, this is why. OBS: Settings > Advanced > Color Range > Limited.'))
    }

    if ($null -ne $colr -and $colr.Kind -ceq 'nclc') {
        [void]$f.Add((New-Finding -Code 'NCLC_NO_RANGE' -Severity 'note' `
            -Title 'the colour box is the older QuickTime form, which cannot state the range' `
            -Detail ('An nclc box carries primaries, transfer and matrix but has no range flag, so the range is genuinely ' +
                     'unstated here rather than limited. Players fall back to limited, which is usually but not always right.') `
            -Fix 'Remux to a file that writes an nclx box if the range matters.'))
    }

    if ($null -ne $colr -and ($colr.Kind -ceq 'rICC' -or $colr.Kind -ceq 'prof')) {
        [void]$f.Add((New-Finding -Code 'ICC_PROFILE' -Severity 'note' `
            -Title 'the colour box holds an ICC profile instead of code points' `
            -Detail ("The colr box carries a " + $colr.IccBytes + " byte ICC profile. That is legal and precise, and most " +
                     "video players ignore it completely.") `
            -Fix ''))
    }

    # --- high dynamic range ------------------------------------------------

    if ($null -ne $transfer -and (Test-IsHdrTransfer -Transfer $transfer)) {
        if ($null -ne $primaries -and $primaries -ne 9) {
            [void]$f.Add((New-Finding -Code 'HDR_NARROW_PRIMARIES' -Severity 'problem' `
                -Title 'an HDR transfer curve on standard gamut primaries' `
                -Detail ("The transfer is " + (Get-CodeName -Table $script:TransferNames -Code $transfer) +
                         " but the primaries are " + (Get-CodeName -Table $script:PrimariesNames -Code $primaries) +
                         ". HDR content is normally BT.2020; this combination will tone map badly.") `
                -Fix 'Re-tag with BT.2020 primaries, or turn HDR capture off if you did not mean to record it.'))
        }
        if (-not $Track.HasMasteringDisplay) {
            [void]$f.Add((New-Finding -Code 'HDR_NO_MASTERING' -Severity 'warning' `
                -Title 'HDR video with no mastering display metadata' `
                -Detail ('There is no mdcv or clli box, so nothing tells a tone mapper how bright the content was graded. ' +
                         'Most players fall back to a fixed assumption and the result is usually too dark.') `
                -Fix 'Keep the original capture metadata, or supply mastering display values when you export.'))
        }
    } elseif ($null -ne $primaries -and $primaries -eq 9 -and $null -ne $transfer -and $transfer -eq 1) {
        [void]$f.Add((New-Finding -Code 'WIDE_GAMUT_SDR' -Severity 'warning' `
            -Title 'BT.2020 primaries with an ordinary BT.709 curve' `
            -Detail ('Wide gamut primaries with a standard dynamic range transfer is an unusual pairing. It happens when a ' +
                     'capture card is set to HDR and the encoder is not, and it makes everything look desaturated.') `
            -Fix 'Match the capture and encode settings; either both HDR or neither.'))
    }

    if ($null -ne $Track.HasMasteringDisplay -and $Track.HasMasteringDisplay -and
        ($null -eq $transfer -or -not (Test-IsHdrTransfer -Transfer $transfer))) {
        [void]$f.Add((New-Finding -Code 'MASTERING_WITHOUT_HDR' -Severity 'note' `
            -Title 'mastering display metadata on a file that is not tagged HDR' `
            -Detail ('There is HDR mastering metadata but the transfer curve is not PQ or HLG, so the metadata describes ' +
                     'something the file does not claim to be.') `
            -Fix ''))
    }

    # --- shape -------------------------------------------------------------

    if ($null -ne $Track.Pasp) {
        if ($Track.Pasp.HSpacing -le 0 -or $Track.Pasp.VSpacing -le 0) {
            [void]$f.Add((New-Finding -Code 'PASP_INVALID' -Severity 'problem' `
                -Title 'the pixel aspect ratio box holds a zero' `
                -Detail ("pasp says " + $Track.Pasp.HSpacing + ":" + $Track.Pasp.VSpacing +
                         ". A zero spacing is meaningless and different players round it differently.") `
                -Fix 'Remux to drop or correct the pasp box.'))
        } elseif ($Track.Pasp.HSpacing -ne $Track.Pasp.VSpacing) {
            [void]$f.Add((New-Finding -Code 'PASP_NON_SQUARE' -Severity 'warning' `
                -Title 'the pixels are not square' `
                -Detail ("pasp says " + $Track.Pasp.HSpacing + ":" + $Track.Pasp.VSpacing +
                         ", so the picture is meant to be stretched on playback. Tools that ignore pasp will show it at the " +
                         "wrong shape, and tools that honour it will disagree with them.") `
                -Fix 'Fine for DVD-era footage; on a screen recording it usually means the capture was set up wrong.'))
        }
    }

    if ($null -ne $Track.Bitstream -and $null -ne $Track.Bitstream.Width -and $Track.Width -gt 0) {
        if ($Track.Bitstream.Width -ne $Track.Width -or $Track.Bitstream.Height -ne $Track.Height) {
            [void]$f.Add((New-Finding -Code 'SIZE_CONFLICT' -Severity 'warning' `
                -Title 'the container and the video stream disagree about the frame size' `
                -Detail ("The sample entry says " + $Track.Width + "x" + $Track.Height + " and the bitstream says " +
                         $Track.Bitstream.Width + "x" + $Track.Bitstream.Height +
                         ". The decoder obeys the bitstream; anything that reads metadata only will report the other number.") `
                -Fix 'Usually harmless, but it will confuse any tool that trusts the container.'))
        }
    }

    return @($f.ToArray())
}

# ---------------------------------------------------------------------------
# Putting one track together.
# ---------------------------------------------------------------------------

function Get-TrackAnalysis {
    param(
        [Parameter(Mandatory = $true)][byte[]] $Bytes,
        [Parameter(Mandatory = $true)] $Entry
    )

    $children = Get-ChildBoxes -Bytes $Bytes -Offset $Entry.ChildOffset -Limit $Entry.ChildLimit

    $colr = $null
    $pasp = $null
    $hasMdcv = $false
    $hasClli = $false
    $childTypes = New-Object System.Collections.ArrayList

    foreach ($c in $children) {
        [void]$childTypes.Add($c.Type)
        if ($c.Type -ceq 'colr' -and $null -eq $colr) {
            $colr = Parse-Colr -Bytes $Bytes -Box $c
        } elseif ($c.Type -ceq 'pasp' -and $null -eq $pasp) {
            $pasp = Parse-Pasp -Bytes $Bytes -Box $c
        } elseif ($c.Type -ceq 'mdcv' -or $c.Type -ceq 'SmDm') {
            $hasMdcv = $true
        } elseif ($c.Type -ceq 'clli' -or $c.Type -ceq 'CoLL') {
            $hasClli = $true
        }
    }

    $bitstream = $null
    $bitstreamError = $null
    try {
        $bitstream = Get-BitstreamInfo -Bytes $Bytes -Entry $Entry
    } catch {
        $m = $_.Exception.Message
        if ($m -like 'colorcheck/*') {
            # A parameter set this tool cannot read is a fact about the file,
            # not a reason to abandon the container tags, which are often the
            # only ones an editor looks at anyway.
            $bitstreamError = $m
        } else {
            throw
        }
    }

    $track = [pscustomobject]@{
        Format              = $Entry.Format
        TrackId             = $Entry.TrackId
        EntryIndex          = $Entry.EntryIndex
        Width               = [int]$Entry.Width
        Height              = [int]$Entry.Height
        Depth               = [int]$Entry.Depth
        Colr                = $colr
        Pasp                = $pasp
        HasMasteringDisplay = ($hasMdcv -or $hasClli)
        HasMdcv             = $hasMdcv
        HasClli             = $hasClli
        Bitstream           = $bitstream
        BitstreamError      = $bitstreamError
        ChildBoxes          = @($childTypes.ToArray())
        Findings            = @()
    }

    $all = New-Object System.Collections.ArrayList
    foreach ($x in (Get-ColourFindings -Track $track)) { [void]$all.Add($x) }
    foreach ($x in (Get-ConsistencyFindings -Track $track)) { [void]$all.Add($x) }
    $track.Findings = @($all.ToArray())

    return $track
}

function Get-EffectiveTags {
    param([Parameter(Mandatory = $true)] $Track)

    $matrix = $null; $primaries = $null; $transfer = $null; $fullRange = $null
    $source = 'nothing'

    $vui = $null
    if ($null -ne $Track.Bitstream -and $null -ne $Track.Bitstream.Vui) { $vui = $Track.Bitstream.Vui }

    if ($null -ne $vui -and $vui.Present) {
        $fullRange = $vui.FullRange
        $source = 'bitstream'
        if ($null -ne $vui.Primaries) {
            $matrix = $vui.Matrix; $primaries = $vui.Primaries; $transfer = $vui.Transfer
        }
    }
    if ($null -ne $Track.Colr) {
        if ($null -ne $Track.Colr.Primaries) {
            $matrix = $Track.Colr.Matrix; $primaries = $Track.Colr.Primaries; $transfer = $Track.Colr.Transfer
            $source = $(if ($source -eq 'bitstream') { 'both' } else { 'container' })
        }
        if ($null -ne $Track.Colr.FullRange) {
            $fullRange = $Track.Colr.FullRange
            if ($source -eq 'nothing') { $source = 'container' }
        }
    }

    return [pscustomobject]@{
        Primaries     = $primaries
        Transfer      = $transfer
        Matrix        = $matrix
        FullRange     = $fullRange
        Source        = $source
        PrimariesName = $(if ($null -eq $primaries) { 'not stated' } else { Get-CodeName -Table $script:PrimariesNames -Code $primaries })
        TransferName  = $(if ($null -eq $transfer)  { 'not stated' } else { Get-CodeName -Table $script:TransferNames  -Code $transfer })
        MatrixName    = $(if ($null -eq $matrix)    { 'not stated' } else { Get-CodeName -Table $script:MatrixNames    -Code $matrix })
        RangeName     = (Get-RangeWord $fullRange)
        IsHdr         = ($null -ne $transfer -and (Test-IsHdrTransfer -Transfer $transfer))
    }
}

function Get-Verdict {
    param([Parameter(Mandatory = $true)] $Tracks)

    $problems = 0
    $warnings = 0
    $notes = 0
    foreach ($t in $Tracks) {
        foreach ($f in $t.Findings) {
            if ($f.Severity -eq 'problem') { $problems++ }
            elseif ($f.Severity -eq 'warning') { $warnings++ }
            else { $notes++ }
        }
    }

    $label = 'consistent'
    if ($problems -gt 0) { $label = 'conflict' }
    elseif ($warnings -gt 0) { $label = 'check this' }

    return [pscustomobject]@{
        Label    = $label
        Problems = $problems
        Warnings = $warnings
        Notes    = $notes
    }
}

function Invoke-ColorCheck {
    param(
        [Parameter(Mandatory = $true)][string] $LiteralPath
    )

    $full = $LiteralPath
    try { $full = [System.IO.Path]::GetFullPath($LiteralPath) } catch { }

    $fi = Read-FileBytes -LiteralPath $full
    $stream = $null
    try {
        $stream = New-Object System.IO.FileStream($full, [System.IO.FileMode]::Open,
                      [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $moov = Get-MoovBody -Stream $stream
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }

    $entries = Get-VideoSampleEntries -Bytes $moov.Bytes
    if (@($entries).Count -eq 0) {
        throw (New-ParseError -Stage 'container' -Message "no video track; this file has nothing to check")
    }

    $tracks = New-Object System.Collections.ArrayList
    foreach ($e in $entries) {
        [void]$tracks.Add((Get-TrackAnalysis -Bytes $moov.Bytes -Entry $e))
    }
    $trackArray = @($tracks.ToArray())

    return [pscustomobject]@{
        Path      = $full
        Name      = (Split-Path -Leaf $full)
        SizeBytes = [long]$fi.Length
        Brand     = $moov.Brand
        Tracks    = $trackArray
        Verdict   = (Get-Verdict -Tracks $trackArray)
    }
}

# ---------------------------------------------------------------------------
# Output.
# ---------------------------------------------------------------------------

function Write-Plain {
    param([string] $Text = '')
    Write-Output $Text
}

function Write-Coloured {
    param(
        [string] $Text = '',
        [string] $Colour = ''
    )
    if ($script:NoColorOutput -or $Colour -eq '') {
        Write-Output $Text
        return
    }
    # Host colour is written straight to the console so a redirect or a pipe
    # still receives clean text. Anything that must be capturable goes through
    # Write-Output instead.
    Write-Host $Text -ForegroundColor $Colour
}

function Get-SeverityColour {
    param([string] $Severity)
    switch ($Severity) {
        'problem' { return 'Red' }
        'warning' { return 'Yellow' }
        default   { return 'DarkGray' }
    }
}

function Get-SeverityMark {
    param([string] $Severity)
    switch ($Severity) {
        'problem' { return '[!]' }
        'warning' { return '[?]' }
        default   { return '[i]' }
    }
}

function Format-Size {
    param([long] $Bytes)
    if ($Bytes -lt 1024) { return "$Bytes B" }
    $units = @('KB', 'MB', 'GB', 'TB')
    $v = [double]$Bytes
    $i = -1
    while ($v -ge 1024 -and $i -lt ($units.Count - 1)) {
        $v = $v / 1024
        $i++
    }
    return ('{0:0.#} {1}' -f $v, $units[$i])
}

function Write-Report {
    param(
        [Parameter(Mandatory = $true)] $Report,
        [switch] $Explain
    )

    Write-Plain ''
    Write-Plain ($Report.Name + '   ' + (Format-Size -Bytes $Report.SizeBytes) +
                 $(if ($null -eq $Report.Brand) { '' } else { '   brand ' + $Report.Brand }))
    Write-Plain ('-' * 78)

    foreach ($t in $Report.Tracks) {
        $eff = Get-EffectiveTags -Track $t

        $codec = $t.Format
        if ($null -ne $t.Bitstream) { $codec = $t.Format + ' (' + $t.Bitstream.Codec + ')' }

        Write-Plain ''
        Write-Plain ('  track ' + $t.TrackId + '   ' + $codec + '   ' + $t.Width + 'x' + $t.Height)

        $depth = ''
        if ($null -ne $t.Bitstream) {
            $depth = '   ' + $t.Bitstream.BitDepthLuma + ' bit'
            if ($t.Bitstream.ChromaFormat -eq 0) { $depth += ' monochrome' }
            elseif ($t.Bitstream.ChromaFormat -eq 1) { $depth += ' 4:2:0' }
            elseif ($t.Bitstream.ChromaFormat -eq 2) { $depth += ' 4:2:2' }
            elseif ($t.Bitstream.ChromaFormat -eq 3) { $depth += ' 4:4:4' }
        }

        Write-Plain ('    primaries   ' + $eff.PrimariesName)
        Write-Plain ('    transfer    ' + $eff.TransferName + $(if ($eff.IsHdr) { '   [HDR]' } else { '' }))
        Write-Plain ('    matrix      ' + $eff.MatrixName)
        Write-Plain ('    range       ' + $eff.RangeName)
        Write-Plain ('    stated in   ' + $eff.Source + $depth)

        if ($null -ne $t.BitstreamError) {
            Write-Plain ('    note        could not read the bitstream tags: ' + $t.BitstreamError)
        }

        if ($Explain) {
            if ($null -ne $t.Colr) {
                $c = $t.Colr
                if ($null -eq $c.Primaries) {
                    Write-Plain ('    colr box    ' + $c.Kind + ', ' + $c.IccBytes + ' byte profile')
                } else {
                    Write-Plain ('    colr box    ' + $c.Kind + ' p=' + $c.Primaries + ' t=' + $c.Transfer +
                                 ' m=' + $c.Matrix + ' range=' + (Get-RangeWord $c.FullRange))
                }
            } else {
                Write-Plain '    colr box    absent'
            }

            if ($null -ne $t.Bitstream -and $null -ne $t.Bitstream.Vui -and $t.Bitstream.Vui.Present) {
                $v = $t.Bitstream.Vui
                if ($null -eq $v.Primaries) {
                    Write-Plain ('    stream VUI  present, no colour description, range=' + (Get-RangeWord $v.FullRange))
                } else {
                    Write-Plain ('    stream VUI  p=' + $v.Primaries + ' t=' + $v.Transfer + ' m=' + $v.Matrix +
                                 ' range=' + (Get-RangeWord $v.FullRange))
                }
            } else {
                Write-Plain '    stream VUI  absent'
            }

            if ($null -ne $t.Pasp) {
                Write-Plain ('    pasp        ' + $t.Pasp.HSpacing + ':' + $t.Pasp.VSpacing)
            }
            if (@($t.ChildBoxes).Count -gt 0) {
                Write-Plain ('    boxes       ' + (@($t.ChildBoxes) -join ' '))
            }
        }

        if (@($t.Findings).Count -eq 0) {
            Write-Coloured '    nothing to report on this track' 'Green'
        } else {
            foreach ($f in $t.Findings) {
                Write-Plain ''
                Write-Coloured ('    ' + (Get-SeverityMark -Severity $f.Severity) + ' ' + $f.Title) (Get-SeverityColour -Severity $f.Severity)
                foreach ($line in (Split-Paragraph -Text $f.Detail -Width 70)) {
                    Write-Plain ('        ' + $line)
                }
                if ($f.Fix -ne '') {
                    foreach ($line in (Split-Paragraph -Text ('Fix: ' + $f.Fix) -Width 70)) {
                        Write-Plain ('        ' + $line)
                    }
                }
            }
        }
    }

    $v = $Report.Verdict
    Write-Plain ''
    $summary = '  ' + $v.Problems + ' problem'    + $(if ($v.Problems -eq 1) { '' } else { 's' }) +
               ', '  + $v.Warnings + ' warning'   + $(if ($v.Warnings -eq 1) { '' } else { 's' }) +
               ', '  + $v.Notes    + ' note'      + $(if ($v.Notes    -eq 1) { '' } else { 's' })
    $colour = 'Green'
    if ($v.Problems -gt 0) { $colour = 'Red' } elseif ($v.Warnings -gt 0) { $colour = 'Yellow' }
    Write-Coloured $summary $colour
    Write-Plain ''
}

function Split-Paragraph {
    param(
        [Parameter(Mandatory = $true)][string] $Text,
        [Parameter(Mandatory = $true)][int] $Width
    )
    if ($Width -lt 16) { $Width = 16 }
    $words = $Text -split '\s+' | Where-Object { $_ -ne '' }
    $lines = New-Object System.Collections.ArrayList
    $cur = ''
    foreach ($w in $words) {
        if ($cur -eq '') {
            $cur = $w
        } elseif (($cur.Length + 1 + $w.Length) -le $Width) {
            $cur = $cur + ' ' + $w
        } else {
            [void]$lines.Add($cur)
            $cur = $w
        }
    }
    if ($cur -ne '') { [void]$lines.Add($cur) }
    if ($lines.Count -eq 0) { [void]$lines.Add('') }
    return @($lines.ToArray())
}

function ConvertTo-ReportObject {
    param([Parameter(Mandatory = $true)] $Report)

    $tracks = @()
    foreach ($t in $Report.Tracks) {
        $eff = Get-EffectiveTags -Track $t

        $colrObj = $null
        if ($null -ne $t.Colr) {
            $colrObj = [ordered]@{
                kind      = $t.Colr.Kind
                primaries = $t.Colr.Primaries
                transfer  = $t.Colr.Transfer
                matrix    = $t.Colr.Matrix
                fullRange = $t.Colr.FullRange
                iccBytes  = $t.Colr.IccBytes
            }
        }

        $vuiObj = $null
        if ($null -ne $t.Bitstream -and $null -ne $t.Bitstream.Vui) {
            $v = $t.Bitstream.Vui
            $vuiObj = [ordered]@{
                present      = [bool]$v.Present
                blockPresent = [bool]$v.Block
                primaries    = $v.Primaries
                transfer     = $v.Transfer
                matrix       = $v.Matrix
                fullRange    = $v.FullRange
                videoFormat  = $v.VideoFormat
            }
        }

        $bitObj = $null
        if ($null -ne $t.Bitstream) {
            $bitObj = [ordered]@{
                codec          = $t.Bitstream.Codec
                profileIdc     = $t.Bitstream.ProfileIdc
                levelIdc       = $t.Bitstream.LevelIdc
                chromaFormat   = $t.Bitstream.ChromaFormat
                bitDepthLuma   = $t.Bitstream.BitDepthLuma
                bitDepthChroma = $t.Bitstream.BitDepthChroma
                width          = $t.Bitstream.Width
                height         = $t.Bitstream.Height
                vui            = $vuiObj
            }
        }

        $findings = @()
        foreach ($f in $t.Findings) {
            $findings += [ordered]@{
                code     = $f.Code
                severity = $f.Severity
                title    = $f.Title
                detail   = $f.Detail
                fix      = $f.Fix
            }
        }

        $tracks += [ordered]@{
            trackId        = $t.TrackId
            format         = $t.Format
            width          = $t.Width
            height         = $t.Height
            depth          = $t.Depth
            effective      = [ordered]@{
                primaries     = $eff.Primaries
                transfer      = $eff.Transfer
                matrix        = $eff.Matrix
                fullRange     = $eff.FullRange
                primariesName = $eff.PrimariesName
                transferName  = $eff.TransferName
                matrixName    = $eff.MatrixName
                rangeName     = $eff.RangeName
                statedIn      = $eff.Source
                isHdr         = $eff.IsHdr
            }
            colr           = $colrObj
            bitstream      = $bitObj
            bitstreamError = $t.BitstreamError
            pasp           = $(if ($null -eq $t.Pasp) { $null } else { [ordered]@{ hSpacing = $t.Pasp.HSpacing; vSpacing = $t.Pasp.VSpacing } })
            hasMdcv        = $t.HasMdcv
            hasClli        = $t.HasClli
            childBoxes     = @($t.ChildBoxes)
            findings       = $findings
        }
    }

    return [ordered]@{
        tool      = $script:ToolName
        version   = $script:ToolVersion
        path      = $Report.Path
        name      = $Report.Name
        sizeBytes = $Report.SizeBytes
        brand     = $Report.Brand
        verdict   = [ordered]@{
            label    = $Report.Verdict.Label
            problems = $Report.Verdict.Problems
            warnings = $Report.Verdict.Warnings
            notes    = $Report.Verdict.Notes
        }
        tracks    = $tracks
    }
}

function Show-Help {
    Write-Plain ''
    Write-Plain 'colorcheck - why does this recording look washed out?'
    Write-Plain ''
    Write-Plain '  colorcheck <file.mp4>            check one file'
    Write-Plain '  colorcheck <folder>              check every mp4/mov in a folder'
    Write-Plain '  colorcheck <folder> -Recurse     and everything under it'
    Write-Plain ''
    Write-Plain 'Options'
    Write-Plain '  -Explain     also print the raw code points and the boxes they came from'
    Write-Plain '  -Json        machine readable output, one object per file'
    Write-Plain '  -Filter      wildcard applied to file names, e.g. -Filter "replay*"'
    Write-Plain '  -Quiet       only print files that have something wrong'
    Write-Plain '  -NoColor     never colour the output'
    Write-Plain '  -Version     print the version and exit'
    Write-Plain ''
    Write-Plain 'What it reads'
    Write-Plain '  The colr box in the MP4/MOV sample entry, and the video_signal_type'
    Write-Plain '  fields in the H.264 or H.265 sequence parameter set. Those two places'
    Write-Plain '  can disagree, and when they do, different players show different'
    Write-Plain '  colours for the same file.'
    Write-Plain ''
    Write-Plain 'Exit codes'
    Write-Plain '  0  nothing at problem severity'
    Write-Plain '  1  at least one problem'
    Write-Plain '  2  nothing could be read'
    Write-Plain ''
    Write-Plain 'Nothing is written and nothing is uploaded. Files are opened read only'
    Write-Plain 'and shared, so a recording still open in OBS can be checked.'
    Write-Plain ''
}

$script:VideoExtensions = @('.mp4', '.mov', '.m4v', '.m4a', '.3gp', '.3g2', '.mp4v', '.qt')

function Resolve-InputFiles {
    param(
        [Parameter(Mandatory = $true)][string] $InputPath,
        [switch] $Recurse,
        [string] $NameFilter
    )

    $items = New-Object System.Collections.ArrayList

    if (Test-Path -LiteralPath $InputPath -PathType Container) {
        $opts = @{ LiteralPath = $InputPath; File = $true; ErrorAction = 'SilentlyContinue' }
        if ($Recurse) { $opts['Recurse'] = $true }
        foreach ($f in (Get-ChildItem @opts)) {
            $ext = [System.IO.Path]::GetExtension($f.Name)
            if ($null -eq $ext) { continue }
            if ($script:VideoExtensions -notcontains $ext.ToLowerInvariant()) { continue }
            if ($NameFilter -ne '' -and $null -ne $NameFilter) {
                if ($f.Name -notlike $NameFilter) { continue }
            }
            [void]$items.Add($f.FullName)
        }
        # A folder listing comes back in whatever order the filesystem feels
        # like. Sorting makes two runs over the same folder comparable.
        return @(@($items.ToArray()) | Sort-Object)
    }

    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {
        [void]$items.Add((Resolve-Path -LiteralPath $InputPath).ProviderPath)
        return @($items.ToArray())
    }

    # Not a literal path, so it may be a wildcard the shell did not expand.
    $globbed = @(Get-ChildItem -Path $InputPath -File -ErrorAction SilentlyContinue)
    foreach ($f in $globbed) { [void]$items.Add($f.FullName) }
    return @(@($items.ToArray()) | Sort-Object)
}

# ---------------------------------------------------------------------------
# Entry point.
# ---------------------------------------------------------------------------

$script:NoColorOutput = $false

function Invoke-Main {
    param(
        [string] $InputPath,
        [switch] $AsJson,
        [switch] $Recurse,
        [string] $NameFilter,
        [switch] $Quiet,
        [switch] $Explain,
        [switch] $NoColor,
        [switch] $ShowVersion,
        [switch] $ShowHelp
    )

    $script:NoColorOutput = [bool]$NoColor
    if ($null -ne $env:NO_COLOR -and $env:NO_COLOR -ne '') { $script:NoColorOutput = $true }

    if ($ShowVersion) {
        Write-Plain ($script:ToolName + ' ' + $script:ToolVersion)
        $script:ExitCode = 0
        return
    }

    if ($ShowHelp -or $null -eq $InputPath -or $InputPath -eq '') {
        Show-Help
        $script:ExitCode = 0
        return
    }

    $files = @(Resolve-InputFiles -InputPath $InputPath -Recurse:$Recurse -NameFilter $NameFilter)

    if (@($files).Count -eq 0) {
        Write-Plain ''
        Write-Plain ("Nothing to check: '" + $InputPath + "' matched no mp4 or mov files.")
        Write-Plain ''
        $script:ExitCode = 2
        return
    }

    $reports  = New-Object System.Collections.ArrayList
    $skipped  = New-Object System.Collections.ArrayList
    $problems = 0
    $readOk   = 0

    foreach ($file in $files) {
        try {
            $r = Invoke-ColorCheck -LiteralPath $file
            $readOk++
            $problems += $r.Verdict.Problems
            [void]$reports.Add($r)
        } catch {
            $m = $_.Exception.Message
            if ($m -like 'colorcheck/*') {
                [void]$skipped.Add([pscustomobject]@{ Path = $file; Reason = $m })
            } else {
                # An untagged exception is this tool's own bug and is worth
                # seeing in full rather than being filed as a bad file.
                throw
            }
        }
    }

    if ($AsJson) {
        $out = @()
        foreach ($r in $reports) {
            if ($Quiet -and $r.Verdict.Problems -eq 0 -and $r.Verdict.Warnings -eq 0) { continue }
            $out += (ConvertTo-ReportObject -Report $r)
        }
        foreach ($s in $skipped) {
            $out += [ordered]@{
                tool = $script:ToolName; version = $script:ToolVersion
                path = $s.Path; name = (Split-Path -Leaf $s.Path)
                error = $s.Reason
            }
        }
        # Depth 8 covers report -> tracks -> bitstream -> vui without the
        # silent truncation ConvertTo-Json does at its default of 2.
        if (@($out).Count -eq 1) {
            Write-Output (ConvertTo-Json -InputObject $out[0] -Depth 8)
        } else {
            Write-Output (ConvertTo-Json -InputObject @($out) -Depth 8)
        }
    } else {
        foreach ($r in $reports) {
            if ($Quiet -and $r.Verdict.Problems -eq 0 -and $r.Verdict.Warnings -eq 0) { continue }
            Write-Report -Report $r -Explain:$Explain
        }
        foreach ($s in $skipped) {
            Write-Plain ''
            Write-Plain ((Split-Path -Leaf $s.Path) + '   skipped')
            Write-Plain ('    ' + $s.Reason)
        }
        if (@($files).Count -gt 1) {
            Write-Plain ''
            Write-Plain ('  ' + $readOk + ' of ' + @($files).Count + ' file' +
                         $(if (@($files).Count -eq 1) { '' } else { 's' }) + ' read, ' +
                         $problems + ' problem' + $(if ($problems -eq 1) { '' } else { 's' }) + ' in total')
            Write-Plain ''
        }
    }

    if ($readOk -eq 0) { $script:ExitCode = 2; return }
    if ($problems -gt 0) { $script:ExitCode = 1; return }
    $script:ExitCode = 0
    return
}

$script:ExitCode = 0
try {
    Invoke-Main -InputPath $Path -AsJson:$Json -Recurse:$Recurse `
        -NameFilter $Filter -Quiet:$Quiet -Explain:$Explain -NoColor:$NoColor `
        -ShowVersion:$Version -ShowHelp:$Help
} catch {
    $msg = $_.Exception.Message
    if ($msg -like 'colorcheck/*') {
        Write-Plain ''
        Write-Plain ('colorcheck could not read that file:')
        Write-Plain ('    ' + $msg)
        Write-Plain ''
        $script:ExitCode = 2
    } else {
        Write-Plain ''
        Write-Plain ('colorcheck hit a bug and stopped. Please report this with the file that caused it.')
        Write-Plain ('    ' + $msg)
        if ($null -ne $_.InvocationInfo) {
            Write-Plain ('    at ' + $_.InvocationInfo.ScriptLineNumber + ': ' + ($_.InvocationInfo.Line).Trim())
        }
        Write-Plain ''
        $script:ExitCode = 3
    }
}

exit $script:ExitCode
