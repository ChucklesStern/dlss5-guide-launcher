[CmdletBinding()]
param(
    [switch]$SelfTest,
    [switch]$UiSmokeTest,
    [string]$UiScreenshotPath,
    [ValidateRange(1,4)][int]$UiScreenshotStep = 1,
    [switch]$Headless,
    [switch]$DryRun,
    [switch]$Rollback,
    [string]$GameExe,
    [ValidateSet('RTX 50 series','RTX 40 series (experimental)','Other / unsupported','Auto')]
    [string]$GpuClass = 'Auto',
    [ValidateSet('DirectX 11','DirectX 12','Vulkan','DirectX 9','Unknown','Auto')]
    [string]$GraphicsApi = 'Auto',
    [ValidateSet('Yes','No','Unsure','Auto')]
    [string]$NativeDlss = 'Auto',
    [string]$SupportFiles,
    [string]$ReShadeRuntime,
    [switch]$AllowPatchedRtx40File,
    [string]$DataRoot,
    [string]$BootstrapLogPath = $env:DLSS5_BOOTSTRAP_LOG
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'DLSS 5 Guide Launcher'
$script:Version = '1.3.1-noadmin'

# Storage locations are resolved at startup, never at script scope. Merely
# evaluating this file must not require any particular profile directory to
# exist, be accessible, or be writable: a null or redirected %LOCALAPPDATA%
# used to throw here, before a single line could be logged anywhere.
$script:ActiveDataRoot = $null
$script:ActiveDataRootKind = 'unresolved'
$script:ActiveDataRootAttempts = @()
$script:CacheRoot = $null
$script:LogRoot = $null
$script:BackupRoot = $null
$script:IndexPath = $null
$script:LogPath = $null

# Stable exit codes, banded so the batch wrapper can name the failing subsystem
# without knowing anything about the application. 10-19 belong to the wrapper.
$script:ExitCode = @{
    Success           = 0
    StartupStorage    = 20
    StartupAssemblies = 21
    StartupUi         = 22
    StartupUnexpected = 23
    InstallFailed     = 30
    RollbackFailed    = 40
    SelfTestFailed    = 50
}
$script:PendingExitCode = 0
$script:StartupStage = 'Script.Load'

$script:PreparedReShade = $null
$script:ReshadeThumbprint = '589690208A5E52FB96980C4A6698F50ACD47C49F'
$script:ReShadeVersion = '6.8.0'
$script:ReShadeInstallerUrl = 'https://reshade.me/downloads/ReShade_Setup_6.8.0_Addon.exe'
$script:ReShadeShadersRepo = 'crosire/reshade-shaders'
$script:ReShadeShadersCommit = '6db142b4b1a05c764222e5b0bd9a644b7ccfe1dc'
$script:ReShadeFxhSha256 = '6dabfbbaf968c3871905d2ea17f96572ff7b1cec01310b5d0e5252b66b30174f'
$script:BridgeRepo = 'NIGos/dlss5-dx11-bridge'
$script:FeederRepo = 'jlrouzies-fr/DLSS5-Feeder'
$script:LumeniteRepo = 'umar-afzaal/LumeniteFX'
$script:LumeniteCommit = '4615b30a277e5525e25581f5a37728cecac33399'
$script:LumeniteArchiveSha256 = 'fb60f9b1a1212d0a718d7ccad8f81af791560c26cc276e3952228a74b5269fe1'

function Test-DirectoryUsable {
    <#
        Reports whether a directory can be created and written to by the current
        user. Returns $null when it can, otherwise a human-readable reason.

        This never throws, because it runs before any log exists. Its callers
        need a reason to record, not an exception to propagate.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'no path was supplied' }
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return 'a file already exists at that path' }
        if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
            New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
        }
        $probe = Join-Path $Path ('.dlss5-root-check-' + [guid]::NewGuid().ToString('N') + '.tmp')
        $stream = [System.IO.File]::Open($probe, 'CreateNew', 'Write', 'None')
        try { $stream.WriteByte(0) } finally { $stream.Dispose() }
        Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
        return $null
    }
    catch {
        $code = 0
        try { $code = Get-NativeErrorCode $_.Exception } catch { $code = 0 }
        if ($code -eq 5 -or $_.Exception -is [System.UnauthorizedAccessException]) {
            return ('Windows denied access (error 5): ' + $_.Exception.Message)
        }
        return $_.Exception.Message
    }
}

function Get-DataRootCandidate {
    <#
        The ordered list of places the launcher will keep its data. A portable
        folder beside the launcher comes first so that everything the user may
        need to read stays where they extracted it. %TEMP% is the fallback.
        Local App Data is deliberately absent: a managed profile can make it
        unreadable to the very user who needs the logs.

        Taking the roots as parameters keeps this a seam the tests can drive
        with synthetic paths instead of depending on runner ACLs.
    #>
    param(
        [AllowEmptyString()][string]$Explicit,
        [AllowEmptyString()][string]$ScriptRoot,
        [AllowEmptyString()][string]$TempRoot
    )
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        $candidates += [pscustomobject]@{ Path = $Explicit; Kind = 'explicit' }
    }
    if (-not [string]::IsNullOrWhiteSpace($ScriptRoot)) {
        $candidates += [pscustomobject]@{ Path = (Join-Path $ScriptRoot 'Data'); Kind = 'portable' }
    }
    if (-not [string]::IsNullOrWhiteSpace($TempRoot)) {
        $candidates += [pscustomobject]@{ Path = (Join-Path $TempRoot 'DLSS5-Guide-Launcher'); Kind = 'temp' }
    }
    # The comma keeps an empty result an empty array: PowerShell unrolls a bare
    # @() on return into $null, which the caller cannot tell from a failure.
    return ,@($candidates)
}

function Resolve-WritableRoot {
    <#
        Walks the candidates in order and returns the first usable one, together
        with every attempt and why it was rejected, so the log can explain the
        choice rather than merely announce it.
    #>
    param([AllowNull()][AllowEmptyCollection()][object[]]$Candidates = @())
    $attempts = @()
    foreach ($candidate in @($Candidates)) {
        $reason = Test-DirectoryUsable $candidate.Path
        if (-not $reason) {
            $attempts += [pscustomobject]@{ Path = $candidate.Path; Kind = $candidate.Kind; Result = 'usable' }
            return [pscustomobject]@{ Path = $candidate.Path; Kind = $candidate.Kind; Attempts = @($attempts); Resolved = $true }
        }
        $attempts += [pscustomobject]@{ Path = $candidate.Path; Kind = $candidate.Kind; Result = $reason }
    }
    return [pscustomobject]@{ Path = $null; Kind = 'none'; Attempts = @($attempts); Resolved = $false }
}

function Initialize-AppLogging {
    <#
        The earliest PowerShell-side side effect: find somewhere to write and
        open the application log. Deliberately lighter than Initialize-AppStorage
        so that storage failures can be reported through a log that already
        exists. Returns $true when the application log is open.

        The roots are parameters rather than direct reads of script state: the
        -DataRoot parameter lives in the script scope, so state named after it
        would shadow it silently.
    #>
    param(
        [AllowEmptyString()][string]$ExplicitRoot = $DataRoot,
        [AllowEmptyString()][string]$ScriptRoot = $PSScriptRoot,
        [AllowEmptyString()][string]$TempRoot = ([System.IO.Path]::GetTempPath())
    )
    $resolution = Resolve-WritableRoot (Get-DataRootCandidate -Explicit $ExplicitRoot -ScriptRoot $ScriptRoot -TempRoot $TempRoot)
    $script:ActiveDataRootAttempts = $resolution.Attempts
    if (-not $resolution.Resolved) {
        $script:ActiveDataRootKind = 'none'
        return $false
    }
    $script:ActiveDataRoot = $resolution.Path
    $script:ActiveDataRootKind = $resolution.Kind
    $logRoot = Join-Path $resolution.Path 'Logs'
    $reason = Test-DirectoryUsable $logRoot
    if ($reason) { return $false }
    $script:LogRoot = $logRoot
    $script:LogPath = Join-Path $logRoot ('launcher-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    return $true
}

function Initialize-AppStorage {
    <# Creates the rest of the portable data root. Requires Initialize-AppLogging. #>
    if (-not $script:ActiveDataRoot) {
        $tried = ($script:ActiveDataRootAttempts | ForEach-Object { '  {0}  ({1})' -f $_.Path, $_.Result }) -join "`r`n"
        throw "The launcher could not find a writable folder for its own data.`r`n`r`nTried:`r`n$tried`r`n`r`nThis launcher does not require or request administrator access. Extract it somewhere your Windows account can write, such as your Downloads folder."
    }
    $script:CacheRoot = Join-Path $script:ActiveDataRoot 'Cache'
    $script:BackupRoot = Join-Path $script:ActiveDataRoot 'Backups'
    $script:IndexPath = Join-Path $script:ActiveDataRoot 'install-index.json'
    foreach ($path in @($script:CacheRoot, $script:BackupRoot)) {
        $reason = Test-DirectoryUsable $path
        if ($reason) {
            throw "The launcher could not create part of its data folder: $path`r`n`r`nReason: $reason`r`n`r`nThis launcher does not require or request administrator access."
        }
    }
}

function Write-AppLog {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')] [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # Logging is best effort by design. A failure to record what happened must
    # never replace or mask the thing that actually happened.
    if ($script:LogPath) {
        try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
    }
    if ($BootstrapLogPath) {
        try { Add-Content -LiteralPath $BootstrapLogPath -Value ('  [app] ' + $line) -Encoding UTF8 } catch { }
    }
    if ($Headless -or $SelfTest) {
        $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Gray'} }
        Write-Host $line -ForegroundColor $color
    }
}

function Set-StartupStage {
    <# Records how far startup got, so a failure can name the stage it died in. #>
    param([Parameter(Mandatory=$true)][string]$Stage)
    $script:StartupStage = $Stage
    Write-AppLog ('Checkpoint: ' + $Stage)
}

function Write-StartupSentinel {
    <#
        Proves to the batch wrapper that this script body actually began, which
        separates "PowerShell ran but the script never started" from "the script
        started and then failed". Best effort: it must never break startup.
    #>
    $path = $env:DLSS5_STARTUP_SENTINEL
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try { Set-Content -LiteralPath $path -Value 'started' -Encoding ASCII -ErrorAction Stop } catch { }
}

function Write-StartupEnvironment {
    <#
        Observed facts only. These narrow down a blocked start, but none of them
        proves on its own why Windows refused: -ExecutionPolicy Bypass does not
        override application control such as AppLocker or WDAC, and a policy
        that blocks the script may leave no trace here at all. Record what was
        seen and let a human draw the conclusion.
    #>
    try { Write-AppLog ('PowerShell version: {0}' -f $PSVersionTable.PSVersion.ToString()) } catch { }
    try { Write-AppLog ('Language mode: {0}' -f $ExecutionContext.SessionState.LanguageMode) } catch { }
    try { Write-AppLog ('64-bit process: {0}' -f [System.Environment]::Is64BitProcess) } catch { }
    try {
        foreach ($policy in @(Get-ExecutionPolicy -List)) {
            Write-AppLog ('Execution policy [{0}]: {1}' -f $policy.Scope, $policy.ExecutionPolicy)
        }
    } catch { }
}

function Get-ExitCodeForStage {
    <# Maps the stage that failed onto the documented exit-code bands. #>
    param([string]$Stage)
    switch -Wildcard ($Stage) {
        'Startup.Storage' { return $script:ExitCode.StartupStorage }
        'Ui.Assemblies'   { return $script:ExitCode.StartupAssemblies }
        'Ui.*'            { return $script:ExitCode.StartupUi }
        'Install*'        { return $script:ExitCode.InstallFailed }
        'Rollback*'       { return $script:ExitCode.RollbackFailed }
        'SelfTest*'       { return $script:ExitCode.SelfTestFailed }
        default           { return $script:ExitCode.StartupUnexpected }
    }
}

function Write-StartupFailure {
    <#
        Records everything needed to identify a failure that the user may never
        have seen on screen, then reports it the best way still available: a
        message box if WinForms loaded, otherwise stderr, which the batch
        wrapper captures into the bootstrap log.
    #>
    param([Parameter(Mandatory=$true)]$ErrorRecord)
    $script:PendingExitCode = Get-ExitCodeForStage $script:StartupStage
    $exception = $ErrorRecord.Exception
    $type = 'unknown'; $message = ''; $hresult = 0; $native = 0
    try { $type = $exception.GetType().FullName } catch { }
    try { $message = $exception.Message } catch { }
    try { $hresult = [int]$exception.HResult } catch { }
    try { $native = Get-NativeErrorCode $exception } catch { }
    $detail = @(
        'The launcher failed before it could finish starting.',
        ('  Stage:         {0}' -f $script:StartupStage),
        ('  Exit code:     {0}' -f $script:PendingExitCode),
        ('  Exception:     {0}' -f $type),
        ('  Message:       {0}' -f $message),
        ('  HRESULT:       0x{0:X8}' -f $hresult),
        ('  Windows error: {0}' -f $native)
    ) -join "`r`n"
    Write-AppLog $detail 'ERROR'
    try { Write-AppLog ('Script stack: ' + $ErrorRecord.ScriptStackTrace) 'ERROR' } catch { }
    if ($script:LogPath) { $detail += ("`r`n`r`nLog: " + $script:LogPath) }

    $reported = $false
    if ($null -ne ([System.Management.Automation.PSTypeName]'System.Windows.Forms.MessageBox').Type) {
        try {
            [void][System.Windows.Forms.MessageBox]::Show($detail, ($script:AppName + ' - startup failed'), 'OK', 'Error')
            $reported = $true
        }
        catch { }
    }
    if (-not $reported) {
        try { [Console]::Error.WriteLine($detail) } catch { }
    }
}

function Write-DataRootLog {
    <# Records the active data root and every location that was rejected. #>
    Write-AppLog ("Data root: {0} ({1})" -f $script:ActiveDataRoot, $script:ActiveDataRootKind) 'OK'
    Write-AppLog ("Log file:  {0}" -f $script:LogPath)
    foreach ($attempt in $script:ActiveDataRootAttempts) {
        if ($attempt.Result -ne 'usable') {
            Write-AppLog ("Rejected data root {0} ({1}): {2}" -f $attempt.Path, $attempt.Kind, $attempt.Result) 'WARN'
        }
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory=$true)][string]$Path)
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PeArchitecture {
    param([Parameter(Mandatory=$true)][string]$Path)
    $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) { return 'Unknown' }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return 'Unknown' }
        $machine = $reader.ReadUInt16()
        switch ($machine) {
            0x8664 { return '64-bit' }
            0x014c { return '32-bit' }
            0xAA64 { return 'ARM64' }
            default { return ('Unknown (0x{0:X4})' -f $machine) }
        }
    }
    finally { $stream.Dispose() }
}

function Get-DetectedGpuClass {
    <#
        Detection is never fatal. A machine that blocks WMI/CIM must not be told
        its GPU is unsupported: that reports a hardware verdict on the strength
        of a policy failure and refuses an install the card could actually run.
        A failed query reports 'Auto' and leaves the choice to the user.
    #>
    try {
        $names = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        $joined = $names -join '; '
        if ($joined -match '(?i)RTX\s*50\d{2}') { return [pscustomobject]@{ Class='RTX 50 series'; Names=$joined; Detected=$true } }
        if ($joined -match '(?i)RTX\s*40\d{2}') { return [pscustomobject]@{ Class='RTX 40 series (experimental)'; Names=$joined; Detected=$true } }
        return [pscustomobject]@{ Class='Other / unsupported'; Names=$joined; Detected=$true }
    }
    catch {
        return [pscustomobject]@{ Class='Auto'; Names=('Detection unavailable: ' + $_.Exception.Message); Detected=$false }
    }
}

function Find-NativeDlss {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ExePath))
    $matches = @(Get-ChildItem -LiteralPath $dir -File -Filter 'nvngx_dlss.dll' -ErrorAction SilentlyContinue)
    if ($matches.Count -gt 0) { return [pscustomobject]@{ Value='Yes'; Evidence=$matches[0].FullName } }
    return [pscustomobject]@{ Value='Unsure'; Evidence='No nvngx_dlss.dll was found beside the selected executable.' }
}

