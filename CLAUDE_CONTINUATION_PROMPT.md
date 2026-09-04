# Claude continuation prompt: fix invisible startup and portable logging

Continue development of this repository:

- Repository: `https://github.com/ChucklesStern/dlss5-guide-launcher`
- Branch: `feature/non-admin-runtime`
- Current tested commit: `e139f7d1070d870da73423c00e6857a42d5ec923`
- Current prerelease: `v1.3.0-noadmin`
- Upstream base: `kayle2203/dlss5-guide-launcher` version `v1.2.0`

Read `CLAUDE_TASK.md`, `README.md`, `SECURITY.md`, and the complete PowerShell and CMD launchers before editing. Preserve the current no-admin ReShade reuse/import work.

## New VM test result

The user downloaded and tried `v1.3.0-noadmin` on a managed Windows virtual machine with no administrator privileges.

Observed behavior:

1. The launcher window never appeared.
2. The user cannot access `%LOCALAPPDATA%\DLSS5-Guide-Launcher\Logs`, so logs stored only there are unusable.
3. We therefore have no evidence yet that the failure reached the ReShade code. Treat this as an early bootstrap/startup failure first—not as a ReShade failure.

The user will not have administrator access. Do not ask them to run anything as Administrator, change system policy, write HKLM, register a Vulkan layer, or bypass AppLocker/WDAC/VM security. Cyberpunk 2077 and Red Dead Redemption 2 are being used in DirectX 12 mode, so Vulkan is out of scope.

## Required fixes

### 1. Add logging before PowerShell starts

Replace the thin `DLSS5-Guide-Launcher.cmd` wrapper with a batch-only bootstrap that creates a timestamped log before invoking `powershell.exe`.

- First choice: `Logs` beside the extracted launcher, for example `%~dp0Logs\bootstrap-YYYYMMDD-HHMMSS.log`.
- If the launcher directory is not writable, fall back to an accessible non-admin location such as `%TEMP%\DLSS5-Guide-Launcher-Logs`.
- Do not use `%LOCALAPPDATA%` for this fallback.
- Record the launch time, launcher directory, Windows version, whether `powershell.exe` can be found, the exact safe command line shape, process exit code, and any stdout/stderr emitted by PowerShell.
- Do not log secrets, environment dumps, tokens, or unrelated personal data.
- If PowerShell cannot start and returns error 5, the bootstrap log must explicitly say that Windows denied creation of `powershell.exe`, meaning no PowerShell or ReShade code ran.
- Keep the console open on failure and print the exact bootstrap-log path.
- Add a separate `Collect-Diagnostics.cmd` that uses only built-in batch commands, does not require PowerShell, writes beside the launcher (with `%TEMP%` fallback), and always pauses so the user can read/copy the result.

The diagnostic batch file must distinguish these stages:

1. CMD wrapper began.
2. `powershell.exe` was found or missing.
3. A harmless `powershell.exe -NoLogo -NoProfile -Command "exit 0"` probe started or was denied.
4. The `.ps1` file was found.
5. The application script started.
6. WinForms initialization began.
7. The main window reached `Shown`.

### 2. Remove the hard dependency on Local App Data

Refactor `DLSS5-Guide-Launcher.ps1` so merely evaluating the script never requires `%LOCALAPPDATA%` to exist or be accessible.

- Add a parameter such as `-DataRoot` and a bootstrap-log parameter such as `-BootstrapLogPath`.
- Default `DataRoot` to a portable `Data` directory beside the launcher: `$PSScriptRoot\Data`.
- Store `Logs`, `Cache`, `Backups`, and `install-index.json` under that portable data root.
- If the portable directory cannot be created, fall back to a clearly reported `%TEMP%\DLSS5-Guide-Launcher` directory—not Local App Data.
- Tell the user the exact active data/log path in the UI and in the bootstrap log.
- Do not initialize paths with `Join-Path $env:LOCALAPPDATA ...` at script scope. A null, inaccessible, or redirected profile must not crash before logging is available.
- Create the application log as the earliest PowerShell-side operation and append explicit startup checkpoints before GPU detection, assembly loading, storage initialization, and `ShowDialog()`.
- Wrap the complete top-level startup in `try/catch/finally`. On failure, append the exception type, message, HRESULT/native error code, and stage to the portable application log and bootstrap log. Show a simple error message box only if WinForms is available; otherwise write to stderr and return a documented nonzero exit code.

