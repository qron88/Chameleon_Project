# Chameleon Patcher

<img src="Assets/Chameleon.png" alt="Chameleon Patcher" width="120" align="right">

Project Chameleon patches a stock NVIDIA driver package so it installs and works properly on PCIe graphic cards 
equipped mobile GPUs  — chiefly laptop RTX 20-, 30- and 40-series and RTX-Ada mobile
packed by Chinese manufacturers. This is the enthusiast unlock, done reproducibly: 
point the tool at a downloaded driver `.exe` and it unpacks, patches, verifies, 
re-signs and repackages it, on any driver version.

Two independent gates have to come off for an unlocked GPU to work, and the patcher handles both:

- **The INF-level PCI ID whitelist.** 61 device/subsystem-ID entries are added to the driver's
  INFs — 58 to `Display.Driver\nv_dispi.inf` (the main desktop INF) and 3 to `nvami.inf` (the
  ASUS OEM INF). All additions, no removals. Most are **generic/OEM subsystem IDs**
  (`SUBSYS_000010DE`, `SUBSYS_44494D50`, `SUBSYS_00000000`); a few are specific real laptop
  subsystem IDs (MSI/ASUS/Lenovo). This is what lets the driver install and the device enumerate.
- **The driver's internal Resource-Manager check.** One registry override,
  `HKR,,RM1457588,%REG_DWORD%,1`, is added to every `nv_miscBase_addreg` AddReg section across the
  driver INFs. Without it a whitelisted GPU installs but misreports VRAM size and has broken
  compute - see [Why VRAM size / compute needs a second fix](#why-vram-size--compute-needs-a-second-fix).

Editing the INFs invalidates `nv_disp.cat`, so the patcher also rebuilds the catalog and re-signs
it with a self-signed code-signing certificate it generates and keeps locally. A patched package
therefore installs only on a machine that trusts that certificate and has Windows Test Signing
mode on - see [Trusting the certificate](#trusting-the-certificate).

`Scripts\whitelist.json` is the data-driven form of those 61 PCI ID whitelist entries (device ID,
subsystem ID, description, and a captured INF section body to use as a template).

## Project layout

```
Chameleon_Project\
├─ Chameleon-Patcher.exe    <- main app, double-click to run; must stay at the root
├─ README.md
├─ Source\                  <- source for the one thing here that ships as a binary
│  ├─ Chameleon-Patcher.cs     <- the GUI; version attributes live at the top
│  └─ Build.ps1                <- rebuilds the .exe into the project root
├─ Logs\                    <- created on first run; one timestamped log per patch attempt
├─ Assets\                  <- branding; not needed at runtime
│  ├─ Chameleon.ico            <- embedded into the .exe at build time
│  ├─ Chameleon.png            <- logo with transparency
│  ├─ Chameleon-source.jpg     <- the original artwork
│  └─ Build-Icon.ps1           <- regenerates the .png and .ico from the source
├─ Scripts\                 <- everything the app calls; also runnable standalone
│  ├─ Invoke-DriverPatchPipeline.ps1
│  ├─ Unpack-DriverExe.ps1
│  ├─ Add-ExtraGpuSupport.ps1
│  ├─ Add-RmCapabilityOverride.ps1
│  ├─ Remove-ForeignOemInfs.ps1
│  ├─ Enable-OptionalComponents.ps1
│  ├─ Test-DriverPatch.ps1
│  ├─ New-DriverSigningCert.ps1
│  ├─ Sign-DriverPackage.ps1
│  ├─ Add-SetupCertOption.ps1
│  ├─ Approve-DriverPatchCert.ps1
│  ├─ Remove-DriverPatchCert.ps1
│  ├─ PatchToolDiscovery.ps1
│  ├─ whitelist.json
│  └─ templates\GpuUnlockCert.nvi.template
└─ Certificates\            <- created automatically the first time a cert is needed
   ├─ DriverPatchSigning.cer   <- public cert; this is all the toolkit needs
   └─ DriverPatchSigning.pfx   <- only if you asked for one (-Exportable)
```

`Certificates\` doesn't need to exist ahead of time - `New-DriverSigningCert.ps1` and
`Invoke-DriverPatchPipeline.ps1` both create it automatically (as a sibling of `Scripts\`) the
first time a certificate is generated there.

Everything under `Scripts\` is plain PowerShell, so it is its own source. `Source\` exists for the
one component that does not read as text once built - the compiled GUI - so the repository always
carries what an `.exe` alone could not tell you: the commented original and the exact command that
produced it. `Assets\` is the same idea for the artwork, keeping `Chameleon-source.jpg` and the
script that regenerates the `.ico` and `.png` from it.

## Files

| File | Purpose |
|---|---|
| `Chameleon-Patcher.exe` | GUI wrapper around the pipeline below - see [GUI](#gui). Carries the project version in its Win32 version resource. |
| `Source\Chameleon-Patcher.cs` | The GUI's source. Version attributes sit at the top of the file and are the single place the release number is declared - see [Version](#version). |
| `Source\Build.ps1` | Rebuilds the `.exe` into the project root with `csc.exe` and prints the version resource it produced. |
| `Scripts\Invoke-DriverPatchPipeline.ps1` | All-in-one: unpack → patch → sign → add the installer checkbox. Takes either a raw downloaded `.exe` or an already-unpacked folder; result is always a plain folder. |
| `Scripts\Unpack-DriverExe.ps1` | Extracts a downloaded driver `.exe` (a 7-Zip SFX) into a plain folder. |
| `Scripts\Add-ExtraGpuSupport.ps1` | Applies `whitelist.json` to **any** stock `Display.Driver` folder — current or future NVIDIA driver versions. Does not hardcode section numbers, so it survives INF renumbering between releases, and resolves INF *filenames* by stem so it survives them being renamed too — see [When NVIDIA renames the INFs](#when-nvidia-renames-the-infs). |
| `Scripts\Add-RmCapabilityOverride.ps1` | Adds the `RM1457588` registry override to every `nv_miscBase_addreg__*` section in every driver INF - fixes VRAM size misreporting and broken compute on whitelisted GPUs. See [below](#why-vram-size--compute-needs-a-second-fix). |
| `Scripts\Remove-ForeignOemInfs.ps1` | Drops the OEM display INFs that cannot match this machine, taking the catalog rebuild from ~50 min to ~7. Opt-in via `-PruneForeignOemInfs`. See [Making a run finish in minutes](#making-a-run-finish-in-minutes-instead-of-an-hour). |
| `Scripts\Enable-OptionalComponents.ps1` | Makes PhysX and the NVIDIA App offered for the unlocked GPUs, and the NVIDIA App unticked-able. See [PhysX and the NVIDIA App](#physx-and-the-nvidia-app). |
| `Scripts\Test-DriverPatch.ps1` | Verifies a package really was patched, and is run **before signing** so a silently-unpatched package can't be signed and shipped as finished. See [The verification gate](#the-verification-gate). Also runnable standalone against any package. |
| `Scripts\New-DriverSigningCert.ps1` | Generates a fresh, locally-owned self-signed code-signing cert (does **not** touch system trust stores). The key is **non-exportable** and stays in `Cert:\CurrentUser\My`, so there is no `.pfx` and no password at all. `-Exportable` opts into a portable `.pfx`. Defaults to a 3-year life. |
| `Scripts\Sign-DriverPackage.ps1` | Rebuilds `nv_disp.cat` from the patched INFs (`Inf2Cat.exe`) and signs it (`signtool.exe`) with your cert. Signs **without any password** when the key is in your certificate store — see [Signing without a password](#signing-without-a-password). |
| `Scripts\PatchToolDiscovery.ps1` | Shared lookup for the external tools (7-Zip/NanaZip, `Inf2Cat.exe`, `signtool.exe`), dot-sourced by the others. The pipeline uses it to check every tool up front, so a missing SDK fails in seconds instead of after a multi-GB copy. Also owns the one GPU-detection routine the prune step, the output-folder tag and the pruned-build gate all share. |
| `Scripts\Add-SetupCertOption.ps1` | Adds a "Chameleon GPU cert." component to `setup.exe`'s Custom Installation Options screen, **ticked by default** and still user-selectable; `-Unchecked` restores opt-in. The label lives in `templates\GpuUnlockCert.nvi.template`, the same string in every locale. |
| `Scripts\Approve-DriverPatchCert.ps1` | Standalone alternative to the installer checkbox: trusts the cert via a separate, explicit script you run yourself. Adds `Root` (makes the chain work) and `TrustedPublisher` (installs without a device-software prompt). No longer writes the redundant `CA` entry. |
| `Scripts\Remove-DriverPatchCert.ps1` | The counterpart to the above. Inventories every patch certificate and which stores it sits in, and removes the ones you pick. Read-only until you ask it to delete. See [Cleaning up trusted certificates](#cleaning-up-trusted-certificates). |
| `Scripts\whitelist.json` | The device/subsystem whitelist data the patcher applies. |
| `Scripts\templates\GpuUnlockCert.nvi.template` | The verified-working installer-component manifest `Add-SetupCertOption.ps1` copies into each patched package. |
| `Certificates\DriverPatchSigning.cer` / `.pfx` | Your signing certificate (created on first use). |

Unpacking a downloaded `.exe` needs a 7z-compatible CLI - this machine has NanaZip (a 7-Zip-
compatible Store app), auto-detected via the `7z.exe` WindowsApps alias. A plain 7-Zip install
under Program Files works too.

## GUI

`Chameleon-Patcher.exe` wraps the whole pipeline in a small Windows app - no PowerShell command
line needed. A field for the driver `.exe`/folder, a "Start Patching" button, a progress bar with
the current step name, a "▼ Show details" toggle that expands to a live console log, and an
"Open log folder" button, plus a "Build for this PC only" checkbox that turns on INF pruning. On success it asks whether to launch `setup.exe` right away; on failure
it points you at the log for that run - see [Patch logs](#patch-logs).

Ticking "Build for this PC only" on a machine whose GPU this patcher doesn't unlock gets a dialog
before the run starts, offering the portable build instead - see [A pruned build needs a GPU worth
pruning for](#a-pruned-build-needs-a-gpu-worth-pruning-for). Answering yes unticks the box, so the
log header and the output folder name both reflect what was actually built.

The certificate boxes are **both optional and normally left empty** - signing uses the key already
in your certificate store, with no password. Fill them in only to sign with a `.pfx` whose key
isn't on this machine. See [Signing without a password](#signing-without-a-password).

It's a self-contained `.exe` compiled from `Source\Chameleon-Patcher.cs` via the .NET Framework's
built-in `csc.exe` (no external tools, no internet needed) - rebuild after editing the source with:

```powershell
.\Source\Build.ps1
```

which is a wrapper around one `csc.exe` call:

```powershell
& "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /target:winexe /out:Chameleon-Patcher.exe /win32icon:Assets\Chameleon.ico /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /platform:x64 Source\Chameleon-Patcher.cs
```

`Build.ps1` writes the `.exe` to the **project root**, not beside itself, and that placement is
load-bearing: the app resolves `Scripts\Invoke-DriverPatchPipeline.ps1` relative to its own folder,
so a binary left in `Source\` would look for `Source\Scripts\` and fail at launch. It also prints
the version resource it produced, so a mismatch between the source attributes and what Explorer
shows surfaces at build time rather than after a release.

`/win32icon` embeds `Assets\Chameleon.ico` as the file icon, and the app reads that same icon back
out of its own `.exe` for the window and taskbar, so no `.ico` has to sit next to the binary.

### Version

The version is declared once, as assembly attributes at the top of `Source\Chameleon-Patcher.cs`:

```csharp
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]
[assembly: AssemblyInformationalVersion("1.0.0")]
```

Everything else reads that one declaration back, so the number appears in three places and cannot
drift between them:

**1. The window title bar**, which is the quickest check and makes a screenshot self-identifying:

```
Chameleon Patcher 1.0.0
```

**2. The file's Win32 version resource.** `csc.exe` folds the attributes in by itself - there is no
`.rc` file to maintain - so the number shows in Explorer's **Details** tab, and in:

```powershell
(Get-Item Chameleon-Patcher.exe).VersionInfo | Select-Object FileVersion, ProductVersion, ProductName
```

**3. Every patch log header**, stamped from the assembly at runtime rather than from a repeated
literal, so a log and the binary that wrote it cannot disagree:

```
=== Chameleon Patcher - patch log ===
started        : 2026-09-11 10:41:02 +02:00
version        : 1.0.0
```

The log line matters because a patched driver package carries no trace of which build of this tool
made it. Bumping a release means editing those three attributes and rebuilding; nothing else
refers to the number. Keep `AssemblyVersion` at `x.y.0.0` and let the file and informational
versions carry the precise one.

### Patch logs

Every run through the GUI writes a log to `Logs\patch-YYYYMMDD-HHMMSS.log`, next to the `.exe`.
The on-screen details panel disappears when you close the window, which is exactly when a failed
patch needs looking at, so the same stream also goes to disk. If a run fails, the app tells you
where the log is and offers to open it; the **Open log folder** button opens the most recent one
with it already selected in Explorer.

A log holds everything needed to diagnose a failure without reproducing it:

- Which build of this tool wrote it, read back from the assembly's own version attributes.
- Machine context - real Windows build (read from the registry, because `Environment.OSVersion`
  reports 6.2.9200 to unmanifested apps and would otherwise claim Windows 8), CLR version, and
  whether the process was elevated.
- The exact inputs and the full child command line, so the run can be repeated by hand.
- Every line the pipeline emitted, stdout and stderr, each stamped with elapsed time since the
  child started. Because the pipeline prints `=== N/M: ... ===` banners, the gap between two
  banners is how long that step took - the quickest way to see that the catalog rebuild is eating
  the wall clock rather than something being stuck.
- Exit code, duration, and a short pointer on where to start reading.

Writes are flushed per line rather than buffered to the end, so the log survives a crash, a
`taskkill`, or a hang partway through - not just a clean failure. Closing the window mid-run
records that explicitly, so an abrupt end is distinguishable from a stall. The 20 most recent logs
are kept and older ones are pruned automatically.

Nothing sensitive is written. The `.pfx` password never appears on the child's command line in the
first place (it travels in an environment variable), and the log header records only whether one
was supplied, never its value.

Running the pipeline directly from PowerShell does not produce one of these files - the logging
lives in the GUI wrapper. Redirect the script's output instead:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "...exe" *> patch.log
```

It must stay at the project root - it locates `Scripts\Invoke-DriverPatchPipeline.ps1` relative
to its own folder. Internally it just runs that same script as a child `powershell.exe` process
and parses its `=== N/M: ... ===` step banners for progress.

It passes `-NonInteractive`, because the child has no attached console and any prompt would hang
with the GUI showing no reason why (`Read-Host -AsSecureString` does not reliably read from a
redirected stdin pipe without a real console - confirmed by testing, it just hangs). With
`-NonInteractive` the pipeline turns any would-be prompt into a clear error that appears in the
log instead. In the normal store-signing case no password is involved at all. If you do type one,
it travels in an environment variable set only on the child process
(`$env:DRIVER_PATCH_PFX_PASSWORD`), never as a command-line argument.

## Dependencies

Everything below is either bundled with Windows already or auto-detected by the scripts - nothing
here requires internet access to install.

Signing does reach the network once, for an RFC3161 timestamp, but that is best-effort: if the
timestamp server is unreachable the catalog is still signed and the run continues with a warning.
`-SkipTimestamp` skips the attempt entirely, making the whole pipeline fully offline-capable.

**Runtime environment**
- **Windows PowerShell 5.1** (`powershell.exe`) - every `.ps1` script targets this specifically,
  not PowerShell 7+. Two real bugs were found and coded around because of Windows-PowerShell-
  specific quirks: `$PSScriptRoot` is empty inside a `param()` default value when a script is
  launched via `-File`, and `Read-Host -AsSecureString` doesn't work over a redirected stdin pipe.
- **.NET Framework 4.x** - `Chameleon-Patcher.exe` is a compiled WinForms app; needs the .NET
  Framework runtime (present on any normal Windows 10/11 install) to run at all.

**External tools each script shells out to**

| Tool | Used by | How it's found |
|---|---|---|
| A 7z-compatible CLI (NanaZip or 7-Zip) | `Unpack-DriverExe.ps1` | Checks the WindowsApps `7z.exe` alias, then `Program Files\7-Zip`, then `PATH`; throws if none found |
| `Inf2Cat.exe` + `signtool.exe` (Windows SDK/WDK) | `Sign-DriverPackage.ps1` | `PatchToolDiscovery.ps1` searches `%WDKContentRoot%` and `Windows Kits\10\bin`, picking the newest SDK version and its x64 build, then falls back to `PATH`. Override with `-Inf2CatPath` / `-SignToolPath`. The pipeline resolves both **before** copying anything, so a missing SDK fails immediately. |
| `certutil.exe` (built into Windows) | `Approve-DriverPatchCert.ps1`, and the `GpuUnlockCert.nvi` installer component | Always present on Windows |
| `New-SelfSignedCertificate` / `Export-Certificate` / `Export-PfxCertificate` (PKI module, built-in) | `New-DriverSigningCert.ps1` | Ships with Windows, no install needed |

**Build-time only** (not needed to *run* the toolkit, only to *rebuild* the GUI after editing
`Source\Chameleon-Patcher.cs`): `csc.exe` at
`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, invoked by `Source\Build.ps1` (see
[GUI](#gui) above).

**Internal dependencies within the project**
- `Invoke-DriverPatchPipeline.ps1` is the orchestrator - it calls all the other scripts in
  sequence, and is the only script `Chameleon-Patcher.exe` itself invokes.
- `Add-ExtraGpuSupport.ps1` needs `whitelist.json`.
- `Add-SetupCertOption.ps1` needs `templates\GpuUnlockCert.nvi.template`.
- `Sign-DriverPackage.ps1`, `Approve-DriverPatchCert.ps1`, and the cert-generation step all
  read/write `Certificates\DriverPatchSigning.pfx` / `.cer`. `Sign-DriverPackage.ps1` only reads
  the **public** `.cer`, to learn which thumbprint to sign with; the `.pfx` is touched solely on
  the fallback path.
- `Invoke-DriverPatchPipeline.ps1` and `Sign-DriverPackage.ps1` both dot-source
  `PatchToolDiscovery.ps1` for tool lookup and signing-identity resolution.

**Expect the catalog rebuild to dominate the runtime.** `Inf2Cat.exe` is a single-threaded 32-bit
tool that re-validates the whole `Display.Driver` folder once per INF, and a real package has ~43
INFs over ~2.7 GB, so step 5 can run for tens of minutes at 100% of one core while every other
step finishes in seconds. Nothing is wrong when it appears to sit on `Processing INF:` for a long
time.

**Other requirements**
- **Administrator rights** - needed for `Approve-DriverPatchCert.ps1` (`certutil -addstore`) and
  for actually running `setup.exe` to install a driver.
- **Input**: a real NVIDIA driver download (`.exe` or unpacked folder) to patch - the project
  doesn't bundle one.

## Usage (recommended: the all-in-one pipeline)

Point it straight at a downloaded driver `.exe` — this is the normal case:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "D:\Downloads\610.88-desktop-win10-win11-64bit-international-dch-whql.exe"
```

One command: unpacks the installer (never touches the source `.exe`), applies the
device/subsystem whitelist, applies the RM capability override, **verifies the patches actually
applied**, reuses (or first generates) a signing cert, rebuilds and signs `nv_disp.cat`, and adds
the opt-in installer checkbox. Output goes to a plain folder, `<basename>_Patched` next to the
source.

Re-run exactly that same command for each future NVIDIA driver release. You do **not** need to
pass a certificate or a password: the pipeline finds your existing signing key in
`Cert:\CurrentUser\My` on its own and signs with it, so every release keeps using the same
already-trusted certificate instead of minting a new one you'd have to re-trust. Before it copies
anything it prints which tools and which certificate it resolved:

```
Preflight: checking tools and signing identity...
  Inf2Cat:  C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x86\Inf2Cat.exe
  signtool: C:\Program Files (x86)\Windows Kits\10\bin\10.0.26100.0\x64\signtool.exe
  cert:     2A4A4A0C6666E4CD1E59E04CBF4EAFCB06843EA8 (from certificate store - no password needed)
```

If you already have an unpacked folder instead of the `.exe`, use `-SourcePackagePath` instead -
same pipeline minus the unpack step:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourcePackagePath "D:\NVIDIA\610.xx-desktop-win10-win11-64bit-international-dch-whql"
```

Use `-SkipSetupCertOption` to leave `setup.cfg` untouched and use `Approve-DriverPatchCert.ps1`
(or `pnputil`) separately instead.

### Doing it step by step instead

Equivalent to what the pipeline does, if you want to inspect or customize each stage (run these
from inside `Scripts\`, or adjust the paths accordingly):

```powershell
cd Scripts
.\Unpack-DriverExe.ps1 -ExePath "610.88-....exe" -OutputPath "610.88_Patched"
.\Add-ExtraGpuSupport.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\Add-RmCapabilityOverride.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\Test-DriverPatch.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\New-DriverSigningCert.ps1
.\Sign-DriverPackage.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
.\Add-SetupCertOption.ps1 -PackageRoot "610.88_Patched" -CerPath "..\Certificates\DriverPatchSigning.cer"
```

`Sign-DriverPackage.ps1` needs no certificate arguments once `New-DriverSigningCert.ps1` has run
once: it finds the key in your certificate store by itself. Pass `-CertThumbprint` to pick a
specific certificate, or `-PfxPath` to sign on a machine that has only the `.pfx`.

Run `Add-RmCapabilityOverride.ps1` **before** signing - it edits the same INFs that get hashed
into `nv_disp.cat`, so signing first would just produce a catalog that no longer matches the
files (Windows would refuse to load the driver at all, not just misreport VRAM/compute).

## The verification gate

Signing is the point of no return for a mistake. `Inf2Cat` will happily build a catalog out of
unpatched INFs, and `signtool` will happily sign it, so a package whose patch step quietly found
nothing to do comes out the far end looking completely finished. It installs, the device
enumerates, and the unlock simply isn't there. That failure is silent and it is easy to reproduce:
a run against a package whose INF layout the patchers don't recognise used to report
`0 entries added` and still sign and declare success.

`Test-DriverPatch.ps1` closes that hole. The pipeline runs it as step 4, between patching and
signing, and refuses to continue if anything is wrong. It re-reads the patched INFs and asserts:

- Every INF named in `whitelist.json` is present and has at least one `[NVIDIA_Devices*]` block.
- Every whitelist entry's PCI device and subsystem ID is actually whitelisted.
- Each device line points at an install Section that **exists** in the same INF.
- Every section a spliced-in `SectionExtraGPU*` body references resolves in that INF.
- Every `%token%` a device line uses is defined in `[Strings]`.
- Every `[nv_miscBase_addreg__NN]` section carries the `RM1457588` override.

Run it yourself against any package, patched or not:

```powershell
.\Scripts\Test-DriverPatch.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
```

Add `-ReportOnly` to inspect without failing. `-SkipPatchVerification` on the pipeline bypasses
the gate, but there is rarely a good reason to.

**One subtlety about matching.** Device lines are matched on the DEV and SUBSYS pair, not on the
`%key%` name, because NVIDIA may already whitelist a given device upstream in a later release. In
that case `Add-ExtraGpuSupport.ps1` correctly skips it and the entry is already present under
NVIDIA's own line. What matters is that the combination is whitelisted, not who put it there.

Note also that a real device line reads

```
%NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE
```

with the install section **before** the hardware ID. An assertion written the other way round
never matches a correctly patched INF.

The two patchers now also fail loudly rather than shrugging. `Add-ExtraGpuSupport.ps1` throws if
an INF has no `[NVIDIA_Devices*]` block at all, and `Add-RmCapabilityOverride.ps1` throws if no
INF in the package has an `[nv_miscBase_addreg__NN]` section. Both of those mean "this driver
release's layout is not what this script understands", which is worth stopping for.

## Making a run finish in minutes instead of an hour

Almost all the wall-clock time in a patch run is `Inf2Cat` rebuilding the catalog, single-threaded
on one core. Two things were measured on a real 2.71 GB `Display.Driver`, and the first one kills
the obvious idea:

**Trimming the `/os` list does nothing.** One target, two targets and all five produce the same
runtime and a byte-identical catalog:

| INFs | OS targets | Time | Catalog |
|---|---|---|---|
| 4 | 1 | 145.3 s | 4473 KB |
| 4 | 2 | 145.3 s | 4473 KB |
| 4 | 5 | 147.4 s | 4473 KB |

**The cost is superlinear in INF count**, and driven by the INFs rather than the payload bytes:

| INFs | Time |
|---|---|
| 1 | 79.7 s |
| 2 | 128.1 s |
| 4 | 147.4 s |
| 8 | 583.8 s |

Four to eight INFs quadruples it, which is why all 43 take about fifty minutes. `Inf2Cat /?`
offers no way to reduce its own work: `/nocat` only suppresses the catalog, `/pageHashes` adds
work, and there is no switch to skip the signability test.

Parallelising it across cores is not available either. All 43 INFs declare
`CatalogFile = NV_DISP.CAT`, so they build one shared catalog, and merging catalogs is not
something Inf2Cat or signtool can do.

So the only real lever is to have fewer INFs, which is what `-PruneForeignOemInfs` does:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -SourceExePath "...exe" -PruneForeignOemInfs
```

A stock package ships 43 display INFs: the generic desktop one plus one per laptop OEM. Usually
exactly one can apply to any given machine. An INF survives if it can match a GPU actually present,
if this toolkit patches it **and** one of its whitelist entries names present hardware, or if you
passed `-KeepInf`. Everything else goes, along with its manifest entry.

That second condition matters more than it sounds. Keeping every INF the toolkit *could* patch is
too generous: on this machine it retained `nvamig.inf`, whose three whitelist entries are all RTX
A3000m, on a box with an A2000m. That INF is 3.9 MB with 62,280 lines and 3,010 sections against
`nv_dispig.inf`'s 677 KB, and on its own it accounted for three quarters of the catalog build.

Measured on 616.86, 43 INFs down to 1:

| Step | Unpruned | Pruned to 2 | Pruned to 1 |
|---|---|---|---|
| Catalog rebuild | ~3000 s | 385 s | **96 s** |
| RM override | 1485 sections / 40 INFs | 122 / 2 | 17 / 1 |
| Whole pipeline | ~57 min | 7.6 min | **2.2 min** |

If nothing matches, the rule backs off to keeping every whitelist INF and says so. Should that
fallback come up empty too, the step refuses to run rather than deleting every display INF — see
[Pruning must never delete every INF](#pruning-must-never-delete-every-inf).

Do not bother trimming the whitelist entries themselves. Measured on an identical two-INF package,
patching zero entries took 391.6 s, all 61 took 384.9 s, and one took 372.5 s. The spread is noise;
the cost is in the INFs and the binaries, not in the device lines added to them.

**The result is specific to the hardware in the machine that built it** and will not install on
other vendors' laptops, which is why it is opt-in rather than the default.

In the GUI this is the **"Build for this PC only"** checkbox, unticked by default to match the
command line. The choice belongs to whoever *builds* the package: by the time `setup.exe` runs the
pruned INFs are already gone, so it is not something the person installing can change.

### A pruned build needs a GPU worth pruning for

`-PruneForeignOemInfs` stops in preflight, before anything is unpacked, if **no GPU in this
machine is one `whitelist.json` unlocks**:

```
Nothing to unlock on this machine, and a for-this-PC-only build was requested.

  NVIDIA GeForce RTX 5070 Ti (DEV_2C05&SUBSYS_F3221569) - not in whitelist.json
```

The two options are opposites here, so the same machine gives them opposite answers:

| | Pruned (`-PruneForeignOemInfs`) | Universal (default) |
|---|---|---|
| What survives | only INFs that can match **this** machine | everything |
| Whitelist entries that can ever match | those for hardware present here | all 61 |
| Machine that built it | must be the machine that needs the unlock | irrelevant |
| No unlockable GPU here | **stops** | runs normally |

This was found by running both on a box with an RTX 5070 Ti. `DEV_2C05` is a desktop Blackwell
part the stock generic INF already carries a bare `DEV` line for, and it is not in
`whitelist.json` at all. The pruned run nonetheless completed: it kept `nv_dispig.inf` because
that INF matches the 5070 Ti, spliced in 58 laptop-GPU device lines that nothing on that machine
can ever match, added the RM override to 17 sections, reported `verification PASSED`, and signed
the result with an untrusted certificate. What came out was NVIDIA's own driver for a GPU that
already worked, needing Test Signing mode to install. Every step reported success and the unlock
was a no-op.

The universal run on the same machine is the *correct* use of it - all 43 INFs, all 61 entries,
installable on the laptop that actually has the locked GPU. So the gate is on the pruned path
only, and a universal build is never questioned.

Detection failing is not the same as "not a target": if no NVIDIA display GPU can be read at all
the run continues with a warning, because `Remove-ForeignOemInfs.ps1` already backs off to keeping
every whitelist INF when it has no hardware to go on, and a WMI quirk should not be what refuses a
run.

Pass `-AllowUnsupportedGpu` to build the pruned package anyway. Ask what the machine's verdict is
without running anything:

```powershell
.\Scripts\Invoke-DriverPatchPipeline.ps1 -CheckLocalGpuSupport
# SUPPORTED | UNSUPPORTED | UNKNOWN, then one line per GPU
```

The GUI asks the same question when the box is ticked, before it starts, and offers to build the
portable package instead - so an unsupported GPU costs a dialog rather than a failed run.

**Multi-GPU machines are handled.** Every display-class NVIDIA GPU present is detected and the
kept set is the union of what they need, so a box with, say, an RTX 5070 Ti and an RTX A2000 keeps
whatever supports either. The 5070 Ti is covered by a bare `DEV_2C05` line in the generic INF and
the A2000 by the whitelist, so both end up served by `nv_dispi.inf` and the prune is still safe.
Where a GPU genuinely needs an OEM INF, that INF is kept too. The reasons are printed per INF:

```
nv_dispig.inf   - patched by this toolkit; matches present hardware DEV_2C05&SUBSYS_88881043
nvamig.inf      - patched by this toolkit
```

Only the GPU is considered, not the HD Audio function NVIDIA exposes on the same PCI device, which
no display INF ever matches.

Why this is safe to do: the 43 display INFs are self-contained with respect to each other, none
referencing another through `Include=`, `Needs=` or `CopyINF=`, and their filenames appear in
exactly one place outside the INFs themselves, the `<manifest>` in `Display.Driver`'s `.nvi`.
`setup.cfg` names no INF at all. So pruning means deleting files and removing their manifest
entries, and nothing else goes stale. The script verifies afterwards that the manifest and the
folder agree, and refuses if a kept INF references one being removed.

Hardware matching follows Windows' own rules: an exact `DEV`+`SUBSYS` line, or a bare `DEV` line
with no `SUBSYS`, which covers any subsystem of that device. An OEM INF listing the right device
under someone else's subsystem can never win the install, so keeping it would be waste. A GPU that
matches no kept INF but *is* in `whitelist.json` is fine and reported as such, since adding it to
the generic INF is the whole point of this toolkit. A GPU matching neither raises a warning.

Only the INFs are pruned, not the driver binaries, so the package stays the same size on disk.

## PhysX and the NVIDIA App

Whether `setup.exe` offers "PhysX System Software" and the NVIDIA App is not a fixed property of
the installer. Both are gated by constraints in `setup.cfg` that read **per-device feature flags
out of the driver INF**:

```xml
<sub-package name="Display.PhysX">
  <constraints>
    <property name="Display.Driver!Feature.Physx" level="silent" .../>
  </constraints>
</sub-package>
```

Those flags are the INF's own `NVSupportPhysx = 1` and `NVSupportGFExperienceUDA = 1` lines,
written into each device install section. NVIDIA sets them unevenly. In stock 616.64's main INF:

| Flag | Sections carrying it |
|---|---|
| Total device install sections | 105 |
| `NVSupportPhysx = 1` | 55 |
| `NVSupportGFExperienceUDA = 1` | 28 |

Because the constraints are `level="silent"`, a GPU whose section lacks the flag makes the
component vanish from the installer with no message at all. That is why the offer appears on some
hardware and not others.

`Enable-OptionalComponents.ps1` levels this out for the GPUs this toolkit unlocks. It resolves
each whitelisted device line to the install Section it points at and ensures that Section carries
both flags. It runs as pipeline step 4, before the catalog is built. Skip it with
`-SkipOptionalComponents`.

It also flips one attribute in `setup.cfg`. `Display.NvApp` ships as
`disposition="default" userSelectable="false"`, meaning pre-ticked and **locked**; the script sets
`userSelectable="true"` so it becomes a row you can untick. PhysX needs no such change, since it
is already `disposition="default"` with no selectability restriction. The result is both
components ticked by default and both removable under Custom Installation Options.

**What it deliberately does not do** is delete the `setup.cfg` constraints. That would force these
components on for every GPU, including ones NVIDIA flagged as unsupported. Setting the INF flags
makes the unlocked GPUs behave like first-class ones instead, which is a much narrower claim.

**On blast radius.** Most whitelisted devices get a freshly spliced `SectionExtraGPU*` section, so
the change lands only on them. A few reuse an existing stock section, because
`Add-ExtraGpuSupport.ps1` prefers a section already valid for that chip in the current driver over
a template captured from an older one. Measured on 616.86, editing those affects one extra device
ID, `DEV_24B6`, which shares `Section139` with a whitelisted RTX A3000 part and gains the App flag
with it. The script prints how many device lines reference every section it touches, so a future
release that shares sections more widely shows up rather than passing unnoticed.

None of this is confirmed through a real install. Verify on your own hardware before relying on it.

## When NVIDIA renames the INFs

`whitelist.json` is keyed by INF filename, `nv_dispi.inf` and `nvami.inf`. Those names are not
stable across releases, and they have now moved in two different ways:

| Release | Main INF | ASUS OEM INF | How it moved |
|---|---|---|---|
| baseline | `nv_dispi.inf` | `nvami.inf` | — |
| 616.86 desktop-notebook hotfix | `nv_dispig.inf` | `nvamig.inf` | `g` **appended** to every stem |
| 616.92 Studio (`nsd-dch`) | `nv_dispsi.inf` | `nvamsi.inf` | trailing letter **replaced** by `si` |

Looking those names up literally failed in the worst possible way on 616.86. The whitelist step
skipped both target INFs and applied nothing, while the RM-override step carried on normally
because it globs `*.inf` and never cared about names. The result was a package that unpacked,
patched, signed and installed cleanly, and delivered **no GPU unlock at all**.

Matching `<stem>*.inf` fixed that case but assumed renames only ever *append*. 616.92 inserts a
letter before the trailing one, so `nv_dispsi.inf` does not begin with `nv_dispi` and the glob
matched nothing again — this time taking the prune step's safety net down with it, see
[below](#pruning-must-never-delete-every-inf).

Both the patcher and the verification gate resolve each whitelist key through one shared helper,
which now tries three tiers, widest last:

1. An exact filename match.
2. `<stem>*.inf` — the appended-suffix case.
3. `<stem minus its last character>*.inf` — the replaced-letter case, requiring a core of at least
   four characters so a short stem can never widen to something like `n*.inf`.

A release using the ordinary names never reaches tier 2 or 3. On 616.92, tier 3 resolves
`nv_disp*.inf` → `nv_dispsi.inf` and `nvam*.inf` → `nvamsi.inf`, both unambiguously — note that
`nvam*` does not catch `nvmdsi.inf`, `nvmisi.inf` or `nvmosi.inf`, which start `nvm`. The
substitution is reported rather than silent:

```
NOTE: this release has no nv_dispi.inf; it ships nv_dispig.inf instead - patching that.
```

and the gate labels it too, so a passing run still shows which file stood in:

```
nv_dispig.inf    58/58 whitelisted, 2 device block(s), 235 spliced section(s) (this release's name for nv_dispi.inf)
```

Both sides must use the same helper. If only the patcher followed a rename, the gate would then
reject a package that had in fact been patched correctly.

If a future release renames an INF beyond a shared core, all three tiers miss and the patcher
throws rather than silently doing nothing, with an error saying `whitelist.json` needs updating.

### Pruning must never delete every INF

`Remove-ForeignOemInfs.ps1` resolves whitelist INFs through that same helper, including in its
"never prune to nothing" fallback. So on 616.92 the fallback could not save the run: the strict
rule matched nothing, the fallback matched nothing either, and the step deleted **all 45** display
INFs, signing off with `Manifest and disk agree: 0 INF(s) each` before the whitelist step threw.
What it left behind was a 3.6 GB package containing no INF at all.

The guard only checked whether the keep set was empty *before* the fallback ran, so it failed
open. It now re-asserts afterwards and throws instead of pruning to nothing:

```
Refusing to prune: that would delete all 45 display INF(s) and leave an unusable package. Even
the keep-everything fallback matched nothing, which means the INF names in whitelist.json
(nv_dispi.inf, nvami.inf) do not resolve against this release. Re-run without
-PruneForeignOemInfs, or update whitelist.json to this release's INF names.
```

Deleting 100% of the display INFs is never a correct outcome, so this holds regardless of what
caused the keep set to come out empty — a naming change, odd hardware detection, or a future bug.

This is deliberately **not** a "notebook builds use `g`" rule. The 581.94 desktop-notebook hotfix
uses the ordinary names, so the suffix is a per-build quirk rather than a flavour convention, and
hardcoding it would only fail differently next time. If a future release renames an INF beyond a
shared stem, the patcher still throws rather than silently doing nothing, and the error says that
`whitelist.json` needs updating.

## Signing without a password

`New-SelfSignedCertificate` puts the private key in `Cert:\CurrentUser\My`, not just in the
exported `.pfx`. `signtool` can use a key straight from that store, selected by thumbprint, so on
the machine that generated the certificate **there is no password to type and no `.pfx` to
unlock** — not on the first run, and not on any later driver release:

```powershell
signtool sign /sha1 <thumbprint> /fd SHA256 nv_disp.cat
```

That is what the pipeline now does by default. It works out the thumbprint on its own by reading
the **public** `Certificates\DriverPatchSigning.cer`, which needs no password, and then checking
whether the matching private key is in your store. The `.pfx` is therefore only a portable backup,
needed when signing on a *different* machine.

There is a real security reason to prefer this and not only a convenience one. `signtool` has no
way to read a `.pfx` password from stdin, so the `/f` + `/p` form has to put the password on a
child process's command line, where any process listing can read it. Signing from the store means
no password exists anywhere in the run.

**On a machine that has only the `.pfx`**, import it once and that machine becomes passwordless
too:

```powershell
Import-PfxCertificate -FilePath "Certificates\DriverPatchSigning.pfx" -CertStoreLocation Cert:\CurrentUser\My
```

Until you do, pass `-PfxPath` and supply its password; the script warns that the password will be
briefly visible on signtool's command line.

**Timestamping is best-effort.** A timestamp is attempted first, and if the timestamp server is
unreachable the catalog is still signed, with a warning, instead of failing the whole run. Pass
`-SkipTimestamp` to skip the attempt entirely and sign fully offline. The only thing an
un-timestamped signature loses is validity past the signing certificate's own expiry, which for a
local 10-year test-signing certificate is not a practical concern.

## Why VRAM size / compute needs a second fix

Symptom: driver installs fine on a whitelisted GPU, device shows up in Device Manager, but VRAM
size is wrong and compute (CUDA/NVENC/OptiX/etc.) doesn't work. Found by diffing stock against a
hand-patched package at the *AddReg section body* level rather than only at the device-ID
whitelist level - device-ID diffing alone completely misses it. Alongside the whitelist entries,
the hand-patched reference adds one registry value, `HKR,,RM1457588,%REG_DWORD%,1`, to a handful
of `nv_miscBase_addreg__NN` AddReg sections per INF.

NVIDIA's driver does a **second, internal Resource-Manager-level hardware check**, separate from
and deeper than the INF's PCI device/subsystem ID whitelist. A device can pass the INF-level
check - so the driver installs, the device enumerates fine - and still fail this internal check,
which is what causes the VRAM/compute symptoms. `RM1457588` reads as a validation-bypass style
override for exactly this internal check.

**NVIDIA ships this same override themselves**, which is the strongest evidence that it is the
intended mechanism rather than a lucky guess. In the stock 595.79 package, `nvmsoai.inf` (an MSI
OEM INF) contains `HKR,,RM1457588,%REG_DWORD%,1` in **both** of its two `nv_miscBase_addreg__NN`
sections. It is the only stock INF that carries it, and the key name also appears inside
`nvlddmkm.sys` and the `gsp_*.bin` GSP firmware images, confirming the driver really does read it.
So NVIDIA's own use of it is precisely the case this project needs: an OEM-specific INF enabling
full capability on hardware the generic desktop INF would otherwise restrict. Applying it to every
`nv_miscBase_addreg__*` section matches what NVIDIA does in that INF, at the same granularity.

(An earlier version of this README claimed stock INFs never contain the key anywhere. That was
wrong, and the truth is more useful.)

This also explains the "install the hand-patched driver first, then install ours over it, and it
works" workaround: that installer writes this registry value once, under the device's own driver
key, during its first install. A driver *update* over an already-installed device does not
necessarily clear per-device registry values that the new INF doesn't mention, so the override
silently survives from that earlier install even though this package's own INF never wrote it. A
**clean** install has no such leftover value, so the internal check stays in effect and the
symptoms show up.

The hand-patched reference only touches the specific `nv_miscBase_addreg__NN` sections referenced
by the specific device Sections its author patched - whichever hardware they personally had to
test with. `Add-RmCapabilityOverride.ps1` instead adds the override to **every**
`nv_miscBase_addreg__*` section in **every** driver INF, rather than trying to resolve which
specific sections each of the 61 `whitelist.json` entries' target Section references (fragile
across the same kind of INF section renumbering `Add-ExtraGpuSupport.ps1` already has to work
around between driver versions). This key has no observed effect on hardware that already passes
the internal check on its own, so applying it broadly is the safer and more complete fix -
verified structurally: after patching, every `nv_miscBase_addreg__*` section in every INF (1400
sections across 39 files in the 595.79 package) has the override, with no duplicate/corrupted
section headers.

## Trusting the certificate

Signing the catalog is not enough by itself — Windows only trusts kernel driver signatures that
chain to a **Microsoft-anchored** certificate (WHQL, or an EV cert cross-signed via the Hardware
Dev Center) *unless the machine is in Test Signing Mode*, in which case it accepts any cert that
you've explicitly trusted locally. There are three ways to get there:

**1. `Scripts\Approve-DriverPatchCert.ps1`** (recommended), run yourself from an elevated prompt,
separately from the installer:

```powershell
.\Scripts\Approve-DriverPatchCert.ps1
```

Prints exactly what it's about to trust and asks for confirmation before running `certutil`. This
is the path to prefer because you watch it happen and it is the one actually verified end to end.

**2. Manually**, if you'd rather see the raw commands:

```powershell
certutil -addstore Root             "Certificates\DriverPatchSigning.cer"
certutil -addstore TrustedPublisher "Certificates\DriverPatchSigning.cer"
```

`Root` is what makes a self-signed signature chain at all, and is the only one strictly required.
`TrustedPublisher` stops Windows asking "Would you like to install this device software?" during
the install. Note there is deliberately **no `CA` entry**: a self-signed certificate is its own
root, so there is no intermediate to chain through, and an earlier version of this project wrote a
`CA` copy that added a second trusted-authority entry for no benefit.

**3. The installer checkbox** — *not fully verified, see below*. `Custom Installation Options` in
`setup.exe` shows a **"Chameleon GPU cert."** row alongside Graphics/Audio Driver,
**ticked by default** since v2. Leave it ticked and `setup.exe` runs `certutil -addstore` itself,
elevated, before installing the driver. Leave it unchecked and nothing about your trust settings
changes. This is genuinely opt-in: the row renders with correct title, description, and version
columns. It is `disposition="default"`, so it starts ticked but stays user-selectable, unlike Graphics/Audio Driver which
default to checked (`disposition="default"`/`"critical"`).

What has been confirmed is that the row *renders* correctly with the intended disposition. What has
**not** been confirmed is the checked-through-a-full-install case: that `certutil` fires cleanly
under the installer's elevated context and the driver then installs without further prompts. Until
you've verified that yourself, prefer option 1. You can check whether it worked with:

```powershell
certutil -store Root <thumbprint>
```

Whichever path, you *also* need one of:

```powershell
# Turn on Windows Test Signing mode (requires Secure Boot disabled in firmware, and a reboot)
bcdedit /set testsigning on
```

Test Mode weakens driver signature enforcement globally and requires Secure Boot off — turn it
back off (`bcdedit /set testsigning off`) when you're done experimenting. **Alternative:** Windows
also lets you disable driver signature enforcement for a single boot (Shift+Restart →
Troubleshoot → Startup Settings → Disable driver signature enforcement) — no trust-store or BCD
changes, but has to be redone after every reboot.

## Renaming the certificate

The name Windows shows for your signing certificate is its subject, set when the certificate is
created. `New-DriverSigningCert.ps1` defaults to:

```
CN=Chameleon Project - Customised driver for Nvidia GPU
```

That name appears in the Windows certificate manager, in `signtool` output, and as the publisher
on the "Would you like to install this device software?" prompt. Override it with `-Subject`.

**A subject cannot be edited after the fact.** It is bound into the signed certificate structure,
so changing the default renames nothing that already exists. To actually carry a new name you have
to create a new certificate, and that has knock-on costs:

- It gets a **new thumbprint**, so it is a different identity as far as Windows is concerned.
- It is **not trusted**, so `Approve-DriverPatchCert.ps1` has to be run again from an elevated
  prompt before anything signed with it will install.
- Packages you signed earlier still carry the **old** certificate. They keep working only while
  that old certificate stays trusted. Re-sign them, or keep both trusted, or accept that the older
  packages become uninstallable.
- Since the non-exportable change, a new certificate has **no `.pfx` backup** unless you ask for
  one with `-Exportable`.

So renaming is worth doing when you are about to mint a certificate anyway, and rarely worth doing
on its own. Nothing forces you to switch: the existing certificate signs future driver releases
perfectly well under its old name.

If you do rename, remember that `Remove-DriverPatchCert.ps1` finds certificates by subject
pattern. Its defaults already cover the current name plus the two legacy names this project has
signed under (see `-SubjectPattern` in that script). Add to that list rather than replacing it,
or a renamed certificate becomes invisible to the tool meant to clean it up and quietly
accumulates as an untracked trusted root.

## Cleaning up trusted certificates

Trusting a certificate is not a one-off cost you pay and forget: each trusted entry is a
self-signed authority your machine will accept code from, kernel drivers included, until you take
it back out. Because every `New-DriverSigningCert.ps1` run used to mint a *new* certificate and
nothing ever removed one, repeated use accumulates them. Check what you have:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1
```

That is read-only. It lists every patch certificate, when it expires, and which stores it sits in.
To prune everything except the one you still sign with:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1 -AllPatchCerts -KeepThumbprint <the one you use>
```

Removing trust from a certificate means catalogs it signed stop validating, so a patched package
signed with it can no longer be installed. An already-installed driver keeps running. Work out
which certificate signed which package before pruning:

```powershell
Get-AuthenticodeSignature "<pkg>\Display.Driver\nv_disp.cat" | Select-Object -ExpandProperty SignerCertificate
```

**One gotcha worth knowing.** A `CurrentUser` trust store is a *merged view*: it shows that user's
own entries plus everything inherited from the matching `LocalMachine` store. An inherited entry
cannot be deleted through the user view — the attempt fails with access-denied even in an elevated
session — it has to be removed from `LocalMachine`. So a certificate listed under
`CurrentUser\Root` is not necessarily removable there. `Remove-DriverPatchCert.ps1` detects this,
skips those entries rather than failing confusingly, and prints the elevated command to finish the
job:

```powershell
.\Scripts\Remove-DriverPatchCert.ps1 -Scope LocalMachine -Thumbprint <thumb1>,<thumb2>
```

Add `-IncludePrivateKeys` to also drop leftover cert+key pairs from `Cert:\CurrentUser\My`. Those
are clutter rather than exposure once their trust entries are gone, and removing a non-exportable
key is irreversible, so it is deliberately opt-in.

## Installing the patched driver

```powershell
pnputil /add-driver "<name>_Patched\Display.Driver\nv_dispi.inf" /install
```

or run `setup.exe` from the patched package root for the full NVIDIA App installer flow.

Only install this on a laptop/desktop whose GPU is actually one of the newly-whitelisted device
IDs in `whitelist.json` — installing it elsewhere just gives you an INF with extra entries that
don't match your hardware, no effect either way.

## Safety notes

- This adds device/subsystem whitelist entries and one registry override value; it does not
  modify the actual GPU driver binaries (`nvlddmkm.sys`, etc.), so it can't functionally do
  anything to hardware NVIDIA's driver doesn't already technically support at the code level — it
  just removes an INF-level gate and an internal validation-check gate, both already present and
  already reachable in the shipped driver binary.
- Applies only to your own hardware; nothing here is transmitted anywhere or affects other
  machines.
- The signing key is created **non-exportable** and never leaves `Cert:\CurrentUser\My`, so by
  default there is no private-key file to leak. If you opt into one with `-Exportable`, keep
  `Certificates\DriverPatchSigning.pfx` private — anyone with it could sign other kernel drivers
  that your machine (once you've trusted the cert) would accept.
- Trusting the certificate is the part with real blast radius, not the patching. Prune what you no
  longer need — see [Cleaning up trusted certificates](#cleaning-up-trusted-certificates) — and
  turn Test Signing mode back off when you're done.