function Get-DetectedApi {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ExePath))
    $logs = @(Get-ChildItem -LiteralPath $dir -File -Filter 'ReShade*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($log in $logs) {
        $text = Get-Content -LiteralPath $log.FullName -Raw -ErrorAction SilentlyContinue
        if ($text -match '(?i)(Direct3D\s*12|D3D12)') { return [pscustomobject]@{ Value='DirectX 12'; Evidence=$log.FullName } }
        if ($text -match '(?i)(Direct3D\s*11|D3D11)') { return [pscustomobject]@{ Value='DirectX 11'; Evidence=$log.FullName } }
        if ($text -match '(?i)Vulkan') { return [pscustomobject]@{ Value='Vulkan'; Evidence=$log.FullName } }
    }

    # Import-name scanning is a hint only. When more than one API is referenced, require a user choice.
    try {
        $bytes = [System.IO.File]::ReadAllBytes($ExePath)
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
        $hits = New-Object System.Collections.Generic.List[string]
        if ($ascii.IndexOf('d3d12.dll', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add('DirectX 12') }
        if ($ascii.IndexOf('d3d11.dll', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add('DirectX 11') }
        if ($ascii.IndexOf('vulkan-1.dll', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add('Vulkan') }
        if ($ascii.IndexOf('d3d9.dll', [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $hits.Add('DirectX 9') }
        if ($hits.Count -eq 1) { return [pscustomobject]@{ Value=$hits[0]; Evidence='Executable import-name hint' } }
        if ($hits.Count -gt 1) { return [pscustomobject]@{ Value='Unknown'; Evidence='The executable references multiple graphics APIs: ' + ($hits -join ', ') } }
    }
    catch { }
    return [pscustomobject]@{ Value='Unknown'; Evidence='No reliable API evidence was found.' }
}

function Resolve-InstallRoute {
    param(
        [Parameter(Mandatory=$true)][string]$Gpu,
        [Parameter(Mandatory=$true)][string]$Api,
        [Parameter(Mandatory=$true)][string]$HasNativeDlss
    )

    $unsupported = $false
    $id = ''
    $title = ''
    $summary = ''
    $warning = ''

    if ($Gpu -eq 'Other / unsupported') {
        $unsupported = $true
        $id = 'UnsupportedGpu'
        $title = 'Unsupported GPU'
        $summary = 'These DLSS 5 Neural Rendering guides are for NVIDIA RTX 50-series GPUs, with an unofficial experimental path for RTX 40-series GPUs.'
    }
    elseif ($Api -eq 'Unknown' -or $HasNativeDlss -eq 'Unsure') {
        $unsupported = $true
        $id = 'NeedsAnswers'
        $title = 'More information required'
        $summary = 'Choose the graphics API and whether this game already has native DLSS. The launcher will not guess when that could select the wrong add-on.'
    }
    elseif ($Api -eq 'DirectX 11' -and $HasNativeDlss -eq 'Yes') {
        $id = 'Dx11Bridge'
        $title = 'DirectX 11 Bridge (game already has DLSS)'
        $summary = 'Installs the core RenoDX DLSS 5 files plus the official DX11 Bridge. The Bridge forwards the game''s existing DLSS activity to the DX12-only Neural Rendering add-on.'
    }
    elseif ($Api -eq 'DirectX 12' -and $HasNativeDlss -eq 'Yes') {
        $id = 'Dx12Native'
        $title = 'Native DirectX 12 DLSS route'
        $summary = 'Installs only the core RenoDX DLSS 5 files. No Bridge or Feeder is needed because the game already provides DLSS calls through DirectX 12.'
    }
    elseif (($Api -eq 'DirectX 11' -or $Api -eq 'DirectX 12') -and $HasNativeDlss -eq 'No') {
        $id = 'Feeder'
        $title = 'DLSS5-Feeder (game has no native DLSS)'
        $summary = 'Installs the core files, DLSS5-Feeder, its shader, and the current recommended LumeniteFX Kernel motion-vector provider. Feeder creates a real DLAA pass so the Neural Rendering add-on has DLSS activity to hook.'
        $warning = 'Beta route: DLAA only, estimated motion vectors can ghost, and the HUD is processed.'
    }
    elseif ($Api -eq 'Vulkan' -and $HasNativeDlss -eq 'No') {
        $unsupported = $true
        $id = 'AdvancedVulkan'
        $title = 'Advanced Feeder route: Vulkan'
        $summary = 'Vulkan requires a separate ReShade layer and placement model. This no-admin build does not register layers or write Vulkan registry keys; use a documented per-user/manual route outside this DX11/DX12 installer.'
    }
    elseif ($Api -eq 'DirectX 9' -and $HasNativeDlss -eq 'No') {
        $unsupported = $true
        $id = 'AdvancedD3D9'
        $title = 'Advanced Feeder route: DirectX 9'
        $summary = 'This route requires dgVoodoo2 before Feeder. Version 1.1 provides the official guide instead of installing a graphics wrapper automatically.'
    }
    else {
        $unsupported = $true
        $id = 'UnsupportedCombination'
        $title = 'Unsupported combination'
        $summary = 'There is no automated route for this API and native-DLSS combination.'
    }

    if ($Gpu -eq 'RTX 40 series (experimental)') {
        $warning = (($warning + ' ').Trim() + ' RTX 40-series support relies on a user-supplied patched nvngx_dlssnr.dll. It is unofficial, unsupported by NVIDIA, and must be explicitly accepted.').Trim()
    }

    [pscustomobject]@{
        Id = $id
        Title = $title
        Summary = $summary
        Warning = $warning
        CanInstall = (-not $unsupported)
        NeedsBridge = ($id -eq 'Dx11Bridge')
        NeedsFeeder = ($id -eq 'Feeder')
        NeedsUpscalerDll = ($id -eq 'Feeder')
    }
}

function Get-GitHubAsset {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string]$AssetName
    )
    $headers = @{ 'User-Agent' = 'DLSS5-Guide-Launcher'; 'Accept' = 'application/vnd.github+json' }
    $release = Invoke-RestMethod -Headers $headers -Uri ('https://api.github.com/repos/{0}/releases/latest' -f $Repository)
    $asset = @($release.assets | Where-Object { $_.name -eq $AssetName }) | Select-Object -First 1
    if (-not $asset) { throw "The latest $Repository release does not contain $AssetName." }
    $safeRepo = $Repository.Replace('/','-')
    $safeTag = ([string]$release.tag_name) -replace '[^A-Za-z0-9._-]', '_'
    $destDir = Join-Path $script:CacheRoot (Join-Path $safeRepo $safeTag)
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $dest = Join-Path $destDir $AssetName
    $expected = ''
    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
        $expected = ([string]$asset.digest).Replace('sha256:','').ToLowerInvariant()
    }
    if (-not $expected) { throw "GitHub did not publish a SHA-256 digest for $Repository/$AssetName, so the launcher refused the download." }
    $validCache = (Test-Path -LiteralPath $dest)
    if ($validCache -and $expected) { $validCache = ((Get-Sha256 $dest) -eq $expected) }
    if (-not $validCache) {
        Write-AppLog "Downloading $AssetName from $Repository release $($release.tag_name)."
        Invoke-WebRequest -Headers $headers -Uri $asset.browser_download_url -OutFile $dest -UseBasicParsing
    }
    $actual = Get-Sha256 $dest
    if ($expected -and $actual -ne $expected) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        throw "SHA-256 verification failed for $AssetName. Expected $expected but downloaded $actual."
    }
    Write-AppLog "Verified $AssetName ($actual)." 'OK'
    [pscustomobject]@{ Path=$dest; Sha256=$actual; Version=[string]$release.tag_name; Url=[string]$asset.browser_download_url }
}

function Get-GitHubRepositoryFile {
    param(
        [Parameter(Mandatory=$true)][string]$Repository,
        [Parameter(Mandatory=$true)][string]$Ref,
        [Parameter(Mandatory=$true)][string]$RepositoryPath,
        [Parameter(Mandatory=$true)][string]$CacheName
    )
    $safeRepo = $Repository.Replace('/','-')
    $safeRef = $Ref -replace '[^A-Za-z0-9._-]', '_'
    $destDir = Join-Path $script:CacheRoot (Join-Path $safeRepo $safeRef)
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $dest = Join-Path $destDir $CacheName
    if (-not (Test-Path -LiteralPath $dest)) {
        $headers = @{ 'User-Agent' = 'DLSS5-Guide-Launcher' }
        $url = 'https://raw.githubusercontent.com/{0}/{1}/{2}' -f $Repository, $Ref, $RepositoryPath
        Invoke-WebRequest -Headers $headers -Uri $url -OutFile $dest -UseBasicParsing
    }
    return $dest
}

function Get-LumeniteFiles {
    $headers = @{ 'User-Agent' = 'DLSS5-Guide-Launcher'; 'Accept' = 'application/vnd.github+json' }
    $commit = $script:LumeniteCommit
    $destDir = Join-Path $script:CacheRoot (Join-Path 'LumeniteFX' $commit)
    $archive = Join-Path $destDir 'source.zip'
    $expanded = Join-Path $destDir 'expanded'
    if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    if ((Test-Path -LiteralPath $archive) -and (Get-Sha256 $archive) -ne $script:LumeniteArchiveSha256) {
        Remove-Item -LiteralPath $archive -Force
        if (Test-Path -LiteralPath $expanded) { Remove-Item -LiteralPath $expanded -Recurse -Force }
    }
    if (-not (Test-Path -LiteralPath $archive)) {
        $url = 'https://github.com/{0}/archive/{1}.zip' -f $script:LumeniteRepo, $commit
        Write-AppLog "Downloading LumeniteFX commit $commit from its official repository."
        Invoke-WebRequest -Headers $headers -Uri $url -OutFile $archive -UseBasicParsing
    }
    $archiveHash = Get-Sha256 $archive
    if ($archiveHash -ne $script:LumeniteArchiveSha256) { throw "LumeniteFX archive verification failed. Expected $($script:LumeniteArchiveSha256) but downloaded $archiveHash." }
    if (-not (Test-Path -LiteralPath $expanded)) { Expand-Archive -LiteralPath $archive -DestinationPath $expanded -Force }
    $mappings = New-Object System.Collections.Generic.List[object]
    foreach ($file in @(Get-ChildItem -LiteralPath $expanded -Recurse -File)) {
        $normalized = $file.FullName.Replace('/','\')
        $shaderMarker = '\Shaders\'
        $textureMarker = '\Textures\'
        $shaderIndex = $normalized.IndexOf($shaderMarker, [System.StringComparison]::OrdinalIgnoreCase)
        $textureIndex = $normalized.IndexOf($textureMarker, [System.StringComparison]::OrdinalIgnoreCase)
        if ($shaderIndex -ge 0) {
            $relative = $normalized.Substring($shaderIndex + $shaderMarker.Length)
            $mappings.Add([pscustomobject]@{ Source=$file.FullName; Relative=('reshade-shaders\Shaders\' + $relative) })
        }
        elseif ($textureIndex -ge 0 -and $file.Name -eq 'lumenite_bluenoise256.png') {
            $mappings.Add([pscustomobject]@{ Source=$file.FullName; Relative='reshade-shaders\Textures\lumenite_bluenoise256.png' })
        }
    }
    $license = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter 'LICENSE.md') | Select-Object -First 1
    $notice = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter 'NOTICE') | Select-Object -First 1
    if ($mappings.Count -lt 2) { throw 'The official LumeniteFX archive did not contain its Shaders/Textures layout.' }
    if (-not $license -or -not $notice) { throw 'The official LumeniteFX archive did not contain its license and notice.' }
    Write-AppLog "Prepared LumeniteFX commit $commit (archive SHA-256 $archiveHash)." 'OK'
    [pscustomobject]@{
        Mappings=@($mappings | ForEach-Object { $_ }); LicenseFile=$license.FullName; NoticeFile=$notice.FullName
        Version=$commit; ArchiveSha256=$archiveHash; Url=('https://github.com/{0}/tree/{1}' -f $script:LumeniteRepo,$commit)
    }
}

function New-ConfiguredReShadeIni {
    param([Parameter(Mandatory=$true)][string]$SourceIniPath)
    if (-not (Test-Path -LiteralPath $SourceIniPath -PathType Leaf)) { throw "ReShade configuration source was not found: $SourceIniPath" }
    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $SourceIniPath)) {
        $normalized = [string]$line
        if ($normalized -match '^(?i)(EffectSearchPaths|TextureSearchPaths)=') {
            $normalized = $normalized.Replace('\**\**','\**')
        }
        $lines.Add($normalized)
    }
    $general = -1
    $nextSection = $lines.Count
    for ($i=0; $i -lt $lines.Count; $i++) {
        if ($lines[$i].Trim() -ieq '[GENERAL]') { $general=$i; continue }
        if ($general -ge 0 -and $i -gt $general -and $lines[$i].Trim() -match '^\[.+\]$') { $nextSection=$i; break }
    }
    if ($general -lt 0) { throw 'ReShade.ini exists but has no [GENERAL] section; set DLSS5_MV_PROVIDER=3 manually.' }
    $presetPathLine = -1
    for ($i=$general+1; $i -lt $nextSection; $i++) {
        if ($lines[$i] -match '^(?i)PresetPath=') { $presetPathLine=$i; break }
    }
    if ($presetPathLine -ge 0) {
        $lines[$presetPathLine]='PresetPath=.\ReShadePreset.ini'
    }
    else {
        $lines.Insert($general+1,'PresetPath=.\ReShadePreset.ini')
        $nextSection++
    }
    $definitionLine = -1
    for ($i=$general+1; $i -lt $nextSection; $i++) {
        if ($lines[$i] -match '^(?i)PreprocessorDefinitions=') { $definitionLine=$i; break }
    }
    $definitions = New-Object System.Collections.Generic.List[string]
    if ($definitionLine -ge 0) {
        $raw = $lines[$definitionLine].Substring($lines[$definitionLine].IndexOf('=')+1)
        foreach ($item in @($raw -split ',')) {
            $trimmed = $item.Trim()
            if ($trimmed -and $trimmed -notmatch '^(?i)DLSS5_MV_PROVIDER=') { $definitions.Add($trimmed) }
        }
    }
    $definitions.Add('DLSS5_MV_PROVIDER=3')
    $newLine = 'PreprocessorDefinitions=' + ($definitions -join ',')
    if ($definitionLine -ge 0) { $lines[$definitionLine]=$newLine } else { $lines.Insert($general+1,$newLine) }
    $generatedDir = Join-Path $script:CacheRoot 'Generated'
    if (-not (Test-Path -LiteralPath $generatedDir)) { New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null }
    $generatedPath = Join-Path $generatedDir ('ReShade-' + [guid]::NewGuid().ToString('N') + '.ini')
    [System.IO.File]::WriteAllLines($generatedPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    return $generatedPath
}

function New-ConfiguredReShadePreset {
    param([string]$SourcePresetPath)
    $lines = New-Object System.Collections.Generic.List[string]
    if ($SourcePresetPath -and (Test-Path -LiteralPath $SourcePresetPath -PathType Leaf)) {
        foreach ($line in @(Get-Content -LiteralPath $SourcePresetPath)) { $lines.Add([string]$line) }
    }

    $provider = 'Lumenite_Kernel@lumenite_Kernel.fx'
    $feed = 'DLSS5_Feed@DLSS5_Feed.fx'
    foreach ($key in @('Techniques','TechniqueSorting')) {
        $lineIndex = -1
        for ($i=0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ('^(?i)' + [regex]::Escape($key) + '=')) { $lineIndex=$i; break }
        }
        $entries = New-Object System.Collections.Generic.List[string]
        if ($lineIndex -ge 0) {
            $raw = $lines[$lineIndex].Substring($lines[$lineIndex].IndexOf('=')+1)
            foreach ($entry in @($raw -split ',')) {
                $trimmed = $entry.Trim()
                if ($trimmed -and $trimmed -notmatch '^(?i)(Lumenite_Kernel@lumenite_Kernel\.fx|DLSS5_Feed@DLSS5_Feed\.fx)$') { $entries.Add($trimmed) }
            }
        }
        $entries.Add($provider)
        $entries.Add($feed)
        $newLine = $key + '=' + ($entries -join ',')
        if ($lineIndex -ge 0) {
            $lines[$lineIndex]=$newLine
        }
        else {
            $firstSection = $lines.Count
            for ($i=0; $i -lt $lines.Count; $i++) { if ($lines[$i].Trim() -match '^\[.+\]$') { $firstSection=$i; break } }
            $lines.Insert($firstSection,$newLine)
        }
    }

    $generatedDir = Join-Path $script:CacheRoot 'Generated'
    if (-not (Test-Path -LiteralPath $generatedDir)) { New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null }
    $generatedPath = Join-Path $generatedDir ('ReShadePreset-' + [guid]::NewGuid().ToString('N') + '.ini')
    [System.IO.File]::WriteAllLines($generatedPath, [string[]]$lines, (New-Object System.Text.UTF8Encoding($false)))
    return $generatedPath
}

