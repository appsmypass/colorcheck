# mutate.ps1 - does the test suite actually catch anything?
#
# A green suite proves nothing on its own. This deliberately breaks colorcheck in
# one specific way at a time and checks that the tests notice. A mutation that
# survives is a hole in the tests, not a success.
#
# Crash safety: the original is copied to colorcheck.ps1.mutbak and a
# .mutate-in-progress marker is dropped before anything is touched. If this
# script is killed mid-run, re-running it restores from the backup first.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File mutate.ps1
#
# -ValidateOnly checks that every anchor still resolves exactly once and exits
# without touching the tool. Use it after editing either file: an unknown
# switch would otherwise be swallowed into $args and start a full run.
#
# -Resume picks up where an interrupted run stopped. A round costs over half an
# hour and this machine reboots without warning, so progress is checkpointed to
# mutate.progress after every mutant. The checkpoint is bound to a hash of the
# tool and the mutant count, so it is silently ignored if either changed.

param([switch]$ValidateOnly, [switch]$Resume)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$m_here = Split-Path -Parent $MyInvocation.MyCommand.Path
$m_tool = Join-Path $m_here 'colorcheck.ps1'
$m_back = Join-Path $m_here 'colorcheck.ps1.mutbak'
$m_mark = Join-Path $m_here '.mutate-in-progress'
$m_self = Join-Path $m_here 'selftest.ps1'
$m_real = Join-Path $m_here 'realcheck.ps1'
$m_prog = Join-Path $m_here 'mutate.progress'

foreach ($f in @($m_tool, $m_self, $m_real)) {
    if (-not (Test-Path $f)) { Write-Error ('missing ' + $f); exit 1 }
}

# A previous run that died would have left a mutated tool in place.
if (Test-Path $m_mark) {
    if (Test-Path $m_back) {
        Write-Output 'recovering a mutated tool from an interrupted run'
        Copy-Item $m_back $m_tool -Force
    }
    Remove-Item $m_mark -Force
}

$m_original = [IO.File]::ReadAllText($m_tool)

# The checkpoint is only valid for the exact tool and mutant list it was
# written against, so it is keyed on a hash of the source. The suites are
# hashed too: editing an assertion changes what "killed" means, and a resume
# that reused those verdicts would be worthless.
function Get-SourceHash {
    param([string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '')
    } finally { $sha.Dispose() }
}

function Invoke-Suite {
    param([string]$Script, [int]$TimeoutSec, [string]$Extra = '')
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe')
    $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $Script + '"' + $Extra
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $pr = New-Object Diagnostics.Process
    $pr.StartInfo = $psi
    $null = $pr.Start()
    # Reading Handle now keeps ExitCode available after the process dies.
    $null = $pr.Handle
    $so = $pr.StandardOutput.ReadToEndAsync()
    $se = $pr.StandardError.ReadToEndAsync()
    $done = $pr.WaitForExit($TimeoutSec * 1000)
    $res = @{}
    if (-not $done) {
        try { $pr.Kill() } catch { }
        $res.Code = -1
        $res.Out = 'TIMEOUT'
        $res.Err = 'TIMEOUT'
        $pr.Dispose()
        return $res
    }
    $res.Code = $pr.ExitCode
    $res.Out = $so.Result
    $res.Err = $se.Result
    $pr.Dispose()
    return $res
}

# ---------------------------------------------------------------------------
# the mutations
# ---------------------------------------------------------------------------

function New-Mut {
    param([string]$Name, [string]$From, [string]$To, [bool]$MustSurvive = $false)
    return @{ Name = $Name; From = $From; To = $To; MustSurvive = $MustSurvive }
}

