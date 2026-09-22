<#
    realcheck.ps1 - colorcheck against real recordings.

    selftest.ps1 proves the parser against files this repository generates,
    which means it can only ever prove the parser agrees with the generator.
    This suite points the tool at whatever mp4 and mov files are actually on
    the machine and checks the answers against something independent: the
    Windows property system, a separate brute force scan written a different
    way, and the file on disk itself.

        powershell -NoProfile -ExecutionPolicy Bypass -File realcheck.ps1
#>

[CmdletBinding()]
param(
    [string] $Root = '',
    [int] $MaxFiles = 40,
    [switch] $StopOnFail
)

$ErrorActionPreference = 'Stop'

$script:Dir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Tool = Join-Path $script:Dir 'colorcheck.ps1'
if (-not (Test-Path $script:Tool)) { throw "colorcheck.ps1 not found next to realcheck.ps1" }

$script:Passed = 0
$script:Failed = 0
$script:Failures = New-Object System.Collections.ArrayList
$script:Group = ''
$script:GroupCount = 0
$script:Started = Get-Date

function Start-Group {
    param([string] $Name)
    $script:Group = $Name
    $script:GroupCount++
    Write-Host ("[" + $script:GroupCount + "] " + $Name) -ForegroundColor Cyan
}

function Pass { $script:Passed++ }

function Fail {
    param([string] $What, [string] $Detail)
    $script:Failed++
    $line = '    FAIL [' + $script:Group + '] ' + $What
    Write-Host $line -ForegroundColor Red
    if ($Detail -ne '') { Write-Host ('           ' + $Detail) -ForegroundColor DarkRed }
    [void]$script:Failures.Add($line + ' :: ' + $Detail)
    if ($StopOnFail) {
        # The mutation harness runs this suite once per mutant, so a failure
        # that skipped the cleanup would leave a folder of copied recordings
        # behind every single time.
        Write-Host ''
        Write-Host ('  stopped on the first failure after ' + $script:Passed + ' passed') -ForegroundColor Red
        Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue
        exit 1
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string] $What)
    $e = $(if ($null -eq $Expected) { '<null>' } else { [string]$Expected })
    $a = $(if ($null -eq $Actual) { '<null>' } else { [string]$Actual })
    if ($e -ceq $a) { Pass } else { Fail $What ("expected '" + $e + "' but got '" + $a + "'") }
}

function Assert-True {
    param($Condition, [string] $What)
    if ($Condition) { Pass } else { Fail $What 'expected true' }
}

function Assert-False {
    param($Condition, [string] $What)
    if (-not $Condition) { Pass } else { Fail $What 'expected false' }
}

function Assert-Match {
    param([string] $Text, [string] $Pattern, [string] $What)
    if ($null -ne $Text -and $Text -match $Pattern) { Pass }
    else { Fail $What ("'" + $Pattern + "' did not match") }
}

function Assert-NotNull {
    param($Value, [string] $What)
    if ($null -ne $Value) { Pass } else { Fail $What 'expected a value but got null' }
}

function Assert-Null {
    param($Value, [string] $What)
    if ($null -eq $Value) { Pass } else { Fail $What ("expected null but got '" + $Value + "'") }
}

function Invoke-Tool {
    param([string[]] $CliArgs)
    $all = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:Tool) + $CliArgs
    $out = & powershell @all 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}

# Passing an argument that ends in a backslash through the native command
# boundary is not safe: powershell quotes it, and the child's own command line
# parser reads the trailing \" as an escaped quote, so the argument swallows
# everything after it. Anything with a trailing backslash has to go through
# -Command, where powershell itself does the parsing.
function Invoke-ToolCommand {
    param([string] $CommandText)
    $out = & powershell -NoProfile -ExecutionPolicy Bypass -Command $CommandText 2>&1 | Out-String
    return [pscustomobject]@{ Out = $out; Exit = $LASTEXITCODE }
}