function Get-ReShadeInstaller {
    $dest = Join-Path $script:CacheRoot ("ReShade_Setup_$($script:ReShadeVersion)_Addon.exe")
    if (-not (Test-Path -LiteralPath $dest)) {
        Write-AppLog "Downloading the ReShade $($script:ReShadeVersion) full add-on installer from reshade.me."
        Invoke-WebRequest -Uri $script:ReShadeInstallerUrl -OutFile $dest -UseBasicParsing
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $dest
    $thumbprint = if ($signature.SignerCertificate) { $signature.SignerCertificate.Thumbprint } else { '' }
    # ReShade intentionally uses the self-signed certificate whose thumbprint is published on reshade.me.
    # Windows can therefore report UnknownError for an untrusted root even when the embedded signature is intact.
    $badSignatureState = $signature.Status -in @('NotSigned','HashMismatch')
    if ($badSignatureState -or $thumbprint -ne $script:ReshadeThumbprint) {
        throw "ReShade signature verification failed. Status: $($signature.Status); certificate: $thumbprint"
    }
    Write-AppLog "Verified the official ReShade installer certificate thumbprint (signature status: $($signature.Status))." 'OK'
    return $dest
}

function Get-ReShadeCoreShader {
    $commit = $script:ReShadeShadersCommit
    $dest = Join-Path $script:CacheRoot ("ReShade.fxh-$commit")
    $url = "https://raw.githubusercontent.com/$($script:ReShadeShadersRepo)/$commit/Shaders/ReShade.fxh"
    if (-not (Test-Path -LiteralPath $dest -PathType Leaf)) {
        Write-AppLog "Downloading ReShade.fxh from the official ReShade shader repository at commit $commit."
        Invoke-WebRequest -Headers @{'User-Agent'="$($script:AppName)/$($script:Version)"} -Uri $url -OutFile $dest -UseBasicParsing
    }
    $hash = Get-Sha256 $dest
    if ($hash -ne $script:ReShadeFxhSha256) {
        throw "ReShade.fxh verification failed. Expected $($script:ReShadeFxhSha256), but found $hash."
    }
    $header = (Get-Content -LiteralPath $dest -TotalCount 8) -join "`n"
    if ($header -notmatch 'SPDX-License-Identifier:\s*CC0-1\.0' -or $header -notmatch '#pragma once') {
        throw 'The verified ReShade.fxh file did not contain its expected CC0 header and include guard.'
    }
    Write-AppLog "Prepared official ReShade.fxh commit $commit (SHA-256 $hash)." 'OK'
    [pscustomobject]@{ Name='ReShade.fxh'; Path=$dest; Version=$commit; Url=$url; Sha256=$hash; License='CC0-1.0' }
}

function Test-IsReShadeRuntime {
    param([Parameter(Mandatory=$true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
        return ($info.ProductName -match '(?i)ReShade' -or $info.FileDescription -match '(?i)ReShade')
    }
    catch { return $false }
}

function Get-NativeErrorCode {
    param([Parameter(Mandatory=$true)][System.Exception]$Exception)
    if ($Exception -is [System.ComponentModel.Win32Exception]) { return $Exception.NativeErrorCode }
    if ($Exception.InnerException -is [System.ComponentModel.Win32Exception]) { return $Exception.InnerException.NativeErrorCode }
    return ($Exception.HResult -band 0xFFFF)
}

function Assert-DirectoryWritable {
    param([Parameter(Mandatory=$true)][string]$Path)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) { throw "Game folder does not exist: $fullPath" }
    $probe = Join-Path $fullPath ('.dlss5-write-check-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $stream = [System.IO.File]::Open($probe,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        try { $stream.WriteByte(0) } finally { $stream.Dispose() }
        Remove-Item -LiteralPath $probe -Force
    }
    catch {
        if (Test-Path -LiteralPath $probe -PathType Leaf) { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
        $code = Get-NativeErrorCode $_.Exception
        if ($code -eq 5 -or $_.Exception -is [System.UnauthorizedAccessException]) {
            throw "Windows denied write access to the game folder (error 5): $fullPath`r`n`r`nNo files were changed. This no-admin launcher will not request elevation. Move/install the game in a folder your Windows account can modify, or ask the VM owner to grant your account Modify permission to this game folder."
        }
        throw "The launcher could not verify write access to the game folder '$fullPath': $($_.Exception.Message)"
    }
    Write-AppLog "Confirmed current-user write access to game folder: $fullPath" 'OK'
}

function New-DefaultReShadeIni {
    $generatedDir = Join-Path $script:CacheRoot 'Generated'
    if (-not (Test-Path -LiteralPath $generatedDir)) { New-Item -ItemType Directory -Path $generatedDir -Force | Out-Null }
    $generatedPath = Join-Path $generatedDir ('ReShade-default-' + [guid]::NewGuid().ToString('N') + '.ini')
    $lines = @(
        '[GENERAL]',
        'EffectSearchPaths=.\reshade-shaders\Shaders\**',
        'PresetPath=.\ReShadePreset.ini',
        'PreprocessorDefinitions=',
        'TextureSearchPaths=.\reshade-shaders\Textures\**',
        '',
        '[ADDON]',
        'AddonPath=.',
        'DisabledAddons='
    )
    [System.IO.File]::WriteAllLines($generatedPath,[string[]]$lines,(New-Object System.Text.UTF8Encoding($false)))
    return $generatedPath
}

function Get-LocalReShadeFiles {
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][string]$SourceMode,
        [bool]$AlreadyInstalled = $false
    )
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf)) { throw "The selected ReShade runtime was not found: $fullPath" }
    if (-not (Test-IsReShadeRuntime $fullPath)) { throw "The selected DLL does not identify itself as ReShade: $fullPath" }
    $architecture = Get-PeArchitecture $fullPath
    if ($architecture -ne '64-bit') { throw "The selected ReShade runtime is $architecture; this launcher requires the 64-bit full add-on runtime." }
    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($fullPath)
    $adjacentIni = Join-Path ([System.IO.Path]::GetDirectoryName($fullPath)) 'ReShade.ini'
    $ini = if (Test-Path -LiteralPath $adjacentIni -PathType Leaf) { $adjacentIni } else { $null }
    $preview = if ($AlreadyInstalled) { "Reuse existing ReShade runtime: $fullPath" } else { "Use selected local ReShade runtime: $fullPath" }
    [pscustomobject]@{
        Runtime=$fullPath
        Ini=$ini
        Version=[string]$info.FileVersion
        Installer=$null
        Url=$null
        SourceMode=$SourceMode
        AlreadyInstalled=$AlreadyInstalled
        Preview=$preview
    }
}

function Resolve-ReShadeSource {
    param(
        [Parameter(Mandatory=$true)][string]$GameDirectory,
        [string]$RuntimePath,
        [bool]$FetchRemote = $false
    )
    $targetDxgi = Join-Path $GameDirectory 'dxgi.dll'
    if (Test-Path -LiteralPath $targetDxgi -PathType Leaf) {
        if (-not (Test-IsReShadeRuntime $targetDxgi)) {
            throw "The game already has a non-ReShade dxgi.dll. The launcher will not overwrite an unknown proxy/loader. Configure ReShade chain-loading manually for this game: $targetDxgi"
        }
        Write-AppLog "Reusing the existing ReShade runtime at $targetDxgi; no ReShade installer will be started." 'OK'
        return (Get-LocalReShadeFiles -Path $targetDxgi -SourceMode 'Existing game runtime' -AlreadyInstalled $true)
    }
    if (-not [string]::IsNullOrWhiteSpace($RuntimePath)) {
        $selected = Get-LocalReShadeFiles -Path $RuntimePath -SourceMode 'User-selected local runtime'
        Write-AppLog "Using the selected local ReShade runtime at $($selected.Runtime); no ReShade installer will be started." 'OK'
        return $selected
    }
    if ($FetchRemote) {
        $staged = Get-StagedReShadeFiles
        $staged | Add-Member -NotePropertyName SourceMode -NotePropertyValue 'Verified official fallback' -Force
        $staged | Add-Member -NotePropertyName AlreadyInstalled -NotePropertyValue $false -Force
        $staged | Add-Member -NotePropertyName Preview -NotePropertyValue "Verified official ReShade $($staged.Version) fallback" -Force
        return $staged
    }
    [pscustomobject]@{
        Runtime=$null; Ini=$null; Version=$script:ReShadeVersion; Installer=$null; Url=$script:ReShadeInstallerUrl
        SourceMode='Verified official fallback'; AlreadyInstalled=$false
        Preview="No existing/local ReShade selected; use the verified official ReShade $($script:ReShadeVersion) fallback"
    }
}

function Get-StagedReShadeFiles {
    if ($script:PreparedReShade) { return $script:PreparedReShade }
    $installer = Get-ReShadeInstaller
    $stageRoot = Join-Path $script:CacheRoot ("ReShade-$($script:ReShadeVersion)-dxgi-x64")
    $stageExe = Join-Path $stageRoot 'DLSS5LauncherStage.exe'
    $runtime = Join-Path $stageRoot 'dxgi.dll'
    $ini = Join-Path $stageRoot 'ReShade.ini'

    if (-not (Test-Path -LiteralPath $stageRoot -PathType Container)) { New-Item -ItemType Directory -Path $stageRoot -Force | Out-Null }
    foreach ($name in @('DLSS5LauncherStage.exe','dxgi.dll','ReShade.ini','ReShadePreset.ini','ReShade.log')) {
        $candidate = Join-Path $stageRoot $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Remove-Item -LiteralPath $candidate -Force }
    }
    $systemExe = Join-Path $env:WINDIR 'System32\notepad.exe'
    if (-not (Test-Path -LiteralPath $systemExe -PathType Leaf) -or (Get-PeArchitecture $systemExe) -ne '64-bit') {
        throw 'A trusted 64-bit Windows staging executable was not available.'
    }
    Copy-Item -LiteralPath $systemExe -Destination $stageExe -Force
    Write-AppLog "Staging the official ReShade $($script:ReShadeVersion) full add-on runtime for 64-bit DX11/DX12 (DXGI)."
    $quotedStageExe = '"' + $stageExe + '"'
    try {
        $process = Start-Process -FilePath $installer -ArgumentList @('--headless','--api','dxgi',$quotedStageExe) -PassThru -Wait
    }
    catch {
        $code = Get-NativeErrorCode $_.Exception
        if ($code -eq 5 -or $_.Exception -is [System.UnauthorizedAccessException]) {
            throw "Windows denied permission to start the official ReShade installer (error 5): $installer`r`n`r`nThis VM blocks the child installer. No administrator access is required: select a local 64-bit ReShade full add-on runtime in the launcher, or install ReShade manually beside the game and rerun the launcher."
        }
        throw "The official ReShade installer could not be started: $($_.Exception.Message)"
    }
    if ($process.ExitCode -eq 5) {
        throw "The official ReShade installer returned access denied (error 5): $installer`r`n`r`nSelect a local 64-bit ReShade full add-on runtime instead. This launcher will not request administrator access."
    }
    if ($process.ExitCode -ne 0) { throw "The official ReShade installer exited with code $($process.ExitCode) while staging the DXGI runtime." }

    if (-not (Test-IsReShadeRuntime $runtime)) { throw 'The official ReShade installer did not produce a recognizable ReShade DXGI runtime.' }
    if ((Get-PeArchitecture $runtime) -ne '64-bit') { throw 'The staged ReShade DXGI runtime is not 64-bit.' }
    if (-not (Test-Path -LiteralPath $ini -PathType Leaf)) { throw 'The official ReShade installer did not produce ReShade.ini.' }
    $iniLines = New-Object System.Collections.Generic.List[string]
    $iniChanged = $false
    foreach ($line in @(Get-Content -LiteralPath $ini)) {
        $normalized = [string]$line
        if ($normalized -match '^(?i)(EffectSearchPaths|TextureSearchPaths)=' -and $normalized.Contains('\**\**')) {
            $normalized = $normalized.Replace('\**\**','\**')
            $iniChanged = $true
        }
        $iniLines.Add($normalized)
    }
    if ($iniChanged) {
        [System.IO.File]::WriteAllLines($ini, [string[]]$iniLines, (New-Object System.Text.UTF8Encoding($false)))
        Write-AppLog 'Normalized the ReShade shader/texture search paths for Windows.' 'OK'
    }
    $info = [System.Diagnostics.FileVersionInfo]::GetVersionInfo($runtime)
    if ($info.FileVersion -notlike "$($script:ReShadeVersion).*") { throw "Expected ReShade $($script:ReShadeVersion), but the staged runtime reports $($info.FileVersion)." }
    Write-AppLog "Prepared official ReShade $($info.FileVersion) DXGI runtime (SHA-256 $(Get-Sha256 $runtime))." 'OK'
    $script:PreparedReShade = [pscustomobject]@{ Runtime=$runtime; Ini=$ini; Version=[string]$info.FileVersion; Installer=$installer; Url=$script:ReShadeInstallerUrl }
    return $script:PreparedReShade
}

function Find-SupportFile {
    param([Parameter(Mandatory=$true)][string]$Root, [Parameter(Mandatory=$true)][string]$Name)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return $null }
    @(Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name -ErrorAction SilentlyContinue) | Select-Object -First 1
}

function Test-NvidiaSignature {
    param([Parameter(Mandatory=$true)][string]$Path)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path
    $subject = if ($sig.SignerCertificate) { [string]$sig.SignerCertificate.Subject } else { '' }
    [pscustomobject]@{ IsValidNvidia=($sig.Status -eq 'Valid' -and $subject -match '(?i)NVIDIA'); Status=[string]$sig.Status; Subject=$subject }
}

function Test-GameClosed {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    $resolved = [System.IO.Path]::GetFullPath($ExePath)
    foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
        try { if ($process.Path -and [System.IO.Path]::GetFullPath($process.Path) -eq $resolved) { return $false } } catch { }
    }
    return $true
}

function Get-ReShadeStatus {
    param([Parameter(Mandatory=$true)][string]$GameDirectory)
    foreach ($name in @('dxgi.dll','d3d11.dll','d3d12.dll')) {
        $path = Join-Path $GameDirectory $name
        if (Test-Path -LiteralPath $path) {
            try {
                if (Test-IsReShadeRuntime $path) { return [pscustomobject]@{ Installed=$true; Path=$path } }
            } catch { }
        }
    }
    [pscustomobject]@{ Installed=$false; Path='' }
}

