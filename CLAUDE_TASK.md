# Claude review brief: no-admin VM build

Review the `feature/non-admin-runtime` branch as a Windows PowerShell 5.1 application. The target user has no administrator privileges in a managed virtual machine and is installing RenoDX DLSS 5 for 64-bit DirectX 11/12 games such as Cyberpunk 2077 and Red Dead Redemption 2.

Required behavior:

- Never request elevation and never recommend “Run as administrator.”
- Do not write HKLM or install/register a Vulkan layer. Vulkan is outside this DX11/DX12 workflow.
- ReShade source priority must be: reuse a recognized game-local `dxgi.dll`; use a user-selected local 64-bit ReShade full-add-on runtime; use the verified official headless installer only as a fallback.
- Preserve a recognized existing ReShade runtime and configuration. Never overwrite an unknown `dxgi.dll`.
- Verify that the current user can create and delete a file in the exact game folder before downloads or installation.
- When Windows returns error 5, name the blocked path or process and give a non-admin recovery action.
- Keep every game-file mutation transactional, backed up, and rollback-safe.
- Maintain Windows PowerShell 5.1 compatibility and the existing self-tests/UI smoke-test options.

Please inspect the current diff for parser/runtime errors, unsafe assumptions, accidental data loss, and UI layout regressions. Add focused tests for ReShade source selection and write-preflight behavior where practical. Do not reintroduce mandatory execution of the ReShade installer or any elevation/Vulkan workaround.
