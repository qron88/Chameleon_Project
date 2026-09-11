<#
.SYNOPSIS
  Adds an opt-in "Chameleon GPU cert." component to a driver package's Custom Install screen,
  wired so it runs before Display.Driver if the person installing leaves it checked.

  The row's label comes from the `title` string in templates\GpuUnlockCert.nvi.template, in both
  the neutral and the per-locale <strings> blocks. Edit it there, not here. The sub-package's
  internal name stays "GpuUnlockCert" - that identifier is what setup.cfg's dependency wiring and
  the component folder are keyed on, and it is never displayed.

.DESCRIPTION
  Verified working on 595.79 / installer engine 2.1002.x: adding a sub-package with
  disposition="optional" hidden="false" hasDriver="true" renders as its own row in the
  Custom Installation Options screen, DEFAULTS TO UNCHECKED (genuine opt-in, unlike
  disposition="default" which pre-checks), and shows correct version columns.

  This is the automated version of what was hand-built and confirmed against a real install of
  Patched_Nvidia_595.79-desktop-win10-win11-64bit-international-dch-whql on 2026-08-05: a
  GpuUnlockCert sub-package + a Display.Driver "after" dependency on it.

  HOW THE EDIT IS MADE. setup.cfg is XML, but it is edited surgically with whitespace- and
  attribute-order-tolerant regexes rather than by round-tripping through an XML parser. Two
  reasons: re-serialising the document would reformat the whole file and produce an enormous diff
  against what NVIDIA shipped, and earlier versions of this script matched byte-exact literals
  (`"<install>`r`n`t`t<search dir=`".`">"`) that would silently stop matching the moment NVIDIA
  changed indentation, line endings, or attribute order. The anchors now tolerate all of those
  while still touching only the two places that need to change, and the result is verified
  structurally afterwards.

  Not yet verified: what actually happens when the box is left CHECKED through a full install
  (i.e. that certutil fires cleanly under the installer's elevated context and the driver
  package then installs without further prompts). Confirm that before relying on this for a
  real install.

.PARAMETER PackageRoot
  Root of the unpacked driver package (contains setup.exe, setup.cfg).

.PARAMETER CerPath
  Certificate to embed (the same one used to sign nv_disp.cat for this package).

.EXAMPLE
  .\Add-SetupCertOption.ps1 -PackageRoot "D:\NVIDIA\610.xx_Patched" -CerPath "..\Certificates\DriverPatchSigning.cer"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [Parameter(Mandatory = $true)]
    [string]$CerPath,

    # disposition="default" pre-ticks the row; "optional" leaves it unticked. Either way the user
    # can toggle it, unlike "critical" which locks it on.
    #
    # This defaults to pre-ticked because the package is built by the same person who installs it,
    # and a driver signed with a certificate the machine does not trust will not load - so an
    # unticked box is a trap you walk into once and then have to redo the install. Worth being
    # deliberate about it though: leaving it ticked adds a self-signed certificate to the
    # machine-wide Root store, which affects what ALL software on the box will accept, not just
    # this driver. Pass -Unchecked to restore the opt-in behaviour.
    [switch]$Unchecked
)

$ErrorActionPreference = 'Stop'

$setupCfgPath = Join-Path $PackageRoot "setup.cfg"
if (-not (Test-Path $setupCfgPath)) { throw "setup.cfg not found under $PackageRoot" }
if (-not (Test-Path $CerPath)) { throw "Certificate not found: $CerPath" }

$componentDir = Join-Path $PackageRoot "GpuUnlockCert"

# Read as UTF8 explicitly: the file has no BOM, and Windows PowerShell 5.1's auto-detection falls
# back to the system ANSI codepage without one, which would corrupt any non-ASCII text.
$cfg = Get-Content $setupCfgPath -Raw -Encoding UTF8
$cfgOriginal = $cfg

# --- State classification -----------------------------------------------------------------------
# This operation touches two independent things on disk: a component FOLDER and setup.cfg. There
# is no way to change both in one atomic step, so instead of pretending otherwise this recovers
# from either half-done state rather than refusing to run.
#
# The write order below is deliberate: files first, setup.cfg last. A crash in between leaves an
# unreferenced folder, which is harmless because nothing in setup.cfg points at it and the package
# still installs. The reverse order would leave setup.cfg declaring a sub-package whose files are
# missing, which breaks the installer. So the risky window is the cheap one - and the old
# "folder exists, refuse" guard turned that harmless leftover into a hard block that needed manual
# cleanup before the step could be retried.
$dirPresent = Test-Path $componentDir
$cfgPresent = $cfg -match 'name\s*=\s*"GpuUnlockCert"'

