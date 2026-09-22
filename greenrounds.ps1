# greenrounds.ps1 - run the full gate three times in a row.
#
# One mutate.ps1 run is a complete round: it starts with a baseline selftest
# and realcheck on the unmodified tool, then injects every mutation. Three
# consecutive clean rounds is the ship gate.
#
# This machine reboots without warning and a round takes over half an hour, so
# nothing here assumes it will be allowed to finish. Rounds already graded
# green are skipped, an interrupted round resumes from mutate.ps1's checkpoint,
# and each attempt writes its own log part so that grading can see the whole
# history rather than just the last attempt. Re-running this script after a
# reboot is always the right move.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$g_here = Split-Path -Parent $MyInvocation.MyCommand.Path
$g_log = Join-Path $g_here 'greenrounds.log'
$g_status = Join-Path $g_here 'greenrounds.status'
$g_mut = Join-Path $g_here 'mutate.ps1'
$g_ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

# A banked round is only evidence about the tool and suites that produced it.
# Editing an assertion between rounds and then counting an older log would be
# a green that means nothing, so every log part is stamped with a hash of the
# files that decide what "killed" means, and a part whose stamp does not match
# is discarded on sight. mp4gen.ps1 is one of them: selftest.ps1 dot-sources it,
# so editing the fixture generator changes which mutants are reachable at all.
# It was left out of this hash once and the omission was invisible, because a
# stale banked round looks exactly like a fresh one.
#
# Mid-round the tool on disk is a mutant, which would hash differently and
# throw away perfectly good banked rounds on every resume. While the harness
# says it is mutating, hash the pristine backup instead. Between rounds there
# is no marker and the live tool is hashed, so an edit is still noticed.
function Get-GateHash {
    $tool = Join-Path $g_here 'colorcheck.ps1'
    if ((Test-Path (Join-Path $g_here '.mutate-in-progress')) -and
        (Test-Path (Join-Path $g_here 'colorcheck.ps1.mutbak'))) {
        $tool = Join-Path $g_here 'colorcheck.ps1.mutbak'
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $text = [IO.File]::ReadAllText($tool)
        foreach ($f in @('selftest.ps1', 'realcheck.ps1', 'mp4gen.ps1', 'mutate.ps1')) {
            $text = $text + [IO.File]::ReadAllText((Join-Path $g_here $f))
        }
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text))).Replace('-', '')
    } finally { $sha.Dispose() }
}
$g_hash = Get-GateHash
$g_stampFile = Join-Path $g_here 'gate.stamp'
$g_oldHash = ''
if (Test-Path $g_stampFile) { $g_oldHash = (Get-Content $g_stampFile -Raw).Trim() }

function G-Log {
    param([string]$Text)
    $line = (Get-Date).ToString('HH:mm:ss') + '  ' + $Text
    Add-Content -Path $g_log -Value $line -Encoding ASCII
}

Add-Content -Path $g_log -Value '' -Encoding ASCII
Set-Content -Path $g_status -Value 'running' -Encoding ASCII
G-Log '--- gate runner starting ---'

# A suite that times out is killed, but the tool process it started is not: it
# can sit blocked in a COM call for an hour still holding the redirected log
# handles it inherited, which makes the round logs undeletable and stalls the
# next launch completely. Sweep them before touching anything else.
#
# Match "-File <the script>" and nothing looser. A first version matched any
# command line mentioning the build directory and promptly killed the shell
# that had just launched the gate, because that shell's own command line
# quoted the same path.
$g_targets = @()
foreach ($n in @('colorcheck.ps1', 'mutate.ps1', 'selftest.ps1', 'realcheck.ps1')) {
    $g_targets = $g_targets + ('-File ' + (Join-Path $g_here $n))
    $g_targets = $g_targets + ('-File "' + (Join-Path $g_here $n) + '"')
}
$g_stale = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object {
                 if ($_.ProcessId -eq $PID -or -not $_.CommandLine) { return $false }
                 $cl = $_.CommandLine
                 $hit = $false
                 foreach ($t in $g_targets) { if ($cl.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) { $hit = $true } }
                 return $hit
             })
foreach ($sp in $g_stale) {
    G-Log ('killing a leftover process from an earlier attempt: pid ' + [string]$sp.ProcessId)
    Stop-Process -Id $sp.ProcessId -Force -ErrorAction SilentlyContinue
}
if ($g_stale.Count -gt 0) { Start-Sleep -Seconds 5 }

