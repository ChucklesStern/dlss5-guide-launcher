# Changelog

## 1.3.0-noadmin — 2026-09-03

- Added a no-elevation ReShade flow that reuses an existing game-local runtime or imports a user-selected 64-bit full-add-on runtime before considering the official installer fallback.
- Added a game-folder write preflight so access-denied failures happen before dependency downloads and before game files are changed.
- Added targeted Windows error 5 messages for an unwritable game folder, blocked current-user storage, and a VM-blocked ReShade child installer.
- Added a minimal game-local `ReShade.ini` when a reused/imported runtime has no adjacent configuration.
- Kept Vulkan registry/layer setup out of the automated DX11/DX12 workflow.

## 1.2.0 — 2026-08-31

- Replaced the crowded one-page form with a polished four-step dark wizard.
- Added plain-language route cards, automatic game analysis, and a visual support-file checklist.
- Moved rollback, logs, source guides, and dependency verification to the review page.
- Added visible progress and friendly inline success/error status while preserving the existing install engine.
- Added DPI-aware fixed layout and UI screenshot/smoke-test support.

## 1.1.2 — 2026-08-31

- Added transactional creation/merging of `ReShadePreset.ini` for the Feeder route.
- Automatically enables Lumenite Kernel and DLSS 5 Feed in the required order while preserving existing techniques.
- Confirmed live Feeder delivery and DLSS 5 feature 18 evaluation in Mass Effect Legendary Edition (ME1).

## 1.1.1 — 2026-08-31

- Fixed ReShade's generated `**\**` shader/texture paths, which Windows can reject with error 123.
- Added the pinned, SHA-256-verified official `ReShade.fxh` core include required to compile Feeder and LumeniteFX.
- Confirmed the defects and fixes through a live DirectX 11 test in Mass Effect Legendary Edition (ME1).

## 1.1.0 — 2026-08-31

- Added automatic installation of the official ReShade 6.8.0 full add-on runtime as the 64-bit DXGI proxy for supported DX11/DX12 routes.
- Added headless ReShade staging and runtime/version/architecture verification.
- Added safe refusal when an existing `dxgi.dll` is not ReShade.
- Added backup/removal of alternate ReShade `d3d11.dll`/`d3d12.dll` proxies to prevent double loading.
- Added ReShade runtime and configuration files to the normal transaction and rollback.
- Preserved existing `ReShade.ini` settings and continued automatic Feeder provider configuration.

## 1.0.0 — 2026-08-30

- Added RTX 50 and experimental RTX 40 selection.
- Added API/native-DLSS decision matrix.
- Added native DX12, DX11 Bridge, and no-DLSS Feeder routes.
- Added 64-bit executable detection and cautious API/DLSS hints.
- Added latest-release resolution and GitHub SHA-256 verification for Bridge and Feeder.
- Added immutable-commit installation of Feeder 0.6's recommended LumeniteFX Kernel provider, including its license/notice.
- Added automatic `DLSS5_MV_PROVIDER=3` configuration while preserving existing ReShade preprocessor definitions.
- Added exact ReShade certificate-thumbprint verification.
- Added transaction backups, JSON manifests, conflict cleanup, and hash-aware rollback.
- Added headless dry-run and self-test modes.