function New-InstallPlan {
    param(
        [Parameter(Mandatory=$true)][string]$ExePath,
        [Parameter(Mandatory=$true)]$Route,
        [Parameter(Mandatory=$true)][string]$Gpu,
        [Parameter(Mandatory=$true)][string]$FilesRoot,
        [string]$ReShadeRuntimePath,
        [bool]$PermitPatched40 = $false,
        [bool]$FetchRemote = $false
    )
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { throw 'Select a real game executable.' }
    if ((Get-PeArchitecture $ExePath) -ne '64-bit') { throw 'This launcher installs only 64-bit DX11/DX12 games.' }
    if (-not $Route.CanInstall) { throw $Route.Summary }
    if (-not (Test-Path -LiteralPath $FilesRoot -PathType Container)) { throw 'Select the folder containing your user-supplied RenoDX/NVIDIA support files.' }

    $dir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($ExePath))
    Assert-DirectoryWritable $dir
    $core = Find-SupportFile -Root $FilesRoot -Name 'renodx-dlss5.addon64'
    $model = Find-SupportFile -Root $FilesRoot -Name 'nvngx_dlssnr.dll'
    $upscaler = Find-SupportFile -Root $FilesRoot -Name 'nvngx_dlss.dll'
    if (-not $core) { throw 'renodx-dlss5.addon64 was not found in the selected support-files folder.' }
    if (-not $model) { throw 'nvngx_dlssnr.dll was not found in the selected support-files folder.' }
    if ($Route.NeedsUpscalerDll -and -not $upscaler -and -not (Test-Path -LiteralPath (Join-Path $dir 'nvngx_dlss.dll'))) {
        throw 'This game has no native DLSS, so nvngx_dlss.dll must also be present in the selected support-files folder.'
    }

    $modelSignature = Test-NvidiaSignature $model.FullName
    if ($Gpu -eq 'RTX 50 series' -and -not $modelSignature.IsValidNvidia) {
        throw "RTX 50 mode requires an NVIDIA-signed nvngx_dlssnr.dll. Signature status: $($modelSignature.Status)."
    }
    if ($Gpu -eq 'RTX 40 series (experimental)' -and -not $PermitPatched40) {
        throw 'Tick the RTX 40 experimental acknowledgement before using a patched model DLL.'
    }
    if ($Gpu -eq 'RTX 40 series (experimental)' -and $modelSignature.IsValidNvidia) {
        throw 'The selected nvngx_dlssnr.dll is still a valid original NVIDIA file. The experimental RTX 40 route requires the user-supplied patched build described by that community guide.'
    }

    $copies = New-Object System.Collections.Generic.List[object]
    $removals = New-Object System.Collections.Generic.List[string]
    $sources = New-Object System.Collections.Generic.List[object]
    $remotePreview = New-Object System.Collections.Generic.List[string]

    $resolvedReShade = Resolve-ReShadeSource -GameDirectory $dir -RuntimePath $ReShadeRuntimePath -FetchRemote $FetchRemote
    if ($FetchRemote) {
        if (-not $resolvedReShade.AlreadyInstalled) {
            $copies.Add([pscustomobject]@{ Source=$resolvedReShade.Runtime; Relative='dxgi.dll'; Origin="$($resolvedReShade.SourceMode): ReShade $($resolvedReShade.Version) full add-on runtime (DXGI, 64-bit)" })
        }
        foreach ($alternate in @('d3d11.dll','d3d12.dll')) {
            $alternatePath = Join-Path $dir $alternate
            if (Test-IsReShadeRuntime $alternatePath) { $removals.Add($alternate) }
        }
        if (-not $resolvedReShade.AlreadyInstalled) {
            $sources.Add([pscustomobject]@{ Name='ReShade full add-on runtime'; Version=$resolvedReShade.Version; Url=$resolvedReShade.Url; Path=$resolvedReShade.Runtime; Sha256=(Get-Sha256 $resolvedReShade.Runtime); SourceMode=$resolvedReShade.SourceMode })
        }
    }
    else {
        $remotePreview.Add($resolvedReShade.Preview)
        foreach ($alternate in @('d3d11.dll','d3d12.dll')) {
            if (Test-IsReShadeRuntime (Join-Path $dir $alternate)) { $removals.Add($alternate) }
        }
    }

    $copies.Add([pscustomobject]@{ Source=$core.FullName; Relative='renodx-dlss5.addon64'; Origin='User supplied' })
    $copies.Add([pscustomobject]@{ Source=$model.FullName; Relative='nvngx_dlssnr.dll'; Origin='User supplied' })
    if ($Route.NeedsUpscalerDll -and $upscaler) { $copies.Add([pscustomobject]@{ Source=$upscaler.FullName; Relative='nvngx_dlss.dll'; Origin='User supplied' }) }

    if ($FetchRemote) {
        if ($Route.NeedsBridge) {
            $bridge = Get-GitHubAsset -Repository $script:BridgeRepo -AssetName 'dlss5-dx11-bridge.addon64'
            $bridgeLicense = Get-GitHubRepositoryFile -Repository $script:BridgeRepo -Ref $bridge.Version -RepositoryPath 'LICENSE' -CacheName 'bridge-LICENSE.txt'
            $copies.Add([pscustomobject]@{ Source=$bridge.Path; Relative='dlss5-dx11-bridge.addon64'; Origin="$($script:BridgeRepo) $($bridge.Version)" })
            $copies.Add([pscustomobject]@{ Source=$bridgeLicense; Relative='DLSS5-ThirdParty-Notices\dx11-bridge-LICENSE.txt'; Origin="$($script:BridgeRepo) license" })
            $sources.Add($bridge)
            $removals.Add('dlss5-feed.addon64')
        }
        elseif ($Route.NeedsFeeder) {
            $addon = Get-GitHubAsset -Repository $script:FeederRepo -AssetName 'dlss5-feed.addon64'
            $fx = Get-GitHubAsset -Repository $script:FeederRepo -AssetName 'DLSS5_Feed.fx'
            if ($addon.Version -notmatch '^v0\.6\.') { throw "This launcher was tested with Feeder 0.6.x, but GitHub reports $($addon.Version). Update the launcher before installing a different Feeder series." }
            $feederLicense = Get-GitHubRepositoryFile -Repository $script:FeederRepo -Ref $addon.Version -RepositoryPath 'LICENSE' -CacheName 'feeder-LICENSE.txt'
            $copies.Add([pscustomobject]@{ Source=$addon.Path; Relative='dlss5-feed.addon64'; Origin="$($script:FeederRepo) $($addon.Version)" })
            $copies.Add([pscustomobject]@{ Source=$fx.Path; Relative='reshade-shaders\Shaders\DLSS5_Feed.fx'; Origin="$($script:FeederRepo) $($fx.Version)" })
            $copies.Add([pscustomobject]@{ Source=$feederLicense; Relative='DLSS5-ThirdParty-Notices\DLSS5-Feeder-LICENSE.txt'; Origin="$($script:FeederRepo) license" })
            $sources.Add($addon); $sources.Add($fx)
            $lumenite = Get-LumeniteFiles
            foreach ($mapping in $lumenite.Mappings) {
                $copies.Add([pscustomobject]@{ Source=$mapping.Source; Relative=$mapping.Relative; Origin="$($script:LumeniteRepo) $($lumenite.Version)" })
            }
            $copies.Add([pscustomobject]@{ Source=$lumenite.LicenseFile; Relative='DLSS5-ThirdParty-Notices\LumeniteFX-LICENSE.md'; Origin="$($script:LumeniteRepo) license" })
            $copies.Add([pscustomobject]@{ Source=$lumenite.NoticeFile; Relative='DLSS5-ThirdParty-Notices\LumeniteFX-NOTICE.txt'; Origin="$($script:LumeniteRepo) notice" })
            $reshadeFxh = Get-ReShadeCoreShader
            $copies.Add([pscustomobject]@{ Source=$reshadeFxh.Path; Relative='reshade-shaders\Shaders\ReShade.fxh'; Origin="$($script:ReShadeShadersRepo) $($reshadeFxh.Version) (CC0-1.0)" })
            $sources.Add($lumenite)
            $sources.Add($reshadeFxh)
            $removals.Add('dlss5-dx11-bridge.addon64')
        }
        else {
            $removals.Add('dlss5-dx11-bridge.addon64')
            $removals.Add('dlss5-feed.addon64')
        }

        $targetIni = Join-Path $dir 'ReShade.ini'
        if ($Route.NeedsFeeder) {
            $iniBase = if (Test-Path -LiteralPath $targetIni -PathType Leaf) { $targetIni } elseif ($resolvedReShade.Ini) { $resolvedReShade.Ini } else { New-DefaultReShadeIni }
            $configuredIni = New-ConfiguredReShadeIni -SourceIniPath $iniBase
            $copies.Add([pscustomobject]@{ Source=$configuredIni; Relative='ReShade.ini'; Origin='ReShade configuration with DLSS5_MV_PROVIDER=3 and launcher preset path' })

            $presetSource = $null
            if (Test-Path -LiteralPath $targetIni -PathType Leaf) {
                foreach ($line in @(Get-Content -LiteralPath $targetIni)) {
                    if ($line -match '^(?i)PresetPath=(.+)$') {
                        $existingPresetValue = $matches[1].Trim().Trim('"')
                        if ($existingPresetValue) {
                            $candidatePreset = if ([System.IO.Path]::IsPathRooted($existingPresetValue)) { $existingPresetValue } else { Join-Path $dir $existingPresetValue }
                            if (Test-Path -LiteralPath $candidatePreset -PathType Leaf) { $presetSource=$candidatePreset }
                        }
                        break
                    }
                }
            }
            if (-not $presetSource) {
                $defaultPreset = Join-Path $dir 'ReShadePreset.ini'
                if (Test-Path -LiteralPath $defaultPreset -PathType Leaf) { $presetSource=$defaultPreset }
            }
            $configuredPreset = New-ConfiguredReShadePreset -SourcePresetPath $presetSource
            $copies.Add([pscustomobject]@{ Source=$configuredPreset; Relative='ReShadePreset.ini'; Origin='Launcher preset: enable Lumenite Kernel above DLSS 5 Feed' })
        }
        elseif (-not (Test-Path -LiteralPath $targetIni -PathType Leaf)) {
            $iniSource = if ($resolvedReShade.Ini) { $resolvedReShade.Ini } else { New-DefaultReShadeIni }
            $copies.Add([pscustomobject]@{ Source=$iniSource; Relative='ReShade.ini'; Origin="Configuration for $($resolvedReShade.SourceMode)" })
        }
    }
    else {
        if ($Route.NeedsBridge) {
            $remotePreview.Add('dlss5-dx11-bridge.addon64 + license (latest verified official Bridge release)')
            $removals.Add('dlss5-feed.addon64')
        }
        elseif ($Route.NeedsFeeder) {
            $remotePreview.Add('dlss5-feed.addon64 + DLSS5_Feed.fx + license (verified Feeder 0.6.x release)')
            $remotePreview.Add('LumeniteFX Shaders/Textures + license/notice (pinned verified official commit)')
            $remotePreview.Add('ReShade.fxh core shader include (pinned verified official ReShade shader commit, CC0-1.0)')
            $remotePreview.Add('ReShade.ini: preserve existing definitions and set DLSS5_MV_PROVIDER=3')
            $remotePreview.Add('ReShadePreset.ini: preserve existing techniques and enable Lumenite Kernel above DLSS 5 Feed')
            $removals.Add('dlss5-dx11-bridge.addon64')
        }
        else {
            $removals.Add('dlss5-dx11-bridge.addon64')
            $removals.Add('dlss5-feed.addon64')
        }
    }

    [pscustomobject]@{
        ExePath=$ExePath
        GameDirectory=$dir
        Route=$Route
        Gpu=$Gpu
        Copies=@($copies | ForEach-Object { $_ })
        Removals=@($removals | ForEach-Object { $_ })
        RemoteSources=@($sources | ForEach-Object { $_ })
        RemotePreview=@($remotePreview | ForEach-Object { $_ })
        ModelSignature=$modelSignature
        ReShadeSource=$resolvedReShade.SourceMode
        ReShadeSummary=$resolvedReShade.Preview
    }
}

function Format-InstallPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Plan.Route.Title)
    $lines.Add('Target: ' + $Plan.GameDirectory)
    $lines.Add('ReShade: ' + $Plan.ReShadeSummary)
    $lines.Add('')
    $lines.Add('Files to install/update:')
    foreach ($item in $Plan.Copies) { $lines.Add(('  + {0}  [{1}]' -f $item.Relative, $item.Origin)) }
    foreach ($item in $Plan.RemotePreview) { $lines.Add('  + ' + $item) }
    if ($Plan.Route.NeedsFeeder -and -not ($Plan.Copies.Relative -contains 'ReShade.ini') -and -not ($Plan.RemotePreview -match '^ReShade\.ini')) {
        $lines.Add('  + ReShade.ini provider setting after ReShade has created that file')
    }
    $existingRemovals = @($Plan.Removals | Where-Object { Test-Path -LiteralPath (Join-Path $Plan.GameDirectory $_) })
    if ($existingRemovals.Count -gt 0) {
        $lines.Add('')
        $lines.Add('Conflicting route files to back up and remove:')
        foreach ($item in $existingRemovals) { $lines.Add('  - ' + $item) }
    }
    $lines.Add('')
    $lines.Add('Every replaced/removed file is backed up before the change.')
    $lines -join [Environment]::NewLine
}

function Copy-Atomically {
    param([Parameter(Mandatory=$true)][string]$Source, [Parameter(Mandatory=$true)][string]$Destination)
    $parent = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($Destination))
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = Join-Path $parent ('.dlss5-launcher-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    }
    catch {
        $code = Get-NativeErrorCode $_.Exception
        if ($code -eq 5 -or $_.Exception -is [System.UnauthorizedAccessException]) {
            throw "Windows denied access while writing '$Destination' (error 5). No elevation will be requested. Confirm that your Windows account can modify this game folder and that the game is closed."
        }
        throw
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue } }
}

function Get-ReversedItems {
    param([object[]]$Items)
    $copy = @($Items)
    [array]::Reverse($copy)
    return $copy
}

function Invoke-InstallPlan {
    param([Parameter(Mandatory=$true)]$Plan)
    if (-not (Test-GameClosed $Plan.ExePath)) { throw 'The selected game is running. Close it before installing.' }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $gameKeyBytes = [System.Text.Encoding]::UTF8.GetBytes(([System.IO.Path]::GetFullPath($Plan.ExePath)).ToLowerInvariant())
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $gameKey = ([BitConverter]::ToString($sha.ComputeHash($gameKeyBytes))).Replace('-','').Substring(0,16).ToLowerInvariant() } finally { $sha.Dispose() }
    $backupDir = Join-Path $script:BackupRoot (Join-Path $gameKey $stamp)
    $fileBackupDir = Join-Path $backupDir 'files'
    New-Item -ItemType Directory -Path $fileBackupDir -Force | Out-Null
    $operations = New-Object System.Collections.Generic.List[object]
    $sequence = 0
    try {
        foreach ($item in $Plan.Copies) {
            $sequence++
            $destination = Join-Path $Plan.GameDirectory $item.Relative
            $existed = Test-Path -LiteralPath $destination -PathType Leaf
            $backup = $null
            $oldHash = $null
            if ($existed) {
                $backup = Join-Path $fileBackupDir ('{0:D3}-{1}' -f $sequence, [System.IO.Path]::GetFileName($destination))
                Copy-Item -LiteralPath $destination -Destination $backup -Force
                $oldHash = Get-Sha256 $destination
            }
            Copy-Atomically -Source $item.Source -Destination $destination
            $operations.Add([pscustomobject]@{
                Action='Copy'; Destination=$destination; Relative=$item.Relative; Existed=$existed; Backup=$backup
                OldSha256=$oldHash; NewSha256=(Get-Sha256 $destination); SourceSha256=(Get-Sha256 $item.Source); Origin=$item.Origin
            })
            Write-AppLog "Installed $($item.Relative)." 'OK'
        }
        foreach ($relative in $Plan.Removals) {
            $destination = Join-Path $Plan.GameDirectory $relative
            if (Test-Path -LiteralPath $destination -PathType Leaf) {
                $sequence++
                $backup = Join-Path $fileBackupDir ('{0:D3}-{1}' -f $sequence, [System.IO.Path]::GetFileName($destination))
                Copy-Item -LiteralPath $destination -Destination $backup -Force
                $oldHash = Get-Sha256 $destination
                Remove-Item -LiteralPath $destination -Force
                $operations.Add([pscustomobject]@{ Action='Remove'; Destination=$destination; Relative=$relative; Existed=$true; Backup=$backup; OldSha256=$oldHash; NewSha256=$null; SourceSha256=$null; Origin='Conflicting route cleanup' })
                Write-AppLog "Backed up and removed conflicting $relative." 'OK'
            }
        }
        $manifest = [ordered]@{
            SchemaVersion=1; LauncherVersion=$script:Version; Created=(Get-Date).ToString('o'); Status='Complete'
            ExePath=$Plan.ExePath; GameDirectory=$Plan.GameDirectory; Route=$Plan.Route.Id; RouteTitle=$Plan.Route.Title; Gpu=$Plan.Gpu
            Operations=@($operations | ForEach-Object { $_ }); LogPath=$script:LogPath
        }
        $manifestPath = Join-Path $backupDir 'manifest.json'
        $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
        Set-InstallIndex -ExePath $Plan.ExePath -ManifestPath $manifestPath
        Write-AppLog "Install manifest: $manifestPath" 'OK'
        return $manifestPath
    }
    catch {
        Write-AppLog ('Install failed: ' + $_.Exception.Message) 'ERROR'
        # Roll back only operations already completed in this transaction.
        foreach ($op in @(Get-ReversedItems @($operations | ForEach-Object { $_ }))) {
            try {
                if ($op.Existed -and $op.Backup) { Copy-Atomically -Source $op.Backup -Destination $op.Destination }
                elseif (-not $op.Existed -and (Test-Path -LiteralPath $op.Destination -PathType Leaf)) { Remove-Item -LiteralPath $op.Destination -Force }
            } catch { Write-AppLog ('Emergency rollback failed for ' + $op.Destination + ': ' + $_.Exception.Message) 'ERROR' }
        }
        throw
    }
}