### 3. Diagnose why the UI never appears

Do not assume the answer. Instrument and test each pre-window operation:

- CMD/process creation failure or error 5.
- PowerShell execution-policy or Mark-of-the-Web failure.
- Missing/inaccessible script.
- Portable storage creation failure.
- `System.Windows.Forms` or `System.Drawing` load failure.
- GPU/WMI/CIM detection failure.
- An exception during UI construction before `ShowDialog()`.

Make GPU detection nonfatal. If WMI/CIM access is denied in the VM, continue with `GPU = Auto/Unknown` and let the user select the GPU class manually.

Do not claim to bypass a managed policy. If the batch-only probe proves that Windows blocks `powershell.exe` itself, report that limitation honestly. In that case, propose a separately built, non-elevating Windows GUI executable as the next engineering option, but do not disguise PowerShell, disable security, or silently work around policy.

### 4. Preserve the current ReShade behavior

Keep this source priority:

1. Reuse a recognized 64-bit ReShade `dxgi.dll` already beside the game executable.
2. Otherwise use a user-selected local 64-bit ReShade full-add-on runtime DLL and copy it as `dxgi.dll`.
3. Only then offer the verified official headless ReShade installer as an optional fallback.

If the VM blocks the ReShade child installer with error 5, name that exact executable in the portable log and tell the user to select a local full-add-on runtime. Never request elevation. Preserve existing ReShade configuration, refuse to overwrite an unknown `dxgi.dll`, keep all game-file changes transactional, and retain rollback.

The runtime metadata can identify ReShade and verify that it is 64-bit, but cannot reliably prove that it is the full-add-on build. Keep that limitation visible.

### 5. Improve delivery and testing

- Maintain Windows PowerShell 5.1 compatibility unless the application is deliberately migrated to a compiled GUI.
- Add automated tests for portable-data-root selection, unwritable primary location with `%TEMP%` fallback, early exception logging, invalid/missing `%LOCALAPPDATA%`, nonfatal GPU detection, and all documented exit codes.
- Add a test that executes the CMD bootstrap and verifies that a bootstrap log is created even when the application `.ps1` path is intentionally invalid.
- Continue running the existing Windows PowerShell parser and self-tests.
- Run `git diff --check` and all Windows tests before publishing.
- Update README, SECURITY, and CHANGELOG with the actual behavior.
- Publish the fix as a new prerelease such as `v1.3.1-noadmin`; do not overwrite `v1.3.0-noadmin`.
- Attach a clean ZIP and publish its SHA-256.

## Acceptance criteria

The work is complete only when all of the following are true:

- Double-clicking the CMD always produces an accessible bootstrap log, even if no GUI appears.
- Neither bootstrap nor application logs depend on Local App Data.
- If PowerShell starts, the application writes startup-stage checkpoints before attempting to show the window.
- If the UI fails, the log names the exact stage and exception.
- If PowerShell itself is blocked, the batch-only log proves that and says no application/ReShade code ran.
- No step requires administrator privileges or Vulkan registry/layer changes.
- Existing/local ReShade paths avoid executing the official ReShade installer.
- The Windows PowerShell 5.1 CI and self-tests pass.
- A new GitHub prerelease ZIP is available for the user to retest on the VM.

Begin by reproducing the startup flow from the current code and identifying every operation that occurs before `ShowDialog()`. Then implement the batch bootstrap and portable logging before making any other behavioral changes.