if ($g_oldHash -ne '' -and $g_oldHash -ne $g_hash) {
    # The tool or a suite changed since these logs were written. They are not
    # evidence about the current build, so throw them away and start over
    # rather than banking a round that tested something else.
    G-Log 'tool or suites changed since the last attempt - discarding all banked rounds'
    $g_stuck = 0
    foreach ($f in @(Get-ChildItem -Path $g_here -Filter 'round*.part*.*' -ErrorAction SilentlyContinue)) {
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        if (Test-Path $f.FullName) {
            $g_stuck = $g_stuck + 1
            G-Log ('  could not delete ' + $f.Name + ' - a killed run left a child process holding the handle')
        }
    }
    Remove-Item (Join-Path $g_here 'mutate.progress') -Force -ErrorAction SilentlyContinue
    if ($g_stuck -gt 0) {
        # Grading a log written by a different build is the one mistake that
        # produces a false green, so refuse to run rather than risk it.
        G-Log 'refusing to start: stale logs could not be removed'
        Set-Content -Path $g_status -Value 'stale logs locked' -Encoding ASCII
        exit 3
    }
}
Set-Content -Path $g_stampFile -Value $g_hash -Encoding ASCII
G-Log ('gate stamp ' + $g_hash.Substring(0, 16))

function Get-Parts {
    param([int]$Round)
    # Comma-wrapped: a plain "return @(...)" unrolls, so an empty result comes
    # back as $null and StrictMode refuses .Count on it.
    # Sort by the part NUMBER, not the name. Sorting by name is lexical, so
    # 'round2.part10.log' lands before 'round2.part2.log' and the grader reads
    # the wrong part as the last one. An interrupted gate really does reach
    # double digit parts.
    $found = @(Get-ChildItem -Path $g_here -Filter ('round' + [string]$Round + '.part*.log') -ErrorAction SilentlyContinue |
               Sort-Object @{ Expression = { [int]([regex]::Match($_.Name, '\.part(\d+)\.log$').Groups[1].Value) } })
    return ,$found
}

function Get-MutantCount {
    $f = Join-Path $g_here 'muts.txt'
    if (-not (Test-Path $f)) { return -1 }
    # '@@!' starts with '@@' too, so this counts tripwires as well.
    return @(Get-Content $f | Where-Object { $_ -like '@@*' }).Count
}

# Grade a round from what it printed, not from its exit code. Start-Process
# -PassThru hands back a Process whose ExitCode is empty unless .Handle was
# read before the wait, and an empty exit code is not a failure.
#
# Returns '' for green, otherwise the reason it is not green. A round that was
# merely interrupted reports 'incomplete', which is resumable rather than fatal.
function Test-Round {
    param([int]$Round)
    $parts = Get-Parts $Round
    if ($parts.Count -eq 0) { return 'incomplete' }
    $all = New-Object System.Collections.Generic.List[string]
    foreach ($p in $parts) {
        foreach ($l in @(Get-Content $p.FullName -ErrorAction SilentlyContinue)) { $all.Add($l) }
    }
    # Case sensitive SURVIVED anywhere, not '-> SURVIVED'. The harness also
    # repeats every survivor in its summary as '  SURVIVED <name>', which has
    # no arrow, and a grader that only knew the arrow form once banked a
    # round containing five dead tripwires as green. Tripwires that behave
    # print lowercase 'survived (correct...)' and are not matched here.
    $surv = @($all | Where-Object { $_ -cmatch 'SURVIVED' })
    if ($surv.Count -gt 0) { return ([string]$surv.Count + ' survivor line(s)') }
    if (@($all | Where-Object { $_ -match 'THE HARNESS IS LYING' }).Count -gt 0) { return 'tripwire was killed' }
    if (@($all | Where-Object { $_ -match 'RESTORE FAILED' }).Count -gt 0) { return 'restore failed' }
    if (@($all | Where-Object { $_ -match 'BASELINE FAILED' }).Count -gt 0) { return 'baseline failed' }
    if (@($all | Where-Object { $_ -match 'SUITE TIMEOUT' }).Count -gt 0) { return 'a suite timed out' }

    # The LAST part is the one that finished the round. Earlier parts are
    # truncated logs from runs that were killed part way. They still carry
    # failure evidence - every signal above is scanned across ALL parts, so a
    # survivor recorded in a dead part still fails the round - but they cannot
    # be expected to print a green line.
    #
    # Demanding green from every part deadlocks the gate. A resumed round
    # always leaves a green-less predecessor, so it grades 'incomplete'
    # forever, and each restart appends one more part that can never satisfy
    # the rule either. muxcheck's round 2 completed 197 of 197 at 23:51 and
    # was still told it had not finished.
    #
    # mutate.ps1 -Resume prints a CUMULATIVE tally, so the final summary line
    # of the last part speaks for the whole round. Summing the tallies across
    # parts is wrong for the same reason: two parts that each ran the full set
    # would add up to double the mutant count and read as a failure.
    $lastPart = $parts[$parts.Count - 1]
    $lastLines = @(Get-Content $lastPart.FullName -ErrorAction SilentlyContinue)
    if (@($lastLines | Where-Object { $_ -match '^mutation harness green' }).Count -eq 0) { return 'incomplete' }

    # Trusting the word green alone is how a short run looks finished, so the
    # tally still has to account for every mutant in muts.txt.
    $tally = $null
    foreach ($l in $lastLines) {
        $mm = [regex]::Match($l, '^mutation harness: (\d+) of (\d+) handled correctly')
        if ($mm.Success) { $tally = $mm }
    }
    if ($tally -eq $null) { return 'incomplete' }
    if ($tally.Groups[1].Value -ne $tally.Groups[2].Value) { return 'a part left mutants unhandled' }
    $want = Get-MutantCount
    if ([int]$tally.Groups[2].Value -ne $want) {
        return ('only ' + $tally.Groups[2].Value + ' of ' + [string]$want + ' mutants ran')
    }
    return ''
}

