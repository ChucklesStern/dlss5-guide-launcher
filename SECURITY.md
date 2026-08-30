# Security notes

This project is a readable PowerShell script, not a compiled installer. Review `DLSS5-Guide-Launcher.ps1` before running it.

## Trust boundaries

- The launcher never downloads or bundles NVIDIA DLLs or the experimental RTX 40 patch.
- User-supplied files are copied only after the selected route is confirmed.
- The current Bridge and Feeder are downloaded from their maintainers' GitHub releases. A release asset is refused unless GitHub publishes a SHA-256 digest and the downloaded file matches it.
- ReShade is downloaded only from `reshade.me`; its embedded certificate thumbprint must match the value published by ReShade, and the staged runtime must identify as 64-bit ReShade 6.8.0.
- The required `ReShade.fxh` core include comes from an immutable commit of ReShade's official shader repository, is checked against the SHA-256 pinned in this release, and carries an SPDX `CC0-1.0` header.
- LumeniteFX is downloaded directly from its official repository at an immutable Git commit and checked against the archive SHA-256 tested with this release. Its license and notice are copied with it; the launcher does not rehost it.
- Every game-file replacement/removal is backed up and recorded in JSON before the operation is considered complete.

The launcher executes the verified official ReShade setup only in its supported headless mode against an isolated Windows staging executable. It does not execute downloaded community add-ons or NVIDIA DLLs itself; ReShade loads those later when the user starts the game.

An existing non-ReShade `dxgi.dll` is never overwritten automatically. ReShade runtime/configuration changes participate in the same backup and hash-aware rollback as the other installed files.

## Antivirus and anti-cheat

No software can promise zero risk. Scan the launcher and every user-supplied binary with Windows Security or another trusted scanner. Do not inject ReShade/add-ons into multiplayer or anti-cheat games unless the game's rules clearly allow it.

## Reporting a problem

When reporting a bug, include the launcher version, selected route, and the log from `%LOCALAPPDATA%\DLSS5-Guide-Launcher\Logs`. Do not upload copyrighted NVIDIA DLLs.