function Get-InstallIndex {
    if (-not (Test-Path -LiteralPath $script:IndexPath)) { return @{} }
    try {
        $obj = Get-Content -LiteralPath $script:IndexPath -Raw | ConvertFrom-Json
        $map = @{}
        foreach ($prop in $obj.PSObject.Properties) { $map[$prop.Name] = [string]$prop.Value }
        return $map
    } catch { return @{} }
}

function Set-InstallIndex {
    param([Parameter(Mandatory=$true)][string]$ExePath, [Parameter(Mandatory=$true)][string]$ManifestPath)
    $map = Get-InstallIndex
    $key = ([System.IO.Path]::GetFullPath($ExePath)).ToLowerInvariant()
    $map[$key] = $ManifestPath
    $ordered = [ordered]@{}
    foreach ($name in @($map.Keys | Sort-Object)) { $ordered[$name] = $map[$name] }
    $ordered | ConvertTo-Json | Set-Content -LiteralPath $script:IndexPath -Encoding UTF8
}

function Invoke-Rollback {
    param([Parameter(Mandatory=$true)][string]$ExePath)
    if (-not (Test-GameClosed $ExePath)) { throw 'The selected game is running. Close it before rollback.' }
    $map = Get-InstallIndex
    $key = ([System.IO.Path]::GetFullPath($ExePath)).ToLowerInvariant()
    if (-not $map.ContainsKey($key) -or -not (Test-Path -LiteralPath $map[$key])) { throw 'No launcher backup was found for this executable.' }
    $manifestPath = $map[$key]
    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.Status -eq 'RolledBack') { throw 'The most recent launcher install has already been rolled back.' }
    foreach ($op in @(Get-ReversedItems @($manifest.Operations))) {
        if ($op.Existed -and $op.Backup -and (Test-Path -LiteralPath $op.Backup)) {
            Copy-Atomically -Source $op.Backup -Destination $op.Destination
            Write-AppLog "Restored $($op.Relative)." 'OK'
        }
        elseif (-not $op.Existed -and (Test-Path -LiteralPath $op.Destination -PathType Leaf)) {
            $currentHash = Get-Sha256 $op.Destination
            if ($currentHash -eq $op.NewSha256) {
                Remove-Item -LiteralPath $op.Destination -Force
                Write-AppLog "Removed launcher-added $($op.Relative)." 'OK'
            }
            else { Write-AppLog "Kept modified $($op.Relative); its hash changed after installation." 'WARN' }
        }
    }
    $manifest.Status = 'RolledBack'
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    return $manifestPath
}

function Test-DecisionMatrix {
    $cases = @(
        @('RTX 50 series','DirectX 12','Yes','Dx12Native',$true),
        @('RTX 50 series','DirectX 11','Yes','Dx11Bridge',$true),
        @('RTX 50 series','DirectX 11','No','Feeder',$true),
        @('RTX 50 series','DirectX 12','No','Feeder',$true),
        @('RTX 40 series (experimental)','DirectX 11','Yes','Dx11Bridge',$true),
        @('RTX 50 series','Vulkan','No','AdvancedVulkan',$false),
        @('Other / unsupported','DirectX 12','Yes','UnsupportedGpu',$false),
        @('RTX 50 series','Unknown','Yes','NeedsAnswers',$false),
        @('RTX 50 series','DirectX 12','Unsure','NeedsAnswers',$false)
    )
    $failed = 0
    foreach ($case in $cases) {
        $route = Resolve-InstallRoute -Gpu $case[0] -Api $case[1] -HasNativeDlss $case[2]
        $ok = ($route.Id -eq $case[3] -and $route.CanInstall -eq $case[4])
        if ($ok) { Write-AppLog ("PASS {0}/{1}/{2} -> {3}" -f $case[0],$case[1],$case[2],$route.Id) 'OK' }
        else { Write-AppLog ("FAIL {0}/{1}/{2}: got {3}/{4}" -f $case[0],$case[1],$case[2],$route.Id,$route.CanInstall) 'ERROR'; $failed++ }
    }
    if ($failed -gt 0) { throw "$failed decision-matrix test(s) failed." }
    Write-AppLog "All $($cases.Count) decision-matrix tests passed." 'OK'
}

function Test-BackupRoundTrip {
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DLSS5-Launcher-SelfTest-' + [guid]::NewGuid().ToString('N'))
    $gameDir = Join-Path $testRoot 'game'
    $sourceDir = Join-Path $testRoot 'support'
    New-Item -ItemType Directory -Path $gameDir,$sourceDir -Force | Out-Null
    try {
        $testExeSource = Join-Path $env:WINDIR 'System32\notepad.exe'
        $testExe = Join-Path $gameDir 'test-game.exe'
        Copy-Item -LiteralPath $testExeSource -Destination $testExe
        Set-Content -LiteralPath (Join-Path $sourceDir 'renodx-dlss5.addon64') -Value 'self-test-addon' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $sourceDir 'nvngx_dlssnr.dll') -Value 'self-test-model' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $gameDir 'renodx-dlss5.addon64') -Value 'original-addon' -Encoding ASCII
        $route = Resolve-InstallRoute -Gpu 'RTX 40 series (experimental)' -Api 'DirectX 12' -HasNativeDlss 'Yes'
        $plan = New-InstallPlan -ExePath $testExe -Route $route -Gpu 'RTX 40 series (experimental)' -FilesRoot $sourceDir -PermitPatched40 $true -FetchRemote $false
        $manifest = Invoke-InstallPlan $plan
        if ((Get-Content -LiteralPath (Join-Path $gameDir 'renodx-dlss5.addon64') -Raw).Trim() -ne 'self-test-addon') { throw 'Install phase did not replace the test add-on.' }
        if (-not (Test-Path -LiteralPath (Join-Path $gameDir 'nvngx_dlssnr.dll'))) { throw 'Install phase did not add the test model.' }
        Invoke-Rollback $testExe | Out-Null
        if ((Get-Content -LiteralPath (Join-Path $gameDir 'renodx-dlss5.addon64') -Raw).Trim() -ne 'original-addon') { throw 'Rollback did not restore the original add-on.' }
        if (Test-Path -LiteralPath (Join-Path $gameDir 'nvngx_dlssnr.dll')) { throw 'Rollback did not remove the launcher-added model.' }
        if (-not (Test-Path -LiteralPath $manifest)) { throw 'The install manifest was not preserved.' }
        Write-AppLog 'Backup/install/rollback round-trip test passed.' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-PortableStorage {
    <#
        Storage-root selection is driven through the Get-DataRootCandidate /
        Resolve-WritableRoot seam with synthetic paths, so the fallback cases are
        deterministic on any machine. Reproducing an ACL denial belongs in a
        separate Windows integration test, not here.
    #>
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DLSS5-Launcher-Storage-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        # The portable folder beside the launcher wins when it is usable.
        $scriptRoot = Join-Path $testRoot 'launcher'
        $tempRoot = Join-Path $testRoot 'temp'
        New-Item -ItemType Directory -Path $scriptRoot,$tempRoot -Force | Out-Null
        $portable = Resolve-WritableRoot (Get-DataRootCandidate -Explicit '' -ScriptRoot $scriptRoot -TempRoot $tempRoot)
        if (-not $portable.Resolved) { throw 'A writable launcher folder did not resolve to a portable data root.' }
        if ($portable.Kind -ne 'portable') { throw "Expected the portable data root, got '$($portable.Kind)'." }
        if ($portable.Path -ne (Join-Path $scriptRoot 'Data')) { throw "Portable data root landed in the wrong place: $($portable.Path)" }

        # An explicit -DataRoot outranks the portable default.
        $explicitPath = Join-Path $testRoot 'explicit'
        $explicit = Resolve-WritableRoot (Get-DataRootCandidate -Explicit $explicitPath -ScriptRoot $scriptRoot -TempRoot $tempRoot)
        if ($explicit.Kind -ne 'explicit' -or $explicit.Path -ne $explicitPath) { throw 'An explicit data root did not take priority.' }

        # A file where the directory should be makes the primary location
        # unusable without needing ACL manipulation.
        $blockedRoot = Join-Path $testRoot 'blocked'
        New-Item -ItemType Directory -Path $blockedRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $blockedRoot 'Data') -Value 'not a directory' -Encoding ASCII
        $fallback = Resolve-WritableRoot (Get-DataRootCandidate -Explicit '' -ScriptRoot $blockedRoot -TempRoot $tempRoot)
        if (-not $fallback.Resolved) { throw 'An unusable portable folder did not fall back at all.' }
        if ($fallback.Kind -ne 'temp') { throw "Expected the temp fallback, got '$($fallback.Kind)'." }
        if ($fallback.Path -ne (Join-Path $tempRoot 'DLSS5-Guide-Launcher')) { throw "Fallback landed in the wrong place: $($fallback.Path)" }
        if (-not (Test-Path -LiteralPath $fallback.Path -PathType Container)) { throw 'The fallback data root was not actually created.' }
        if (Test-DirectoryUsable $fallback.Path) { throw 'The fallback data root is not writable.' }
        $rejected = @($fallback.Attempts | Where-Object { $_.Result -ne 'usable' })
        if ($rejected.Count -ne 1) { throw 'The rejected portable location was not recorded for the log.' }

        # Local App Data must never appear, whatever the profile looks like.
        foreach ($attempt in $fallback.Attempts) {
            if ($attempt.Path -match '(?i)AppData\\Local\\DLSS5-Guide-Launcher') { throw 'A candidate resolved into Local App Data.' }
        }

        # A null or empty %LOCALAPPDATA% is now irrelevant, and an invalid or
        # exhausted candidate list must report rather than throw.
        $none = Resolve-WritableRoot (Get-DataRootCandidate -Explicit '' -ScriptRoot '' -TempRoot '')
        if ($none.Resolved -or $none.Path) { throw 'An empty candidate list did not report an unresolved root.' }
        $invalid = Test-DirectoryUsable ([string][char]0x0001 + ':\\nope')
        if (-not $invalid) { throw 'An invalid path was reported as usable.' }

        Write-AppLog 'Portable data-root selection and fallback tests passed.' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-StartupContract {
    <#
        The exit-code table and the startup instrumentation are a contract with
        the batch wrapper, which reports the failing subsystem purely from the
        code. Assert the mapping rather than trusting it to stay in step.
    #>
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DLSS5-Launcher-Startup-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        $cases = @(
            @('Startup.Storage', $script:ExitCode.StartupStorage),
            @('Ui.Assemblies',   $script:ExitCode.StartupAssemblies),
            @('Ui.Construction', $script:ExitCode.StartupUi),
            @('Ui.Show',         $script:ExitCode.StartupUi),
            @('Install.Plan',    $script:ExitCode.InstallFailed),
            @('Install.Apply',   $script:ExitCode.InstallFailed),
            @('Rollback',        $script:ExitCode.RollbackFailed),
            @('SelfTest',        $script:ExitCode.SelfTestFailed),
            @('Script.Load',     $script:ExitCode.StartupUnexpected)
        )
        foreach ($case in $cases) {
            $actual = Get-ExitCodeForStage $case[0]
            if ($actual -ne $case[1]) { throw "Stage '$($case[0])' mapped to exit code $actual, expected $($case[1])." }
        }

        $values = @($script:ExitCode.Values)
        if (@($values | Sort-Object -Unique).Count -ne $values.Count) { throw 'The documented exit codes are not distinct.' }
        foreach ($value in $values) {
            if ($value -ge 10 -and $value -le 19) { throw "Exit code $value collides with the bootstrap wrapper's reserved 10-19 band." }
        }

        # The sentinel is what lets the wrapper distinguish "never began" from
        # "began and failed", and it must be best effort in both directions.
        $previous = $env:DLSS5_STARTUP_SENTINEL
        try {
            $sentinel = Join-Path $testRoot 'sentinel.tmp'
            $env:DLSS5_STARTUP_SENTINEL = $sentinel
            Write-StartupSentinel
            if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf)) { throw 'The startup sentinel was not written.' }

            $env:DLSS5_STARTUP_SENTINEL = Join-Path $testRoot 'missing-parent\nested\sentinel.tmp'
            Write-StartupSentinel

            $env:DLSS5_STARTUP_SENTINEL = ''
            Write-StartupSentinel
        }
        finally { $env:DLSS5_STARTUP_SENTINEL = $previous }

        # A blocked GPU query must report a manual choice, never a hardware verdict.
        $gpu = Get-DetectedGpuClass
        if (-not $gpu.PSObject.Properties['Detected']) { throw 'GPU detection did not report whether it succeeded.' }
        if ([string]::IsNullOrWhiteSpace([string]$gpu.Class)) { throw 'GPU detection returned no class at all.' }

        # A failure the user never saw on screen still has to be legible in the
        # log afterwards, so drive the reporter directly rather than trusting it.
        $savedCode = $script:PendingExitCode
        $savedStage = $script:StartupStage
        try {
            $script:StartupStage = 'Ui.Construction'
            $probe = New-Object System.IO.FileNotFoundException('a synthetic startup failure for the self-test')
            $record = New-Object System.Management.Automation.ErrorRecord($probe, 'SelfTestProbe', [System.Management.Automation.ErrorCategory]::NotSpecified, $null)
            Write-StartupFailure $record
            if ($script:PendingExitCode -ne $script:ExitCode.StartupUi) {
                throw "A UI-stage failure mapped to exit code $($script:PendingExitCode), expected $($script:ExitCode.StartupUi)."
            }
            if ($script:LogPath) {
                $logged = Get-Content -LiteralPath $script:LogPath -Raw
                foreach ($required in @('Stage:         Ui.Construction', 'System.IO.FileNotFoundException', 'a synthetic startup failure', 'HRESULT:', 'Windows error:')) {
                    if (-not $logged.Contains($required)) { throw "The startup failure log is missing: $required" }
                }
            }
        }
        finally {
            $script:PendingExitCode = $savedCode
            $script:StartupStage = $savedStage
        }

        Write-AppLog 'Startup contract, sentinel and exit-code mapping tests passed.' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Test-NoAdminHelpers {
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DLSS5-Launcher-NoAdmin-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        Assert-DirectoryWritable $testRoot
        if (@(Get-ChildItem -LiteralPath $testRoot -Filter '.dlss5-write-check-*.tmp' -File).Count -ne 0) {
            throw 'The write-access preflight left a probe file behind.'
        }
        $ini = New-DefaultReShadeIni
        $text = Get-Content -LiteralPath $ini -Raw
        foreach ($required in @('[GENERAL]','AddonPath=.','DisabledAddons=','EffectSearchPaths=.\reshade-shaders\Shaders\**')) {
            if (-not $text.Contains($required)) { throw "Generated ReShade.ini is missing: $required" }
        }
        $fallback = Resolve-ReShadeSource -GameDirectory $testRoot -FetchRemote $false
        if ($fallback.SourceMode -ne 'Verified official fallback' -or $fallback.Runtime) {
            throw 'ReShade source resolver did not produce the expected no-download fallback preview.'
        }
        $fakeDxgi = Join-Path $testRoot 'dxgi.dll'
        Set-Content -LiteralPath $fakeDxgi -Value 'not reshade' -Encoding ASCII
        $blockedUnknownProxy = $false
        try { Resolve-ReShadeSource -GameDirectory $testRoot -FetchRemote $false | Out-Null }
        catch { $blockedUnknownProxy = $_.Exception.Message -match 'non-ReShade dxgi\.dll' }
        if (-not $blockedUnknownProxy) { throw 'ReShade source resolver did not block an unknown dxgi.dll.' }
        Write-AppLog 'No-admin write preflight and ReShade configuration tests passed.' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function New-ReShadeTestRuntime {
    <#
        Builds a real DLL whose Win32 version resource identifies it as ReShade
        and whose PE header says 64-bit, so the ReShade source rules are proven
        against a genuine file rather than a stub that flatters them.

        If the .NET Framework compiler is unavailable this throws rather than
        skipping: a silently skipped regression test is worse than none.
    #>
    param([Parameter(Mandatory=$true)][string]$Path)
    $typeName = 'DlssFiveReShadeFixture' + [guid]::NewGuid().ToString('N')
    $source = @"
using System.Reflection;
[assembly: AssemblyProduct("ReShade")]
[assembly: AssemblyTitle("ReShade")]
[assembly: AssemblyFileVersion("6.8.0.0")]
public class $typeName { }
"@
    try {
        $parameters = New-Object System.CodeDom.Compiler.CompilerParameters
        $parameters.OutputAssembly = $Path
        $parameters.GenerateExecutable = $false
        $parameters.GenerateInMemory = $false
        $parameters.CompilerOptions = '/platform:x64'
        Add-Type -TypeDefinition $source -CompilerParameters $parameters
    }
    catch {
        if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
            throw "The ReShade regression tests could not build their fixture DLL, so they cannot run: $($_.Exception.Message)"
        }
    }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw 'The ReShade regression tests could not build their fixture DLL, so they cannot run.'
    }
    return $Path
}

