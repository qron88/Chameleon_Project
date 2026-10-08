# Changelog

All notable changes to Project Chameleon are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

The version is declared in the assembly attributes at the top of `Source\Chameleon-Patcher.cs`
and nowhere else; see [Version](README.md#version).

## [1.0.3] - 2026-10-07

### Fixed

- **A run could permanently destroy the signing key it should have reused.** The pipeline found
  its certificate only through the `.cer` files in `Certificates\`. With that folder deleted or
  emptied, it concluded there was no certificate, minted a new one, and the old-key cleanup then
  deleted the existing certificate from `Cert:\CurrentUser\My`. That key is non-exportable, so it
  was gone for good, while its trust entry stayed behind in `LocalMachine\Root`. When no `.cer`
  leads to a key, the store is now searched by subject (a valid code-signing certificate with a
  private key, preferring one already trusted in `Root`, then the latest expiry), and the
  missing `.cer` is re-exported. An explicit `-PfxPath` turns the search off.
- **Old signing keys were pruned before signing, and on runs that had just minted a
  replacement.** The cleanup now runs only after the catalog is signed, so a failed run never
  costs a key, and it is skipped on a run that minted a new certificate.
- **Closing the GUI mid-run did not stop the run.** The window said closing would abort the
  patch, but the hidden `powershell.exe` and the 7z / Inf2Cat / signtool processes it started
  kept running with nothing to report to. Closing now stops the whole process tree
  (`taskkill /T`), logs that it did, and ignores late output from the dying child. The 20 s
  pre-run queries also stop their full process tree when they time out.
- **A path ending in a backslash broke the GUI's command line.** A drive root such as `D:\` was
  quoted as `"D:\"`, which the Windows command-line rules read as an escaped quote, merging every
  following argument into one. Arguments are now quoted by those rules (trailing backslashes
  doubled), and a typed folder path loses a trailing separator.
- **`Sign-DriverPackage.ps1` run on its own could not find a certificate minted by 1.0.2.** Its
  default looked only for the legacy `DriverPatchSigning.cer`. It now uses the same candidate
  order and store search as the pipeline.
- **`Approve-DriverPatchCert.ps1` could trust a different certificate from the one the pipeline
  signs with.** It preferred the legacy `DriverPatchSigning.cer` over the thumbprint-named
  files, the opposite of the pipeline. It now uses the shared candidate order and picks the
  certificate whose key is on the machine; on a machine without the key, the first existing
  candidate.
- **The patcher, the prune step, the optional-components step and the verification gate each
  matched INF device lines by their own rule.** A stock line such as `...&SUBSYS_X&REV_A1`
  counted as the whitelist entry for the patcher, which then skipped it, but not for the gate,
  which then failed the run with a misleading "not correctly patched". A line with `&CC_...`
  counted for the patcher but not for pruning, so the INF serving the GPU through such a line
  could be pruned. All four now use one parser and one matching rule (`Get-InfDeviceLine` /
  `Test-InfDeviceIdMatch` in `PatchToolDiscovery.ps1`), which also ignores trailing `;`
  comments.
- **An entry present in only one `[NVIDIA_Devices...]` block was treated as present
  everywhere.** Each block serves a different OS target. The patcher now adds the line to every
  block that lacks it, reusing the section the other block uses, and the gate checks every block.
- **The installer checkbox trusted the certificate in `Root` only.** `Approve-DriverPatchCert.ps1`
  adds `Root` and `TrustedPublisher`; the checkbox now does the same, so installing through
  `setup.exe` does not stop at a "Would you like to install this device software?" prompt.
- **A failed prune could not be undone.** `Remove-ForeignOemInfs.ps1` deleted INFs before
  verifying the result, so a failure partway left them gone. They are now moved to a staging
  folder and deleted only after verification passes; a failure moves them back and restores the
  manifest. `Enable-OptionalComponents.ps1` likewise restores `setup.cfg` if its edit does not
  verify.
- **A pruned build warned about whitelist INFs it had just pruned on purpose.** On an A2000m
  box, `-PruneForeignOemInfs` removes `nvami.inf` because its three entries are all RTX A3000m,
  and then the whitelist step, the optional-components step and the verification gate each
  warned that the INF was missing and that "NVIDIA may have renamed or dropped" it. Three
  warnings on every pruned run teach you to ignore the one that matters. The pipeline now records
  which whitelist INFs the prune step removed and passes them on (`-PrunedInf`); those are
  reported as a note, while a whitelist INF missing for any other reason still warns. If every
  whitelist INF was pruned, the whitelist step now says there is nothing to unlock on this PC
  instead of suggesting the INFs were renamed.
- **The GUI's "Select .exe..." button had its top edge clipped.** The hint label above it had no
  explicit height, so it took the 23 px default, overlapped the top 2 px of the button and, being
  in front of it, hid that strip including the hover highlight. The label now has a fixed height,
  and the "Or select an unpacked folder..." button below no longer overlaps the bottom edge either.

### Changed

- **The GUI's signing-certificate fields are hidden unless asked for.** The normal case never
  needs them: the key is found in the certificate store, and a PC without one gets a new
  certificate, both without a password. The `.pfx` path and password now appear only after
  ticking "Sign with an existing certificate from a .pfx file", with one line each saying what
  the ticked and unticked states do; while it is unticked the fields are ignored, and unticking
  clears the password. Starting with the box ticked but the `.pfx` file or its password missing
  stops before the run and offers to fill them in or untick the box. When a run fails because a `.pfx`
  password is needed, the GUI opens the fields, pre-fills the project's default `.pfx` if there
  is one, and says what to enter. The window now lays itself out from the controls actually
  shown, so it shrinks and grows with the `.pfx` fields and the log panel.
- **The GUI no longer freezes while it checks the GPU and output folder before a run.** Both
  queries now run off the UI thread, with the inputs locked until the run starts or is
  abandoned.
- Documentation brought in line with the code: `Add-SetupCertOption.ps1`'s header described the
  checkbox as unticked by default, and several examples still named the legacy `.cer`.

## [1.0.2] - 2026-10-06

### Fixed

- **`Add-SetupCertOption.ps1`'s restore path always failed verification.** `$disposition` was
  assigned only in the branch that writes `setup.cfg` fresh, but the structural check after the
  commit compares the written disposition against that variable on BOTH paths. On the restore
  path (a previous run interrupted after the `setup.cfg` edit, component folder missing) the
  variable was `$null`, so the check always threw - and the rollback then deleted the folder the
  script had just restored, leaving the package in the same broken state with no way out. The
  variable is now defined before the branch, so the restore path verifies against the intended
  disposition.
- **The installer checkbox re-added the redundant `CA` trust entry.** `templates\GpuUnlockCert.nvi.template`
  still ran `certutil -addstore CA` in both its install and repair phases, even though the project
  deliberately stopped writing the `CA` store for self-signed certificates (see
  `Approve-DriverPatchCert.ps1` and the README) - so every package built with the default
  pipeline re-created the redundant second trusted-authority entry. The two `CA` phases are
  removed from the template; only the `Root` entry remains, and the component's description text
  no longer claims a "root/intermediate CA".
- **`Unpack-DriverExe.ps1` left a partial folder behind after a failed extraction.** The output
  folder was created before 7z ran, so an extraction that failed partway (corrupt archive, full
  disk) left a partial folder that made the next run die instantly on the "Output path already
  exists" guard. The extraction is now wrapped so a failure removes the partial folder before
  rethrowing, and a re-run starts clean.

### Changed

- **`New-DriverSigningCert.ps1` exports `DriverPatchSigning_<thumbprint>.cer`** instead of
  overwriting the fixed-name `DriverPatchSigning.cer` on every run. Each minted certificate now
  has its own unambiguous public file, and minting a new certificate no longer silently re-points
  the old file. The pipeline checks the thumbprint-named files (newest first) before the legacy
  fixed name, and `Approve-DriverPatchCert.ps1` falls back to the most recently minted one when
  the legacy name is absent - so existing `DriverPatchSigning.cer` files keep working unchanged.
- **`Add-ExtraGpuSupport.ps1`'s section-reuse check now sees past extra line qualifiers.** The
  pattern that looks for an already-whitelisted bare device id required the line to end right
  after `DEV`/`SUBSYS`, so a stock line carrying an extra qualifier (e.g. `&CC_030000`) was
  missed and a fresh section family was created from the template instead of reusing the
  existing one. The pattern now also accepts a following `&`, so the reuse optimization applies
  to those lines too.

## [1.0.1] - 2026-09-18

### Added

- **Automatic cleanup of old signing keys.** Every pipeline run now prunes the pile of old
  driver-patch signing certificates from `Cert:\CurrentUser\My`, keeping only the certificate that
  run signed with. This is the safe half of certificate cleanup: per-user, no elevation, and it
  withdraws no trust, so it cannot break an already-patched package. Pass `-KeepAllOldCerts` to
  opt out. The destructive half — withdrawing trust from the Root / CA / TrustedPublisher stores —
  remains opt-in via `Remove-DriverPatchCert.ps1`.

### Fixed

- **7z discovery in `Unpack-DriverExe.ps1` skipped NanaZip.** The unpack step carried its own
  simplified `Find-SevenZip` that did not check the NanaZip candidate, so a machine with only
  NanaZip installed passed the pipeline's preflight (which does check NanaZip) but then failed at
  extraction, after the run had already started. The unpack step now reuses the shared
  `Find-SevenZip` from `PatchToolDiscovery.ps1` via dot-source, so preflight and extraction always
  agree on which 7z CLI to use.
- **INF patches silently flipped the file's BOM state.** `Set-Content -Encoding UTF8` always writes
  a UTF-8 BOM, but NVIDIA's stock INFs are BOM-less UTF-8, so a patch that rewrote an INF added a
  BOM the stock file did not have - an unnecessary encoding diff in a signed package. The patching
  scripts now rewrite INFs through a shared `Write-InfLines` helper (in `PatchToolDiscovery.ps1`)
  that detects the file's original BOM state and matches it. `Add-ExtraGpuSupport.ps1`,
  `Add-RmCapabilityOverride.ps1` and `Enable-OptionalComponents.ps1` all use it now.
- **GUI status label rendered over the buttons.** The status label was positioned at
  `ClientSize.Height - 25`, which put it on top of the "Show details" / "Open log folder" buttons
  the moment a run finished, its text rendering over them. It now sits at a fixed position in a
  dedicated status row below the buttons, and the window heights were adjusted to make room.
- **GUI could hang when the child filled the stderr buffer.** The GUI read only stdout and never
  drained stderr. In a redirected, non-interactive context the pipeline's `Write-Host` banners land
  on stderr, so a child that filled the stderr buffer would block on write and never exit, hanging
  the GUI with no reason. The GUI now drains both streams concurrently and waits for the 20 s
  timeout before consuming them, so the bound is real rather than checked after the fact.
- **Signing password lingered in the box after a run.** The password field is now cleared once a
  run finishes, so a signing password is not left sitting on screen. Retyping it for a retry is the
  price of not keeping it visible.

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
