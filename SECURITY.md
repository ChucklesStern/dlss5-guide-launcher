# Security notes

This project is a readable PowerShell script, not a compiled installer. Review `DLSS5-Guide-Launcher.ps1` before running it.

## Trust boundaries

- The launcher never downloads or bundles NVIDIA DLLs or the experimental RTX 40 patch.
- User-supplied files are copied only after the selected route is confirmed.
- The current Bridge and Feeder are downloaded from their maintainers' GitHub releases. A release asset is refused unless GitHub publishes a SHA-256 digest and the downloaded file matches it.
- An existing or user-selected ReShade runtime is accepted only when its Windows metadata identifies it as ReShade and its PE header identifies it as 64-bit. A local runtime remains user-supplied, so obtain and scan it from a source you trust.
- The fallback ReShade installer is downloaded only from `reshade.me`; its embedded certificate thumbprint must match the value published by ReShade, and the staged runtime must identify as 64-bit ReShade 6.8.0.
- The required `ReShade.fxh` core include comes from an immutable commit of ReShade's official shader repository, is checked against the SHA-256 pinned in this release, and carries an SPDX `CC0-1.0` header.
- LumeniteFX is downloaded directly from its official repository at an immutable Git commit and checked against the archive SHA-256 tested with this release. Its license and notice are copied with it; the launcher does not rehost it.
- Every game-file replacement/removal is backed up and recorded in JSON before the operation is considered complete.

The launcher first reuses an existing ReShade DXGI runtime or copies a user-selected local runtime. Only when neither is supplied does it execute the verified official ReShade setup in supported headless mode against an isolated Windows staging executable. It does not execute downloaded community add-ons or NVIDIA DLLs itself; ReShade loads those later when the user starts the game.

This fork never requests elevation, writes to HKLM, installs a Vulkan layer, or attempts to bypass AppLocker/WDAC/VM policy. It verifies current-user write access to the game folder before downloads and reports Windows error 5 with the blocked path or child process.

An existing non-ReShade `dxgi.dll` is never overwritten automatically. ReShade runtime/configuration changes participate in the same backup and hash-aware rollback as the other installed files.

## Antivirus and anti-cheat

No software can promise zero risk. Scan the launcher and every user-supplied binary with Windows Security or another trusted scanner. Do not inject ReShade/add-ons into multiplayer or anti-cheat games unless the game's rules clearly allow it.

## Reporting a problem

When reporting a bug, include the launcher version, the selected route, the startup log from `Logs\` beside the launcher, and the application log from `Data\Logs`. If neither folder was writable the launcher falls back to `%TEMP%\DLSS5-Guide-Launcher-Logs` and prints the path it used. Local App Data is never used for either. The logs record the folder the launcher was extracted to and how far startup got; they do not record argument values, environment dumps, or file contents. Do not upload copyrighted NVIDIA DLLs.