function Set-PeMachineForTest {
    <#
        Rewrites the PE machine field of a copy, so the architecture rule can be
        tested without a second compiler invocation that may not be loadable in
        this process.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Path,
        [Parameter(Mandatory=$true)][uint16]$Machine
    )
    $stream = [System.IO.File]::Open($Path, 'Open', 'ReadWrite', 'None')
    try {
        $reader = New-Object System.IO.BinaryReader($stream)
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        $stream.Position = $peOffset + 4
        $writer = New-Object System.IO.BinaryWriter($stream)
        $writer.Write($Machine)
        $writer.Flush()
    }
    finally { $stream.Dispose() }
}

function Test-ReShadeSourceSelection {
    <#
        The no-admin ReShade rules are the reason this build exists, and the
        surrounding work must not quietly change them. Assert the whole source
        priority rather than relying on reading the code.
    #>
    $testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('DLSS5-Launcher-ReShade-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    try {
        $runtime = New-ReShadeTestRuntime -Path (Join-Path $testRoot 'ReShade64.dll')
        if ((Get-PeArchitecture $runtime) -ne '64-bit') { throw 'The fixture runtime is not 64-bit; the tests below would prove nothing.' }
        if (-not (Test-IsReShadeRuntime $runtime)) { throw 'The fixture runtime is not recognised as ReShade; the tests below would prove nothing.' }

        # 1. A recognised runtime already beside the game is reused as-is, and
        #    no installer is prepared.
        $gameExisting = Join-Path $testRoot 'game-existing'
        New-Item -ItemType Directory -Path $gameExisting -Force | Out-Null
        Copy-Item -LiteralPath $runtime -Destination (Join-Path $gameExisting 'dxgi.dll')
        $existing = Resolve-ReShadeSource -GameDirectory $gameExisting -FetchRemote $false
        if ($existing.SourceMode -ne 'Existing game runtime') { throw "Expected the existing game runtime, got '$($existing.SourceMode)'." }
        if (-not $existing.AlreadyInstalled) { throw 'A reused runtime was not reported as already installed.' }
        if ($existing.Installer) { throw 'Reusing an existing runtime must not prepare the ReShade installer.' }

        # 2. Otherwise a runtime the user selected is imported.
        $gameSelected = Join-Path $testRoot 'game-selected'
        New-Item -ItemType Directory -Path $gameSelected -Force | Out-Null
        $selected = Resolve-ReShadeSource -GameDirectory $gameSelected -RuntimePath $runtime -FetchRemote $false
        if ($selected.SourceMode -ne 'User-selected local runtime') { throw "Expected the user-selected runtime, got '$($selected.SourceMode)'." }
        if ($selected.AlreadyInstalled) { throw 'A newly imported runtime was reported as already installed.' }
        if ($selected.Installer) { throw 'Importing a local runtime must not prepare the ReShade installer.' }
        if ($selected.Runtime -ne ([System.IO.Path]::GetFullPath($runtime))) { throw 'The selected runtime path was not preserved.' }

        # 3. Only with neither does the official fallback appear, and nothing is
        #    downloaded or executed to preview it.
        $gameFallback = Join-Path $testRoot 'game-fallback'
        New-Item -ItemType Directory -Path $gameFallback -Force | Out-Null
        $fallback = Resolve-ReShadeSource -GameDirectory $gameFallback -FetchRemote $false
        if ($fallback.SourceMode -ne 'Verified official fallback') { throw "Expected the official fallback, got '$($fallback.SourceMode)'." }
        if ($fallback.Runtime -or $fallback.Installer) { throw 'Previewing the fallback must not stage a runtime or an installer.' }

        # 4. An unknown proxy is refused, and left exactly as it was found.
        $gameUnknown = Join-Path $testRoot 'game-unknown'
        New-Item -ItemType Directory -Path $gameUnknown -Force | Out-Null
        $unknownDxgi = Join-Path $gameUnknown 'dxgi.dll'
        Set-Content -LiteralPath $unknownDxgi -Value 'some other mod loader' -Encoding ASCII
        $unknownHash = Get-Sha256 $unknownDxgi
        $refused = $false
        try { Resolve-ReShadeSource -GameDirectory $gameUnknown -RuntimePath $runtime -FetchRemote $false | Out-Null }
        catch { $refused = $_.Exception.Message -match 'non-ReShade dxgi\.dll' }
        if (-not $refused) { throw 'An unknown dxgi.dll was not refused.' }
        if ((Get-Sha256 $unknownDxgi) -ne $unknownHash) { throw 'An unknown dxgi.dll was modified despite the refusal.' }

        # 5. A runtime that is not 64-bit is refused, whatever it calls itself.
        $x86Runtime = Join-Path $testRoot 'ReShade32.dll'
        Copy-Item -LiteralPath $runtime -Destination $x86Runtime
        Set-PeMachineForTest -Path $x86Runtime -Machine ([uint16]0x014C)
        if ((Get-PeArchitecture $x86Runtime) -ne '32-bit') { throw 'The 32-bit fixture was not produced correctly.' }
        $rejectedArchitecture = $false
        try { Get-LocalReShadeFiles -Path $x86Runtime -SourceMode 'test' | Out-Null }
        catch { $rejectedArchitecture = $_.Exception.Message -match '32-bit' }
        if (-not $rejectedArchitecture) { throw 'A 32-bit ReShade runtime was not refused.' }

        # 6. A DLL that does not identify itself as ReShade is refused too.
        $notReShade = Join-Path $testRoot 'random.dll'
        Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\kernel32.dll') -Destination $notReShade
        $rejectedIdentity = $false
        try { Get-LocalReShadeFiles -Path $notReShade -SourceMode 'test' | Out-Null }
        catch { $rejectedIdentity = $_.Exception.Message -match 'does not identify itself as ReShade' }
        if (-not $rejectedIdentity) { throw 'A DLL that is not ReShade was accepted as a runtime.' }

        Write-AppLog 'ReShade source-priority regression tests passed.' 'OK'
    }
    finally {
        if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Show-MainWindow {
    Set-StartupStage 'Ui.Assemblies'
    Write-AppLog 'WinForms.Initialization.Begin'
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    Write-AppLog 'WinForms.Initialization.Complete' 'OK'

    Set-StartupStage 'Ui.GpuDetection'
    Write-AppLog 'GpuDetection.Begin'
    $detectedGpu = Get-DetectedGpuClass
    if ($detectedGpu.Detected) {
        Write-AppLog ('GpuDetection.Complete: ' + $detectedGpu.Class) 'OK'
    }
    else {
        Write-AppLog ('GpuDetection.Complete: unavailable, continuing with a manual choice. ' + $detectedGpu.Names) 'WARN'
    }

    Set-StartupStage 'Ui.Construction'
    Write-AppLog 'Ui.Construction.Begin'
    $colors = @{
        Window      = [System.Drawing.Color]::FromArgb(15,23,42)
        Header      = [System.Drawing.Color]::FromArgb(11,18,32)
        Navigation  = [System.Drawing.Color]::FromArgb(17,27,47)
        Surface     = [System.Drawing.Color]::FromArgb(24,36,59)
        SurfaceAlt  = [System.Drawing.Color]::FromArgb(30,44,70)
        Input       = [System.Drawing.Color]::FromArgb(10,18,33)
        Border      = [System.Drawing.Color]::FromArgb(51,65,85)
        Accent      = [System.Drawing.Color]::FromArgb(59,130,246)
        AccentHover = [System.Drawing.Color]::FromArgb(37,99,235)
        Success     = [System.Drawing.Color]::FromArgb(34,197,94)
        Warning     = [System.Drawing.Color]::FromArgb(245,158,11)
        Danger      = [System.Drawing.Color]::FromArgb(248,113,113)
        Text        = [System.Drawing.Color]::FromArgb(248,250,252)
        Muted       = [System.Drawing.Color]::FromArgb(148,163,184)
        Disabled    = [System.Drawing.Color]::FromArgb(71,85,105)
    }

    $newLabel = {
        param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [float]$Size = 9.5, [bool]$Bold = $false, $Color = $colors.Text)
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Location = New-Object System.Drawing.Point($X,$Y)
        $label.Size = New-Object System.Drawing.Size($Width,$Height)
        $label.ForeColor = $Color
        $label.BackColor = [System.Drawing.Color]::Transparent
        $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
        $label.Font = New-Object System.Drawing.Font('Segoe UI',$Size,$style)
        $Parent.Controls.Add($label)
        return $label
    }
    $newButton = {
        param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width, [int]$Height, [string]$Kind = 'Secondary')
        $button = New-Object System.Windows.Forms.Button
        $button.Text = $Text
        $button.Location = New-Object System.Drawing.Point($X,$Y)
        $button.Size = New-Object System.Drawing.Size($Width,$Height)
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderSize = if ($Kind -eq 'Primary') { 0 } else { 1 }
        $button.FlatAppearance.BorderColor = $colors.Border
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold',9.5)
        if ($Kind -eq 'Primary') {
            $button.BackColor = $colors.Accent
            $button.ForeColor = [System.Drawing.Color]::White
            $button.FlatAppearance.MouseOverBackColor = $colors.AccentHover
        }
        elseif ($Kind -eq 'Danger') {
            $button.BackColor = $colors.Surface
            $button.ForeColor = $colors.Danger
            $button.FlatAppearance.MouseOverBackColor = $colors.SurfaceAlt
        }
        else {
            $button.BackColor = $colors.Surface
            $button.ForeColor = $colors.Text
            $button.FlatAppearance.MouseOverBackColor = $colors.SurfaceAlt
        }
        $Parent.Controls.Add($button)
        return $button
    }
    $styleInput = {
        param($Control)
        $Control.BackColor = $colors.Input
        $Control.ForeColor = $colors.Text
        $Control.Font = New-Object System.Drawing.Font('Segoe UI',10)
        if ($Control -is [System.Windows.Forms.ComboBox]) {
            $Control.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
            $Control.DrawMode = [System.Windows.Forms.DrawMode]::OwnerDrawFixed
            $Control.ItemHeight = 22
            $Control.Add_DrawItem({
                param($sender,$eventArgs)
                if ($eventArgs.Index -lt 0) { return }
                $background = if (($eventArgs.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0) { $colors.SurfaceAlt } else { $colors.Input }
                $backgroundBrush = New-Object System.Drawing.SolidBrush($background)
                $textBrush = New-Object System.Drawing.SolidBrush($colors.Text)
                try {
                    $eventArgs.Graphics.FillRectangle($backgroundBrush,$eventArgs.Bounds)
                    $eventArgs.Graphics.DrawString([string]$sender.Items[$eventArgs.Index],$sender.Font,$textBrush,[float]($eventArgs.Bounds.X + 4),[float]($eventArgs.Bounds.Y + 2))
                }
                finally { $backgroundBrush.Dispose(); $textBrush.Dispose() }
            })
        }
    }

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "$($script:AppName) v$($script:Version)"
    $form.StartPosition = 'CenterScreen'
    $form.ClientSize = New-Object System.Drawing.Size(1080,760)
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Font = New-Object System.Drawing.Font('Segoe UI',9.5)
    $form.BackColor = $colors.Window
    $form.ForeColor = $colors.Text
    $form.Icon = [System.Drawing.SystemIcons]::Application
    $form.SuspendLayout()

    # Header
    $header = New-Object System.Windows.Forms.Panel
    $header.Location = New-Object System.Drawing.Point(0,0)
    $header.Size = New-Object System.Drawing.Size(1080,86)
    $header.BackColor = $colors.Header
    $form.Controls.Add($header)
    $mark = New-Object System.Windows.Forms.Label
    $mark.Text = 'D5'
    $mark.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $mark.Location = New-Object System.Drawing.Point(24,18)
    $mark.Size = New-Object System.Drawing.Size(50,50)
    $mark.BackColor = $colors.Accent
    $mark.ForeColor = [System.Drawing.Color]::White
    $mark.Font = New-Object System.Drawing.Font('Segoe UI Semibold',15)
    $header.Controls.Add($mark)
    [void](& $newLabel $header 'DLSS 5 Guide Launcher' 90 18 420 28 16 $true $colors.Text)
    [void](& $newLabel $header 'A guided, reversible setup for the correct game route' 91 49 520 22 9.5 $false $colors.Muted)
    $versionBadge = & $newLabel $header ("VERSION " + $script:Version) 905 25 142 32 8.5 $true $colors.Text
    $versionBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $versionBadge.BackColor = $colors.Surface

    # Navigation
    $nav = New-Object System.Windows.Forms.Panel
    $nav.Location = New-Object System.Drawing.Point(0,86)
    $nav.Size = New-Object System.Drawing.Size(230,674)
    $nav.BackColor = $colors.Navigation
    $form.Controls.Add($nav)
    [void](& $newLabel $nav 'SETUP' 24 24 170 22 8.5 $true $colors.Muted)
    $stepNames = @('Choose game','Check setup','Support files','Review & install')
    $navButtons = @()
    for ($i=0; $i -lt $stepNames.Count; $i++) {
        $button = New-Object System.Windows.Forms.Button
        $button.Text = ('  {0}     {1}' -f ($i + 1), $stepNames[$i])
        $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
        $button.Location = New-Object System.Drawing.Point(14,(54 + ($i * 62)))
        $button.Size = New-Object System.Drawing.Size(202,50)
        $button.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
        $button.FlatAppearance.BorderSize = 0
        $button.Font = New-Object System.Drawing.Font('Segoe UI Semibold',10)
        $button.BackColor = $colors.Navigation
        $button.ForeColor = $colors.Muted
        $button.Cursor = [System.Windows.Forms.Cursors]::Hand
        $button.Tag = $i
        $nav.Controls.Add($button)
        $navButtons += $button
    }
    $safeCard = New-Object System.Windows.Forms.Panel
    $safeCard.Location = New-Object System.Drawing.Point(14,514)
    $safeCard.Size = New-Object System.Drawing.Size(202,136)
    $safeCard.BackColor = $colors.Surface
    $nav.Controls.Add($safeCard)
    [void](& $newLabel $safeCard 'SAFE BY DEFAULT' 16 14 170 20 8.5 $true $colors.Success)
    [void](& $newLabel $safeCard 'Files are verified before use. Existing files are backed up before every change.' 16 41 170 58 9 $false $colors.Text)
    [void](& $newLabel $safeCard 'Rollback is always one click away.' 16 96 170 36 8.5 $false $colors.Muted)

    # Shared content and footer
    $content = New-Object System.Windows.Forms.Panel
    $content.Location = New-Object System.Drawing.Point(254,106)
    $content.Size = New-Object System.Drawing.Size(802,550)
    $content.BackColor = $colors.Window
    $form.Controls.Add($content)
    $footer = New-Object System.Windows.Forms.Panel
    $footer.Location = New-Object System.Drawing.Point(230,680)
    $footer.Size = New-Object System.Drawing.Size(850,80)
    $footer.BackColor = $colors.Header
    $form.Controls.Add($footer)
    $footerHint = & $newLabel $footer 'Step 1 of 4' 24 25 390 24 9 $false $colors.Muted
    # The active data root is shown on every page: when something goes wrong the
    # user needs to know where to look without being told to hunt for it.
    $dataRootText = if ($script:ActiveDataRoot) { 'Data and logs: ' + $script:ActiveDataRoot } else { 'Data and logs: unavailable - no writable folder was found' }
    $dataRootLabel = & $newLabel $footer $dataRootText 24 48 490 20 8 $false $colors.Muted
    $backButton = & $newButton $footer 'Back' 532 16 126 42 'Secondary'
    $nextButton = & $newButton $footer 'Continue' 672 16 154 42 'Primary'
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.Location = New-Object System.Drawing.Point(0,75)
    $progress.Size = New-Object System.Drawing.Size(850,5)
    $progress.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $progress.MarqueeAnimationSpeed = 25
    $progress.Visible = $false
    $footer.Controls.Add($progress)

    $pages = @()
    for ($i=0; $i -lt 4; $i++) {
        $page = New-Object System.Windows.Forms.Panel
        $page.Location = New-Object System.Drawing.Point(0,0)
        $page.Size = New-Object System.Drawing.Size(802,550)
        $page.BackColor = $colors.Window
        $page.Visible = ($i -eq 0)
        $content.Controls.Add($page)
        $pages += $page
    }

    # Page 1: game selection
    $pageGame = $pages[0]
    [void](& $newLabel $pageGame 'Choose your game' 0 0 700 34 20 $true $colors.Text)
    [void](& $newLabel $pageGame 'Select the executable you normally launch. We will inspect it without changing anything.' 1 43 760 25 10 $false $colors.Muted)
    $gameCard = New-Object System.Windows.Forms.Panel
    $gameCard.Location = New-Object System.Drawing.Point(0,90)
    $gameCard.Size = New-Object System.Drawing.Size(802,146)
    $gameCard.BackColor = $colors.Surface
    $pageGame.Controls.Add($gameCard)
    [void](& $newLabel $gameCard 'GAME EXECUTABLE' 22 18 240 20 8.5 $true $colors.Muted)
    $gameBox = New-Object System.Windows.Forms.TextBox
    $gameBox.Location = New-Object System.Drawing.Point(22,49)
    $gameBox.Size = New-Object System.Drawing.Size(624,28)
    $gameBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    & $styleInput $gameBox
    $gameCard.Controls.Add($gameBox)
    $gameBrowse = & $newButton $gameCard 'Browse' 658 45 120 36 'Secondary'
    $detectButton = & $newButton $gameCard 'Analyze game' 22 94 150 34 'Primary'
    [void](& $newLabel $gameCard 'Read-only check. No files are installed on this step.' 187 101 500 22 9 $false $colors.Muted)

    $analysisCard = New-Object System.Windows.Forms.Panel
    $analysisCard.Location = New-Object System.Drawing.Point(0,256)
    $analysisCard.Size = New-Object System.Drawing.Size(802,198)
    $analysisCard.BackColor = $colors.Surface
    $pageGame.Controls.Add($analysisCard)
    [void](& $newLabel $analysisCard 'GAME CHECK' 22 17 180 20 8.5 $true $colors.Muted)
    $analysisHeadline = & $newLabel $analysisCard 'Waiting for a game' 22 45 740 28 13 $true $colors.Text
    $analysisDetail = & $newLabel $analysisCard 'Choose an executable, then select Analyze game.' 22 80 740 92 9.5 $false $colors.Muted
    $analysisDetail.AutoEllipsis = $true

    $privacyCard = New-Object System.Windows.Forms.Panel
    $privacyCard.Location = New-Object System.Drawing.Point(0,474)
    $privacyCard.Size = New-Object System.Drawing.Size(802,62)
    $privacyCard.BackColor = $colors.SurfaceAlt
    $pageGame.Controls.Add($privacyCard)
    [void](& $newLabel $privacyCard 'Your game stays local' 18 11 190 20 9.5 $true $colors.Success)
    [void](& $newLabel $privacyCard 'The launcher reads file names, architecture, and local logs only.' 18 33 650 20 9 $false $colors.Muted)

    # Page 2: route selection
    $pageSetup = $pages[1]
    [void](& $newLabel $pageSetup 'Check the setup' 0 0 700 34 20 $true $colors.Text)
    [void](& $newLabel $pageSetup 'Confirm the detected details. These answers decide which route is safe for this game.' 1 43 760 25 10 $false $colors.Muted)
    [void](& $newLabel $pageSetup 'GRAPHICS CARD' 0 91 220 20 8.5 $true $colors.Muted)
    $gpuBox = New-Object System.Windows.Forms.ComboBox
    $gpuBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $gpuBox.Location = New-Object System.Drawing.Point(0,116)
    $gpuBox.Size = New-Object System.Drawing.Size(252,28)
    [void]$gpuBox.Items.AddRange([object[]]@('RTX 50 series','RTX 40 series (experimental)','Other / unsupported'))
    & $styleInput $gpuBox
    if ($detectedGpu.Detected) { $gpuBox.SelectedItem = $detectedGpu.Class }
    $pageSetup.Controls.Add($gpuBox)
    [void](& $newLabel $pageSetup 'GRAPHICS API' 274 91 220 20 8.5 $true $colors.Muted)
    $apiBox = New-Object System.Windows.Forms.ComboBox
    $apiBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $apiBox.Location = New-Object System.Drawing.Point(274,116)
    $apiBox.Size = New-Object System.Drawing.Size(218,28)
    [void]$apiBox.Items.AddRange([object[]]@('Unknown','DirectX 11','DirectX 12','Vulkan','DirectX 9'))
    & $styleInput $apiBox
    $apiBox.SelectedItem = 'Unknown'
    $pageSetup.Controls.Add($apiBox)
    [void](& $newLabel $pageSetup 'NATIVE DLSS?' 514 91 220 20 8.5 $true $colors.Muted)
    $nativeBox = New-Object System.Windows.Forms.ComboBox
    $nativeBox.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $nativeBox.Location = New-Object System.Drawing.Point(514,116)
    $nativeBox.Size = New-Object System.Drawing.Size(288,28)
    [void]$nativeBox.Items.AddRange([object[]]@('Unsure','Yes','No'))
    & $styleInput $nativeBox
    $nativeBox.SelectedItem = 'Unsure'
    $pageSetup.Controls.Add($nativeBox)
    $gpuText = if ($detectedGpu.Detected) { 'Detected: ' + $detectedGpu.Names } else { 'Could not read the graphics card on this machine, so please choose it above. ' + $detectedGpu.Names }
    $gpuInfo = & $newLabel $pageSetup $gpuText 0 154 802 25 8.5 $false $colors.Muted
    $gpuInfo.AutoEllipsis = $true

    $routeCard = New-Object System.Windows.Forms.Panel
    $routeCard.Location = New-Object System.Drawing.Point(0,192)
    $routeCard.Size = New-Object System.Drawing.Size(802,265)
    $routeCard.BackColor = $colors.Surface
    $pageSetup.Controls.Add($routeCard)
    $routeAccent = New-Object System.Windows.Forms.Panel
    $routeAccent.Location = New-Object System.Drawing.Point(0,0)
    $routeAccent.Size = New-Object System.Drawing.Size(6,265)
    $routeAccent.BackColor = $colors.Warning
    $routeCard.Controls.Add($routeAccent)
    $routeEyebrow = & $newLabel $routeCard 'RECOMMENDED ROUTE' 26 20 300 20 8.5 $true $colors.Muted
    $routeTitle = & $newLabel $routeCard 'More information required' 26 48 742 32 14 $true $colors.Text
    $routeText = & $newLabel $routeCard '' 26 89 742 96 9.5 $false $colors.Muted
    $routeWarning = & $newLabel $routeCard '' 26 192 742 55 9 $true $colors.Warning
    [void](& $newLabel $pageSetup 'Tip: If detection says Unsure, check the game graphics menu for a DLSS option.' 0 476 780 25 9 $false $colors.Muted)

    # Page 3: local support files
    $pageFiles = $pages[2]
    [void](& $newLabel $pageFiles 'Add your support files' 0 0 700 34 20 $true $colors.Text)
    [void](& $newLabel $pageFiles 'Choose one folder. The launcher searches its subfolders and checks every required file.' 1 43 760 25 10 $false $colors.Muted)
    [void](& $newLabel $pageFiles 'SUPPORT-FILES FOLDER' 0 88 260 20 8.5 $true $colors.Muted)
    $supportBox = New-Object System.Windows.Forms.TextBox
    $supportBox.Location = New-Object System.Drawing.Point(0,114)
    $supportBox.Size = New-Object System.Drawing.Size(650,28)
    $supportBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    & $styleInput $supportBox
    $pageFiles.Controls.Add($supportBox)
    $supportBrowse = & $newButton $pageFiles 'Browse' 662 110 140 36 'Secondary'

    $fileCard = New-Object System.Windows.Forms.Panel
    $fileCard.Location = New-Object System.Drawing.Point(0,164)
    $fileCard.Size = New-Object System.Drawing.Size(802,210)
    $fileCard.BackColor = $colors.Surface
    $pageFiles.Controls.Add($fileCard)
    [void](& $newLabel $fileCard 'REQUIRED FROM YOU' 22 16 240 20 8.5 $true $colors.Muted)
    $coreName = & $newLabel $fileCard 'RenoDX Neural Rendering add-on' 22 49 390 24 10 $true $colors.Text
    $coreStatus = & $newLabel $fileCard 'Not checked' 525 49 250 24 9.5 $true $colors.Muted
    [void](& $newLabel $fileCard 'renodx-dlss5.addon64' 22 73 390 20 8.5 $false $colors.Muted)
    $modelName = & $newLabel $fileCard 'Neural Rendering model' 22 105 390 24 10 $true $colors.Text
    $modelStatus = & $newLabel $fileCard 'Not checked' 525 105 250 24 9.5 $true $colors.Muted
    [void](& $newLabel $fileCard 'nvngx_dlssnr.dll' 22 129 390 20 8.5 $false $colors.Muted)
    $upscalerName = & $newLabel $fileCard 'DLSS upscaler (Feeder route only)' 22 161 390 24 10 $true $colors.Text
    $upscalerStatus = & $newLabel $fileCard 'Not checked' 525 161 250 24 9.5 $true $colors.Muted
    [void](& $newLabel $fileCard 'nvngx_dlss.dll' 22 185 390 20 8.5 $false $colors.Muted)

    $autoCard = New-Object System.Windows.Forms.Panel
    $autoCard.Location = New-Object System.Drawing.Point(0,386)
    $autoCard.Size = New-Object System.Drawing.Size(802,120)
    $autoCard.BackColor = $colors.SurfaceAlt
    $pageFiles.Controls.Add($autoCard)
    [void](& $newLabel $autoCard 'RESHade runtime (optional)' 18 10 260 22 9 $true $colors.Success)
    $reshadeBox = New-Object System.Windows.Forms.TextBox
    $reshadeBox.Location = New-Object System.Drawing.Point(18,39)
    $reshadeBox.Size = New-Object System.Drawing.Size(610,28)
    $reshadeBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    & $styleInput $reshadeBox
    $autoCard.Controls.Add($reshadeBox)
    $reshadeBrowse = & $newButton $autoCard 'Browse DLL' 640 35 140 36 'Secondary'
    [void](& $newLabel $autoCard "Leave blank to reuse the game's existing ReShade dxgi.dll, or use the verified official installer fallback." 18 78 755 32 8.5 $false $colors.Muted)
    $ack40 = New-Object System.Windows.Forms.CheckBox
    $ack40.Text = 'I understand RTX 40 mode uses my own unofficial patched DLL and is not supported by NVIDIA.'
    $ack40.Location = New-Object System.Drawing.Point(0,511)
    $ack40.Size = New-Object System.Drawing.Size(790,34)
    $ack40.ForeColor = $colors.Warning
    $ack40.BackColor = $colors.Window
    $ack40.Font = New-Object System.Drawing.Font('Segoe UI Semibold',9.5)
    $ack40.Visible = $false
    $pageFiles.Controls.Add($ack40)

    # Page 4: review and install
    $pageReview = $pages[3]
    [void](& $newLabel $pageReview 'Review and install' 0 0 700 34 20 $true $colors.Text)
    [void](& $newLabel $pageReview 'Nothing changes until you confirm. A complete backup is created first.' 1 43 760 25 10 $false $colors.Muted)
    $reviewRoute = & $newLabel $pageReview '' 0 78 802 30 12 $true $colors.Success
    $reviewBox = New-Object System.Windows.Forms.TextBox
    $reviewBox.Location = New-Object System.Drawing.Point(0,116)
    $reviewBox.Size = New-Object System.Drawing.Size(802,252)
    $reviewBox.Multiline = $true
    $reviewBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
    $reviewBox.ReadOnly = $true
    $reviewBox.BorderStyle = [System.Windows.Forms.BorderStyle]::None
    $reviewBox.BackColor = $colors.Surface
    $reviewBox.ForeColor = $colors.Text
    $reviewBox.Font = New-Object System.Drawing.Font('Consolas',9)
    $reviewBox.Text = 'Your install summary will appear here.'
    $pageReview.Controls.Add($reviewBox)
    $backupCard = New-Object System.Windows.Forms.Panel
    $backupCard.Location = New-Object System.Drawing.Point(0,380)
    $backupCard.Size = New-Object System.Drawing.Size(802,50)
    $backupCard.BackColor = $colors.SurfaceAlt
    $pageReview.Controls.Add($backupCard)
    [void](& $newLabel $backupCard 'BACKUP ON' 16 14 95 22 8.5 $true $colors.Success)
    [void](& $newLabel $backupCard 'Every replaced or removed file can be restored with Roll back.' 112 13 650 24 9.5 $false $colors.Text)
    $statusBox = New-Object System.Windows.Forms.Label
    $statusBox.Location = New-Object System.Drawing.Point(0,442)
    $statusBox.Size = New-Object System.Drawing.Size(802,40)
    $statusBox.Text = 'Ready to install after you review the list above.'
    $statusBox.ForeColor = $colors.Muted
    $statusBox.Font = New-Object System.Drawing.Font('Segoe UI',9.5)
    $pageReview.Controls.Add($statusBox)
    $verifyButton = & $newButton $pageReview 'Verify downloads' 0 500 144 34 'Secondary'
    $rollback = & $newButton $pageReview 'Roll back' 154 500 116 34 'Danger'
    $guides = & $newButton $pageReview 'Official guides' 280 500 130 34 'Secondary'
    $openLog = & $newButton $pageReview 'Open log' 420 500 110 34 'Secondary'
    $openFolder = & $newButton $pageReview 'Open game folder' 540 500 156 34 'Secondary'

    $state = [pscustomobject]@{ CurrentStep=0; MaxStep=0; Busy=$false; Analysis=$null; PreviewPlan=$null }
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.SetToolTip($verifyButton,'Download and verify remote dependencies now, without installing them.')
    $toolTip.SetToolTip($rollback,'Restore the most recent backup for the selected game.')
    $toolTip.SetToolTip($nextButton,'Continue to the next guided step.')
    if ($script:LogPath) { $toolTip.SetToolTip($openLog,('Open the current log: ' + $script:LogPath)) }
    $toolTip.SetToolTip($dataRootLabel,$dataRootText)

    $setStatus = {
        param([string]$Text, [string]$Kind = 'Info')
        $statusBox.Text = $Text
        $statusBox.ForeColor = switch ($Kind) { 'Success' {$colors.Success} 'Warning' {$colors.Warning} 'Error' {$colors.Danger} default {$colors.Muted} }
    }
    $showError = {
        param([string]$Text)
        & $setStatus $Text 'Error'
        [void][System.Windows.Forms.MessageBox]::Show($form,$Text,$script:AppName,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)
    }
    $setBusy = {
        param([bool]$Busy, [string]$Message = '')
        $state.Busy = $Busy
        $form.UseWaitCursor = $Busy
        $progress.Visible = $Busy
        $backButton.Enabled = (-not $Busy -and $state.CurrentStep -gt 0)
        $nextButton.Enabled = -not $Busy
        foreach ($button in $navButtons) { $button.Enabled = -not $Busy }
        if ($Message) { & $setStatus $Message 'Info' }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $showStep = {
        param([int]$Index)
        if ($Index -lt 0 -or $Index -gt 3 -or $Index -gt $state.MaxStep) { return }
        $state.CurrentStep = $Index
        for ($i=0; $i -lt $pages.Count; $i++) {
            $pages[$i].Visible = ($i -eq $Index)
            $navButtons[$i].BackColor = if ($i -eq $Index) { $colors.SurfaceAlt } else { $colors.Navigation }
            $navButtons[$i].ForeColor = if ($i -eq $Index) { $colors.Text } elseif ($i -lt $state.MaxStep) { $colors.Success } else { $colors.Muted }
            $navButtons[$i].Enabled = -not $state.Busy
        }
        $pages[$Index].BringToFront()
        $backButton.Enabled = (-not $state.Busy -and $Index -gt 0)
        $nextButton.Text = switch ($Index) { 0 {'Continue'} 1 {'Continue'} 2 {'Review setup'} 3 {'Install now'} }
        $footerHint.Text = ('Step {0} of 4  -  {1}' -f ($Index + 1), $stepNames[$Index])
        if ($Index -eq 3) { $nextButton.BackColor = $colors.Success; $nextButton.FlatAppearance.MouseOverBackColor = [System.Drawing.Color]::FromArgb(22,163,74) }
        else { $nextButton.BackColor = $colors.Accent; $nextButton.FlatAppearance.MouseOverBackColor = $colors.AccentHover }
    }
    $updateRoute = {
        $route = Resolve-InstallRoute -Gpu ([string]$gpuBox.SelectedItem) -Api ([string]$apiBox.SelectedItem) -HasNativeDlss ([string]$nativeBox.SelectedItem)
        $routeTitle.Text = $route.Title
        $routeText.Text = $route.Summary
        $routeWarning.Text = if ($route.Warning) { 'PLEASE NOTE: ' + $route.Warning } elseif ($route.CanInstall) { 'This route can be installed automatically.' } else { 'Complete the answers above to continue.' }
        $routeAccent.BackColor = if ($route.CanInstall) { $colors.Success } elseif ($route.Id -eq 'NeedsAnswers') { $colors.Warning } else { $colors.Danger }
        $routeWarning.ForeColor = if ($route.CanInstall -and -not $route.Warning) { $colors.Success } elseif ($route.Id -eq 'NeedsAnswers') { $colors.Warning } else { $colors.Danger }
        $ack40.Visible = ($gpuBox.SelectedItem -eq 'RTX 40 series (experimental)')
        $reviewRoute.Text = $route.Title
        return $route
    }
    $analyzeGame = {
        if (-not (Test-Path -LiteralPath $gameBox.Text -PathType Leaf)) { throw 'Choose a real game executable first.' }
        $fullExe = [System.IO.Path]::GetFullPath($gameBox.Text)
        $arch = Get-PeArchitecture $fullExe
        $api = Get-DetectedApi $fullExe
        $native = Find-NativeDlss $fullExe
        $gameDirectory = [System.IO.Path]::GetDirectoryName($fullExe)
        $rsStatus = Get-ReShadeStatus $gameDirectory
        if ($api.Value -ne 'Unknown') { $apiBox.SelectedItem = $api.Value }
        $nativeBox.SelectedItem = $native.Value
        $state.Analysis = [pscustomobject]@{ Exe=$fullExe; Architecture=$arch; Api=$api; Native=$native; ReShade=$rsStatus }
        $analysisHeadline.Text = [System.IO.Path]::GetFileName($fullExe) + ' is ready to review'
        $analysisHeadline.ForeColor = if ($arch -eq '64-bit') { $colors.Success } else { $colors.Danger }
        $analysisDetail.Text = "Architecture: $arch`r`nGraphics API: $($api.Value) - $($api.Evidence)`r`nNative DLSS: $($native.Value) - $($native.Evidence)`r`nReShade: $(if ($rsStatus.Installed) { 'Installed at ' + $rsStatus.Path + ' (will be reused)' } else { 'Not installed; select a local runtime or use the verified fallback.' })"
        if ($arch -ne '64-bit') { throw 'This launcher currently supports only 64-bit DX11 and DX12 games.' }
        [void](& $updateRoute)
    }
    $refreshFileChecks = {
        $root = $supportBox.Text
        if ([string]::IsNullOrWhiteSpace($root)) {
            $coreStatus.Text = 'Choose a folder'
            $coreStatus.ForeColor = $colors.Muted
            $modelStatus.Text = 'Choose a folder'
            $modelStatus.ForeColor = $colors.Muted
            $upscalerStatus.Text = 'Choose a folder'
            $upscalerStatus.ForeColor = $colors.Muted
            return
        }
        $core = Find-SupportFile -Root $root -Name 'renodx-dlss5.addon64'
        $model = Find-SupportFile -Root $root -Name 'nvngx_dlssnr.dll'
        $upscaler = Find-SupportFile -Root $root -Name 'nvngx_dlss.dll'
        $coreStatus.Text = if ($core) { 'Found' } else { 'Missing' }
        $coreStatus.ForeColor = if ($core) { $colors.Success } else { $colors.Danger }
        $modelStatus.Text = if ($model) { 'Found' } else { 'Missing' }
        $modelStatus.ForeColor = if ($model) { $colors.Success } else { $colors.Danger }
        $route = & $updateRoute
        if ($route.NeedsUpscalerDll) {
            $targetHasUpscaler = $false
            if (Test-Path -LiteralPath $gameBox.Text -PathType Leaf) {
                $targetHasUpscaler = Test-Path -LiteralPath (Join-Path ([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($gameBox.Text))) 'nvngx_dlss.dll') -PathType Leaf
            }
            $upscalerStatus.Text = if ($upscaler) { 'Found' } elseif ($targetHasUpscaler) { 'Already in game' } else { 'Missing' }
            $upscalerStatus.ForeColor = if ($upscaler -or $targetHasUpscaler) { $colors.Success } else { $colors.Danger }
            $upscalerName.ForeColor = $colors.Text
        }
        else {
            $upscalerStatus.Text = 'Not needed'
            $upscalerStatus.ForeColor = $colors.Muted
            $upscalerName.ForeColor = $colors.Muted
        }
    }
    $prepareReview = {
        $route = & $updateRoute
        $plan = New-InstallPlan -ExePath $gameBox.Text -Route $route -Gpu ([string]$gpuBox.SelectedItem) -FilesRoot $supportBox.Text -ReShadeRuntimePath $reshadeBox.Text -PermitPatched40 $ack40.Checked -FetchRemote $false
        $state.PreviewPlan = $plan
        $reviewRoute.Text = $route.Title
        $reviewBox.Text = Format-InstallPlan $plan
        & $setStatus 'Ready. Select Install now when you are comfortable with the plan.' 'Success'
    }
    $installAction = {
        & $setBusy $true 'Downloading and verifying the required files...'
        try {
            $route = & $updateRoute
            $plan = New-InstallPlan -ExePath $gameBox.Text -Route $route -Gpu ([string]$gpuBox.SelectedItem) -FilesRoot $supportBox.Text -ReShadeRuntimePath $reshadeBox.Text -PermitPatched40 $ack40.Checked -FetchRemote $true
            $previewText = Format-InstallPlan $plan
            $reviewBox.Text = $previewText
            & $setBusy $false
            $answer = [System.Windows.Forms.MessageBox]::Show($form,"The files shown in the review will now be installed.`r`n`r`nA backup will be created first. Continue?",'Confirm installation',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { & $setStatus 'Installation cancelled. No files were changed.' 'Info'; return }
            & $setBusy $true 'Installing files and creating a backup...'
            $manifest = Invoke-InstallPlan $plan
            $rsStatus = Get-ReShadeStatus $plan.GameDirectory
            if (-not $rsStatus.Installed -or [System.IO.Path]::GetFileName($rsStatus.Path) -ine 'dxgi.dll') { throw 'The transactional install completed, but the ReShade DXGI runtime could not be verified.' }
            $completion = if ($route.NeedsFeeder) { 'Installed successfully. The preset enables Lumenite Kernel above DLSS 5 Feed. In game, enable Neural Rendering in the DLSS 5 panel.' } else { 'Installed successfully. In game, open ReShade and enable Neural Rendering in the DLSS 5 panel.' }
            & $setStatus $completion 'Success'
            Write-AppLog "UI install complete. Backup manifest: $manifest" 'OK'
            [void][System.Windows.Forms.MessageBox]::Show($form,'Installation completed successfully. A reversible backup was created.',$script:AppName,[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information)
        }
        catch { & $showError $_.Exception.Message }
        finally { & $setBusy $false; & $showStep 3 }
    }

    $gameBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Windows executables (*.exe)|*.exe'
        $dialog.Title = 'Choose the game executable'
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
            $gameBox.Text = $dialog.FileName
            try { & $analyzeGame } catch { & $showError $_.Exception.Message }
        }
    })
    $detectButton.Add_Click({
        try { & $analyzeGame } catch { & $showError $_.Exception.Message }
    })
    $supportBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose the folder containing renodx-dlss5.addon64 and your NVIDIA DLLs'
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $supportBox.Text = $dialog.SelectedPath; & $refreshFileChecks }
    })
    $supportBox.Add_TextChanged({ & $refreshFileChecks })
    $reshadeBrowse.Add_Click({
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'ReShade runtime (*.dll)|*.dll'
        $dialog.Title = 'Choose a local 64-bit ReShade full add-on runtime'
        if ($dialog.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) { $reshadeBox.Text = $dialog.FileName }
    })
    $reshadeBox.Add_TextChanged({ $state.PreviewPlan = $null })
    $gpuBox.Add_SelectedIndexChanged({ [void](& $updateRoute); & $refreshFileChecks })
    $apiBox.Add_SelectedIndexChanged({ [void](& $updateRoute) })
    $nativeBox.Add_SelectedIndexChanged({ [void](& $updateRoute) })
    $ack40.Add_CheckedChanged({ $state.PreviewPlan = $null })

    for ($i=0; $i -lt $navButtons.Count; $i++) {
        $navButtons[$i].Add_Click({ & $showStep ([int]$this.Tag) })
    }
    $backButton.Add_Click({ if ($state.CurrentStep -gt 0) { & $showStep ($state.CurrentStep - 1) } })
    $nextButton.Add_Click({
        if ($state.Busy) { return }
        try {
            switch ($state.CurrentStep) {
                0 {
                    & $analyzeGame
                    $state.MaxStep = [Math]::Max($state.MaxStep,1)
                    & $showStep 1
                }
                1 {
                    $route = & $updateRoute
                    if (-not $route.CanInstall) { throw $route.Summary }
                    $state.MaxStep = [Math]::Max($state.MaxStep,2)
                    & $refreshFileChecks
                    & $showStep 2
                }
                2 {
                    & $prepareReview
                    $state.MaxStep = [Math]::Max($state.MaxStep,3)
                    & $showStep 3
                }
                3 { & $installAction }
            }
        }
        catch { & $showError $_.Exception.Message }
    })
    $verifyButton.Add_Click({
        & $setBusy $true 'Downloading and verifying remote dependencies...'
        try {
            $route = & $updateRoute
            $plan = New-InstallPlan -ExePath $gameBox.Text -Route $route -Gpu ([string]$gpuBox.SelectedItem) -FilesRoot $supportBox.Text -ReShadeRuntimePath $reshadeBox.Text -PermitPatched40 $ack40.Checked -FetchRemote $true
            $state.PreviewPlan = $plan
            $reviewBox.Text = Format-InstallPlan $plan
            & $setStatus 'All remote dependencies passed verification. Nothing has been installed yet.' 'Success'
        }
        catch { & $showError $_.Exception.Message }
        finally { & $setBusy $false; & $showStep 3 }
    })
    $rollback.Add_Click({
        try {
            if (-not (Test-Path -LiteralPath $gameBox.Text -PathType Leaf)) { throw 'Choose the same game executable first.' }
            $answer = [System.Windows.Forms.MessageBox]::Show($form,'Restore the most recent launcher backup for this game?','Confirm rollback',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                $manifest = Invoke-Rollback $gameBox.Text
                & $setStatus ("Rollback complete. Manifest: " + $manifest) 'Success'
            }
        }
        catch { & $showError $_.Exception.Message }
    })
    $guides.Add_Click({ Start-Process 'https://github.com/jlrouzies-fr/DLSS5-Feeder'; Start-Process 'https://github.com/NIGos/dlss5-dx11-bridge'; Start-Process 'https://github.com/umar-afzaal/LumeniteFX'; Start-Process 'https://reshade.me/' })
    $openLog.Add_Click({ if (Test-Path -LiteralPath $script:LogPath) { Start-Process notepad.exe -ArgumentList ('"' + $script:LogPath + '"') } })
    $openFolder.Add_Click({ if (Test-Path -LiteralPath $gameBox.Text -PathType Leaf) { Start-Process explorer.exe -ArgumentList ('"' + [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetFullPath($gameBox.Text)) + '"') } })

    if ($GameExe) { $gameBox.Text = $GameExe }
    if ($SupportFiles) { $supportBox.Text = $SupportFiles }
    if ($ReShadeRuntime) { $reshadeBox.Text = $ReShadeRuntime }
    [void](& $updateRoute)
    & $refreshFileChecks
    & $showStep 0
    $form.ResumeLayout($false)
    Write-AppLog 'Ui.Construction.Complete' 'OK'
    Set-StartupStage 'Ui.Show'
    $form.Add_Shown({
        Write-AppLog 'Ui.Shown' 'OK'
        if ($GameExe -and (Test-Path -LiteralPath $GameExe -PathType Leaf)) {
            try { & $analyzeGame } catch { $analysisHeadline.Text = 'Game selected - review needed'; $analysisDetail.Text = $_.Exception.Message }
        }
        if ($UiScreenshotPath -and $UiScreenshotStep -gt 1) {
            $state.MaxStep = $UiScreenshotStep - 1
            if ($UiScreenshotStep -eq 3) { & $refreshFileChecks }
            & $showStep ($UiScreenshotStep - 1)
            [System.Windows.Forms.Application]::DoEvents()
        }
        if ($UiScreenshotPath) {
            $capturePath = [System.IO.Path]::GetFullPath($UiScreenshotPath)
            $captureParent = [System.IO.Path]::GetDirectoryName($capturePath)
            if (-not (Test-Path -LiteralPath $captureParent)) { New-Item -ItemType Directory -Path $captureParent -Force | Out-Null }
            $bitmap = New-Object System.Drawing.Bitmap($form.Width,$form.Height)
            try { $form.DrawToBitmap($bitmap,(New-Object System.Drawing.Rectangle(0,0,$form.Width,$form.Height))); $bitmap.Save($capturePath,[System.Drawing.Imaging.ImageFormat]::Png) }
            finally { $bitmap.Dispose() }
        }
    })
    if ($UiSmokeTest) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 900
        $timer.Add_Tick({ $timer.Stop(); $form.Close() })
        $timer.Start()
    }
    [void]$form.ShowDialog()
}