function Get-FileHashHex {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

# ---------------------------------------------------------------------------
# An independent reader, written on purpose in a different style to the one in
# the tool: a flat scan over the first part of the file looking for the four
# character codes, with no box walking at all. If the tool and this disagree
# about whether a colr box exists, one of them is wrong.
# ---------------------------------------------------------------------------

function Find-FourCCOffsets {
    param([byte[]] $Bytes, [string] $Code)
    $hits = New-Object System.Collections.ArrayList
    $c0 = [byte][char]$Code[0]; $c1 = [byte][char]$Code[1]
    $c2 = [byte][char]$Code[2]; $c3 = [byte][char]$Code[3]
    $last = $Bytes.Length - 4
    for ($i = 0; $i -le $last; $i++) {
        if ($Bytes[$i] -eq $c0 -and $Bytes[$i + 1] -eq $c1 -and $Bytes[$i + 2] -eq $c2 -and $Bytes[$i + 3] -eq $c3) {
            [void]$hits.Add($i)
        }
    }
    return @($hits.ToArray())
}

function Get-ShellProperty {
    param([string] $Path, [string[]] $Names)
    $result = @{}
    try {
        $shell = New-Object -ComObject Shell.Application
        $folder = $shell.Namespace((Split-Path -Parent $Path))
        if ($null -eq $folder) { return $result }
        $item = $folder.ParseName((Split-Path -Leaf $Path))
        if ($null -eq $item) { return $result }
        for ($i = 0; $i -lt 320; $i++) {
            $label = $folder.GetDetailsOf($null, $i)
            if ($null -eq $label -or $label -eq '') { continue }
            if ($Names -contains $label) {
                $value = $folder.GetDetailsOf($item, $i)
                if ($null -ne $value -and $value -ne '') { $result[$label] = $value }
            }
        }
    } catch { }
    return $result
}

function ConvertTo-Number {
    param([string] $Text)
    if ($null -eq $Text) { return $null }
    $digits = ($Text -replace '[^0-9]', '')
    if ($digits -eq '') { return $null }
    return [long]$digits
}

$script:Work = Join-Path $env:TEMP ('colorcheck-realcheck-' + $PID)
if (Test-Path $script:Work) { Remove-Item $script:Work -Recurse -Force }
New-Item -ItemType Directory -Path $script:Work -Force | Out-Null

Write-Host ''
Write-Host 'colorcheck realcheck' -ForegroundColor White
Write-Host ''

# ---------------------------------------------------------------------------

Start-Group 'finding real recordings'

$roots = @()
if ($Root -ne '') {
    $roots = @($Root)
} else {
    foreach ($r in @("$env:USERPROFILE\Videos", "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Documents",
                     "$env:USERPROFILE\Desktop", "$env:USERPROFILE\Pictures", "$env:USERPROFILE\OneDrive",
                     'C:\Users\Public')) {
        if (Test-Path $r) { $roots += $r }
    }
}

# Get-ChildItem -Include is ignored unless the path itself carries a wildcard,
# which silently returns every file on the disk instead of the media files.
# Filtering on the extension afterwards is the version that actually works.
$wanted = @('.mp4', '.mov', '.m4v')
$all = New-Object System.Collections.ArrayList
foreach ($r in $roots) {
    Get-ChildItem -LiteralPath $r -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $wanted -contains $_.Extension.ToLower() } |
        ForEach-Object { [void]$all.Add($_) }
}

$media = @($all | Sort-Object FullName -Unique | Sort-Object Length -Descending | Select-Object -First $MaxFiles)
Write-Host ('    ' + @($media).Count + ' file(s) found under ' + @($roots).Count + ' folder(s)') -ForegroundColor DarkGray

Assert-True (@($roots).Count -ge 1) 'at least one folder to search'
Assert-True (@($media).Count -ge 1) 'at least one real recording on this machine'

