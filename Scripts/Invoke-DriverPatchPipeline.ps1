<#
.SYNOPSIS
  All-in-one: unpack -> patch device/subsystem whitelist -> generate/reuse signing cert ->
  rebuild and sign the catalog -> add an opt-in cert-trust option to the installer, for a
  downloaded NVIDIA driver installer .exe (or an already-unpacked package folder).

.DESCRIPTION
  Point this at either a downloaded driver .exe (-SourceExePath) or an already-unpacked package
  folder (-SourcePackagePath) and it runs the whole pipeline:

    1. Unpacks the .exe (Unpack-DriverExe.ps1) or copies the folder - never touches the source.
    1a. With -PruneForeignOemInfs, drops the OEM display INFs that cannot match this machine
        first, so every later step has far less to do. Optional and off by default, because the
        result is no longer portable to other vendors' laptops.
    2. Runs Add-ExtraGpuSupport.ps1 against the copy's Display.Driver folder.
    3. Runs Add-RmCapabilityOverride.ps1, which adds the RM1457588 registry override needed for
       whitelisted GPUs to report correct VRAM size and have working compute (CUDA/NVENC/OptiX) -
       the INF whitelist alone only gets the driver to install, not to fully work. See that
       script's own header comment for the full root-cause writeup.
    4. Runs Enable-OptionalComponents.ps1, so PhysX and the NVIDIA App are offered for the
       unlocked GPUs too. Both are gated on per-device INF feature flags that NVIDIA sets
       unevenly, and because the gating constraints are level="silent" a missing flag makes the
       component disappear from the installer without a word. Also makes the NVIDIA App a row the
       user can untick rather than a locked one. Skip with -SkipOptionalComponents.
    5. Verifies the patches ACTUALLY APPLIED (Test-DriverPatch.ps1) and refuses to go any
       further if they didn't. Inf2Cat will happily build a catalog out of unpatched INFs and
       signtool will happily sign it, so without this a package whose patch step silently found
       nothing to do comes out looking finished and simply has no unlock. Skip with
       -SkipPatchVerification.
    6. Works out which certificate to sign with. If the private key is already in
       Cert:\CurrentUser\My - which is where New-SelfSignedCertificate puts it, so this is the
       normal case on the machine that made the cert - signing is PASSWORDLESS and nothing is
       prompted. Otherwise it falls back to a .pfx + password, or generates a fresh cert
       (New-DriverSigningCert.ps1) in the "Certificates" folder next to "Scripts".
    7. Runs Sign-DriverPackage.ps1 to rebuild nv_disp.cat and Authenticode-sign it. Timestamping
       is best-effort: if the timestamp server is unreachable the catalog is still signed, with a
       warning, instead of failing the run.
    8. Runs Add-SetupCertOption.ps1, which adds a "Chameleon GPU cert." component
       to the Custom Installation Options screen - defaults to CHECKED, and only trusts the
       certificate (via certutil, wired to run before Display.Driver) if the person running the
       installer leaves it checked. Skip with -SkipSetupCertOption if you'd rather keep using
       Approve-DriverPatchCert.ps1 standalone instead.

  The result is always a plain folder (install via pnputil or by running its setup.exe) - this
  does not repack into a single .exe.

  What this still does NOT do: touch any Windows trust store directly, or enable Test Signing
  mode. Those only happen if the person running setup.exe opts in on the installer checkbox from
  step 8, or via Approve-DriverPatchCert.ps1 run separately.

.PARAMETER PruneForeignOemInfs
  Delete the OEM display INFs that cannot match this machine before doing anything else. A stock
  package ships 43; only the generic desktop INF and whatever matches your actual GPU can ever
  apply. Inf2Cat's cost is superlinear in INF count, so this is the only thing that meaningfully
  shortens a run: measured on 616.86, the catalog rebuild went from about 3000 s to 399 s.

  The resulting package is specific to the hardware in this machine and is NOT portable to other
  vendors' laptops, which is why it is opt-in. See Remove-ForeignOemInfs.ps1.

  Because the result is specific to THIS machine, this switch also requires that one of this
  machine's GPUs is a GPU whitelist.json unlocks. If none is, the run stops in preflight before
  anything is unpacked - see -AllowUnsupportedGpu. A universal build has no such requirement.