function Invoke-HeadlessMode {
    if (-not $GameExe) { throw '-GameExe is required in headless mode.' }
    if ($Rollback) {
        Set-StartupStage 'Rollback'
        $rolledBack = Invoke-Rollback $GameExe
        Write-Host "Rollback complete. Manifest: $rolledBack"
        return
    }
    $gpu = $GpuClass
    if ($gpu -eq 'Auto') {
        $detected = Get-DetectedGpuClass
        if (-not $detected.Detected) {
            throw "The graphics card could not be read on this machine ($($detected.Names)). Pass -GpuClass explicitly; the launcher will not guess a hardware verdict from a failed query."
        }
        $gpu = $detected.Class
    }
    $api = if ($GraphicsApi -eq 'Auto') { (Get-DetectedApi $GameExe).Value } else { $GraphicsApi }
    $native = if ($NativeDlss -eq 'Auto') { (Find-NativeDlss $GameExe).Value } else { $NativeDlss }
    $route = Resolve-InstallRoute -Gpu $gpu -Api $api -HasNativeDlss $native
    if (-not $route.CanInstall) { throw $route.Summary }
    Set-StartupStage 'Install.Plan'
    $plan = New-InstallPlan -ExePath $GameExe -Route $route -Gpu $gpu -FilesRoot $SupportFiles -ReShadeRuntimePath $ReShadeRuntime -PermitPatched40 ([bool]$AllowPatchedRtx40File) -FetchRemote (-not [bool]$DryRun)
    if ($DryRun) {
        [pscustomobject]@{ Gpu=$gpu; Api=$api; NativeDlss=$native; Route=$route; Plan=(Format-InstallPlan $plan) } | ConvertTo-Json -Depth 6
        return
    }
    Set-StartupStage 'Install.Apply'
    $manifest = Invoke-InstallPlan $plan
    Write-Host "Installation complete. Manifest: $manifest"
}