if (@($media).Count -eq 0) {
    Write-Host ''
    Write-Host '  no media found, nothing to check against' -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

$unique = @{}
foreach ($m in $media) {
    $h = Get-FileHashHex $m.FullName
    if (-not $unique.ContainsKey($h)) { $unique[$h] = $m }
}
$distinct = @($unique.Values)
Write-Host ('    ' + @($distinct).Count + ' distinct by content') -ForegroundColor DarkGray
Assert-True (@($distinct).Count -ge 1) 'at least one distinct recording'

# ---------------------------------------------------------------------------

Start-Group 'every real recording is readable'

$reports = @{}
foreach ($m in $media) {
    $run = Invoke-Tool @($m.FullName, '-Json')
    Assert-True ($run.Exit -ne 3) ('no internal bug on ' + $m.Name)
    $parsed = $null
    try { $parsed = $run.Out | ConvertFrom-Json } catch { }
    Assert-NotNull $parsed ('json parses for ' + $m.Name)
    if ($null -eq $parsed) { continue }
    $reports[$m.FullName] = $parsed
    $hasError = $false
    try { $hasError = ($null -ne $parsed.error) } catch { }
    Assert-False $hasError ('no read error on ' + $m.Name)
    Assert-Equal 'colorcheck' $parsed.tool ('the tool names itself for ' + $m.Name)
    Assert-Equal $m.Name $parsed.name ('the file is named for ' + $m.Name)
    Assert-Equal $m.Length $parsed.sizeBytes ('the size on disk matches for ' + $m.Name)
    Assert-True (@($parsed.tracks).Count -ge 1) ('at least one video track in ' + $m.Name)
    Assert-True ($parsed.brand.Length -ge 3) ('a brand was read from ' + $m.Name)
}

foreach ($m in $distinct) {
    $text = Invoke-Tool @($m.FullName, '-NoColor')
    Assert-True ($text.Exit -ne 3) ('the text report does not hit a bug on ' + $m.Name)
    Assert-Match $text.Out ([regex]::Escape($m.Name)) ('the text report names ' + $m.Name)
    Assert-Match $text.Out 'track 1' ('the text report shows a track for ' + $m.Name)
    Assert-Match $text.Out 'problems?, ' ('the text report totals the findings for ' + $m.Name)
}

# ---------------------------------------------------------------------------

Start-Group 'agreement with the windows property system'

$checkedShell = 0
$classedVideo = 0
foreach ($m in $distinct) {
    $r = $reports[$m.FullName]
    if ($null -eq $r) { continue }
    $props = Get-ShellProperty -Path $m.FullName -Names @('Frame width', 'Frame height', 'Video compression', 'Perceived type', 'Kind', 'Length')

    # The file system is a source of truth the tool never consults for size, so
    # a disagreement here means the tool reported a size it invented.
    $onDisk = (Get-Item -LiteralPath $m.FullName).Length
    Assert-Equal $onDisk $r.sizeBytes ('the reported size matches the file system for ' + $m.Name)

    # Windows classifies the file from its own registered handlers. If windows
    # calls it video, the tool had better have found a video track in it.
    $kind = $props['Perceived type']
    if ($null -eq $kind -or $kind -eq '') { $kind = $props['Kind'] }
    if ($null -ne $kind -and $kind -ne '') {
        $classedVideo++
        Assert-Match $kind 'Video' ('windows calls ' + $m.Name + ' a video')
        Assert-True (@($r.tracks).Count -ge 1) ('the tool found a video track in ' + $m.Name)
    }

    # Frame width and height only appear once windows has indexed the file, so
    # this is a bonus cross-check rather than one that can be relied on. When
    # it is there it is authoritative, because it comes from a completely
    # separate demuxer.
    $w = ConvertTo-Number $props['Frame width']
    $h = ConvertTo-Number $props['Frame height']
    if ($null -eq $w -or $null -eq $h) { continue }
    $checkedShell++
    $track = $r.tracks[0]
    Assert-Equal $w $track.width ('windows agrees about the width of ' + $m.Name)
    Assert-Equal $h $track.height ('windows agrees about the height of ' + $m.Name)
    if ($null -ne $track.bitstream) {
        # The container and the coded stream are two different records of the
        # same fact, and windows reads the container one. Agreeing with both
        # is the only way to know the bit reader landed on the right bits.
        Assert-Equal $w $track.bitstream.width ('the coded stream agrees about the width of ' + $m.Name)
        Assert-Equal $h $track.bitstream.height ('the coded stream agrees about the height of ' + $m.Name)
    }
}
Assert-True ($classedVideo -ge 1) 'windows classified at least one file as video'
Write-Host ("    frame size available from windows for " + $checkedShell + " of " + @($distinct).Count + " file(s)") -ForegroundColor DarkGray

# ---------------------------------------------------------------------------

Start-Group 'agreement with an independent scan'

foreach ($m in $distinct) {
    $r = $reports[$m.FullName]
    if ($null -eq $r) { continue }

    # The moov of a recording is small and sits at one end of the file, so
    # reading both ends is enough to find every sample entry box without
    # loading tens of megabytes.
    $take = [int][Math]::Min(4000000, $m.Length)
    $fs = New-Object System.IO.FileStream($m.FullName, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $head = New-Object byte[] $take
        [void]$fs.Read($head, 0, $take)
        $tailLen = [int][Math]::Min(4000000, $m.Length)
        $fs.Seek(-$tailLen, [System.IO.SeekOrigin]::End) | Out-Null
        $tail = New-Object byte[] $tailLen
        [void]$fs.Read($tail, 0, $tailLen)
    } finally { $fs.Dispose() }

    $colrHits = @(Find-FourCCOffsets -Bytes $head -Code 'colr').Count + @(Find-FourCCOffsets -Bytes $tail -Code 'colr').Count
    $toolHasColr = ($null -ne $r.tracks[0].colr)
    if ($toolHasColr) {
        Assert-True ($colrHits -ge 1) ('a raw scan also finds colr in ' + $m.Name)
    }

    $avcHits = @(Find-FourCCOffsets -Bytes $head -Code 'avcC').Count + @(Find-FourCCOffsets -Bytes $tail -Code 'avcC').Count
    $hvcHits = @(Find-FourCCOffsets -Bytes $head -Code 'hvcC').Count + @(Find-FourCCOffsets -Bytes $tail -Code 'hvcC').Count
    if ($null -ne $r.tracks[0].bitstream) {
        if ($r.tracks[0].bitstream.codec -eq 'H.264') {
            Assert-True ($avcHits -ge 1) ('a raw scan also finds avcC in ' + $m.Name)
        } else {
            Assert-True ($hvcHits -ge 1) ('a raw scan also finds hvcC in ' + $m.Name)
        }
    }

    $moovHits = @(Find-FourCCOffsets -Bytes $head -Code 'moov').Count + @(Find-FourCCOffsets -Bytes $tail -Code 'moov').Count
    Assert-True ($moovHits -ge 1) ('a raw scan finds moov in ' + $m.Name)

    $ftypHits = @(Find-FourCCOffsets -Bytes $head -Code 'ftyp').Count
    Assert-True ($ftypHits -ge 1) ('a raw scan finds ftyp in ' + $m.Name)

    # The codec four character code the tool reports must be in the file.
    $fmt = $r.tracks[0].format
    $fmtHits = @(Find-FourCCOffsets -Bytes $head -Code $fmt).Count + @(Find-FourCCOffsets -Bytes $tail -Code $fmt).Count
    Assert-True ($fmtHits -ge 1) ('the reported format ' + $fmt + ' really appears in ' + $m.Name)

    foreach ($box in @($r.tracks[0].childBoxes)) {
        $hits = @(Find-FourCCOffsets -Bytes $head -Code $box).Count + @(Find-FourCCOffsets -Bytes $tail -Code $box).Count
        Assert-True ($hits -ge 1) ('the reported child box ' + $box + ' really appears in ' + $m.Name)
    }
}

# ---------------------------------------------------------------------------

Start-Group 'internal agreement'

foreach ($m in $distinct) {
    $r = $reports[$m.FullName]
    if ($null -eq $r) { continue }
    $text = (Invoke-Tool @($m.FullName, '-Explain', '-NoColor')).Out

    $t = $r.tracks[0]
    Assert-Match $text ([regex]::Escape($t.width.ToString() + 'x' + $t.height.ToString())) ('the text and json agree on the size of ' + $m.Name)
    Assert-Match $text ([regex]::Escape($t.format)) ('the text and json agree on the format of ' + $m.Name)
    Assert-Match $text ([regex]::Escape($t.effective.matrixName)) ('the text and json agree on the matrix of ' + $m.Name)
    Assert-Match $text ([regex]::Escape($t.effective.rangeName)) ('the text and json agree on the range of ' + $m.Name)
    Assert-Match $text ([regex]::Escape($t.effective.statedIn)) ('the text and json agree on where the tags live in ' + $m.Name)

    $counted = 0
    foreach ($track in $r.tracks) { $counted += @($track.findings).Count }
    $total = $r.verdict.problems + $r.verdict.warnings + $r.verdict.notes
    Assert-Equal $counted $total ('the verdict counts every finding in ' + $m.Name)

    $expectedLabel = 'consistent'
    if ($r.verdict.problems -gt 0) { $expectedLabel = 'conflict' }
    elseif ($r.verdict.warnings -gt 0) { $expectedLabel = 'check this' }
    Assert-Equal $expectedLabel $r.verdict.label ('the verdict label follows the counts for ' + $m.Name)

    $run = Invoke-Tool @($m.FullName, '-NoColor')
    $expectedExit = $(if ($r.verdict.problems -gt 0) { 1 } else { 0 })
    Assert-Equal $expectedExit $run.Exit ('the exit code follows the verdict for ' + $m.Name)

    if ($null -ne $t.colr -and $null -ne $t.bitstream -and $null -ne $t.bitstream.vui -and $t.bitstream.vui.present) {
        if ($null -ne $t.colr.primaries -and $null -ne $t.bitstream.vui.primaries) {
            $agree = ($t.colr.matrix -eq $t.bitstream.vui.matrix)
            $reported = @($t.findings | ForEach-Object { $_.code }) -contains 'MATRIX_CONFLICT'
            Assert-Equal (-not $agree) $reported ('a matrix conflict is reported exactly when the two disagree in ' + $m.Name)
        }
    }
}

# ---------------------------------------------------------------------------

Start-Group 'determinism'

foreach ($m in $distinct) {
    $a = (Invoke-Tool @($m.FullName, '-Json')).Out
    $b = (Invoke-Tool @($m.FullName, '-Json')).Out
    Assert-Equal $a.Trim() $b.Trim() ('two runs over ' + $m.Name + ' produce the same json')
}

# ---------------------------------------------------------------------------

Start-Group 'the file on disk is left alone'

foreach ($m in $distinct) {
    $before = Get-FileHashHex $m.FullName
    $beforeWrite = (Get-Item -LiteralPath $m.FullName).LastWriteTimeUtc
    [void](Invoke-Tool @($m.FullName, '-Explain', '-NoColor'))
    [void](Invoke-Tool @($m.FullName, '-Json'))
    $after = Get-FileHashHex $m.FullName
    $afterWrite = (Get-Item -LiteralPath $m.FullName).LastWriteTimeUtc
    Assert-Equal $before $after ('the bytes of ' + $m.Name + ' are unchanged')
    Assert-Equal $beforeWrite.Ticks $afterWrite.Ticks ('the timestamp of ' + $m.Name + ' is unchanged')
}

$strayBefore = @(Get-ChildItem -LiteralPath $script:Work -Force -ErrorAction SilentlyContinue).Count
[void](Invoke-Tool @($distinct[0].FullName, '-NoColor'))
$strayAfter = @(Get-ChildItem -LiteralPath $script:Work -Force -ErrorAction SilentlyContinue).Count
Assert-Equal $strayBefore $strayAfter 'the tool writes nothing beside the file it reads'

# ---------------------------------------------------------------------------

Start-Group 'a recording still being written'

$sharedCopy = Join-Path $script:Work 'still-recording.mp4'
Copy-Item -LiteralPath $distinct[0].FullName -Destination $sharedCopy -Force

$holder = New-Object System.IO.FileStream($sharedCopy, [System.IO.FileMode]::Open,
              [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
try {
    $held = Invoke-Tool @($sharedCopy, '-NoColor')
    Assert-True ($held.Exit -ne 3) 'a file held open for writing does not trip a bug'
    Assert-Match $held.Out 'still-recording\.mp4' 'a file held open for writing is still read'
    Assert-Match $held.Out 'track 1' 'a file held open for writing still yields a track'
} finally {
    $holder.Dispose()
}

# ---------------------------------------------------------------------------

Start-Group 'large files are not read whole'

$biggest = @($distinct | Sort-Object Length -Descending)[0]

# colorcheck seeks to the moov and reads the colour boxes, never the media,
# so the cost must not follow the size of the recording.
#
# A fixed ceiling in seconds is a lie on a busy machine. It passes on an idle
# box and fails on a healthy tool the moment something else takes the cores,
# and inside the mutation harness a spurious suite failure reads as "the
# mutant was killed" - which hides real gaps and murders tripwires. It did
# exactly that here: five tripwires died in a single round and the gate
# banked it as green.
#
# Comparing against a whole file read is no better once the recording is
# small enough to sit in the cache, because then the constant is doing all
# the work. So the claim is made against the tool itself: the same file, two
# gigabytes longer, measured back to back. Both numbers feel the same load,
# and the padding is never read, so neither contention nor the cache can move
# the answer. Growing a copy does not write the padding, so it is free.
$padded = Join-Path $script:Work ('padded-' + $biggest.Name)
Copy-Item -LiteralPath $biggest.FullName -Destination $padded -Force
$grow = [IO.File]::Open($padded, [IO.FileMode]::Open, [IO.FileAccess]::Write)
try { $grow.SetLength($biggest.Length + 2GB) } finally { $grow.Dispose() }
Assert-Equal ($biggest.Length + 2GB) (Get-Item -LiteralPath $padded).Length 'the padded copy really is two gigabytes longer'

# The first read of a file that was created moments ago can carry one-off
# costs that have nothing to do with the tool: the filesystem settling, a
# scanner looking at new content, a cold cache. Both files therefore get an
# untimed run first. What is being claimed is the steady state cost, so
# anything that is paid only once belongs outside the clock. It costs about
# two seconds on this suite and brings the two timings to within a few
# milliseconds of each other.
[void](Invoke-Tool @($biggest.FullName, '-Json'))
[void](Invoke-Tool @($padded, '-Json'))

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$fast = Invoke-Tool @($biggest.FullName, '-Json')
$sw.Stop()
$plainSecs = $sw.Elapsed.TotalSeconds
Assert-True ($fast.Exit -ne 3) 'the biggest file does not trip a bug'
Write-Host ('    ' + [int]$sw.Elapsed.TotalMilliseconds + ' ms for ' + [int]($biggest.Length / 1MB) + ' MB') -ForegroundColor DarkGray

$padWatch = [System.Diagnostics.Stopwatch]::StartNew()
$padRes = Invoke-Tool @($padded, '-Json')
$padWatch.Stop()
$padSecs = $padWatch.Elapsed.TotalSeconds
Write-Host ('    ' + [int]$padWatch.Elapsed.TotalMilliseconds + ' ms for the same file two gigabytes longer') -ForegroundColor DarkGray
Assert-True ($padRes.Exit -ne 3) 'the padded file does not trip a bug'
# Three times plus two seconds is enormous head room for jitter, and still
# nowhere near what reading two gigabytes of padding would cost.
Assert-True ($padSecs -lt ($plainSecs * 3 + 2)) 'a large file is answered without reading all of it'
Remove-Item $padded -Force -ErrorAction SilentlyContinue

# The whole file read is kept as a witness that the recording really is
# intact and readable end to end, reported but never used as a clock.
# ReadAllBytes throws above two gigabytes and a real capture passes that
# easily, so the reference read streams.
$copyWatch = [System.Diagnostics.Stopwatch]::StartNew()
$bytesRead = [int64]0
$refStream = [IO.File]::Open($biggest.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
try {
    $refBuf = New-Object byte[] (1MB)
    while ($true) {
        $refGot = $refStream.Read($refBuf, 0, $refBuf.Length)
        if ($refGot -le 0) { break }
        $bytesRead = $bytesRead + $refGot
    }
} finally { $refStream.Dispose() }
$copyWatch.Stop()
Assert-Equal $biggest.Length $bytesRead 'the reference read really read the whole file'
Write-Host ('    ' + [int]$copyWatch.Elapsed.TotalMilliseconds + ' ms to read every byte for comparison') -ForegroundColor DarkGray

# ---------------------------------------------------------------------------

Start-Group 'real recordings with the colour box rewritten'

function Find-ColrBoxOffset {
    param([string] $Path)
    $len = (Get-Item -LiteralPath $Path).Length
    $take = [int][Math]::Min(4000000, $len)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $head = New-Object byte[] $take
        [void]$fs.Read($head, 0, $take)
        $headHits = @(Find-FourCCOffsets -Bytes $head -Code 'colr')
        foreach ($h in $headHits) {
            if ($h -lt 4) { continue }
            $size = ([int]$head[$h - 4] -shl 24) -bor ([int]$head[$h - 3] -shl 16) -bor ([int]$head[$h - 2] -shl 8) -bor [int]$head[$h - 1]
            if ($size -eq 19) { return ($h - 4) }
        }
        $tailLen = [int][Math]::Min(4000000, $len)
        $fs.Seek(-$tailLen, [System.IO.SeekOrigin]::End) | Out-Null
        $tail = New-Object byte[] $tailLen
        [void]$fs.Read($tail, 0, $tailLen)
        $base = $len - $tailLen
        foreach ($h in @(Find-FourCCOffsets -Bytes $tail -Code 'colr')) {
            if ($h -lt 4) { continue }
            $size = ([int]$tail[$h - 4] -shl 24) -bor ([int]$tail[$h - 3] -shl 16) -bor ([int]$tail[$h - 2] -shl 8) -bor [int]$tail[$h - 1]
            if ($size -eq 19) { return ($base + $h - 4) }
        }
    } finally { $fs.Dispose() }
    return -1
}

function Set-BytesAt {
    param([string] $Path, [long] $Offset, [byte[]] $Value)
    $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $fs.Write($Value, 0, $Value.Length)
    } finally { $fs.Dispose() }
}

$donor = @($distinct | Sort-Object Length)[0]
$donorReport = $reports[$donor.FullName]
$donorHasColr = ($null -ne $donorReport -and $null -ne $donorReport.tracks[0].colr)
Assert-True $donorHasColr ('the smallest recording ' + $donor.Name + ' carries a colr box to rewrite')

$colrAt = -1
if ($donorHasColr) { $colrAt = Find-ColrBoxOffset $donor.FullName }
Assert-True ($colrAt -ge 0) 'the colour box was located in the real recording'

if ($colrAt -ge 0) {
    $vuiRange = $donorReport.tracks[0].bitstream.vui.fullRange
    $vuiMatrix = $donorReport.tracks[0].bitstream.vui.matrix

    # Flipping only the range byte leaves everything else in the file exactly
    # as the recorder wrote it, so any finding is caused by that one byte.
    $flip = Join-Path $script:Work 'range-flipped.mp4'
    Copy-Item -LiteralPath $donor.FullName -Destination $flip -Force
    $newRange = $(if ($vuiRange) { [byte]0x00 } else { [byte]0x80 })
    Set-BytesAt -Path $flip -Offset ($colrAt + 8 + 4 + 6) -Value @($newRange)
    $flipped = (Invoke-Tool @($flip, '-Json')).Out | ConvertFrom-Json
    $flipCodes = @($flipped.tracks[0].findings | ForEach-Object { $_.code })
    Assert-True ($flipCodes -contains 'RANGE_CONFLICT') 'flipping one range bit in a real file is caught'
    Assert-Equal 'conflict' $flipped.verdict.label 'flipping one range bit gives a conflict verdict'
    Assert-Equal 1 (Invoke-Tool @($flip, '-NoColor')).Exit 'flipping one range bit exits one'
    Assert-Equal $donorReport.tracks[0].width $flipped.tracks[0].width 'flipping one range bit leaves the size alone'

    # 6 is the 525 line standard definition matrix, which is wrong for HD.
    $sd = Join-Path $script:Work 'sd-matrix.mp4'
    Copy-Item -LiteralPath $donor.FullName -Destination $sd -Force
    Set-BytesAt -Path $sd -Offset ($colrAt + 8 + 4 + 4) -Value @([byte]0x00, [byte]0x06)
    $sdReport = (Invoke-Tool @($sd, '-Json')).Out | ConvertFrom-Json
    $sdCodes = @($sdReport.tracks[0].findings | ForEach-Object { $_.code })
    Assert-Equal 6 $sdReport.tracks[0].colr.matrix 'the rewritten matrix is read back'
    if ($sdReport.tracks[0].height -ge 720) {
        Assert-True ($sdCodes -contains 'SD_MATRIX_ON_HD') 'a standard definition matrix written into a real hd file is caught'
    }
    if ($null -ne $vuiMatrix -and $vuiMatrix -ne 6) {
        Assert-True ($sdCodes -contains 'MATRIX_CONFLICT') 'the rewritten matrix disagrees with the untouched stream'
    }

    # nclc is the same ten bytes with a different label and no range flag.
    $nclc = Join-Path $script:Work 'as-nclc.mp4'
    Copy-Item -LiteralPath $donor.FullName -Destination $nclc -Force
    Set-BytesAt -Path $nclc -Offset ($colrAt + 8) -Value ([byte[]][char[]]'nclc')
    $nclcReport = (Invoke-Tool @($nclc, '-Json')).Out | ConvertFrom-Json
    Assert-Equal 'nclc' $nclcReport.tracks[0].colr.kind 'the rewritten colour box kind is read back'
    Assert-Null $nclcReport.tracks[0].colr.fullRange 'an nclc box in a real file states no range'
    $nclcCodes = @($nclcReport.tracks[0].findings | ForEach-Object { $_.code })
    Assert-True ($nclcCodes -contains 'NCLC_NO_RANGE') 'an nclc box in a real file is noted'

    # A label no reader knows is a fact about the file, not a crash.
    $junk = Join-Path $script:Work 'junk-kind.mp4'
    Copy-Item -LiteralPath $donor.FullName -Destination $junk -Force
    Set-BytesAt -Path $junk -Offset ($colrAt + 8) -Value ([byte[]][char[]]'zzzz')
    $junkRun = Invoke-Tool @($junk, '-NoColor')
    Assert-Equal 2 $junkRun.Exit 'an unknown colour box type is reported as unreadable, not a bug'
    Assert-Match $junkRun.Out 'colorcheck/colr' 'an unknown colour box type is tagged as a colr problem'
}

# ---------------------------------------------------------------------------

Start-Group 'damaged real recordings'

$donorBytes = [IO.File]::ReadAllBytes($donor.FullName)

$halfPath = Join-Path $script:Work 'half.mp4'
[IO.File]::WriteAllBytes($halfPath, [byte[]]($donorBytes[0..([int]($donorBytes.Length / 2))]))
$half = Invoke-Tool @($halfPath, '-NoColor')
Assert-True ($half.Exit -eq 0 -or $half.Exit -eq 1 -or $half.Exit -eq 2) 'half a recording gives a sane exit code'
Assert-True ($half.Exit -ne 3) 'half a recording is not an internal bug'

$headPath = Join-Path $script:Work 'head-only.mp4'
[IO.File]::WriteAllBytes($headPath, [byte[]]($donorBytes[0..2000]))
$head = Invoke-Tool @($headPath, '-NoColor')
Assert-Equal 2 $head.Exit 'a file cut off before the moov is unreadable'
Assert-Match $head.Out 'colorcheck/' 'a file cut off before the moov says why'

$zeroPath = Join-Path $script:Work 'zero.mp4'
[IO.File]::WriteAllBytes($zeroPath, (New-Object byte[] 0))
Assert-Equal 2 (Invoke-Tool @($zeroPath, '-NoColor')).Exit 'an empty file is unreadable'

$textPath = Join-Path $script:Work 'text.mp4'
Set-Content -LiteralPath $textPath -Value ('not a recording ' * 500) -Encoding ASCII
$textRun = Invoke-Tool @($textPath, '-NoColor')
Assert-Equal 2 $textRun.Exit 'a text file with an mp4 name is unreadable'
Assert-True ($textRun.Exit -ne 3) 'a text file with an mp4 name is not an internal bug'

# One flipped byte deep in the sample data must not change the answer, because
# the tool never looks there.
$mdatPath = Join-Path $script:Work 'mdat-damaged.mp4'
$damaged = [byte[]]$donorBytes.Clone()
$mid = [int]($damaged.Length / 2)
for ($i = 0; $i -lt 256; $i++) { $damaged[$mid + $i] = [byte](255 - $damaged[$mid + $i]) }
[IO.File]::WriteAllBytes($mdatPath, $damaged)
$damagedReport = (Invoke-Tool @($mdatPath, '-Json')).Out | ConvertFrom-Json
Assert-Equal $donorReport.tracks[0].width $damagedReport.tracks[0].width 'damage in the sample data does not change the width'
Assert-Equal $donorReport.tracks[0].effective.matrixName $damagedReport.tracks[0].effective.matrixName 'damage in the sample data does not change the matrix'
Assert-Equal $donorReport.verdict.label $damagedReport.verdict.label 'damage in the sample data does not change the verdict'

# ---------------------------------------------------------------------------

Start-Group 'paths and folders'

$spaced = Join-Path $script:Work 'a folder with spaces'
New-Item -ItemType Directory -Path $spaced -Force | Out-Null
$spacedFile = Join-Path $spaced 'my recording (1).mp4'
Copy-Item -LiteralPath $donor.FullName -Destination $spacedFile -Force
$spacedRun = Invoke-Tool @($spacedFile, '-NoColor')
Assert-True ($spacedRun.Exit -ne 3) 'a path with spaces and brackets does not trip a bug'
Assert-Match $spacedRun.Out 'my recording' 'a path with spaces and brackets is read'

$bracketFile = Join-Path $spaced 'clip[1].mp4'
Copy-Item -LiteralPath $donor.FullName -Destination $bracketFile -Force
$bracketRun = Invoke-Tool @($bracketFile, '-NoColor')
Assert-True ($bracketRun.Exit -ne 3) 'a name with square brackets does not trip a bug'
Assert-Match $bracketRun.Out 'clip' 'a name with square brackets is read'

$folderRun = Invoke-Tool @($spaced, '-NoColor')
Assert-Match $folderRun.Out 'files read' 'a folder with spaces reports a total'
Assert-Match $folderRun.Out 'my recording' 'a folder run reaches the first file'
Assert-Match $folderRun.Out 'clip' 'a folder run reaches the second file'

$trailing = $spaced + '\'
$trailingCmd = '& ' + "'" + $script:Tool + "'" + ' -Path ' + "'" + $trailing + "'" + ' -NoColor'
$trailingRun = Invoke-ToolCommand $trailingCmd
Assert-True ($trailingRun.Exit -ne 3) 'a trailing backslash does not trip a bug'
Assert-Match $trailingRun.Out 'my recording' 'a trailing backslash still finds the files'

$filterRun = Invoke-Tool @($spaced, '-Filter', 'clip*', '-NoColor')
Assert-Match $filterRun.Out 'clip' 'a filter over real files matches'
Assert-True ($filterRun.Out -notmatch 'my recording') 'a filter over real files excludes the rest'

$recurseRun = Invoke-Tool @($script:Work, '-Recurse', '-NoColor')
Assert-Match $recurseRun.Out 'my recording' 'recurse reaches into the subfolder'
Assert-True ($recurseRun.Exit -ne 3) 'a recursive run over damaged files does not trip a bug'
Assert-Match $recurseRun.Out 'skipped' 'a recursive run reports the files it could not read'

$jsonFolder = (Invoke-Tool @($spaced, '-Json')).Out | ConvertFrom-Json
Assert-Equal 2 @($jsonFolder).Count 'a folder in json yields one object per file'

$quietFolder = Invoke-Tool @($spaced, '-Quiet', '-NoColor')
Assert-True ($quietFolder.Exit -ne 3) 'a quiet folder run does not trip a bug'

# ---------------------------------------------------------------------------

Start-Group 'version and help against the real tool'

$ver = Invoke-Tool @('-Version')
Assert-Match $ver.Out 'colorcheck \d+\.\d+\.\d+' 'the version line is well formed'
Assert-Equal 0 $ver.Exit 'the version flag exits zero'

$help = Invoke-Tool @('-Help')
Assert-Match $help.Out 'colr box' 'the help explains what it reads'
Assert-Equal 0 $help.Exit 'the help exits zero'

$toolBytes = [IO.File]::ReadAllBytes($script:Tool)
$nonAscii = 0
foreach ($b in $toolBytes) { if ($b -gt 126) { $nonAscii++ } }
Assert-Equal 0 $nonAscii 'the published tool is pure ascii'

# ---------------------------------------------------------------------------

Remove-Item $script:Work -Recurse -Force -ErrorAction SilentlyContinue

$elapsed = [int]((Get-Date) - $script:Started).TotalSeconds
Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host ("  " + $script:Passed + " passed, 0 failed in " + $elapsed + " s across " + $script:GroupCount + " groups") -ForegroundColor Green
} else {
    Write-Host ("  " + $script:Passed + " passed, " + $script:Failed + " FAILED in " + $elapsed + " s across " + $script:GroupCount + " groups") -ForegroundColor Red
    Write-Host ''
    foreach ($f in $script:Failures) { Write-Host ('  ' + $f) -ForegroundColor DarkRed }
}
Write-Host ''

if ($script:Failed -ne 0) { exit 1 }
exit 0