.PARAMETER AllowUnsupportedGpu
  Go ahead with -PruneForeignOemInfs even though no GPU in this machine is one whitelist.json
  unlocks. Only meaningful together with -PruneForeignOemInfs, and only worth passing if you know
  what you are getting: a package cut down to this machine, carrying whitelist entries this
  machine cannot match, re-signed with a certificate Windows does not trust yet. For a package
  aimed at a DIFFERENT machine's locked GPU, build universal (drop -PruneForeignOemInfs) instead.

.PARAMETER CheckLocalGpuSupport
  Print whether this machine's GPU is one whitelist.json unlocks and stop, without touching
  anything. First line is SUPPORTED, UNSUPPORTED or UNKNOWN (nothing detectable to judge),
  followed by human-readable detail. Used by the GUI so the rule lives in exactly one place.

.PARAMETER KeepInf
  Extra INFs to protect from -PruneForeignOemInfs, by filename or bare stem.

.PARAMETER SkipOptionalComponents
  Don't touch the PhysX / NVIDIA App feature flags, and leave setup.cfg's NvApp row locked. The
  installer then offers those components only where NVIDIA's own per-GPU flags allow it.

.PARAMETER SourceExePath
  Path to a downloaded NVIDIA driver installer .exe (a self-extracting 7z archive). Mutually
  exclusive with -SourcePackagePath.

.PARAMETER SourcePackagePath
  Root of an ALREADY-UNPACKED stock NVIDIA driver package (must contain setup.exe, setup.cfg,
  and a Display.Driver subfolder). Mutually exclusive with -SourceExePath.

.PARAMETER OutputPath
  Where to place the patched+signed copy/extraction. Defaults to "<source>_Patched" next to the
  source. Must not already exist (re-run against a fresh path rather than overwriting a prior
  attempt).

.PARAMETER CertThumbprint
  Sign with this certificate from Cert:\CurrentUser\My. Passwordless, and the preferred way to
  reuse an already-trusted certificate across driver releases. If omitted, the pipeline still
  tries to find the key in the store on its own (via the public .cer next to the .pfx), so you
  normally don't need to pass anything at all.

