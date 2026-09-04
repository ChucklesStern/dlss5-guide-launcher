<#
.SYNOPSIS
    Tests for the batch bootstrap wrapper (DLSS5-Guide-Launcher.cmd).

.DESCRIPTION
    These tests exercise the wrapper as a black box: they run cmd.exe against a
    disposable fixture folder and assert on the exit code and on the bootstrap
    log it leaves behind. Nothing in the checkout is mutated, because the script
    under test is copied into the fixture and the application script is chosen
    through the documented DLSS5_SCRIPT_PATH override.

    Windows PowerShell 5.1 compatible. Run from any directory:
        .\tests\Test-Bootstrap.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:Failures = 0
$script:Passes = 0

function Write-Result {
    param([string]$Name, [bool]$Ok, [string]$Detail)
    if ($Ok) {
        $script:Passes++
        Write-Host ("  PASS  {0}" -f $Name) -ForegroundColor Green
        return
    }
    $script:Failures++
    Write-Host ("  FAIL  {0}" -f $Name) -ForegroundColor Red
    if ($Detail) { Write-Host ("        {0}" -f $Detail) -ForegroundColor Red }
}

function Assert-Equal {
    param([string]$Name, $Expected, $Actual)
    Write-Result $Name ($Expected -eq $Actual) ("expected '{0}', got '{1}'" -f $Expected, $Actual)
}

function Assert-Contains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    Write-Result $Name ($Haystack -like ('*' + $Needle + '*')) ("log did not contain: {0}" -f $Needle)
}

function Assert-NotContains {
    param([string]$Name, [string]$Haystack, [string]$Needle)
    Write-Result $Name (-not ($Haystack -like ('*' + $Needle + '*'))) ("log unexpectedly contained: {0}" -f $Needle)
}

# --- fixture -----------------------------------------------------------------

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceCmd = Join-Path $repoRoot 'DLSS5-Guide-Launcher.cmd'
if (-not (Test-Path -LiteralPath $sourceCmd)) { throw "Bootstrap not found: $sourceCmd" }

$fixtureRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('dlss5-bootstrap-' + [guid]::NewGuid().ToString('N'))

function New-Fixture {
    <# Fresh launcher folder containing only the bootstrap under test. #>
    param([string]$Name)
    $dir = Join-Path $fixtureRoot $Name
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    Copy-Item -LiteralPath $sourceCmd -Destination (Join-Path $dir 'DLSS5-Guide-Launcher.cmd')
    return $dir
}

function New-StubScript {
    <# A stand-in application script, selected via DLSS5_SCRIPT_PATH. #>
    param([string]$Directory, [string]$Name, [string[]]$Body)
    $path = Join-Path $Directory $Name
    [System.IO.File]::WriteAllLines($path, [string[]]$Body, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}

function Invoke-Bootstrap {
    <#
        Runs the wrapper and returns its exit code plus every bootstrap log it
        produced. TEMP is redirected per-invocation so the fallback path is
        deterministic and never pollutes the real temp folder.
    #>
    param(
        [string]$LauncherDir,
        [string]$ScriptPath,
        [string]$TempOverride,
        [string[]]$Arguments = @()
    )
    $previous = @{
        Script = $env:DLSS5_SCRIPT_PATH
        Temp   = $env:TEMP
        Tmp    = $env:TMP
    }
    $env:DLSS5_NO_PAUSE = '1'
    if ($ScriptPath) { $env:DLSS5_SCRIPT_PATH = $ScriptPath } else { $env:DLSS5_SCRIPT_PATH = $null }
    if ($TempOverride) {
        New-Item -ItemType Directory -Path $TempOverride -Force | Out-Null
        $env:TEMP = $TempOverride
        $env:TMP = $TempOverride
    }
    try {
        $cmdPath = Join-Path $LauncherDir 'DLSS5-Guide-Launcher.cmd'
        # Windows PowerShell turns redirected native stderr into ErrorRecords,
        # which would throw under the strict preference this file otherwise uses.
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = & $env:ComSpec '/c' $cmdPath @Arguments 2>&1
            $code = $LASTEXITCODE
        }
        finally { $ErrorActionPreference = $previousPreference }
    }
    finally {
        $env:DLSS5_SCRIPT_PATH = $previous.Script
        $env:TEMP = $previous.Temp
        $env:TMP = $previous.Tmp
        $env:DLSS5_NO_PAUSE = $null
    }

    $searchRoots = @((Join-Path $LauncherDir 'Logs'))
    if ($TempOverride) { $searchRoots += (Join-Path $TempOverride 'DLSS5-Guide-Launcher-Logs') }
    $logs = @()
    foreach ($root in $searchRoots) {
        if (Test-Path -LiteralPath $root -PathType Container) {
            $logs += @(Get-ChildItem -LiteralPath $root -Filter 'bootstrap-*.log' -File -ErrorAction SilentlyContinue)
        }
    }
    $text = ''
    foreach ($log in $logs) { $text += (Get-Content -LiteralPath $log.FullName -Raw) }

    return [pscustomobject]@{
        ExitCode = $code
        Console  = ($output | Out-String)
        Log      = $text
        LogCount = $logs.Count
        LogPaths = @($logs | ForEach-Object { $_.FullName })
    }
}

