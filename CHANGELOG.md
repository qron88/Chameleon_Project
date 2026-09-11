# Changelog

All notable changes to Project Chameleon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in the assembly attributes at the top of `Source\Chameleon-Patcher.cs`
and nowhere else; see [Version](README.md#version).

## [1.0.0] - 2026-09-11

First public release. Everything below describes the state of the toolkit at that point rather
than a change against a previous published version.

### Added

- **`Chameleon-Patcher.exe`** - a WinForms GUI over the whole pipeline, compiled by the .NET
  Framework's built-in `csc.exe`. No SDK, no package restore and no internet access needed.
- **`Scripts\Invoke-DriverPatchPipeline.ps1`** - one command from a downloaded driver `.exe` to a
  patched, signed package: unpack, patch, verify, sign, add the installer checkbox.
- **PCI device/subsystem whitelist patching** (`Add-ExtraGpuSupport.ps1`) driven by
  `whitelist.json`, with no hardcoded INF section numbers, so it survives NVIDIA renumbering
  sections between releases.
- **RM capability override** (`Add-RmCapabilityOverride.ps1`) - adds `RM1457588` to every
  `nv_miscBase_addreg__*` section, fixing VRAM misreporting and broken compute on unlocked GPUs.
  This is a second, separate unlock from the PCI ID whitelist.
- **A verification gate** (`Test-DriverPatch.ps1`) that runs before signing and refuses to
  continue if the patches did not actually apply, so a silently-unpatched package can never be
  signed and shipped as finished.
- **Passwordless signing** from the certificate store, keeping the signing key non-exportable in
  `Cert:\CurrentUser\My` so no `.pfx` password ever reaches a command line.
- **`-PruneForeignOemInfs`** - drops OEM display INFs that cannot match the building machine,
  taking a run from roughly 57 minutes to about 2.
- **Optional-component enabling** (`Enable-OptionalComponents.ps1`) so PhysX and the NVIDIA App
  are offered for unlocked GPUs, and the NVIDIA App can be unticked.
- **Certificate lifecycle scripts** for creating, trusting and later removing patch certificates.
- **Per-run logging** to `Logs\patch-YYYYMMDD-HHMMSS.log`, flushed per line so a log survives a
  crash or a kill, and carrying the tool version, real Windows build and full child command line.
- **Version metadata** in the executable's Win32 version resource, its window title bar and every
  log header, all read from one set of assembly attributes.
- **`Source\`** - the GUI's commented source and `Build.ps1`, which rebuilds the `.exe` into the
  project root and prints the version resource it produced.

### Fixed

- **INF filename resolution across driver releases.** NVIDIA renames display INFs between builds,
  and in two different ways: 616.86 appends a letter (`nv_dispi.inf` becomes `nv_dispig.inf`)
  while 616.92 Studio replaces the trailing one (`nv_dispsi.inf`). Resolution now tries an exact
  match, then `<stem>*.inf`, then `<stem minus its last character>*.inf`, reporting which file
  stood in. Previously a rename made the whitelist step silently patch nothing while the rest of
  the pipeline reported success, producing a correctly signed package with no GPU unlock at all.
- **Pruning could delete every display INF.** The "never prune to nothing" guard resolved its
  fallback set through the same renaming-aware lookup, so on 616.92 the fallback itself matched
  nothing, the keep set stayed empty, and all 45 display INFs were deleted - leaving a 3.6 GB
  package containing no INF and reporting `Manifest and disk agree: 0 INF(s) each` on the way
  out. The guard now re-asserts after the fallback and refuses to prune instead.