if ($dirPresent -and $cfgPresent) {
    throw "This package already has the cert option: setup.cfg declares GpuUnlockCert and $componentDir exists. Re-run against a fresh copy of the package rather than double-patching."
}
if ($cfgPresent -and -not $dirPresent) {
    Write-Warning "setup.cfg already declares GpuUnlockCert but $componentDir is missing - a previous run was interrupted after the setup.cfg edit. Restoring the component files; setup.cfg is left as it is."
}
if ($dirPresent -and -not $cfgPresent) {
    Write-Warning "$componentDir exists but setup.cfg does not declare it - a previous run was interrupted before the setup.cfg edit. Refreshing the files and completing the edit."
}

Write-Host "Adding GpuUnlockCert component to $PackageRoot" -ForegroundColor Cyan

$templatePath = Join-Path $PSScriptRoot "templates\GpuUnlockCert.nvi.template"
if (-not (Test-Path $templatePath)) { throw "Template not found: $templatePath" }

if ($cfgPresent) {
    Write-Host "  setup.cfg already declares the component - only the files need restoring." -ForegroundColor DarkGray
}
else {

# --- 1. Declare the sub-package as a child of <install> ----------------------------------------
# Tolerates any whitespace/newline style after <install> and does not care what element comes
# first inside it. $2 is the existing indentation of the first child, reused verbatim so the
# inserted line lines up with its siblings whatever NVIDIA's indentation happens to be.
$installRx = [regex]'(<install\s*>)(\s*)'
$installMatch = $installRx.Match($cfg)
if (-not $installMatch.Success) {
    throw "Could not find an <install> element in setup.cfg. This package's format differs from what this script was verified against - inspect setup.cfg manually and adjust before proceeding (do not guess at a different insertion point blindly)."
}

$disposition = if ($Unchecked) { 'optional' } else { 'default' }
$subPackageXml = '<sub-package disposition="' + $disposition + '" hidden="false" name="GpuUnlockCert"><properties/><options/><constraints/></sub-package>'
$indent = $installMatch.Groups[2].Value
$cfg = $installRx.Replace(
    $cfg,
    ('$1' + $indent + $subPackageXml + '$2'),
    1)   # first occurrence only

# --- 2. Make Display.Driver depend on it, so certutil runs first --------------------------------
# Attribute order is not assumed: the name attribute may sit before or after disposition.
$ddRx = [regex]'(<sub-package\b[^>]*?\bname\s*=\s*"Display\.Driver"[^>]*?>)(\s*)'
$ddMatch = $ddRx.Match($cfg)
if (-not $ddMatch.Success) {
    throw "Could not find the Display.Driver sub-package element in setup.cfg - inspect manually rather than guessing at a different insertion point."
}
if ($ddMatch.Groups[1].Value.TrimEnd().EndsWith('/>')) {
    throw "The Display.Driver sub-package is self-closing and has no children, so a <dependencies> block cannot be added to it. This package's format differs from what this script was verified against."
}

$childIndent = $ddMatch.Groups[2].Value
# Match the file's own indent character rather than always appending a tab, so a space-indented
# setup.cfg doesn't end up with a stray tab mixed in. Cosmetic, but this file is meant to stay
# readable as a near-verbatim copy of what NVIDIA shipped.
$indentUnit = if ($childIndent -match "`t") { "`t" } else { "    " }
$deeperIndent = $childIndent + $indentUnit
$packageLine = '<package package="GpuUnlockCert" type="after"/>'

# Display.Driver may already carry a <dependencies> block (other sub-packages in this file do).
# Add to it in that case rather than emitting a second, sibling <dependencies>.
$afterOpenTag = $cfg.Substring($ddMatch.Index + $ddMatch.Length)
if ($afterOpenTag -match '^<dependencies\s*>') {
    $insertAt = $ddMatch.Index + $ddMatch.Length + $Matches[0].Length
    $cfg = $cfg.Substring(0, $insertAt) + $deeperIndent + $packageLine + $cfg.Substring($insertAt)
    Write-Host "  Display.Driver already had a <dependencies> block - added the GpuUnlockCert entry to it." -ForegroundColor DarkGray
}
else {
    $dependenciesXml = '<dependencies>' + $deeperIndent + $packageLine + $childIndent + '</dependencies>'
    $cfg = $ddRx.Replace($cfg, ('$1' + $childIndent + $dependenciesXml + '$2'), 1)
}

}   # end: if (-not $cfgPresent)

