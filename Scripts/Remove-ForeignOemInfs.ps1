<#
.SYNOPSIS
  Drops the OEM display INFs that cannot match this machine, so every later step - and above all
  the catalog rebuild - has far less to chew on.

.DESCRIPTION
  A stock NVIDIA DCH package ships 43 display INFs: the generic desktop one, plus one per laptop
  OEM. Only a couple can ever apply to any given machine. Inf2Cat's cost is superlinear in INF
  count and, measured on a real 2.71 GB Display.Driver, is completely unaffected by the /os list:

      1 INF   79.7 s        4 INFs  147.4 s  (identical at 1, 2 or 5 /os targets)
      2 INFs 128.1 s        8 INFs  583.8 s

  Four to eight INFs quadruples the time, which is why all 43 take about fifty minutes. Cutting
  the count is therefore the only lever that actually moves the needle - Inf2Cat has no switch to
  reduce its own work, and its single shared catalog rules out splitting the run across cores.

  WHAT IT IS SAFE TO REMOVE, AND WHY. Verified against 616.64 and 616.86:
    - The 43 display INFs are self-contained with respect to each other. None references another
      via Include=, Needs= or CopyINF=; the only external references are nvpcf.inf and nvppc.inf,
      which live in sibling subpackages this script never touches.
    - INF filenames appear in exactly ONE place outside the INFs themselves: the <manifest> in
      Display.Driver's .nvi. setup.cfg names no INF at all. So pruning means deleting files and
      removing their manifest entries, and nothing else goes stale.

  WHAT IT KEEPS. An INF survives if any of these hold:
    - It is named in whitelist.json, i.e. it is one this toolkit patches.
    - It can match a GPU actually present in this machine. Matching follows Windows' own
      semantics: an exact DEV+SUBSYS line, or a bare DEV line with no SUBSYS, which matches any
      subsystem of that device. An OEM INF listing the right DEV under someone else's SUBSYS can
      never win the install, so keeping it would be pure waste.
    - You named it with -KeepInf.

  The package that comes out is no longer usable on other vendors' laptops. For a package you are
  building to install on one known machine that is not a loss; if you want a portable package,
  don't use this.

.PARAMETER PackageRoot
  Root of the (already copied/unpacked) package. Must contain Display.Driver.

.PARAMETER WhitelistPath
  Defaults to whitelist.json next to this script.

.PARAMETER KeepInf
  Extra INFs to keep. Accepts a filename or a bare stem, and tolerates this release's renaming
  (nv_dispi -> nv_dispig).

.PARAMETER HardwareId
  Additional hardware IDs to treat as present, for building a package aimed at another machine.
  Accepts anything containing DEV_xxxx and optionally SUBSYS_xxxxxxxx, e.g. a full
  "PCI\VEN_10DE&DEV_25B8&SUBSYS_000010DE" string.

.PARAMETER IgnoreLocalHardware
  Don't inspect this machine's GPUs at all. Use with -HardwareId or -KeepInf when preparing a
  package for a different computer.

.EXAMPLE
  .\Remove-ForeignOemInfs.ps1 -PackageRoot "610.88_Patched"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WhitelistPath,

    [string[]]$KeepInf = @(),

    [string[]]$HardwareId = @(),

    [switch]$IgnoreLocalHardware
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not $WhitelistPath) { $WhitelistPath = Join-Path $PSScriptRoot "whitelist.json" }
if (-not (Test-Path $WhitelistPath)) { throw "whitelist.json not found: $WhitelistPath" }

$displayDriver = Join-Path $PackageRoot "Display.Driver"
if (-not (Test-Path $displayDriver)) { throw "Display.Driver not found under $PackageRoot" }

$allInfs = @(Get-ChildItem $displayDriver -Filter *.inf -File | Sort-Object Name)
if ($allInfs.Count -eq 0) { throw "No .inf files under $displayDriver - is this a Display.Driver folder?" }

$nviFiles = @(Get-ChildItem $displayDriver -Filter *.nvi -File)
if ($nviFiles.Count -ne 1) {
    throw "Expected exactly one .nvi in $displayDriver, found $($nviFiles.Count). This package's layout differs from what this script was verified against."
}
$nviPath = $nviFiles[0].FullName

$keep = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$reasons = @{}

function Add-Keep {
    param([string]$Name, [string]$Why)
    if ($keep.Add($Name)) { $reasons[$Name] = $Why }
    elseif ($reasons.ContainsKey($Name) -and $reasons[$Name] -notlike "*$Why*") { $reasons[$Name] += "; $Why" }
}