# --- tests -------------------------------------------------------------------

try {
    New-Item -ItemType Directory -Path $fixtureRoot -Force | Out-Null
    Write-Host "Bootstrap tests" -ForegroundColor Cyan
    Write-Host ("Fixture root: {0}" -f $fixtureRoot) -ForegroundColor DarkGray
    Write-Host ''

    # A. A missing application script must still produce a log. This is the
    #    acceptance criterion that a launch which shows no window is evidenced.
    Write-Host 'A. missing application script' -ForegroundColor Cyan
    $dirA = New-Fixture 'missing-script'
    $resultA = Invoke-Bootstrap -LauncherDir $dirA -ScriptPath (Join-Path $dirA 'does-not-exist.ps1')
    Assert-Equal 'exits with the documented bootstrap code 13' 13 $resultA.ExitCode
    Write-Result 'writes a bootstrap log anyway' ($resultA.LogCount -ge 1) 'no bootstrap log was created'
    Assert-Contains 'names the missing script stage' $resultA.Log 'Stage 4: FAILED'
    Assert-Contains 'records that the wrapper began' $resultA.Log 'Stage 1: CMD wrapper began.'
    Assert-Contains 'proves PowerShell process creation succeeded' $resultA.Log 'Stage 3: OK'

    # B. The application's exit code must survive the wrapper unchanged, so the
    #    band it falls in still identifies the failing subsystem.
    Write-Host ''
    Write-Host 'B. exit code passthrough' -ForegroundColor Cyan
    $dirB = New-Fixture 'exit-code'
    $stubB = New-StubScript $dirB 'stub.ps1' @('exit 30')
    $resultB = Invoke-Bootstrap -LauncherDir $dirB -ScriptPath $stubB
    Assert-Equal 'forwards the application exit code' 30 $resultB.ExitCode
    Assert-Contains 'records the application exit code' $resultB.Log 'the application exited with code 30'

    # C. Output must reach the log, because the console may never be seen.
    Write-Host ''
    Write-Host 'C. stdout and stderr capture' -ForegroundColor Cyan
    $dirC = New-Fixture 'output-capture'
    $stubC = New-StubScript $dirC 'stub.ps1' @(
        "Write-Output 'MARKER-ON-STDOUT'",
        "[Console]::Error.WriteLine('MARKER-ON-STDERR')",
        'exit 0'
    )
    $resultC = Invoke-Bootstrap -LauncherDir $dirC -ScriptPath $stubC
    Assert-Equal 'succeeds' 0 $resultC.ExitCode
    Assert-Contains 'captures stdout' $resultC.Log 'MARKER-ON-STDOUT'
    Assert-Contains 'captures stderr' $resultC.Log 'MARKER-ON-STDERR'

    # D. Deterministic fallback: a *file* named Logs makes the primary location
    #    unusable without needing ACL manipulation on a CI runner.
    Write-Host ''
    Write-Host 'D. unwritable primary location falls back to TEMP' -ForegroundColor Cyan
    $dirD = New-Fixture 'log-fallback'
    Set-Content -LiteralPath (Join-Path $dirD 'Logs') -Value 'not a directory' -Encoding ASCII
    $tempD = Join-Path $fixtureRoot 'temp-for-fallback'
    $stubD = New-StubScript $dirD 'stub.ps1' @('exit 0')
    $resultD = Invoke-Bootstrap -LauncherDir $dirD -ScriptPath $stubD -TempOverride $tempD
    Assert-Equal 'still succeeds' 0 $resultD.ExitCode
    Write-Result 'writes the log under TEMP' ($resultD.LogCount -ge 1) 'no fallback log was created'
    Assert-Contains 'reports that the fallback was used' $resultD.Log 'fallback (the launcher folder was not writable)'
    $fallbackDir = Join-Path $tempD 'DLSS5-Guide-Launcher-Logs'
    Write-Result 'fallback location is genuinely writable' (Test-Path -LiteralPath $fallbackDir -PathType Container) 'fallback directory missing'
    Assert-NotContains 'never falls back to Local App Data' $resultD.Log 'AppData\Local\DLSS5-Guide-Launcher'

    # E/F. The sentinel separates "script never began" from "script began and
    #      then failed". Absence must read as undetermined, not as proof.
    Write-Host ''
    Write-Host 'E. startup sentinel present' -ForegroundColor Cyan
    $dirE = New-Fixture 'sentinel-present'
    $stubE = New-StubScript $dirE 'stub.ps1' @(
        'if ($env:DLSS5_STARTUP_SENTINEL) { Set-Content -LiteralPath $env:DLSS5_STARTUP_SENTINEL -Value ''began'' }',
        'exit 0'
    )
    $resultE = Invoke-Bootstrap -LauncherDir $dirE -ScriptPath $stubE
    Assert-Contains 'reports that the script began' $resultE.Log 'began executing (startup sentinel present)'
    Assert-NotContains 'does not report undetermined' $resultE.Log 'UNDETERMINED'

    Write-Host ''
    Write-Host 'F. startup sentinel absent' -ForegroundColor Cyan
    $dirF = New-Fixture 'sentinel-absent'
    $stubF = New-StubScript $dirF 'stub.ps1' @('exit 0')
    $resultF = Invoke-Bootstrap -LauncherDir $dirF -ScriptPath $stubF
    Assert-Contains 'reports undetermined rather than guessing' $resultF.Log 'UNDETERMINED'

    # G. Argument values may contain personal paths, so only the shape and the
    #    count are recorded.
    Write-Host ''
    Write-Host 'G. arguments are counted, never logged' -ForegroundColor Cyan
    $dirG = New-Fixture 'argument-privacy'
    $stubG = New-StubScript $dirG 'stub.ps1' @('exit 0')
    $resultG = Invoke-Bootstrap -LauncherDir $dirG -ScriptPath $stubG -Arguments @('-GameExe', 'C:\Users\private-marker\game.exe')
    Assert-Contains 'records the argument count' $resultG.Log '2 forwarded argument(s)'
    Assert-Contains 'records a fixed command shape' $resultG.Log '-ExecutionPolicy Bypass -STA -File <script>'
    Assert-NotContains 'never records argument values' $resultG.Log 'private-marker'

    # H. The diagnostics tool must run standalone and always report.
    Write-Host ''
    Write-Host 'H. standalone diagnostics' -ForegroundColor Cyan
    $sourceDiag = Join-Path $repoRoot 'Collect-Diagnostics.cmd'
    $dirH = New-Fixture 'diagnostics'
    Copy-Item -LiteralPath $sourceDiag -Destination (Join-Path $dirH 'Collect-Diagnostics.cmd')
    $env:DLSS5_NO_PAUSE = '1'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $null = & $env:ComSpec '/c' (Join-Path $dirH 'Collect-Diagnostics.cmd') 2>&1; $codeH = $LASTEXITCODE }
    finally { $env:DLSS5_NO_PAUSE = $null; $ErrorActionPreference = $previousPreference }
    Assert-Equal 'always exits 0' 0 $codeH
    $reports = @(Get-ChildItem -Path (Join-Path $dirH 'Logs') -Filter 'diagnostics-*.txt' -File -ErrorAction SilentlyContinue)
    Write-Result 'writes a diagnostics report' ($reports.Count -ge 1) 'no diagnostics report was created'
    if ($reports.Count -ge 1) {
        $reportText = Get-Content -LiteralPath $reports[0].FullName -Raw
        Assert-Contains 'probes PowerShell process creation' $reportText 'Probing process creation for'
        Assert-Contains 'reports launcher folder write access' $reportText 'Launcher folder is writable'
        Assert-Contains 'notes the missing application script' $reportText 'Application script is MISSING'
    }
    # I. End-to-end proof that -DataRoot reaches the resolver. The script scope
    #    holds both the parameter and the launcher's own state, so a state
    #    variable named after the parameter would shadow it silently and this is
    #    the only test that would notice.
    Write-Host ''
    Write-Host 'I. -DataRoot is honoured end to end' -ForegroundColor Cyan
    $launcher = Join-Path $repoRoot 'DLSS5-Guide-Launcher.ps1'
    $dataRootI = Join-Path $fixtureRoot 'explicit-data-root'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $null = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher -SelfTest -DataRoot $dataRootI 2>&1
        $codeI = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $previousPreference }
    Assert-Equal 'self-tests pass under an explicit data root' 0 $codeI
    $logsI = @(Get-ChildItem -Path (Join-Path $dataRootI 'Logs') -Filter 'launcher-*.log' -File -ErrorAction SilentlyContinue)
    Write-Result 'writes its log under the explicit data root' ($logsI.Count -ge 1) "no log under $dataRootI"
    Write-Result 'creates Cache under the explicit data root' (Test-Path -LiteralPath (Join-Path $dataRootI 'Cache') -PathType Container) 'Cache missing'
    Write-Result 'creates Backups under the explicit data root' (Test-Path -LiteralPath (Join-Path $dataRootI 'Backups') -PathType Container) 'Backups missing'
    if ($logsI.Count -ge 1) {
        $logTextI = Get-Content -LiteralPath $logsI[0].FullName -Raw
        Assert-Contains 'records the active data root' $logTextI 'Data root:'
        Assert-Contains 'records that the root was explicit' $logTextI '(explicit)'
    }

    # J. A hostile %LOCALAPPDATA% must be irrelevant now, not merely survivable.
    Write-Host ''
    Write-Host 'J. startup does not depend on %LOCALAPPDATA%' -ForegroundColor Cyan
    $dataRootJ = Join-Path $fixtureRoot 'no-localappdata'
    $previousLocal = $env:LOCALAPPDATA
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $env:LOCALAPPDATA = ''
        $null = & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $launcher -SelfTest -DataRoot $dataRootJ 2>&1
        $codeJ = $LASTEXITCODE
    }
    finally {
        $env:LOCALAPPDATA = $previousLocal
        $ErrorActionPreference = $previousPreference
    }
    Assert-Equal 'starts with an empty %LOCALAPPDATA%' 0 $codeJ
    $logsJ = @(Get-ChildItem -Path (Join-Path $dataRootJ 'Logs') -Filter 'launcher-*.log' -File -ErrorAction SilentlyContinue)
    Write-Result 'still writes its log' ($logsJ.Count -ge 1) 'no log was written'
    # K. The real script through the real wrapper: the sentinel that Phase 1
    #    could only report as UNDETERMINED must now resolve, and the wrapper
    #    must see the application's own startup checkpoints.
    Write-Host ''
    Write-Host 'K. real launcher through the real wrapper' -ForegroundColor Cyan
    $dirK = New-Fixture 'end-to-end'
    Copy-Item -LiteralPath (Join-Path $repoRoot 'DLSS5-Guide-Launcher.ps1') -Destination (Join-Path $dirK 'DLSS5-Guide-Launcher.ps1')
    $dataRootK = Join-Path $fixtureRoot 'end-to-end-data'
    $resultK = Invoke-Bootstrap -LauncherDir $dirK -Arguments @('-SelfTest', '-DataRoot', $dataRootK)
    Assert-Equal 'self-tests pass through the wrapper' 0 $resultK.ExitCode
    Assert-Contains 'the wrapper sees that the script began' $resultK.Log 'began executing (startup sentinel present)'
    Assert-NotContains 'no longer undetermined' $resultK.Log 'UNDETERMINED'
    Assert-Contains 'the application mirrors checkpoints into the bootstrap log' $resultK.Log '[app]'
    Assert-Contains 'records the startup checkpoint' $resultK.Log 'Checkpoint: Startup.Begin'
    Assert-Contains 'records the observed language mode' $resultK.Log 'Language mode:'

}
finally {
    if (Test-Path -LiteralPath $fixtureRoot) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
if ($script:Failures -gt 0) {
    Write-Host ("{0} passed, {1} FAILED" -f $script:Passes, $script:Failures) -ForegroundColor Red
    exit 1
}
Write-Host ("All {0} bootstrap tests passed." -f $script:Passes) -ForegroundColor Green
exit 0