# --- 3. Commit, with rollback ------------------------------------------------------------------
# Everything above was computed in memory; nothing on disk has changed yet. Files go first and
# setup.cfg last, so an abrupt kill leaves at worst an unreferenced folder. Anything this script
# can actually catch gets undone, so a failure leaves the package exactly as it was found rather
# than half-patched.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$createdDir = $false
$wroteCfg = $false

try {
    if (-not (Test-Path $componentDir)) {
        New-Item -ItemType Directory -Path $componentDir | Out-Null
        $createdDir = $true
    }
    # -Force so a leftover folder from an interrupted run is refreshed rather than colliding.
    Copy-Item -Path $CerPath -Destination (Join-Path $componentDir "GpuUnlockCert.cer") -Force
    $nviDest = Join-Path $componentDir "GpuUnlockCert.nvi"
    Copy-Item -Path $templatePath -Destination $nviDest -Force
    # The component declares its disposition in two places, its own .nvi and the setup.cfg
    # sub-package. Keep them in step rather than betting on which one the installer prefers.
    if ($Unchecked) {
        $nviText = Get-Content $nviDest -Raw -Encoding UTF8
        $nviText = [regex]::Replace($nviText, '(<nvi\b[^>]*?)disposition="default"', '$1disposition="optional"', 1)
        [System.IO.File]::WriteAllText($nviDest, $nviText, $utf8NoBom)
    }

    if (-not $cfgPresent) {
        [System.IO.File]::WriteAllText($setupCfgPath, $cfg, $utf8NoBom)
        $wroteCfg = $true
    }

    # --- 4. Verify the result structurally, not just that it still parses ----------------------
    try {
        $xml = [xml](Get-Content $setupCfgPath -Raw -Encoding UTF8)
    }
    catch {
        throw "setup.cfg is no longer valid XML after patching. Error: $_"
    }

    $declared = $xml.SelectSingleNode("//sub-package[@name='GpuUnlockCert']")
    if (-not $declared) {
        throw "setup.cfg parses but contains no GpuUnlockCert sub-package - the insertion did not take effect."
    }
    $dependency = $xml.SelectSingleNode("//sub-package[@name='Display.Driver']/dependencies/package[@package='GpuUnlockCert']")
    if (-not $dependency) {
        throw "setup.cfg parses and declares GpuUnlockCert, but Display.Driver does not depend on it, so certutil would not run before the driver installs."
    }
    if ($dependency.type -ne 'after') {
        throw "The GpuUnlockCert dependency on Display.Driver has type='$($dependency.type)' instead of 'after'."
    }
    if ($declared.disposition -ne $disposition) {
        throw "GpuUnlockCert has disposition='$($declared.disposition)' but '$disposition' was intended."
    }
    foreach ($needed in @("GpuUnlockCert.cer", "GpuUnlockCert.nvi")) {
        if (-not (Test-Path (Join-Path $componentDir $needed))) {
            throw "$needed is missing from $componentDir after the copy."
        }
    }
}
catch {
    Write-Warning "Failed partway through - rolling back so the package is left as it was found."
    if ($wroteCfg) {
        try {
            [System.IO.File]::WriteAllText($setupCfgPath, $cfgOriginal, $utf8NoBom)
            Write-Warning "  setup.cfg restored to its previous contents."
        }
        catch { Write-Warning "  COULD NOT restore setup.cfg - re-copy it from the source package." }
    }
    if ($createdDir) {
        try {
            Remove-Item -LiteralPath $componentDir -Recurse -Force -ErrorAction Stop
            Write-Warning "  $componentDir removed."
        }
        catch { Write-Warning "  COULD NOT remove $componentDir - delete it by hand before retrying." }
    }
    throw
}

$state = if ($Unchecked) { "UNCHECKED (opt-in)" } else { "CHECKED (the user can still untick it)" }
Write-Host "Done. setup.cfg now offers 'Chameleon GPU cert.' under Custom Installation" -ForegroundColor Green
Write-Host "Options, defaulting to $state." -ForegroundColor Green
if (-not $Unchecked) {
    Write-Host "Leaving it ticked adds a self-signed certificate to the machine-wide Root store," -ForegroundColor Yellow
    Write-Host "which affects what all software on the box accepts, not just this driver." -ForegroundColor Yellow
}
Write-Host "Verified structurally: the sub-package is declared and Display.Driver depends on it." -ForegroundColor DarkGray