# --- 1. Load the whitelist ---------------------------------------------------------------------
# The decision about which whitelist INFs to keep is deliberately deferred until after hardware
# detection below. Keeping every INF the toolkit *could* patch is too generous: on 616.86 that
# retained nvamig.inf, whose three entries are all RTX A3000m, on a machine with an A2000m. That
# INF is 3.9 MB with 62,280 lines and 3,010 sections against nv_dispig.inf's 677 KB, and it alone
# accounted for three quarters of the catalog build - 385 s with it, 96 s without.
$whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

# --- 2. INFs that can match hardware actually present ------------------------------------------
$targets = New-Object System.Collections.Generic.List[object]

if (-not $IgnoreLocalHardware) {
    # Detection lives in PatchToolDiscovery.ps1 so this script, the output-folder tag and the
    # pipeline's pruned-build gate all read the same hardware the same way. See Get-LocalNvidiaGpu
    # for why it is display-class only and what the fallback is for.
    foreach ($d in @(Get-LocalNvidiaGpu -AllowNonDisplayFallback)) { $HardwareId += $d.DeviceID }
}
foreach ($h in $HardwareId) {
    if (-not $h) { continue }
    $dev = $null; $sub = $null
    if ($h -match 'DEV_([0-9A-Fa-f]{4})')     { $dev = $Matches[1].ToUpperInvariant() }
    if ($h -match 'SUBSYS_([0-9A-Fa-f]{8})')  { $sub = $Matches[1].ToUpperInvariant() }
    if ($dev) { $targets.Add([PSCustomObject]@{ Dev = $dev; Subsys = $sub; Source = $h }) }
}

$uniqueTargets = @($targets | Sort-Object Dev, Subsys -Unique)
if ($uniqueTargets.Count -gt 0) {
    Write-Host "Hardware to keep support for:" -ForegroundColor Cyan
    foreach ($t in $uniqueTargets) {
        $lbl = "DEV_$($t.Dev)"
        if ($t.Subsys) { $lbl += "&SUBSYS_$($t.Subsys)" }
        Write-Host ("  " + $lbl)
    }
}
else {
    Write-Warning "No NVIDIA PCI device found to match against. Only whitelist and -KeepInf INFs will be kept."
}

# --- 1b. Whitelist INFs, but only the ones that can serve a GPU that is actually here -----------
# Patching an INF whose whitelist entries all name hardware you do not have achieves nothing, and
# on a big OEM INF it dominates the catalog build. With no hardware to go on we cannot make that
# judgement, so every whitelist INF is kept as before.
foreach ($key in $whitelist.PSObject.Properties.Name) {
    foreach ($r in @(Resolve-WhitelistInf -DisplayDriverPath $displayDriver -InfName $key)) {
        if ($uniqueTargets.Count -eq 0) {
            Add-Keep -Name $r.Name -Why "patched by this toolkit"
            continue
        }
        $serves = $null
        foreach ($e in $whitelist.$key) {
            foreach ($t in $uniqueTargets) {
                if ($e.dev -ne $t.Dev) { continue }
                # A whitelist entry with no subsystem covers every subsystem of that device.
                if ((-not $e.subsys) -or ($t.Subsys -and $e.subsys -eq $t.Subsys)) {
                    $serves = "DEV_$($e.dev)"
                    if ($e.subsys) { $serves += "&SUBSYS_$($e.subsys)" }
                    break
                }
            }
            if ($serves) { break }
        }
        if ($serves) { Add-Keep -Name $r.Name -Why "patched by this toolkit for present hardware $serves" }
    }
}

foreach ($inf in $allInfs) {
    # Deliberately NOT skipping INFs already in the keep set. An INF kept because this toolkit
    # patches it may ALSO be what supports one of the present GPUs - nv_dispi.inf carries a bare
    # DEV line for most desktop parts - and the safety net below decides whether a GPU is covered
    # by looking for a recorded hardware match. Skipping here left that match unrecorded and made
    # a perfectly supported GPU, e.g. an RTX 5070 Ti at DEV_2C05, warn as unsupported.
    $lines = Get-Content $inf.FullName -Encoding UTF8
    foreach ($t in $uniqueTargets) {
        # Windows matches either an exact DEV+SUBSYS line, or a bare DEV line (no SUBSYS), which
        # covers every subsystem of that device. Anything else can never win the install.
        $exact = $null
        if ($t.Subsys) { $exact = 'PCI\\VEN_10DE&DEV_' + $t.Dev + '&SUBSYS_' + $t.Subsys + '\s*$' }
        $bare = 'PCI\\VEN_10DE&DEV_' + $t.Dev + '\s*$'
        $hit = $false
        foreach ($l in $lines) {
            if ($l -match $bare) { $hit = $true; break }
            if ($exact -and $l -match $exact) { $hit = $true; break }
        }
        if ($hit) {
            $lbl = "DEV_$($t.Dev)"
            if ($t.Subsys) { $lbl += "&SUBSYS_$($t.Subsys)" }
            Add-Keep -Name $inf.Name -Why "matches present hardware $lbl"
            break
        }
    }
}