$sw = [Diagnostics.Stopwatch]::StartNew()
$round = 0

while ($round -lt 3) {
    $round = $round + 1

    # Everything already on disk is re-graded rather than trusted.
    $verdict = Test-Round $round
    if ($verdict -eq '') {
        $parts = Get-Parts $round
        $sum = @()
        foreach ($p in $parts) {
            foreach ($l in @(Get-Content $p.FullName)) { if ($l -like 'mutation harness:*') { $sum = $sum + $l } }
        }
        $tail = 'already green'
        if ($sum.Count -gt 0) { $tail = $sum[$sum.Count - 1] }
        G-Log ('round ' + [string]$round + ' GREEN (banked) - ' + $tail)
        continue
    }
    if ($verdict -ne 'incomplete') {
        G-Log ('round ' + [string]$round + ' FAILED: ' + $verdict)
        Set-Content -Path $g_status -Value ('failed round ' + [string]$round) -Encoding ASCII
        exit 1
    }

    $existing = (Get-Parts $round).Count
    $part = $existing + 1
    if ($existing -gt 0) { G-Log ('round ' + [string]$round + ' was interrupted; resuming as part ' + [string]$part) }
    else { G-Log ('round ' + [string]$round + ' of 3 starting') }

    $out = Join-Path $g_here ('round' + [string]$round + '.part' + [string]$part + '.log')
    $err = Join-Path $g_here ('round' + [string]$round + '.part' + [string]$part + '.err')
    $pr = Start-Process -FilePath $g_ps `
        -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $g_mut, '-Resume' `
        -WorkingDirectory $g_here `
        -RedirectStandardOutput $out -RedirectStandardError $err `
        -WindowStyle Hidden -PassThru
    # Read the handle before waiting or ExitCode comes back empty.
    $null = $pr.Handle
    $pr.WaitForExit()

    $verdict = Test-Round $round
    if ($verdict -eq 'incomplete') {
        G-Log ('round ' + [string]$round + ' did not finish - run this script again to resume')
        Set-Content -Path $g_status -Value ('interrupted round ' + [string]$round) -Encoding ASCII
        exit 2
    }
    if ($verdict -ne '') {
        G-Log ('round ' + [string]$round + ' FAILED: ' + $verdict)
        foreach ($t in @(Get-Content $out -ErrorAction SilentlyContinue | Select-Object -Last 25)) { G-Log ('  | ' + $t) }
        Set-Content -Path $g_status -Value ('failed round ' + [string]$round) -Encoding ASCII
        exit 1
    }

    $summary = @(Get-Content $out | Where-Object { $_ -like 'mutation harness:*' })
    $tail = 'green'
    if ($summary.Count -gt 0) { $tail = $summary[$summary.Count - 1] }
    G-Log ('round ' + [string]$round + ' GREEN - ' + $tail)
}

$sw.Stop()
G-Log ('all three rounds green (this run took ' + ('{0:F1}' -f $sw.Elapsed.TotalMinutes) + ' min)')
Set-Content -Path $g_status -Value 'green' -Encoding ASCII
exit 0