.PARAMETER PfxPath
  Fallback for a machine that has the .pfx but not its key in the certificate store. Reuse an
  existing signing certificate instead of generating a new one - e.g. one you already trusted on
  this machine, so this run's signature validates without repeating the trust step. If omitted,
  reuses "..\Certificates\DriverPatchSigning.pfx" (relative to this script) if present, else
  generates a new cert there (creating the Certificates folder if it doesn't exist yet).
  Importing the .pfx into Cert:\CurrentUser\My once removes the password from all future runs.

.PARAMETER SkipPatchVerification
  Skip the pre-signing check that the patches actually applied. Only do this if you know why you
  need to - it exists to stop a silently-unpatched package from being signed and shipped as
  finished. Test-DriverPatch.ps1 -ReportOnly inspects without failing if you just want a look.

.PARAMETER SkipTimestamp
  Don't contact the timestamp server at all. Makes signing fully offline-capable.

.PARAMETER NonInteractive
  Never prompt. If a password would be needed and none was supplied, fail with a clear message
  instead of blocking on Read-Host, which cannot be answered when there is no attached console.
  The GUI wrapper passes this.

.PARAMETER WhitelistPath
  Defaults to whitelist.json next to this script.

.PARAMETER SkipSetupCertOption
  Skip the installer-checkbox step. The signed package still works via pnputil /
  Approve-DriverPatchCert.ps1 as before.

.EXAMPLE
  .\Invoke-DriverPatchPipeline.ps1 -SourceExePath "D:\Downloads\610.88-desktop-win10-win11-64bit-international-dch-whql.exe"

.EXAMPLE
  .\Invoke-DriverPatchPipeline.ps1 -SourcePackagePath "D:\NVIDIA\610.xx-desktop-win10-win11-64bit-international-dch-whql"
#>
[CmdletBinding()]
param(
    [string]$SourceExePath,
    [string]$SourcePackagePath,

    [string]$OutputPath,

    [string]$WhitelistPath,

    [string]$CertThumbprint,

    [string]$PfxPath,
    [securestring]$PfxPassword,

    [switch]$SkipSetupCertOption,

    [switch]$PruneForeignOemInfs,

    [switch]$AllowUnsupportedGpu,

    # Print the output path this run would use and stop, without touching anything. Used by the
    # GUI so the folder-naming rule lives in exactly one place.
    [switch]$ShowOutputPath,

    # Print this machine's whitelist-coverage verdict and stop. Same reasoning as
    # -ShowOutputPath: the GUI asks rather than reimplementing the rule in C#.
    [switch]$CheckLocalGpuSupport,

    [string[]]$KeepInf = @(),

    [switch]$SkipOptionalComponents,

    [switch]$SkipPatchVerification,

    [switch]$SkipTimestamp,

    [switch]$NonInteractive,

    [string]$SignToolPath,
    [string]$Inf2CatPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

# $PSScriptRoot is unreliable inside a param() default value under Windows PowerShell when the
# script is launched as a fresh process (powershell.exe -File ..., e.g. from the GUI wrapper) -
# confirmed: it's empty there even though it's already reliably set by this point in the script
# body. Resolving the default here instead is the standard workaround.
if (-not $WhitelistPath) {
    $WhitelistPath = Join-Path $PSScriptRoot "whitelist.json"
}

# Non-interactive callers (e.g. the GUI wrapper) can supply the password via this environment
# variable instead of the Read-Host prompt below - Read-Host doesn't reliably read from a
# redirected stdin pipe when there's no real attached console, so an env var is what a calling
# process actually uses. Interactive use (running this script directly) is unaffected: the
# prompt below only fires when this isn't set.
#
# This is now only consulted on the .pfx FALLBACK path. When the signing key is in
# Cert:\CurrentUser\My (the normal case) no password is involved at any point, and the GUI does
# not set this variable at all.
if (-not $PfxPassword -and $env:DRIVER_PATCH_PFX_PASSWORD) {
    $PfxPassword = ConvertTo-SecureString $env:DRIVER_PATCH_PFX_PASSWORD -AsPlainText -Force
}

# --- Is this machine's GPU one this toolkit unlocks? -------------------------------------------
# Only a PRUNED build depends on the answer, because only a pruned build is cut down to the INFs
# that can match this machine. On a machine whose GPU the stock driver already supports there is
# then nothing left for the unlock to unlock, and the run produces a re-signed copy of a driver
# that worked to begin with. A universal build is unaffected: it keeps everything, every whitelist
# entry lands in it, and building it on a machine with a fully supported GPU is the normal way to
# make a package for someone else's locked one.
function Get-LocalGpuSupportReport {
    param([string]$Path)
    $report = Test-WhitelistCoversLocalGpu -WhitelistPath $Path
    $lines = New-Object System.Collections.Generic.List[string]
    if (-not $report.Detected) {
        $lines.Add("No NVIDIA display GPU could be read from this machine, so there is nothing to check against.")
    }
    foreach ($c in $report.Covered)   { $lines.Add("  $($c.Gpu.Label) - unlocked by whitelist.json entry $($c.Entry)") }
    foreach ($u in $report.Uncovered) { $lines.Add("  $($u.Label) - not in whitelist.json") }
    return [PSCustomObject]@{
        Verdict = $(if (-not $report.Detected) { 'UNKNOWN' } elseif ($report.AnyCovered) { 'SUPPORTED' } else { 'UNSUPPORTED' })
        Detail  = $lines
        Report  = $report
    }
}

if ($CheckLocalGpuSupport) {
    $support = Get-LocalGpuSupportReport -Path $WhitelistPath
    Write-Output $support.Verdict
    foreach ($l in $support.Detail) { Write-Output $l }
    return
}

if ([bool]$SourceExePath -eq [bool]$SourcePackagePath) {
    throw @"
Pass exactly one of -SourceExePath or -SourcePackagePath, not both/neither.

Examples:
  .\Invoke-DriverPatchPipeline.ps1 -SourceExePath "C:\Downloads\610.88-desktop-...-whql.exe"
  .\Invoke-DriverPatchPipeline.ps1 -SourcePackagePath "C:\NVIDIA\610.88-desktop-...-whql"
"@
}

function Test-DriverPackageRoot {
    param([string]$Path)
    (Test-Path (Join-Path $Path "setup.exe")) -and
    (Test-Path (Join-Path $Path "setup.cfg")) -and
    (Test-Path (Join-Path $Path "Display.Driver"))
}

# A universal build stays "<source>_Patched", exactly as before, which also keeps every folder
# made before pruning existed correctly labelled. A pruned build gets the GPU it was built for
# appended, because that package installs on nothing else and the folder name is the only thing
# telling two of them apart later.
$outputSuffix = "_Patched"
if ($PruneForeignOemInfs) { $outputSuffix = "_Patched_" + (Get-LocalGpuTag) }

$usingExe = [bool]$SourceExePath
if ($usingExe) {
    $SourceExePath = (Resolve-Path $SourceExePath).Path
    if (-not $OutputPath) {
        $parent = Split-Path $SourceExePath -Parent
        $leaf = [System.IO.Path]::GetFileNameWithoutExtension($SourceExePath)
        $OutputPath = Join-Path $parent ($leaf + $outputSuffix)
    }
}
else {
    $SourcePackagePath = (Resolve-Path $SourcePackagePath).Path
    if (-not (Test-DriverPackageRoot $SourcePackagePath)) {
        throw "`"$SourcePackagePath`" doesn't look like an unpacked driver package root (expected setup.exe, setup.cfg, and a Display.Driver folder)."
    }
    if (-not $OutputPath) {
        $parent = Split-Path $SourcePackagePath -Parent
        $leaf = Split-Path $SourcePackagePath -Leaf
        $OutputPath = Join-Path $parent ($leaf + $outputSuffix)
    }
}

# The GUI needs the same answer before it starts, for its overwrite check and to launch setup.exe
# afterwards. Rather than reimplementing the naming rule in C# and letting the two drift, it asks
# here and uses whatever comes back.
if ($ShowOutputPath) {
    Write-Output $OutputPath
    return
}

if (Test-Path $OutputPath) {
    throw "Output path already exists: $OutputPath`nRemove it or pass a different -OutputPath - this script never overwrites a previous run."
}

# --- Gate: a pruned build needs a GPU worth pruning for ----------------------------------------
# Deliberately placed before the tool/certificate preflight and therefore before the multi-GB
# unpack, and deliberately AFTER the -ShowOutputPath return so the GUI can still ask for the
# folder name on a machine that fails this.
#
# Only Detected-and-nothing-covered stops the run. UNKNOWN does not: if no GPU can be read there
# is nothing to judge, Remove-ForeignOemInfs.ps1 already backs off to keeping every whitelist INF
# in that case, and a detection quirk must not be what refuses a run.
if ($PruneForeignOemInfs) {
    $support = Get-LocalGpuSupportReport -Path $WhitelistPath
    $detail = ($support.Detail -join "`n")

    if ($support.Verdict -eq 'UNSUPPORTED' -and -not $AllowUnsupportedGpu) {
        throw @"
Nothing to unlock on this machine, and a for-this-PC-only build was requested.

$detail

"Build for this PC only" (-PruneForeignOemInfs) throws away every display INF that cannot match
this machine. None of the $($support.Report.EntryCount) whitelist entries can match it either, so what would come out is
NVIDIA's own driver for a GPU it already supports, re-signed with a certificate Windows does not
trust until you either tick the installer's cert box or turn on Test Signing mode. That is all
cost and no unlock, so the run stops here instead of spending an hour proving it.

What you probably want instead:
  - Untick "Build for this PC only" in the GUI, or drop -PruneForeignOemInfs on the command line.
    A universal build keeps all $($support.Report.EntryCount) whitelist entries and installs on the machine that has the
    locked GPU - building it here is the normal way to make a package for a different PC.
  - Pass -AllowUnsupportedGpu if you want the pruned build anyway and know why.
"@
    }

    if ($support.Verdict -eq 'UNSUPPORTED') {
        Write-Warning "No GPU in this machine is one whitelist.json unlocks - continuing only because -AllowUnsupportedGpu was passed. This package will unlock nothing here."
        Write-Host $detail -ForegroundColor DarkGray
    }
    elseif ($support.Verdict -eq 'UNKNOWN') {
        Write-Warning "Could not read any NVIDIA display GPU from this machine, so a pruned build cannot be checked against it. Continuing; Remove-ForeignOemInfs.ps1 keeps every whitelist INF when it has no hardware to go on."
    }
    else {
        Write-Host "Pruned build target:" -ForegroundColor DarkGray
        Write-Host $detail -ForegroundColor DarkGray
    }
    Write-Host ""
}

# --- Preflight -------------------------------------------------------------------------------
# Resolve every external tool AND the signing identity before unpacking or copying anything.
# Both used to be discovered late, which meant a missing SDK or an unavailable signing key only
# surfaced after a multi-GB extraction/copy had already been paid for.
Write-Host "Preflight: checking tools and signing identity..." -ForegroundColor DarkGray

$tools = Assert-PatchTools -NeedSevenZip:$usingExe -Inf2CatPath $Inf2CatPath -SignToolPath $SignToolPath
if ($usingExe) { Write-Host "  7z:       $($tools.SevenZip)" -ForegroundColor DarkGray }
Write-Host "  Inf2Cat:  $($tools.Inf2Cat)" -ForegroundColor DarkGray
Write-Host "  signtool: $($tools.SignTool)" -ForegroundColor DarkGray

$certificatesDir = Join-Path (Split-Path $PSScriptRoot -Parent) "Certificates"
$defaultPfx = Join-Path $certificatesDir "DriverPatchSigning.pfx"
$defaultCer = Join-Path $certificatesDir "DriverPatchSigning.cer"

# Prefer a private key that is already in Cert:\CurrentUser\My. Reading a public .cer needs no
# password at all, so when the key for that cert is in the store we can sign with
# `signtool /sha1` and never ask for anything - on this run or any future driver release.
$cerCandidates = @()
if ($PfxPath) { $cerCandidates += [System.IO.Path]::ChangeExtension($PfxPath, '.cer') }
$cerCandidates += $defaultCer

$signingCert = Resolve-SigningCertificate -Thumbprint $CertThumbprint -CerPathCandidates $cerCandidates
$generateNewCert = $false

if ($signingCert) {
    Write-Host "  cert:     $($signingCert.Thumbprint) (from certificate store - no password needed)" -ForegroundColor Green
}
else {
    if (-not $PfxPath -and (Test-Path $defaultPfx)) { $PfxPath = $defaultPfx }

    if ($PfxPath) {
        if (-not (Test-Path $PfxPath)) { throw "Pfx not found: $PfxPath" }
        Write-Host "  cert:     $PfxPath (private key not in this machine's store, so its password is required)" -ForegroundColor Yellow
        if (-not $PfxPassword) {
            if ($NonInteractive) {
                throw @"
The signing certificate's private key is not in Cert:\CurrentUser\My, so the .pfx password is
required - but none was supplied and prompting is disabled.

Fix it once and every future run becomes passwordless:
  Import-PfxCertificate -FilePath "$PfxPath" -CertStoreLocation Cert:\CurrentUser\My
"@
            }
            $PfxPassword = Read-Host -AsSecureString -Prompt "Password for $PfxPath"
        }
        # Fail now, not after the copy, if the password is wrong. EphemeralKeySet avoids
        # persisting the key into the user's on-disk key container just to validate it.
        try {
            $probe = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
                $PfxPath, $PfxPassword,
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
            $probe.Dispose()
        }
        catch {
            throw "Could not open $PfxPath with the supplied password - check the password and try again. ($($_.Exception.Message))"
        }
    }
    else {
        # Nothing to validate and nothing to ask for: the new certificate's key is created
        # non-exportable and stays in Cert:\CurrentUser\My, so there is no .pfx and therefore no
        # password involved even on a first-ever run.
        $generateNewCert = $true
        Write-Host "  cert:     none found - a new one will be generated in $certificatesDir (no password needed)" -ForegroundColor Yellow
    }
}
Write-Host ""

$totalSteps = 5   # copy/unpack, whitelist, RM override, certificate, sign
if ($PruneForeignOemInfs)         { $totalSteps++ }
if (-not $SkipOptionalComponents) { $totalSteps++ }
if (-not $SkipPatchVerification)  { $totalSteps++ }
if (-not $SkipSetupCertOption)    { $totalSteps++ }
$stepNum = 0
function Step-Banner {
    param([string]$Text)
    $script:stepNum++
    Write-Host "`n=== ${script:stepNum}/${totalSteps}: $Text ===" -ForegroundColor Magenta
}

if ($usingExe) {
    Step-Banner "Unpacking installer"
    & (Join-Path $PSScriptRoot "Unpack-DriverExe.ps1") -ExePath $SourceExePath -OutputPath $OutputPath
}
else {
    Step-Banner "Copying package"
    Write-Host "  $SourcePackagePath"
    Write-Host "  -> $OutputPath"
    Copy-Item -Path $SourcePackagePath -Destination $OutputPath -Recurse
    Get-ChildItem -Path $OutputPath -Filter ".claude" -Directory -Recurse -ErrorAction SilentlyContinue |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

if ($PruneForeignOemInfs) {
    # Runs FIRST, before any patching, so every later step has fewer INFs to walk: the whitelist
    # patch, the RM override, the verification gate and above all the catalog rebuild. Measured on
    # 616.86, pruning 43 INFs down to 2 took the rebuild from ~3000 s to 399 s.
    Step-Banner "Pruning OEM INFs that cannot match this machine"
    & (Join-Path $PSScriptRoot "Remove-ForeignOemInfs.ps1") `
        -PackageRoot $OutputPath `
        -WhitelistPath $WhitelistPath `
        -KeepInf $KeepInf
}

Step-Banner "Patching device/subsystem whitelist"
& (Join-Path $PSScriptRoot "Add-ExtraGpuSupport.ps1") `
    -DisplayDriverPath (Join-Path $OutputPath "Display.Driver") `
    -WhitelistPath $WhitelistPath

Step-Banner "Adding RM capability override (VRAM size / compute fix)"
& (Join-Path $PSScriptRoot "Add-RmCapabilityOverride.ps1") `
    -DisplayDriverPath (Join-Path $OutputPath "Display.Driver")

if (-not $SkipOptionalComponents) {
    # Make PhysX and the NVIDIA App behave for the unlocked GPUs the way they do for the ones
    # NVIDIA supports out of the box. Both are gated on per-device INF feature flags that NVIDIA
    # sets unevenly, and a missing flag makes the component vanish from the installer with no
    # message. Runs before the gate so the catalog is built from fully-final INFs.
    Step-Banner "Enabling PhysX / NVIDIA App for the unlocked GPUs"
    & (Join-Path $PSScriptRoot "Enable-OptionalComponents.ps1") `
        -PackageRoot $OutputPath `
        -WhitelistPath $WhitelistPath
}

if (-not $SkipPatchVerification) {
    # The gate. Signing is the point of no return for a mistake: Inf2Cat will build a catalog
    # from unpatched INFs and signtool will sign it, producing a package that looks finished and
    # has no working unlock. This re-reads the INFs and refuses to go on unless the patches are
    # actually there.
    Step-Banner "Verifying the patch actually applied"
    & (Join-Path $PSScriptRoot "Test-DriverPatch.ps1") `
        -DisplayDriverPath (Join-Path $OutputPath "Display.Driver") `
        -WhitelistPath $WhitelistPath
}

Step-Banner "Signing certificate"
if ($signingCert) {
    Write-Host "  Reusing the certificate already in this machine's store - no password needed."
    Write-Host "    Subject:    $($signingCert.Subject)"
    Write-Host "    Thumbprint: $($signingCert.Thumbprint)"
    Write-Host "    Expires:    $($signingCert.NotAfter)"
    Write-Host "  (remove it from Cert:\CurrentUser\My, or pass -CertThumbprint, to use a different one)" -ForegroundColor DarkGray
}
elseif ($generateNewCert) {
    Write-Host "  No certificate found - generating a new one in $certificatesDir"
    if (-not (Test-Path $certificatesDir)) {
        New-Item -ItemType Directory -Path $certificatesDir -Force | Out-Null
    }
    # No password: the key is created non-exportable and stays in Cert:\CurrentUser\My, so there
    # is no .pfx to protect. Signing then reads the key from the store, on this run and every
    # later one.
    $newThumb = & (Join-Path $PSScriptRoot "New-DriverSigningCert.ps1") -OutputDir $certificatesDir
    $newThumb = ([string](@($newThumb) | Select-Object -Last 1)).Trim()
    if (-not $newThumb) { throw "New-DriverSigningCert.ps1 did not return a thumbprint - cannot continue." }
    $signingCert = Resolve-SigningCertificate -Thumbprint $newThumb
    Write-Host ""
    Write-Host "  NOTE: this new certificate is not trusted yet, so the driver will not load until" -ForegroundColor Yellow
    Write-Host "  you run Approve-DriverPatchCert.ps1 (elevated) and enable Test Signing mode." -ForegroundColor Yellow
}
else {
    Write-Host "  Using certificate file: $PfxPath"
    Write-Host "  One-time fix to make all future runs passwordless:" -ForegroundColor DarkGray
    Write-Host "    Import-PfxCertificate -FilePath `"$PfxPath`" -CertStoreLocation Cert:\CurrentUser\My" -ForegroundColor DarkGray
}

Step-Banner "Rebuilding + signing catalog"
$signArgs = @{
    DisplayDriverPath = (Join-Path $OutputPath "Display.Driver")
    Inf2CatPath       = $tools.Inf2Cat
    SignToolPath      = $tools.SignTool
    SkipTimestamp     = $SkipTimestamp
    NonInteractive    = $NonInteractive
}
if ($signingCert) {
    $signArgs['CertThumbprint'] = $signingCert.Thumbprint
}
else {
    $signArgs['PfxPath']     = $PfxPath
    $signArgs['PfxPassword'] = $PfxPassword
}
& (Join-Path $PSScriptRoot "Sign-DriverPackage.ps1") @signArgs

if (-not $SkipSetupCertOption) {
    Step-Banner "Adding opt-in cert-trust option to installer"
    # Add-SetupCertOption.ps1 needs the public .cer, not the .pfx - export it fresh from whatever
    # cert is actually in use rather than assuming a same-named .cer sits next to it. Exporting
    # the PUBLIC half of a store certificate needs no password at all; the .pfx branch below is
    # only reached when signing fell back to a certificate file.
    $disposeCertObj = $false
    if ($signingCert) {
        $certObj = $signingCert
    }
    else {
        $certObj = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            $PfxPath, $PfxPassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet)
        $disposeCertObj = $true
    }
    $tempCerPath = Join-Path ([System.IO.Path]::GetTempPath()) "GpuUnlockCert_$([guid]::NewGuid()).cer"
    [System.IO.File]::WriteAllBytes($tempCerPath, $certObj.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert))
    try {
        & (Join-Path $PSScriptRoot "Add-SetupCertOption.ps1") -PackageRoot $OutputPath -CerPath $tempCerPath
    }
    finally {
        Remove-Item $tempCerPath -ErrorAction SilentlyContinue
        if ($disposeCertObj) { $certObj.Dispose() }
    }
}

Write-Host "`n=== Done ===" -ForegroundColor Green
Write-Host "Patched, signed package ready at: $OutputPath"
Write-Host ""
if (-not $SkipSetupCertOption) {
    Write-Host "setup.exe's Custom Installation Options now includes a 'Chameleon GPU cert.'" -ForegroundColor Green
    Write-Host "box, ticked by default. Left ticked it trusts the cert before the driver installs;" -ForegroundColor Green
    Write-Host "untick it and the install makes no trust changes." -ForegroundColor Green
    Write-Host ""
    Write-Host "Still available if you'd rather not use the installer checkbox:" -ForegroundColor Yellow
    Write-Host "  .\Approve-DriverPatchCert.ps1"
}
else {
    Write-Host "Not done (deliberately - see README.md): trusting the certificate on this machine." -ForegroundColor Yellow
    Write-Host "That's a separate, explicit step:" -ForegroundColor Yellow
    Write-Host "  .\Approve-DriverPatchCert.ps1"
}
Write-Host "Then install via pnputil, or run $OutputPath\setup.exe."