# --- 3. Explicit keeps -------------------------------------------------------------------------
foreach ($k in $KeepInf) {
    if (-not $k) { continue }
    $want = $k
    if ($want -notlike '*.inf') { $want = $want + '.inf' }
    $found = @(Resolve-WhitelistInf -DisplayDriverPath $displayDriver -InfName $want)
    if ($found.Count -eq 0) { Write-Warning "-KeepInf '$k' matches no INF in this package." }
    foreach ($f in $found) { Add-Keep -Name $f.Name -Why "requested with -KeepInf" }
}

# --- 3b. Never prune to nothing -----------------------------------------------------------------
# If the stricter rule above matched nothing at all - an unrecognised GPU, or detection returning
# something odd - falling through would delete every display INF and leave an unusable package.
# Back off to the old behaviour and say so, rather than producing a confident-looking wreck.
if ($keep.Count -eq 0) {
    Write-Warning "No INF matched the present hardware or the whitelist entries for it. Falling back to keeping every INF this toolkit patches, so the package stays usable. The catalog build will be slower."
    foreach ($key in $whitelist.PSObject.Properties.Name) {
        foreach ($r in @(Resolve-WhitelistInf -DisplayDriverPath $displayDriver -InfName $key)) {
            Add-Keep -Name $r.Name -Why "fallback: patched by this toolkit, no hardware match found"
        }
    }
}

# The fallback above resolves whitelist INFs through Resolve-WhitelistInf, so a release that has
# renamed them beyond what that function recognises makes the fallback itself keep nothing - and
# the check before it has already passed. That is not hypothetical: on 616.92 this deleted all 45
# display INFs and reported "Manifest and disk agree: 0 INF(s) each" on the way out, leaving a
# 3.6 GB package with no INF in it. Deleting every display INF is never a correct outcome, so
# assert it here rather than trusting the guard above to have filled the set.
if ($keep.Count -eq 0) {
    throw ("Refusing to prune: that would delete all $($allInfs.Count) display INF(s) and leave an " +
           "unusable package. Even the keep-everything fallback matched nothing, which means the " +
           "INF names in whitelist.json ($(($whitelist.PSObject.Properties.Name) -join ', ')) do " +
           "not resolve against this release. Re-run without -PruneForeignOemInfs, or update " +
           "whitelist.json to this release's INF names.")
}

# --- 4. Safety net: is every detected GPU actually covered by something we keep? ----------------
# A GPU may legitimately match no STOCK INF - that is the entire reason this toolkit exists, and
# whitelist.json is what adds it to the generic desktop INF. So a GPU only counts as unsupported
# when no kept INF matches it AND the whitelist does not cover it either. That combination means
# the pruned package could not install here, which is worth stopping to look at.
$wlDevs = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($key in $whitelist.PSObject.Properties.Name) {
    foreach ($e in $whitelist.$key) { [void]$wlDevs.Add($e.dev) }
}
foreach ($t in $uniqueTargets) {
    $matchedByKept = @($keep | Where-Object { $reasons[$_] -like "*DEV_$($t.Dev)*" }).Count -gt 0
    if ($matchedByKept) { continue }
    if ($wlDevs.Contains($t.Dev)) {
        Write-Host ("  DEV_$($t.Dev) is not in any stock INF but IS in whitelist.json - it will be supported once patched.") -ForegroundColor DarkGray
        continue
    }
    Write-Warning "DEV_$($t.Dev) is present in this machine, matches none of the INFs being kept, and is not in whitelist.json. The pruned package may not install on it. Pass -KeepInf for whichever INF supports it, or -IgnoreLocalHardware if you know better."
}

# --- 5. Decide and report ----------------------------------------------------------------------
$prune = @($allInfs | Where-Object { -not $keep.Contains($_.Name) })