$muts = @(
    (New-Mut 'u16 is assembled with the wrong shift' '    return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]' '    return ([int]$Bytes[$Offset] -shl 4) -bor [int]$Bytes[$Offset + 1]'),
    (New-Mut 'u16 reads its two bytes little endian' '    return ([int]$Bytes[$Offset] -shl 8) -bor [int]$Bytes[$Offset + 1]' '    return ([int]$Bytes[$Offset + 1] -shl 8) -bor [int]$Bytes[$Offset]'),
    (New-Mut 'u24 drops its top byte' '    return ([int]$Bytes[$Offset] -shl 16) -bor ([int]$Bytes[$Offset + 1] -shl 8) -bor [int]$Bytes[$Offset + 2]' '    return ([int]$Bytes[$Offset + 1] -shl 8) -bor [int]$Bytes[$Offset + 2]'),
    (New-Mut 'u32 top byte lands in the wrong place' '    $v = $v -bor ([uint32]$Bytes[$Offset] -shl 24)' '    $v = $v -bor ([uint32]$Bytes[$Offset] -shl 23)'),
    (New-Mut 'u32 loses its second byte' '    $v = $v -bor ([uint32]$Bytes[$Offset + 1] -shl 16)' '    $v = $v -bor ([uint32]$Bytes[$Offset + 1] -shl 17)'),
    (New-Mut 'tripwire: the u32 accumulator is seeded with [int] instead of [uint32] (PowerShell''s -bor promotes it back, so nothing changes)' ('    $v = [uint32]0' + "`r`n" + '    $v = $v -bor ([uint32]$Bytes[$Offset] -shl 24)') ('    $v = [int]0' + "`r`n" + '    $v = $v -bor ([uint32]$Bytes[$Offset] -shl 24)') $true),
    (New-Mut 'the high half of a 64 bit value is misplaced' '    return ([uint64]$hi -shl 32) -bor [uint64]$lo' '    return ([uint64]$hi -shl 31) -bor [uint64]$lo'),
    (New-Mut 'a 64 bit read takes its low half from the wrong offset' '    $lo = Read-UInt32BE -Bytes $Bytes -Offset ($Offset + 4)' '    $lo = Read-UInt32BE -Bytes $Bytes -Offset ($Offset + 8)'),
    (New-Mut 'a negative offset is accepted by the 16 bit reader' ('    if ($Offset -lt 0) { throw (New-ParseError -Stage ''read'' -Message "negative offset $Offset") }' + "`r`n" + '    if ($Offset + 2 -gt $Bytes.Length) {') ('    if ($false) { throw (New-ParseError -Stage ''read'' -Message "negative offset $Offset") }' + "`r`n" + '    if ($Offset + 2 -gt $Bytes.Length) {')),
    (New-Mut 'the 16 bit reader runs one byte past the buffer' '    if ($Offset + 2 -gt $Bytes.Length) {' '    if ($Offset + 2 -gt ($Bytes.Length + 1)) {'),
    (New-Mut 'the 32 bit reader runs past the buffer' ('    if ($Offset + 4 -gt $Bytes.Length) {' + "`r`n" + '        throw (New-ParseError -Stage ''read'' -Message "want 4 bytes at $Offset, have $($Bytes.Length)")' + "`r`n" + '    }' + "`r`n" + '    # Built as [uint32] because a 32 bit box size with the high bit set is a') ('    if ($Offset + 4 -gt ($Bytes.Length + 1)) {' + "`r`n" + '        throw (New-ParseError -Stage ''read'' -Message "want 4 bytes at $Offset, have $($Bytes.Length)")' + "`r`n" + '    }' + "`r`n" + '    # Built as [uint32] because a 32 bit box size with the high bit set is a')),
    (New-Mut 'a four character code reads one byte early' '        $b = $Bytes[$Offset + $i]' '        $b = $Bytes[$Offset + $i - 1]'),
    (New-Mut 'a four character code accepts control characters' '        if ($b -ge 32 -and $b -le 126) {' '        if ($true) {'),
    (New-Mut 'a four character code is only three characters long' ('    for ($i = 0; $i -lt 4; $i++) {' + "`r`n" + '        $b = $Bytes[$Offset + $i]') ('    for ($i = 0; $i -lt 3; $i++) {' + "`r`n" + '        $b = $Bytes[$Offset + $i]')),
    (New-Mut 'an already tagged error is tagged a second time' '        if ($msg -like ''colorcheck/*'') { throw $msg }' '        if ($false) { throw $msg }'),
    (New-Mut 'a box header shorter than eight bytes is read anyway' ('    if ($Offset + 8 -gt $Limit) {' + "`r`n" + '        throw (New-ParseError -Stage ''box'' -Message "truncated box header at $Offset")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''box'' -Message "truncated box header at $Offset")')),
    (New-Mut 'the box type is read from the size field' ('    $type = Read-FourCC -Bytes $Bytes -Offset ($Offset + 4)' + "`r`n" + '    $header = 8') ('    $type = Read-FourCC -Bytes $Bytes -Offset $Offset' + "`r`n" + '    $header = 8')),
    (New-Mut 'a 64 bit box size is read from the wrong offset' ('        $size = Read-UInt64BE -Bytes $Bytes -Offset ($Offset + 8)' + "`r`n" + '        $header = 16') ('        $size = Read-UInt64BE -Bytes $Bytes -Offset ($Offset + 4)' + "`r`n" + '        $header = 16')),
    (New-Mut 'a 64 bit box keeps the eight byte header length' ('        $size = Read-UInt64BE -Bytes $Bytes -Offset ($Offset + 8)' + "`r`n" + '        $header = 16') ('        $size = Read-UInt64BE -Bytes $Bytes -Offset ($Offset + 8)' + "`r`n" + '        $header = 8')),
    (New-Mut 'a 64 bit box smaller than its own header is accepted' ('        if ($size -lt [uint64]16) {' + "`r`n" + '            throw (New-ParseError -Stage ''box'' -Message "64 bit box ''$type'' at $Offset declares $size bytes, below its own 16 byte header")') ('        if ($false) {' + "`r`n" + '            throw (New-ParseError -Stage ''box'' -Message "64 bit box ''$type'' at $Offset declares $size bytes, below its own 16 byte header")')),
    (New-Mut 'an open ended box stops one byte short of the parent' ('        $size = [uint64]($Limit - $Offset)' + "`r`n" + '        if ($size -lt [uint64]8) {') ('        $size = [uint64]($Limit - $Offset - 1)' + "`r`n" + '        if ($size -lt [uint64]8) {')),
    (New-Mut 'a box smaller than its own header is accepted' ('    } elseif ($size -lt [uint64]8) {' + "`r`n" + '        throw (New-ParseError -Stage ''box'' -Message "box ''$type'' at $Offset declares $size bytes, below its own 8 byte header")') ('    } elseif ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''box'' -Message "box ''$type'' at $Offset declares $size bytes, below its own 8 byte header")')),
    (New-Mut 'a box running past its parent is accepted' '    if ([uint64]$Offset + $size -gt [uint64]$Limit) {' '    if ($false) {'),
    (New-Mut 'the body of a box starts at the box itself' '        BodyOffset  = $Offset + $header' '        BodyOffset  = $Offset'),
    (New-Mut 'the body size still counts the header' '        BodySize    = [long]$size - $header' '        BodySize    = [long]$size'),
    (New-Mut 'a box ends one byte early' '        End         = $Offset + [long]$size' '        End         = $Offset + [long]$size - 1'),
    (New-Mut 'child boxes are walked past the end of the parent' ('    while ($p + 8 -le $Limit) {' + "`r`n" + '        $h = Read-BoxHeader -Bytes $Bytes -Offset $p -Limit $Limit') ('    while ($p + 8 -le ($Limit + 64)) {' + "`r`n" + '        $h = Read-BoxHeader -Bytes $Bytes -Offset $p -Limit $Limit')),
    (New-Mut 'walking children steps by the header instead of the box' ('        $p = $h.End' + "`r`n" + '    }' + "`r`n" + '    return @($out.ToArray())') ('        $p = $h.Offset + $h.HeaderSize' + "`r`n" + '    }' + "`r`n" + '    return @($out.ToArray())')),
    (New-Mut 'finding a child box matches any case' '        if ($b.Type -ceq $Type) { return $b }' '        if ($b.Type -eq $Type) { return $b }'),
    (New-Mut 'finding a child box returns the last one instead of the first' ('        if ($b.Type -ceq $Type) { return $b }' + "`r`n" + '    }' + "`r`n" + '    return $null') ('        if ($b.Type -ceq $Type) { $last = $b }' + "`r`n" + '    }' + "`r`n" + '    if ($null -ne $last) { return $last }' + "`r`n" + '    return $null')),
    (New-Mut 'collecting child boxes ignores the requested type' '        if ($b.Type -ceq $Type) { [void]$out.Add($b) }' '        [void]$out.Add($b)'),
    (New-Mut 'a short read is treated as a complete one' ('        $n = $Stream.Read($buf, $got, $Count - $got)' + "`r`n" + '        if ($n -le 0) { break }' + "`r`n" + '        $got += $n') ('        $n = $Stream.Read($buf, $got, $Count - $got)' + "`r`n" + '        if ($n -le 0) { break }' + "`r`n" + '        $got = $Count')),
    (New-Mut 'a read that came up short is returned anyway' ('    if ($got -lt $Count) {' + "`r`n" + '        throw (New-ParseError -Stage ''read'' -Message "wanted $Count bytes at $Position, got $got")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''read'' -Message "wanted $Count bytes at $Position, got $got")')),
    (New-Mut 'a seek past the end of the file is allowed' '    if ($Position -ge $Stream.Length) {' '    if ($false) {'),
    (New-Mut 'a negative read count is allowed through' '    if ($Count -lt 0) { throw (New-ParseError -Stage ''read'' -Message "negative count $Count") }' '    if ($false) { throw (New-ParseError -Stage ''read'' -Message "negative count $Count") }'),
    (New-Mut 'the top level walk reads only eight bytes so no 64 bit size fits' '        $head = Read-At -Stream $Stream -Position $pos -Count ([int][Math]::Min([long]16, $len - $pos))' '        $head = Read-At -Stream $Stream -Position $pos -Count ([int][Math]::Min([long]8, $len - $pos))'),
    (New-Mut 'the top level size is read from the type field' ('        $size   = [uint64](Read-UInt32BE -Bytes $head -Offset 0)' + "`r`n" + '        $type   = Read-FourCC -Bytes $head -Offset 4') ('        $size   = [uint64](Read-UInt32BE -Bytes $head -Offset 4)' + "`r`n" + '        $type   = Read-FourCC -Bytes $head -Offset 4')),
    (New-Mut 'a top level box that overruns the file is trusted' '        if ($end -gt $len) {' '        if ($false) {'),
    (New-Mut 'an overrunning final box is not marked truncated' '                BodySize = [long]($len - $pos) - $header; End = $len; Truncated = $true' '                BodySize = [long]($len - $pos) - $header; End = $len; Truncated = $false'),
    (New-Mut 'the top level walk never advances so it loops forever' ('        $pos = $end' + "`r`n" + '        $seen++') ('        $pos = $pos' + "`r`n" + '        $seen++')),
    (New-Mut 'a file with thousands of top level boxes is accepted' '        if ($seen -gt 4096) {' '        if ($false) {'),
    (New-Mut 'a file with no boxes at all is accepted' ('    if (@($top).Count -eq 0) {' + "`r`n" + '        throw (New-ParseError -Stage ''container'' -Message "no boxes at all; not an MP4 or MOV")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''container'' -Message "no boxes at all; not an MP4 or MOV")')),
    (New-Mut 'the brand is read from the wrong place in the ftyp box' '        $fb = Read-At -Stream $Stream -Position $ftyp.BodyOffset -Count 4' '        $fb = Read-At -Stream $Stream -Position ($ftyp.BodyOffset + 4) -Count 4'),
    (New-Mut 'the first box is taken as the moov box' '    foreach ($b in $top) { if ($b.Type -ceq ''moov'') { $moov = $b; break } }' '    foreach ($b in $top) { $moov = $b; break }'),
    (New-Mut 'a file with no moov box is accepted' ('    if ($null -eq $moov) {' + "`r`n" + '        $types = (@($top) | ForEach-Object { $_.Type }) -join '', ''') ('    if ($false) {' + "`r`n" + '        $types = (@($top) | ForEach-Object { $_.Type }) -join '', ''')),
    (New-Mut 'a cut off moov box is parsed anyway' ('    if ($moov.Truncated) {' + "`r`n" + '        throw (New-ParseError -Stage ''container'' -Message "the moov box is cut off; the file is incomplete")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''container'' -Message "the moov box is cut off; the file is incomplete")')),
    (New-Mut 'an empty moov box is parsed anyway' '    if ($moov.BodySize -le 0) {' '    if ($false) {'),
    (New-Mut 'an absurdly large moov box is read into memory' '    if ($moov.BodySize -gt 268435456) {' '    if ($false) {'),
    (New-Mut 'the moov body is read from the box header' '        Bytes      = (Read-At -Stream $Stream -Position $moov.BodyOffset -Count ([int]$moov.BodySize))' '        Bytes      = (Read-At -Stream $Stream -Position $moov.Offset -Count ([int]$moov.BodySize))'),
    (New-Mut 'the handler type is read from the start of the hdlr body' '    return Read-FourCC -Bytes $Bytes -Offset ($hdlr.BodyOffset + 8)' '    return Read-FourCC -Bytes $Bytes -Offset $hdlr.BodyOffset'),
    (New-Mut 'a truncated hdlr box is read anyway' '    if ($hdlr.BodySize -lt 12) { return $null }' '    if ($false) { return $null }'),
    (New-Mut 'a version one track header is read as version zero' ('    if ($version -eq 1) {' + "`r`n" + '        if ($tkhd.BodySize -lt 28) { return 0 }') ('    if ($false) {' + "`r`n" + '        if ($tkhd.BodySize -lt 28) { return 0 }')),
    (New-Mut 'the track id is read from the creation time' '    return [long](Read-UInt32BE -Bytes $Bytes -Offset ($tkhd.BodyOffset + 12))' '    return [long](Read-UInt32BE -Bytes $Bytes -Offset ($tkhd.BodyOffset + 4))'),
    (New-Mut 'audio tracks are analysed as video' '        if ($handler -cne ''vide'') { continue }' '        if ($false) { continue }'),
    (New-Mut 'the sample description count is read from the version field' '        $count = Read-UInt32BE -Bytes $Bytes -Offset ($stsd.BodyOffset + 4)' '        $count = Read-UInt32BE -Bytes $Bytes -Offset $stsd.BodyOffset'),
    (New-Mut 'an absurd sample description count is trusted' '        if ($count -gt 256) {' '        if ($false) {'),
    (New-Mut 'the first sample entry starts before the stsd header' '        $p = $stsd.BodyOffset + 8' '        $p = $stsd.BodyOffset + 4'),
    (New-Mut 'the visual sample entry header length is off by two' '    $w = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 24)' '    $w = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 26)'),
    (New-Mut 'the frame height is read from the width field' '                $h = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 26)' '                $h = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 24)'),
    (New-Mut 'the bit depth is read from the wrong field' '                $depth = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 74)' '                $depth = Read-UInt16BE -Bytes $Bytes -Offset ($se.BodyOffset + 72)'),
    (New-Mut 'child boxes are searched from the start of the sample entry' '                    ChildOffset   = $se.BodyOffset + $script:VisualSampleEntryHeader' '                    ChildOffset   = $se.BodyOffset'),
    (New-Mut 'the visual sample entry header constant is wrong' '$script:VisualSampleEntryHeader = 78' '$script:VisualSampleEntryHeader = 86'),
    (New-Mut 'an unknown code point is reported as a known name' ('    if ($Table.ContainsKey($Code)) { return $Table[$Code] }' + "`r`n" + '    return "unknown ($Code)"') ('    if ($Table.ContainsKey($Code)) { return $Table[$Code] }' + "`r`n" + '    return "BT.709"')),
    (New-Mut 'ordinary gamma is treated as an HDR curve' '    return ($Transfer -eq 16 -or $Transfer -eq 18)' '    return ($Transfer -eq 16 -or $Transfer -eq 18 -or $Transfer -eq 1)'),
    (New-Mut 'HLG is no longer recognised as HDR' '    return ($Transfer -eq 16 -or $Transfer -eq 18)' '    return ($Transfer -eq 16)'),
    (New-Mut 'a truncated colour box is parsed anyway' ('    if ($Box.BodySize -lt 4) {' + "`r`n" + '        throw (New-ParseError -Stage ''colr'' -Message "colr box holds only $($Box.BodySize) bytes")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''colr'' -Message "colr box holds only $($Box.BodySize) bytes")')),
    (New-Mut 'a colour box ten bytes short is parsed anyway' ('        if ($Box.BodySize -lt 10) {' + "`r`n" + '            throw (New-ParseError -Stage ''colr'' -Message "''$kind'' colr box needs 10 bytes, has $($Box.BodySize)")') ('        if ($false) {' + "`r`n" + '            throw (New-ParseError -Stage ''colr'' -Message "''$kind'' colr box needs 10 bytes, has $($Box.BodySize)")')),
    (New-Mut 'the colour primaries are read from the kind field' '        $prim = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 4)' '        $prim = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 2)'),
    (New-Mut 'the transfer curve and the matrix are swapped' ('        $tran = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 6)' + "`r`n" + '        $matx = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 8)') ('        $tran = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 8)' + "`r`n" + '        $matx = Read-UInt16BE -Bytes $Bytes -Offset ($Box.BodyOffset + 6)')),
    (New-Mut 'an nclc box is given a range it cannot carry' ('        if ($kind -ceq ''nclx'') {' + "`r`n" + '            if ($Box.BodySize -lt 11) {') ('        if ($true) {' + "`r`n" + '            if ($Box.BodySize -lt 11) {')),
    (New-Mut 'the range flag is read from the matrix byte' '            $rangeByte = $Bytes[$Box.BodyOffset + 10]' '            $rangeByte = $Bytes[$Box.BodyOffset + 9]'),
    (New-Mut 'the range flag tests the wrong bit' '            $full = (($rangeByte -band 0x80) -ne 0)' '            $full = (($rangeByte -band 0x40) -ne 0)'),
    (New-Mut 'an nclx box with no range byte is accepted' ('            if ($Box.BodySize -lt 11) {' + "`r`n" + '                throw (New-ParseError -Stage ''colr'' -Message "''nclx'' colr box is missing its range byte")') ('            if ($false) {' + "`r`n" + '                throw (New-ParseError -Stage ''colr'' -Message "''nclx'' colr box is missing its range byte")')),
    (New-Mut 'an ICC profile is reported with the header bytes counted' '        IccBytes   = [int]($Box.BodySize - 4)' '        IccBytes   = [int]$Box.BodySize'),
    (New-Mut 'an unrecognised colour type is accepted silently' '    throw (New-ParseError -Stage ''colr'' -Message "unrecognised colour type ''$kind''")' '    return $null'),
    (New-Mut 'a truncated pixel aspect box is parsed anyway' ('    if ($Box.BodySize -lt 8) {' + "`r`n" + '        throw (New-ParseError -Stage ''pasp'' -Message "pasp box holds only $($Box.BodySize) bytes")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''pasp'' -Message "pasp box holds only $($Box.BodySize) bytes")')),
    (New-Mut 'the vertical pixel spacing is read from the horizontal one' '    $v = Read-UInt32BE -Bytes $Bytes -Offset ($Box.BodyOffset + 4)' '    $v = Read-UInt32BE -Bytes $Bytes -Offset $Box.BodyOffset'),
    (New-Mut 'emulation prevention bytes are left in the stream' '        if ($zeros -ge 2 -and $b -eq 3) {' '        if ($false) {'),
    (New-Mut 'the zero run is not reset after an escape is removed' ('            $zeros = 0' + "`r`n" + '            continue') '            continue'),
    (New-Mut 'the zero run counts any byte' '        if ($b -eq 0) { $zeros++ } else { $zeros = 0 }' '        $zeros++'),
    (New-Mut 'an escape is removed after only one zero byte' '        if ($zeros -ge 2 -and $b -eq 3) {' '        if ($zeros -ge 1 -and $b -eq 3) {'),
    (New-Mut 'the bit reader thinks the buffer is eight times longer' '        TotalBits = $Bytes.Length * 8' '        TotalBits = $Bytes.Length * 64'),
    (New-Mut 'the bit reader divides rather than shifts so it rounds to nearest' '    $byte = $Reader.Bytes[($Reader.BitPos -shr 3)]' '    $byte = $Reader.Bytes[[int]($Reader.BitPos / 8)]'),
    (New-Mut 'bits come out of the byte in the wrong order' '    $shift = 7 - ($Reader.BitPos -band 7)' '    $shift = ($Reader.BitPos -band 7)'),
    (New-Mut 'the bit reader runs off the end of the parameter set' ('    if ($Reader.BitPos -ge $Reader.TotalBits) {' + "`r`n" + '        throw (New-ParseError -Stage ''sps'' -Message "ran off the end of the parameter set after $($Reader.BitPos) bits")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''sps'' -Message "ran off the end of the parameter set after $($Reader.BitPos) bits")')),
    (New-Mut 'reading several bits shifts the wrong way' '        $v = ($v -shl 1) -bor [uint32](Read-Bit -Reader $Reader)' '        $v = ($v -shr 1) -bor [uint32](Read-Bit -Reader $Reader)'),
    (New-Mut 'a zero bit count consumes a bit anyway' '    if ($Count -eq 0) { return 0 }' '    if ($Count -eq 0) { return (Read-Bit -Reader $Reader) }'),
    (New-Mut 'skipping bits runs past the end of the parameter set' ('    if ($Reader.BitPos + $Count -gt $Reader.TotalBits) {' + "`r`n" + '        throw (New-ParseError -Stage ''sps'' -Message "skipping $Count bits runs past the end of the parameter set")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''sps'' -Message "skipping $Count bits runs past the end of the parameter set")')),
    (New-Mut 'an exp-Golomb code is off by one' '    return [long]((([long]1 -shl $leadingZeros) - 1) + $suffix)' '    return [long](([long]1 -shl $leadingZeros) + $suffix)'),
    (New-Mut 'an exp-Golomb code ignores its suffix' ('    $suffix = Read-Bits -Reader $Reader -Count $leadingZeros' + "`r`n" + '    return [long]((([long]1 -shl $leadingZeros) - 1) + $suffix)') ('    $suffix = Read-Bits -Reader $Reader -Count $leadingZeros' + "`r`n" + '    return [long](([long]1 -shl $leadingZeros) - 1)')),
    (New-Mut 'an unaligned stream is read forever instead of reported' '        if ($leadingZeros -gt 32) {' '        if ($false) {'),
    (New-Mut 'a signed exp-Golomb code has its sign backwards' '        return [long](-1 * ($k / 2))' '        return [long]($k / 2)'),
    (New-Mut 'a signed exp-Golomb code rounds the wrong way' '    return [long](($k + 1) / 2)' '    return [long]($k / 2)'),
    (New-Mut 'a stream with no VUI block is reported as carrying colour' ('        Present     = $false' + "`r`n" + '        Block       = $false') ('        Present     = $true' + "`r`n" + '        Block       = $false')),
    (New-Mut 'the aspect ratio extension is read even when the flag says no' ('    if ($aspectPresent -eq 1) {' + "`r`n" + '        $aspectIdc = Read-Bits -Reader $Reader -Count 8') ('    if ($true) {' + "`r`n" + '        $aspectIdc = Read-Bits -Reader $Reader -Count 8')),
    (New-Mut 'the extended sample aspect ratio is not read when it should be' '        if ($aspectIdc -eq 255) {' '        if ($false) {'),
    (New-Mut 'the overscan flag is skipped so every later field shifts' ('    $overscanPresent = Read-Bit -Reader $Reader' + "`r`n" + '    $overscan = $null') ('    $overscanPresent = 0' + "`r`n" + '    $overscan = $null')),
    (New-Mut 'a VUI block with no signal type is reported as having one' '    if ($signalPresent -ne 1) {' '    if ($false) {'),
    (New-Mut 'the video format field is the wrong width so range shifts' '    $videoFormat = Read-Bits -Reader $Reader -Count 3' '    $videoFormat = Read-Bits -Reader $Reader -Count 4'),
    (New-Mut 'the full range flag is inverted' '    $fullRange   = ((Read-Bit -Reader $Reader) -eq 1)' '    $fullRange   = ((Read-Bit -Reader $Reader) -eq 0)'),
    (New-Mut 'the colour description is read even when it is absent' ('    if ($colourPresent -eq 1) {' + "`r`n" + '        $prim = Read-Bits -Reader $Reader -Count 8') ('    if ($true) {' + "`r`n" + '        $prim = Read-Bits -Reader $Reader -Count 8')),
    (New-Mut 'the stream transfer curve and matrix are swapped' ('        $tran = Read-Bits -Reader $Reader -Count 8' + "`r`n" + '        $matx = Read-Bits -Reader $Reader -Count 8') ('        $matx = Read-Bits -Reader $Reader -Count 8' + "`r`n" + '        $tran = Read-Bits -Reader $Reader -Count 8')),
    (New-Mut 'a NAL unit that is not a parameter set is parsed as one' '        if ($nalType -ne 7) {' '        if ($false) {'),
    (New-Mut 'the NAL header mask takes too many bits' '        $nalType = [int]$Nal[0] -band 0x1F' '        $nalType = [int]$Nal[0] -band 0x3F'),
    (New-Mut 'the NAL header byte is parsed as part of the payload' '        $rbsp = Remove-EmulationPrevention -Bytes $Nal[1..($Nal.Length - 1)]' '        $rbsp = Remove-EmulationPrevention -Bytes $Nal'),
    (New-Mut 'a high profile stream skips its chroma fields' '        if ($script:AvcHighProfiles -contains [int]$profileIdc) {' '        if ($false) {'),
    (New-Mut 'the bit depth is reported eight too low' '            $bitDepthLuma = [int](Read-Ue -Reader $r) + 8' '            $bitDepthLuma = [int](Read-Ue -Reader $r)'),
    (New-Mut 'the scaling matrix is skipped so the frame size shifts' ('            $scalingPresent = Read-Bit -Reader $r' + "`r`n" + '            if ($scalingPresent -eq 1) {') ('            $scalingPresent = 0' + "`r`n" + '            if ($scalingPresent -eq 1) {')),
    (New-Mut 'chroma format three does not consume its extra flag' '            if ($chromaFormat -eq 3) { [void](Read-Bit -Reader $r) }  # separate_colour_plane_flag' '            if ($false) { [void](Read-Bit -Reader $r) }  # separate_colour_plane_flag'),
    (New-Mut 'the picture order count cycle is not consumed' '            for ($i = 0; $i -lt $cycle; $i++) { [void](Read-Se -Reader $r) }' '            for ($i = 0; $i -lt 0; $i++) { [void](Read-Se -Reader $r) }'),
    (New-Mut 'an undefined picture order count type is accepted' '        } elseif ($pocType -ne 2) {' '        } elseif ($false) {'),
    (New-Mut 'the frame width forgets its plus one' '        $widthMbs   = [int](Read-Ue -Reader $r) + 1' '        $widthMbs   = [int](Read-Ue -Reader $r)'),
    (New-Mut 'the frame width is counted in pixels not macroblocks' '        $width  = ($widthMbs * 16) - ($subWidthC * ($cropLeft + $cropRight))' '        $width  = $widthMbs - ($subWidthC * ($cropLeft + $cropRight))'),
    (New-Mut 'the crop offsets are ignored so 1080p is reported as 1088' '        $height = ($heightUnits * 16 * $heightMult) - ($subHeightC * $heightMult * ($cropTop + $cropBottom))' '        $height = ($heightUnits * 16 * $heightMult)'),
    (New-Mut 'chroma subsampling does not double the crop offsets' '        $subWidthC  = $(if ($chromaFormat -eq 3) { 1 } elseif ($chromaFormat -eq 0) { 1 } else { 2 })' '        $subWidthC  = 1'),
    (New-Mut 'an interlaced stream is measured as progressive' '        $heightMult = $(if ($frameMbsOnly -eq 1) { 1 } else { 2 })' '        $heightMult = 1'),
    (New-Mut 'the VUI present flag is ignored so colour is invented' ('        [void](Read-Bit -Reader $r)  # strong_intra_smoothing_enabled_flag' + "`r`n" + '' + "`r`n" + '        $vui = New-AbsentVui' + "`r`n" + '        if ((Read-Bit -Reader $r) -eq 1) {') ('        [void](Read-Bit -Reader $r)  # strong_intra_smoothing_enabled_flag' + "`r`n" + '' + "`r`n" + '        $vui = New-AbsentVui' + "`r`n" + '        if ($true) {')),
    (New-Mut 'the container and the stream matrix are never compared' '        if ($colr.Matrix -ne $vui.Matrix) {' '        if ($false) {'),
    (New-Mut 'the primaries comparison reads the matrix instead' '        if ($colr.Primaries -ne $vui.Primaries) {' '        if ($colr.Primaries -ne $vui.Matrix) {'),
    (New-Mut 'a transfer curve conflict is never reported' '        if ($colr.Transfer -ne $vui.Transfer) {' '        if ($false) {'),
    (New-Mut 'a range conflict is never reported' '        if ($colr.FullRange -ne $vui.FullRange) {' '        if ($false) {'),
    (New-Mut 'a file with no colour tags at all is reported as fine' '    if (-not $colrHasCodes -and -not $vuiHasColour) {' '    if ($false) {'),
    (New-Mut 'an unspecified matrix is treated as a real one' '    } elseif ($null -ne $effMatrix -and $effMatrix -eq 2) {' '    } elseif ($false) {'),
    (New-Mut 'a missing colour box is never mentioned' '    if (-not $colrHasCodes -and $vuiHasColour) {' '    if ($false) {'),
    (New-Mut 'a missing stream description is never mentioned' '    if ($colrHasCodes -and -not $vuiHasColour) {' '    if ($false) {'),
    (New-Mut 'standard definition is the fallback at every frame height' ('    if ($Height -le 576) { return 6 }' + "`r`n" + '    return 1') ('    if ($Height -le 576) { return 6 }' + "`r`n" + '    return 6')),
    (New-Mut 'the standard definition cutoff is one line too low' '    if ($Height -le 576) { return 6 }' '    if ($Height -le 480) { return 6 }'),
    (New-Mut 'a zero height picks a real matrix instead of none' '    if ($Height -le 0)   { return 0 }' '    if ($Height -le 0)   { return 1 }'),
    (New-Mut 'an unknown range is described as limited' '    if ($null -eq $FullRange) { return ''unknown'' }' '    if ($null -eq $FullRange) { return ''limited (16-235)'' }'),
    (New-Mut 'full and limited range are described the wrong way round' ('    if ($FullRange) { return ''full (0-255)'' }' + "`r`n" + '    return ''limited (16-235)''') ('    if ($FullRange) { return ''limited (16-235)'' }' + "`r`n" + '    return ''full (0-255)''')),
    (New-Mut 'high definition footage tagged BT.601 is not reported' '        if (($matrix -eq 5 -or $matrix -eq 6) -and $expected -eq 1) {' '        if ($false) {'),
    (New-Mut 'only one of the two standard definition matrices is caught' '        if (($matrix -eq 5 -or $matrix -eq 6) -and $expected -eq 1) {' '        if (($matrix -eq 5) -and $expected -eq 1) {'),
    (New-Mut 'standard definition tagged BT.709 is not mentioned' '        } elseif ($matrix -eq 1 -and $expected -eq 6) {' '        } elseif ($false) {'),
    (New-Mut 'an RGB tagged file is not mentioned' '    if ($null -ne $matrix -and $matrix -eq 0) {' '    if ($false) {'),
    (New-Mut 'full range is never flagged' '    if ($null -ne $fullRange -and $fullRange -eq $true) {' '    if ($false) {'),
    (New-Mut 'the older QuickTime colour box is not mentioned' '    if ($null -ne $colr -and $colr.Kind -ceq ''nclc'') {' '    if ($false) {'),
    (New-Mut 'an embedded ICC profile is not mentioned' '    if ($null -ne $colr -and ($colr.Kind -ceq ''rICC'' -or $colr.Kind -ceq ''prof'')) {' '    if ($false) {'),
    (New-Mut 'HDR on narrow primaries is not reported' '        if ($null -ne $primaries -and $primaries -ne 9) {' '        if ($false) {'),
    (New-Mut 'missing mastering metadata on HDR is not reported' '        if (-not $Track.HasMasteringDisplay) {' '        if ($false) {'),
    (New-Mut 'wide gamut with an ordinary curve is not reported' '    } elseif ($null -ne $primaries -and $primaries -eq 9 -and $null -ne $transfer -and $transfer -eq 1) {' '    } elseif ($false) {'),
    (New-Mut 'mastering metadata on a file that is not HDR is not mentioned' '    if ($null -ne $Track.HasMasteringDisplay -and $Track.HasMasteringDisplay -and' '    if ($false -and $Track.HasMasteringDisplay -and'),
    (New-Mut 'a zero pixel spacing is treated as merely non square' '        if ($Track.Pasp.HSpacing -le 0 -or $Track.Pasp.VSpacing -le 0) {' '        if ($false) {'),
    (New-Mut 'non square pixels are never reported' '        } elseif ($Track.Pasp.HSpacing -ne $Track.Pasp.VSpacing) {' '        } elseif ($false) {'),
    (New-Mut 'a frame size disagreement is never reported' '        if ($Track.Bitstream.Width -ne $Track.Width -or $Track.Bitstream.Height -ne $Track.Height) {' '        if ($false) {'),
    (New-Mut 'the container no longer wins over the stream' ('    if ($null -ne $Track.Colr) {' + "`r`n" + '        if ($null -ne $Track.Colr.Primaries) {' + "`r`n" + '            $matrix = $Track.Colr.Matrix; $primaries = $Track.Colr.Primaries; $transfer = $Track.Colr.Transfer') ('    if ($null -ne $Track.Colr) {' + "`r`n" + '        if ($false) {' + "`r`n" + '            $matrix = $Track.Colr.Matrix; $primaries = $Track.Colr.Primaries; $transfer = $Track.Colr.Transfer')),
    (New-Mut 'the container range is ignored in the effective tags' ('        if ($null -ne $Track.Colr.FullRange) {' + "`r`n" + '            $fullRange = $Track.Colr.FullRange' + "`r`n" + '            if ($source -eq ''nothing'') { $source = ''container'' }') ('        if ($false) {' + "`r`n" + '            $fullRange = $Track.Colr.FullRange' + "`r`n" + '            if ($source -eq ''nothing'') { $source = ''container'' }')),
    (New-Mut 'tags found in both places are credited to the container alone' '            $source = $(if ($source -eq ''bitstream'') { ''both'' } else { ''container'' })' '            $source = ''container'''),
    (New-Mut 'warnings are counted as problems' ('            if ($f.Severity -eq ''problem'') { $problems++ }' + "`r`n" + '            elseif ($f.Severity -eq ''warning'') { $warnings++ }') ('            if ($f.Severity -eq ''problem'') { $problems++ }' + "`r`n" + '            elseif ($f.Severity -eq ''warning'') { $problems++ }')),
    (New-Mut 'notes are counted as warnings' '            else { $notes++ }' '            else { $warnings++ }'),
    (New-Mut 'a file with problems is still called consistent' ('    if ($problems -gt 0) { $label = ''conflict'' }' + "`r`n" + '    elseif ($warnings -gt 0) { $label = ''check this'' }') ('    if ($false) { $label = ''conflict'' }' + "`r`n" + '    elseif ($warnings -gt 0) { $label = ''check this'' }')),
    (New-Mut 'warnings no longer ask the reader to look' '    elseif ($warnings -gt 0) { $label = ''check this'' }' '    elseif ($false) { $label = ''check this'' }'),
    (New-Mut 'a file with no video track is accepted' ('    if (@($entries).Count -eq 0) {' + "`r`n" + '        throw (New-ParseError -Stage ''container'' -Message "no video track; this file has nothing to check")') ('    if ($false) {' + "`r`n" + '        throw (New-ParseError -Stage ''container'' -Message "no video track; this file has nothing to check")')),
    (New-Mut 'an unreadable file still exits zero' '    if ($readOk -eq 0) { $script:ExitCode = 2; return }' '    if ($false) { $script:ExitCode = 2; return }'),
    (New-Mut 'a file with problems still exits zero' '    if ($problems -gt 0) { $script:ExitCode = 1; return }' '    if ($false) { $script:ExitCode = 1; return }'),
    (New-Mut 'a folder that matched nothing exits zero' ('        $script:ExitCode = 2' + "`r`n" + '        return' + "`r`n" + '    }') ('        $script:ExitCode = 0' + "`r`n" + '        return' + "`r`n" + '    }')),
    (New-Mut 'a tool bug is filed as a bad file instead of being raised' '            if ($m -like ''colorcheck/*'') {' '            if ($true) {'),
    (New-Mut 'the JSON is truncated at the default depth' '            Write-Output (ConvertTo-Json -InputObject $out[0] -Depth 8)' '            Write-Output (ConvertTo-Json -InputObject $out[0] -Depth 2)'),
    (New-Mut 'a single report is emitted as a bare object inside an array' '        if (@($out).Count -eq 1) {' '        if ($false) {'),
    (New-Mut 'quiet mode hides files that have problems' ('            if ($Quiet -and $r.Verdict.Problems -eq 0 -and $r.Verdict.Warnings -eq 0) { continue }' + "`r`n" + '            $out += (ConvertTo-ReportObject -Report $r)') ('            if ($Quiet) { continue }' + "`r`n" + '            $out += (ConvertTo-ReportObject -Report $r)')),
    (New-Mut 'a folder listing comes back in filesystem order' ('        return @(@($items.ToArray()) | Sort-Object)' + "`r`n" + '    }' + "`r`n" + '' + "`r`n" + '    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {') ('        return @($items.ToArray())' + "`r`n" + '    }' + "`r`n" + '' + "`r`n" + '    if (Test-Path -LiteralPath $InputPath -PathType Leaf) {')),
    (New-Mut 'every file in a folder is treated as a recording' '            if ($script:VideoExtensions -notcontains $ext.ToLowerInvariant()) { continue }' '            if ($false) { continue }'),
    (New-Mut 'the name filter is ignored' '                if ($f.Name -notlike $NameFilter) { continue }' '                if ($false) { continue }'),
    (New-Mut 'a folder is always searched recursively' '        if ($Recurse) { $opts[''Recurse''] = $true }' '        $opts[''Recurse''] = $true'),
    (New-Mut 'the no colour environment variable is ignored' '    if ($null -ne $env:NO_COLOR -and $env:NO_COLOR -ne '''') { $script:NoColorOutput = $true }' '    if ($false) { $script:NoColorOutput = $true }'),
    (New-Mut 'tripwire: a comment about byte order is reworded' '# The whole ISO base media file format is big endian. PowerShell''s' '# reworded by the mutation harness; this line is never executed' $true),
    (New-Mut 'tripwire: a comment about the sample entry header is reworded' '# Getting this constant wrong is the classic way to "find" a colr box that is' '# reworded by the mutation harness; this line is never executed either' $true),
    (New-Mut 'tripwire: the string builder in the four character code reader is renamed' ('    $sb = New-Object System.Text.StringBuilder' + "`r`n" + '    for ($i = 0; $i -lt 4; $i++) {' + "`r`n" + '        $b = $Bytes[$Offset + $i]' + "`r`n" + '        # A four character code is nominally printable ASCII. Anything outside' + "`r`n" + '        # that range is shown as a dot so a corrupt header cannot inject' + "`r`n" + '        # control characters into the terminal.' + "`r`n" + '        if ($b -ge 32 -and $b -le 126) {' + "`r`n" + '            [void]$sb.Append([char]$b)' + "`r`n" + '        } else {' + "`r`n" + '            [void]$sb.Append(''.'')' + "`r`n" + '        }' + "`r`n" + '    }' + "`r`n" + '    return $sb.ToString()') ('    $renamedByHarness = New-Object System.Text.StringBuilder' + "`r`n" + '    for ($i = 0; $i -lt 4; $i++) {' + "`r`n" + '        $b = $Bytes[$Offset + $i]' + "`r`n" + '        # A four character code is nominally printable ASCII. Anything outside' + "`r`n" + '        # that range is shown as a dot so a corrupt header cannot inject' + "`r`n" + '        # control characters into the terminal.' + "`r`n" + '        if ($b -ge 32 -and $b -le 126) {' + "`r`n" + '            [void]$renamedByHarness.Append([char]$b)' + "`r`n" + '        } else {' + "`r`n" + '            [void]$renamedByHarness.Append(''.'')' + "`r`n" + '        }' + "`r`n" + '    }' + "`r`n" + '    return $renamedByHarness.ToString()') $true),
    (New-Mut 'tripwire: an unused local is introduced in the verdict' ('    $problems = 0' + "`r`n" + '    $warnings = 0') ('    $problems = 0' + "`r`n" + '    $unusedByHarness = 0' + "`r`n" + '    $warnings = 0') $true),
    (New-Mut 'tripwire: the comment above the bit reader is reworded' '    # -shr 3 rather than [int]($BitPos / 8): PowerShell''s [int] cast rounds to' '    # reworded by the mutation harness; this comment is never executed' $true),
    (New-Mut 'the matrix conflict names the container and the stream the wrong way round' ('                -Detail ("The colr box says " + (Get-CodeName -Table $script:MatrixNames -Code $colr.Matrix) +' + "`r`n" + '                         " and the bitstream says " + (Get-CodeName -Table $script:MatrixNames -Code $vui.Matrix) +') ('                -Detail ("The colr box says " + (Get-CodeName -Table $script:MatrixNames -Code $vui.Matrix) +' + "`r`n" + '                         " and the bitstream says " + (Get-CodeName -Table $script:MatrixNames -Code $colr.Matrix) +')),
    (New-Mut 'the primaries conflict names the container and the stream the wrong way round' ('                -Detail ("The colr box says " + (Get-CodeName -Table $script:PrimariesNames -Code $colr.Primaries) +' + "`r`n" + '                         " and the bitstream says " + (Get-CodeName -Table $script:PrimariesNames -Code $vui.Primaries) + ".") `') ('                -Detail ("The colr box says " + (Get-CodeName -Table $script:PrimariesNames -Code $vui.Primaries) +' + "`r`n" + '                         " and the bitstream says " + (Get-CodeName -Table $script:PrimariesNames -Code $colr.Primaries) + ".") `')),
    (New-Mut 'the transfer conflict names the container and the stream the wrong way round' ('                -Detail ("The colr box says " + (Get-CodeName -Table $script:TransferNames -Code $colr.Transfer) +' + "`r`n" + '                         " and the bitstream says " + (Get-CodeName -Table $script:TransferNames -Code $vui.Transfer) +') ('                -Detail ("The colr box says " + (Get-CodeName -Table $script:TransferNames -Code $vui.Transfer) +' + "`r`n" + '                         " and the bitstream says " + (Get-CodeName -Table $script:TransferNames -Code $colr.Transfer) +')),
    (New-Mut 'the range conflict names the container and the stream the wrong way round' ('                -Detail ("The colr box says " + (Get-RangeWord $colr.FullRange) + " and the bitstream says " +' + "`r`n" + '                         (Get-RangeWord $vui.FullRange) +') ('                -Detail ("The colr box says " + (Get-RangeWord $vui.FullRange) + " and the bitstream says " +' + "`r`n" + '                         (Get-RangeWord $colr.FullRange) +')),
    (New-Mut 'the size conflict names the sample entry and the bitstream the wrong way round' ('                -Detail ("The sample entry says " + $Track.Width + "x" + $Track.Height + " and the bitstream says " +' + "`r`n" + '                         $Track.Bitstream.Width + "x" + $Track.Bitstream.Height +') ('                -Detail ("The sample entry says " + $Track.Bitstream.Width + "x" + $Track.Bitstream.Height + " and the bitstream says " +' + "`r`n" + '                         $Track.Width + "x" + $Track.Height +')),
    (New-Mut 'the standard definition matrix finding prints the frame size as height by width' '                -Detail ("This is " + $Track.Width + "x" + $height + " but the matrix is " +' '                -Detail ("This is " + $height + "x" + $Track.Width + " but the matrix is " +'),
    (New-Mut 'the high definition matrix finding prints the frame size as height by width' '                -Detail ("This is " + $Track.Width + "x" + $height + " tagged BT.709. It may well be correct, but the fallback " +' '                -Detail ("This is " + $height + "x" + $Track.Width + " tagged BT.709. It may well be correct, but the fallback " +'),
    (New-Mut 'the icc profile size counts the four byte colour type as profile data' '            -Detail ("The colr box carries a " + $colr.IccBytes + " byte ICC profile. That is legal and precise, and most " +' '            -Detail ("The colr box carries a " + ($colr.IccBytes + 4) + " byte ICC profile. That is legal and precise, and most " +'),
    (New-Mut 'the invalid pasp finding prints the spacings the wrong way round' ('                -Detail ("pasp says " + $Track.Pasp.HSpacing + ":" + $Track.Pasp.VSpacing +' + "`r`n" + '                         ". A zero spacing is meaningless and different players round it differently.") `') ('                -Detail ("pasp says " + $Track.Pasp.VSpacing + ":" + $Track.Pasp.HSpacing +' + "`r`n" + '                         ". A zero spacing is meaningless and different players round it differently.") `')),
    (New-Mut 'the non square pasp finding prints the spacings the wrong way round' ('                -Detail ("pasp says " + $Track.Pasp.HSpacing + ":" + $Track.Pasp.VSpacing +' + "`r`n" + '                         ", so the picture is meant to be stretched on playback. Tools that ignore pasp will show it at the " +') ('                -Detail ("pasp says " + $Track.Pasp.VSpacing + ":" + $Track.Pasp.HSpacing +' + "`r`n" + '                         ", so the picture is meant to be stretched on playback. Tools that ignore pasp will show it at the " +')),
    (New-Mut 'the narrow gamut hdr finding names the transfer and the primaries the wrong way round' ('                -Detail ("The transfer is " + (Get-CodeName -Table $script:TransferNames -Code $transfer) +' + "`r`n" + '                         " but the primaries are " + (Get-CodeName -Table $script:PrimariesNames -Code $primaries) +') ('                -Detail ("The transfer is " + (Get-CodeName -Table $script:PrimariesNames -Code $primaries) +' + "`r`n" + '                         " but the primaries are " + (Get-CodeName -Table $script:TransferNames -Code $transfer) +'))
)

# ---------------------------------------------------------------------------
# validate every anchor before touching anything
# ---------------------------------------------------------------------------

# Counted by hand: .Count on a collection of hashtables is exactly the thing
# StrictMode 2.0 refuses to evaluate.
$m_count = 0
foreach ($mu in $muts) { $m_count = $m_count + 1 }

Write-Output ('validating ' + [string]$m_count + ' mutation anchors...')
$bad = 0
foreach ($mu in $muts) {
    $n = 0
    $idx = 0
    while ($true) {
        $idx = $m_original.IndexOf($mu.From, $idx)
        if ($idx -lt 0) { break }
        $n = $n + 1
        $idx = $idx + 1
    }
    if ($mu.MustSurvive) {
        # the tripwire anchor is allowed to be common; only the first hit is used
        if ($n -lt 1) { Write-Output ('  ANCHOR MISSING: ' + $mu.Name); $bad = $bad + 1 }
    } elseif ($n -ne 1) {
        Write-Output ('  ANCHOR MATCHES ' + [string]$n + ' TIMES: ' + $mu.Name)
        Write-Output ('    [' + $mu.From + ']')
        $bad = $bad + 1
    }
}
if ($bad -gt 0) {
    Write-Output ''
    Write-Output ([string]$bad + ' anchors are unusable; fix them before trusting this harness')
    exit 1
}
Write-Output 'all anchors resolve exactly once'
Write-Output ''
if ($ValidateOnly) { exit 0 }

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------

Copy-Item $m_tool $m_back -Force
[IO.File]::WriteAllText($m_mark, 'mutating')

$killed = 0
$survived = 0
$survivors = New-Object System.Collections.Generic.List[string]
$sw = [Diagnostics.Stopwatch]::StartNew()

# Resume state. $m_done is the number of mutants already decided; anything at
# or below it is replayed from the checkpoint instead of re-run.
$m_gen  = Join-Path $m_here 'mp4gen.ps1'
$m_hash = Get-SourceHash ($m_original + [IO.File]::ReadAllText($m_self) + [IO.File]::ReadAllText($m_real) + [IO.File]::ReadAllText($m_gen))
$m_done = 0
if ($Resume -and (Test-Path $m_prog)) {
    $ok = $true
    $pDone = 0; $pKilled = 0; $pSurv = 0; $pHash = ''; $pCount = 0
    $pNames = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content $m_prog -ErrorAction SilentlyContinue)) {
        $eq = ([string]$line).IndexOf('=')
        if ($eq -lt 1) { continue }
        $k = $line.Substring(0, $eq)
        $v = $line.Substring($eq + 1)
        if ($k -eq 'hash') { $pHash = $v }
        elseif ($k -eq 'count') { $pCount = [int]$v }
        elseif ($k -eq 'done') { $pDone = [int]$v }
        elseif ($k -eq 'killed') { $pKilled = [int]$v }
        elseif ($k -eq 'survived') { $pSurv = [int]$v }
        elseif ($k -eq 'survivor') { $pNames.Add($v) }
    }
    if ($pHash -ne $m_hash) { Write-Output 'checkpoint is for a different tool build; starting over'; $ok = $false }
    elseif ($pCount -ne $m_count) { Write-Output 'checkpoint is for a different mutant list; starting over'; $ok = $false }
    elseif ($pDone -lt 1 -or $pDone -ge $m_count) { $ok = $false }
    if ($ok) {
        $m_done = $pDone
        $killed = $pKilled
        $survived = $pSurv
        foreach ($n in $pNames) { $survivors.Add($n) }
        Write-Output ('resuming after mutant ' + [string]$m_done + ' of ' + [string]$m_count +
                      ' (' + [string]$killed + ' killed, ' + [string]$survived + ' survived so far)')
        Write-Output ''
    }
}

function Save-Progress {
    param([int]$Done, [int]$Killed, [int]$Survived, $Names, [string]$Hash, [int]$Count)
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine('hash=' + $Hash)
    [void]$sb.AppendLine('count=' + [string]$Count)
    [void]$sb.AppendLine('done=' + [string]$Done)
    [void]$sb.AppendLine('killed=' + [string]$Killed)
    [void]$sb.AppendLine('survived=' + [string]$Survived)
    foreach ($n in $Names) { [void]$sb.AppendLine('survivor=' + $n) }
    [IO.File]::WriteAllText($m_prog, $sb.ToString(), (New-Object Text.ASCIIEncoding))
}

try {
    # control: the unmodified tool must pass, or every "killed" below is noise
    if ($m_done -eq 0) {
        Write-Output 'baseline (unmodified tool)'
        $r = Invoke-Suite $m_self 2400
        if ($r.Code -ne 0) {
            Write-Output '  BASELINE FAILED: selftest does not pass on the unmodified tool'
            Write-Output $r.Out
            exit 1
        }
        Write-Output '  selftest passes'
        $r = Invoke-Suite $m_real 2400
        if ($r.Code -ne 0) {
            Write-Output '  BASELINE FAILED: realcheck does not pass on the unmodified tool'
            Write-Output $r.Out
            exit 1
        }
        Write-Output '  realcheck passes'
        Write-Output ''
    }

    $i = 0
    foreach ($mu in $muts) {
        $i = $i + 1
        if ($i -le $m_done) { continue }
        $idx = $m_original.IndexOf($mu.From)
        $mutated = $m_original.Substring(0, $idx) + $mu.To + $m_original.Substring($idx + $mu.From.Length)
        if ($mutated -eq $m_original) {
            Write-Output ('  ' + $mu.Name + ': mutation produced no change')
            exit 1
        }
        [IO.File]::WriteAllText($m_tool, $mutated)

        $by = ''
        $r = Invoke-Suite $m_self 2400 ' -StopOnFail'
        # A timeout is not a kill. Invoke-Suite reports -1 for "I could not
        # finish", and counting that as a dead mutant is how a busy machine
        # certifies coverage it does not have. Stop the round instead.
        if ($r.Out -eq 'TIMEOUT') {
            Write-Output ('  SUITE TIMEOUT: selftest did not finish on ' + $mu.Name)
            exit 1
        }
        if ($r.Code -ne 0) { $by = 'selftest' }
        if ($by -eq '') {
            $r = Invoke-Suite $m_real 2400 ' -StopOnFail'
            if ($r.Out -eq 'TIMEOUT') {
                Write-Output ('  SUITE TIMEOUT: realcheck did not finish on ' + $mu.Name)
                exit 1
            }
            if ($r.Code -ne 0) { $by = 'realcheck' }
        }

        $label = ([string]$i).PadLeft(2) + '/' + [string]$m_count + '  ' + $mu.Name
        if ($mu.MustSurvive) {
            if ($by -eq '') {
                Write-Output ($label + ' -> survived (correct, this one changes nothing)')
                $killed = $killed + 1
            } else {
                Write-Output ($label + ' -> KILLED BY ' + $by + ' - THE HARNESS IS LYING')
                # A tripwire changes no behaviour, so a suite that fails on
                # one is failing for a reason that has nothing to do with the
                # code under test. Keep the output. Without it the next
                # occurrence is another mystery, and the last one quietly
                # invalidated a whole gate.
                $dump = Join-Path $m_here ('tripwire-killed-' + $by + '-' + [string]$i + '.log')
                [IO.File]::WriteAllText($dump, [string]$r.Out + "`r`n---- stderr ----`r`n" + [string]$r.Err)
                Write-Output ('        evidence in ' + [IO.Path]::GetFileName($dump))
                $survivors.Add($mu.Name + ' (tripwire was killed by ' + $by + ')')
                $survived = $survived + 1
            }
        } else {
            if ($by -ne '') {
                Write-Output ($label + ' -> killed by ' + $by)
                $killed = $killed + 1
            } else {
                Write-Output ($label + ' -> SURVIVED')
                $survivors.Add($mu.Name)
                $survived = $survived + 1
            }
        }
        Save-Progress $i $killed $survived $survivors $m_hash $m_count
    }
} finally {
    [IO.File]::WriteAllText($m_tool, $m_original)
    Remove-Item $m_mark -Force -ErrorAction SilentlyContinue
    Remove-Item $m_back -Force -ErrorAction SilentlyContinue
}

$sw.Stop()

# the restore has to be exact, or the next round tests a damaged tool
$after = [IO.File]::ReadAllText($m_tool)
if ($after -ne $m_original) {
    Write-Output ''
    Write-Output 'RESTORE FAILED: colorcheck.ps1 does not match what we started with'
    exit 1
}

Write-Output ''
Write-Output ('mutation harness: ' + [string]$killed + ' of ' + [string]$m_count + ' handled correctly in ' + ('{0:F1}' -f $sw.Elapsed.TotalMinutes) + ' min')
if ($survived -gt 0) {
    Write-Output ''
    foreach ($s in $survivors) { Write-Output ('  SURVIVED ' + $s) }
    Write-Output ''
    Write-Output 'every survivor is a gap in the test suite'
    exit 1
}
# A finished round must not leave a checkpoint behind, or the next round would
# resume from it and do no work at all.
Remove-Item $m_prog -Force -ErrorAction SilentlyContinue
Write-Output 'mutation harness green - the tests catch every deliberate break'
exit 0