function Invoke-Main {
    <#
        The whole of startup, guarded. Ordering matters and is deliberate:
        prove the script body began, open a log, only then touch storage, so
        that every later failure has somewhere to be recorded.

        This is called as a bare statement rather than for its return value, so
        that headless output such as the -DryRun JSON still reaches stdout
        unchanged. The exit code travels in script state instead.
    #>
    try {
        Write-StartupSentinel
        $loggingReady = Initialize-AppLogging
        Set-StartupStage 'Startup.Begin'
        Write-AppLog "$($script:AppName) v$($script:Version) started."
        if (-not $loggingReady) {
            Write-Warning 'The launcher could not open its own log file. Startup continues, and the bootstrap log records what happens next.'
        }
        Write-StartupEnvironment

        Set-StartupStage 'Startup.Storage'
        Initialize-AppStorage
        Write-DataRootLog

        if ($SelfTest) {
            Set-StartupStage 'SelfTest'
            Test-DecisionMatrix
            Test-BackupRoundTrip
            Test-PortableStorage
            Test-StartupContract
            Test-NoAdminHelpers
            Test-ReShadeSourceSelection
            return
        }

        if ($Headless) {
            Set-StartupStage 'Headless'
            Invoke-HeadlessMode
            return
        }

        Show-MainWindow
    }
    catch {
        Write-StartupFailure $_
    }
}

Invoke-Main
exit $script:PendingExitCode
