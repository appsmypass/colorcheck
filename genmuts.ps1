# genmuts.ps1 - turns muts.txt into the $muts block inside mutate.ps1
#
# The anchors are kept in a plain data file so that quoting them for PowerShell
# is done once, here, instead of by hand in eighty places. Every literal single
# quote is doubled, and a multi line anchor is emitted as an explicit join so
# the exact CRLF pair in the source is what gets searched for.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$data = Join-Path $here 'muts.txt'
$target = Join-Path $here 'mutate.ps1'

$script:Name = ''
$script:Survive = $false
$script:From = New-Object System.Collections.ArrayList
$script:To = New-Object System.Collections.ArrayList
$script:Items = New-Object System.Collections.ArrayList

function Flush-Item {
    if ($script:Name.Length -eq 0) { return }
    [void]$script:Items.Add(@{
        Name = $script:Name
        Survive = $script:Survive
        From = @($script:From.ToArray())
        To = @($script:To.ToArray())
    })
}

# "@@ name" is an ordinary mutant that a suite must catch.
# "@@! name" is a tripwire: a change that alters nothing observable, so a
# suite that "catches" it is testing noise and the harness fails itself.
foreach ($line in [IO.File]::ReadAllLines($data)) {
    if ($line.StartsWith('@@! ')) {
        Flush-Item
        $script:Name = $line.Substring(4)
        $script:Survive = $true
        $script:From = New-Object System.Collections.ArrayList
        $script:To = New-Object System.Collections.ArrayList
    } elseif ($line.StartsWith('@@ ')) {
        Flush-Item
        $script:Name = $line.Substring(3)
        $script:Survive = $false
        $script:From = New-Object System.Collections.ArrayList
        $script:To = New-Object System.Collections.ArrayList
    } elseif ($line -eq '-') {
        # A bare dash is a blank line in the anchor. Requiring a trailing space
        # would make the data file depend on whitespace no editor preserves.
        [void]$script:From.Add('')
    } elseif ($line -eq '+') {
        [void]$script:To.Add('')
    } elseif ($line.StartsWith('- ')) {
        [void]$script:From.Add($line.Substring(2))
    } elseif ($line.StartsWith('+ ')) {
        [void]$script:To.Add($line.Substring(2))
    } elseif ($line.Trim().Length -gt 0) {
        Write-Error ('unrecognised line: ' + $line)
        exit 1
    }
}
Flush-Item

function Q {
    param([string]$Text)
    return "'" + $Text.Replace("'", "''") + "'"
}

# the six literal characters  "`r`n"  as they must appear in the generated file
$bt = [string][char]96
$nl = '"' + $bt + 'r' + $bt + 'n"'

function Q-Lines {
    param($Lines)
    $parts = @()
    foreach ($l in $Lines) { $parts += (Q $l) }
    if ($parts.Count -eq 1) { return $parts[0] }
    return '(' + ($parts -join (' + ' + $nl + ' + ')) + ')'
}

$total = 0
foreach ($it in $script:Items) { $total = $total + 1 }

$sb = New-Object System.Text.StringBuilder
[void]$sb.Append('$muts = @(')
[void]$sb.Append("`r`n")
$n = 0
foreach ($it in $script:Items) {
    $n = $n + 1
    $tail = ','
    if ($n -eq $total) { $tail = '' }
    $surv = ''
    if ($it.Survive) { $surv = ' $true' }
    [void]$sb.Append('    (New-Mut ' + (Q $it.Name) + ' ' + (Q-Lines $it.From) + ' ' + (Q-Lines $it.To) + $surv + ')' + $tail)
    [void]$sb.Append("`r`n")
}
[void]$sb.Append(')')
[void]$sb.Append("`r`n")

$text = [IO.File]::ReadAllText($target)
$startMark = '$muts = @(' + "`r`n"
$start = $text.IndexOf($startMark)
if ($start -lt 0) { Write-Error 'no $muts block found'; exit 1 }
$endMark = "`r`n)`r`n`r`n# ---"
$end = $text.IndexOf($endMark, $start)
if ($end -lt 0) { Write-Error 'no end of $muts block found'; exit 1 }
$out = $text.Substring(0, $start) + $sb.ToString() + $text.Substring($end + "`r`n)`r`n".Length)
[IO.File]::WriteAllText($target, $out, (New-Object System.Text.ASCIIEncoding))
Write-Output ('wrote ' + [string]$total + ' mutants into mutate.ps1')