Write-Host ""
Write-Host ("Keeping " + $keep.Count + " of " + $allInfs.Count + " display INF(s):") -ForegroundColor Green
foreach ($n in @($keep | Sort-Object)) { Write-Host ("  " + $n.PadRight(16) + " - " + $reasons[$n]) }

if ($prune.Count -eq 0) {
    Write-Host ""
    Write-Host "Nothing to prune." -ForegroundColor DarkGray
    return
}

Write-Host ""
Write-Host ("Pruning " + $prune.Count + " INF(s) that cannot match this machine:") -ForegroundColor Yellow
Write-Host ("  " + (($prune | ForEach-Object { $_.Name }) -join ', '))

# Sanity: no kept INF may reference one we are about to remove.
$pruneNames = @($prune | ForEach-Object { $_.Name })
foreach ($n in @($keep)) {
    $p = Join-Path $displayDriver $n
    if (-not (Test-Path $p)) { continue }
    foreach ($l in (Get-Content $p -Encoding UTF8)) {
        if ($l -match '^\s*(Include|Needs|CopyINF)\s*=\s*(.+)$') {
            foreach ($ref in ($Matches[2] -split ',')) {
                if ($pruneNames -contains $ref.Trim()) {
                    throw "$n references $($ref.Trim()), which is scheduled for removal. Add it with -KeepInf and re-run."
                }
            }
        }
    }
}

# --- 5. Apply: files first, then the manifest --------------------------------------------------
if (-not $PSCmdlet.ShouldProcess($displayDriver, "Remove $($prune.Count) OEM INF(s) and their manifest entries")) {
    return
}

# The manifest entries are edited as TEXT, not by round-tripping the XML. This .nvi is 100 KB of
# NVIDIA's own formatting with many <file .../> elements packed several to a line; re-serialising
# it would rewrite the whole document and produce an enormous diff against what they shipped.
# Removing just the matching elements keeps every other byte identical, and the result is parsed
# and cross-checked against the folder afterwards.
$nviText = Get-Content $nviPath -Raw -Encoding UTF8
$nviOriginal = $nviText
$removedEntries = 0
foreach ($n in $pruneNames) {
    $rx = [regex]('<file\s+name\s*=\s*"' + [regex]::Escape($n) + '"[^>]*/>')
    $before = $rx.Matches($nviText).Count
    if ($before -eq 0) {
        Write-Warning "No manifest entry found for $n - it was already absent."
        continue
    }
    $nviText = $rx.Replace($nviText, '')
    $removedEntries += $before
}

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$removedFiles = 0
try {
    [System.IO.File]::WriteAllText($nviPath, $nviText, $utf8NoBom)
    foreach ($f in $prune) {
        [System.IO.File]::Delete($f.FullName)
        $removedFiles++
    }
}
catch {
    Write-Warning "Failed partway through - restoring the manifest. Any INF already deleted must be recovered from the source package."
    try { [System.IO.File]::WriteAllText($nviPath, $nviOriginal, $utf8NoBom) } catch { }
    throw
}

# --- 6. Verify --------------------------------------------------------------------------------
try { $check = [xml](Get-Content $nviPath -Raw -Encoding UTF8) }
catch { throw "$nviPath is no longer valid XML after pruning - restore the package from source. $_" }

$manifestInfs = @($check.nvi.manifest.file | ForEach-Object { $_.getAttribute('name') } | Where-Object { $_ -like '*.inf' })
$onDisk = @(Get-ChildItem $displayDriver -Filter *.inf -File | ForEach-Object { $_.Name })
$orphanEntries = @($manifestInfs | Where-Object { $onDisk -notcontains $_ })
$unlisted = @($onDisk | Where-Object { $manifestInfs -notcontains $_ })

if ($orphanEntries.Count) { throw "Manifest still lists INFs that are gone from disk: $($orphanEntries -join ', ')" }
if ($unlisted.Count)      { throw "INFs on disk are missing from the manifest: $($unlisted -join ', ')" }

Write-Host ""
Write-Host ("Removed $removedFiles INF file(s) and $removedEntries manifest entry/entries.") -ForegroundColor Green
Write-Host ("Manifest and disk agree: $($manifestInfs.Count) INF(s) each.") -ForegroundColor Green
Write-Host "The catalog rebuild later on should now take minutes rather than tens of minutes." -ForegroundColor Green
Write-Host "This package is now specific to the hardware above - not portable to other OEM laptops." -ForegroundColor Yellow
