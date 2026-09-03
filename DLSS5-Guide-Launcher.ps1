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
    [switch]$AllowPatchedRtx40File
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:AppName = 'DLSS 5 Guide Launcher'
$script:Version = '1.3.0-noadmin'
$script:AppDataRoot = Join-Path $env:LOCALAPPDATA 'DLSS5-Guide-Launcher'
$script:CacheRoot = Join-Path $script:AppDataRoot 'Cache'
$script:LogRoot = Join-Path $script:AppDataRoot 'Logs'
$script:BackupRoot = Join-Path $script:AppDataRoot 'Backups'
$script:IndexPath = Join-Path $script:AppDataRoot 'install-index.json'
$script:LogPath = $null
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

function Initialize-AppStorage {
    foreach ($path in @($script:AppDataRoot, $script:CacheRoot, $script:LogRoot, $script:BackupRoot)) {
        try {
            if (-not (Test-Path -LiteralPath $path)) {
                New-Item -ItemType Directory -Path $path -Force | Out-Null
            }
        }
        catch {
            $code = Get-NativeErrorCode $_.Exception
            if ($code -eq 5 -or $_.Exception -is [System.UnauthorizedAccessException]) {
                throw "Windows denied access to the launcher's current-user storage (error 5): $path`r`n`r`nThis launcher does not require or request administrator access. Ask the VM owner to allow your account to write under %LOCALAPPDATA%, or use a Windows account with a writable profile."
            }
            throw
        }
    }
    $script:LogPath = Join-Path $script:LogRoot ('launcher-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}

function Write-AppLog {
    param([string]$Message, [ValidateSet('INFO','OK','WARN','ERROR')] [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogPath) { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 }
    if ($Headless -or $SelfTest) {
        $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERROR' {'Red'} default {'Gray'} }
        Write-Host $line -ForegroundColor $color
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
    try {
        $names = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { [string]$_.Name })
        $joined = $names -join '; '
        if ($joined -match '(?i)RTX\s*50\d{2}') { return [pscustomobject]@{ Class='RTX 50 series'; Names=$joined } }
        if ($joined -match '(?i)RTX\s*40\d{2}') { return [pscustomobject]@{ Class='RTX 40 series (experimental)'; Names=$joined } }
        return [pscustomobject]@{ Class='Other / unsupported'; Names=$joined }
    }
    catch { return [pscustomobject]@{ Class='Other / unsupported'; Names='Detection failed: ' + $_.Exception.Message } }
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

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $detectedGpu = Get-DetectedGpuClass
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
    $gpuBox.SelectedItem = $detectedGpu.Class
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
    $gpuInfo = & $newLabel $pageSetup ('Detected: ' + $detectedGpu.Names) 0 154 802 25 8.5 $false $colors.Muted
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
    $form.Add_Shown({
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

Initialize-AppStorage
Write-AppLog "$($script:AppName) v$($script:Version) started."

if ($SelfTest) {
    Test-DecisionMatrix
    Test-BackupRoundTrip
    Test-NoAdminHelpers
    exit 0
}

if ($Headless) {
    if (-not $GameExe) { throw '-GameExe is required in headless mode.' }
    if ($Rollback) {
        $rolledBack = Invoke-Rollback $GameExe
        Write-Host "Rollback complete. Manifest: $rolledBack"
        exit 0
    }
    $gpu = if ($GpuClass -eq 'Auto') { (Get-DetectedGpuClass).Class } else { $GpuClass }
    $api = if ($GraphicsApi -eq 'Auto') { (Get-DetectedApi $GameExe).Value } else { $GraphicsApi }
    $native = if ($NativeDlss -eq 'Auto') { (Find-NativeDlss $GameExe).Value } else { $NativeDlss }
    $route = Resolve-InstallRoute -Gpu $gpu -Api $api -HasNativeDlss $native
    if (-not $route.CanInstall) { throw $route.Summary }
    $plan = New-InstallPlan -ExePath $GameExe -Route $route -Gpu $gpu -FilesRoot $SupportFiles -ReShadeRuntimePath $ReShadeRuntime -PermitPatched40 ([bool]$AllowPatchedRtx40File) -FetchRemote (-not [bool]$DryRun)
    if ($DryRun) {
        [pscustomobject]@{ Gpu=$gpu; Api=$api; NativeDlss=$native; Route=$route; Plan=(Format-InstallPlan $plan) } | ConvertTo-Json -Depth 6
        exit 0
    }
    $manifest = Invoke-InstallPlan $plan
    Write-Host "Installation complete. Manifest: $manifest"
    exit 0
}

Show-MainWindow
