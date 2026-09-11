<#
.SYNOPSIS
  Verifies that a Display.Driver folder really was patched, BEFORE its catalog gets signed.

.DESCRIPTION
  Signing is the point of no return for a mistake: Inf2Cat happily builds a catalog from
  unpatched INFs and signtool happily signs it, so a package where the patches silently failed to
  apply comes out looking finished. It installs, the device enumerates, and the unlock simply
  isn't there. Nothing in the pipeline used to notice - a run against a package whose INF layout
  the patchers didn't recognise reported "0 entries added" and still signed and declared success.

  This script is that missing check. It re-reads the patched INFs and asserts what the patchers
  were supposed to have done:

    1. Every INF named in whitelist.json is present, and has at least one [NVIDIA_Devices*] block.
    2. Every whitelist entry's PCI device (+ subsystem) ID is whitelisted in that INF.
    3. Each such device line points at an install Section that actually EXISTS in the same INF.
    4. Every section a spliced-in SectionExtraGPU* body references resolves in the same INF
       (AddReg/DelReg/CopyFiles/AddService/AddSoftware targets, and Include'd files).
    5. Every %token% a device line uses is defined in [Strings].
    6. Every [nv_miscBase_addreg__NN] section carries the RM1457588 override, and at least one
       such section exists.

  Device lines are matched on the DEV/SUBSYS pair rather than on the %key% name, because NVIDIA
  may already whitelist a given device upstream in a later release - in which case
  Add-ExtraGpuSupport.ps1 correctly skips it and the entry is present under NVIDIA's own line.
  What matters is that the combination is whitelisted, not who put it there.

  NOTE ON LINE SHAPE: a real INF device line is
      %NVIDIA_DEV.1E90% = Section001, PCI\VEN_10DE&DEV_1E90&SUBSYS_000010DE
  i.e. the install section comes BEFORE the hardware ID, not after it. Assertions written the
  other way round never match a correctly patched INF.

.PARAMETER DisplayDriverPath
  The patched Display.Driver folder to check.

.PARAMETER WhitelistPath
  Defaults to whitelist.json next to this script.

.PARAMETER ReportOnly
  Print findings but never throw. Without this, any error-class finding throws.

.PARAMETER SkipRmOverrideCheck
  Don't assert the RM1457588 override (use if you ran the pipeline with that step skipped).

.EXAMPLE
  .\Test-DriverPatch.ps1 -DisplayDriverPath "610.88_Patched\Display.Driver"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DisplayDriverPath,

    [string]$WhitelistPath,

    [switch]$ReportOnly,

    [switch]$SkipRmOverrideCheck
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not $WhitelistPath) {
    $WhitelistPath = Join-Path $PSScriptRoot "whitelist.json"
}
if (-not (Test-Path $DisplayDriverPath)) { throw "Display.Driver path not found: $DisplayDriverPath" }
if (-not (Test-Path $WhitelistPath))     { throw "whitelist.json not found: $WhitelistPath" }

$whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

$errors   = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

# "CopyINF = nvppc.inf" and "Include = ..." reference INFs from ELSEWHERE - sibling subpackages of
# the driver package (nvppc.inf ships in <pkg>\PPC\, nvpcf.inf in <pkg>\NVPCF\), or an INF already
# in the Windows INF store by install time. Verified against stock 595.79: [Section001] carries the
# very same "CopyINF = nvppc.inf" line, so a spliced copy of it is faithful, not broken. Resolve
# these against the whole package tree and treat a miss as informational only, never as a reason
# to block signing.
$packageRoot = Split-Path $DisplayDriverPath -Parent
$packageInfNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
if ($packageRoot -and (Test-Path $packageRoot)) {
    Get-ChildItem -Path $packageRoot -Filter *.inf -Recurse -ErrorAction SilentlyContinue |
        ForEach-Object { [void]$packageInfNames.Add($_.Name) }
}

function Get-InfSections {
    <# sectionName (case-insensitive) -> list of body lines #>
    param([string[]]$Lines)
    $sections = New-Object 'System.Collections.Generic.Dictionary[string,System.Collections.Generic.List[string]]' ([StringComparer]::OrdinalIgnoreCase)
    $current = $null
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[([^\]]+)\]\s*$') {
            $current = $Matches[1].Trim()
            if (-not $sections.ContainsKey($current)) {
                $sections[$current] = New-Object System.Collections.Generic.List[string]
            }
        }
        elseif ($current) {
            $sections[$current].Add($line)
        }
    }
    return $sections
}

function Get-ReferencedSections {
    <#
      Pulls section names out of the INF directives that reference other sections. Deliberately
      conservative: "Needs =" points into an INCLUDED inf and cannot be resolved locally, and
      unknown directives are ignored rather than guessed at.
    #>
    param([string[]]$Body)
    $refs = New-Object System.Collections.Generic.List[string]
    $includes = New-Object System.Collections.Generic.List[string]
    foreach ($raw in $Body) {
        $line = ($raw -split ';')[0].Trim()
        if (-not $line) { continue }
        if ($line -notmatch '^\s*([A-Za-z]+)\s*=\s*(.+)$') { continue }
        $directive = $Matches[1]
        $value = $Matches[2].Trim()
        switch ($directive.ToLowerInvariant()) {
            'addreg'   { foreach ($v in ($value -split ',')) { $t = $v.Trim(); if ($t) { $refs.Add($t) } } }
            'delreg'   { foreach ($v in ($value -split ',')) { $t = $v.Trim(); if ($t) { $refs.Add($t) } } }
            'copyfiles' {
                foreach ($v in ($value -split ',')) {
                    $t = $v.Trim()
                    # "CopyFiles = @filename" copies a single file rather than naming a section.
                    if ($t -and -not $t.StartsWith('@')) { $refs.Add($t) }
                }
            }
            'addservice' {
                # AddService = <svcname>, <flags>, <install-section>[, <eventlog-section>]
                $parts = @($value -split ',' | ForEach-Object { $_.Trim() })
                for ($i = 2; $i -lt $parts.Count; $i++) { if ($parts[$i]) { $refs.Add($parts[$i]) } }
            }
            'addsoftware' {
                # AddSoftware = <name>, <flags>, <install-section>
                $parts = @($value -split ',' | ForEach-Object { $_.Trim() })
                if ($parts.Count -ge 3 -and $parts[2]) { $refs.Add($parts[2]) }
            }
            'include'  { foreach ($v in ($value -split ',')) { $t = $v.Trim(); if ($t) { $includes.Add($t) } } }
            'copyinf'  { foreach ($v in ($value -split ',')) { $t = $v.Trim(); if ($t) { $includes.Add($t) } } }
        }
    }
    return [PSCustomObject]@{ Sections = $refs; Includes = $includes }
}

Write-Host "Verifying patched package: $DisplayDriverPath" -ForegroundColor Cyan
Write-Host ""

# --- Per-INF whitelist checks -----------------------------------------------------------------
$totalChecked = 0
$totalPresent = 0

# Resolve every whitelist key onto the file this release actually ships, using exactly the same
# helper the patcher uses. This has to match: if the gate looked up literal filenames while the
# patcher followed a rename, the gate would reject a package that had in fact been patched
# correctly. Resolving up front also keeps the check loop below single-level.
$targets = New-Object System.Collections.Generic.List[object]
foreach ($prop in $whitelist.PSObject.Properties) {
    $resolved = @(Resolve-WhitelistInf -DisplayDriverPath $DisplayDriverPath -InfName $prop.Name)
    if ($resolved.Count -eq 0) {
        $warnings.Add("$($prop.Name) is not in this package, and nor is any same-stem variant of it - $($prop.Value.Count) whitelist entries could not be checked. NVIDIA may have renamed or dropped this INF.")
        continue
    }
    foreach ($r in $resolved) {
        $targets.Add([PSCustomObject]@{
            Key = $prop.Name; Entries = $prop.Value; Path = $r.Path; Name = $r.Name; Exact = $r.Exact
        })
    }
}

foreach ($t in $targets) {
    $infName = $t.Name          # the real filename, so findings name the file that exists
    $entries = $t.Entries
    $infPath = $t.Path
    $aka = ""
    if (-not $t.Exact) { $aka = " (this release's name for $($t.Key))" }

    $lines = Get-Content -Path $infPath -Encoding UTF8
    $sections = Get-InfSections -Lines $lines

    # Collect the union of every [NVIDIA_Devices*] block body.
    $deviceLines = New-Object System.Collections.Generic.List[string]
    $deviceBlockCount = 0
    foreach ($k in $sections.Keys) {
        if ($k -match '^NVIDIA_Devices') {
            $deviceBlockCount++
            foreach ($l in $sections[$k]) { $deviceLines.Add($l) }
        }
    }
    if ($deviceBlockCount -eq 0) {
        $errors.Add("$infName has no [NVIDIA_Devices*] block at all - the whitelist patcher could not have applied anything. This INF's layout is not what the patcher expects.")
        continue
    }

    $stringsDefined = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($sections.ContainsKey('Strings')) {
        foreach ($l in $sections['Strings']) {
            if ($l -match '^\s*([^;=\s]+)\s*=') { [void]$stringsDefined.Add($Matches[1].Trim()) }
        }
    }

    $missing = New-Object System.Collections.Generic.List[string]
    $badSection = New-Object System.Collections.Generic.List[string]
    $badToken = New-Object System.Collections.Generic.List[string]

    foreach ($entry in $entries) {
        $totalChecked++
        $dev = $entry.dev
        $subsys = $entry.subsys
        $idLabel = if ($subsys) { "DEV_$dev&SUBSYS_$subsys" } else { "DEV_$dev" }

        # Match the real line shape: %token% = <Section>, PCI\VEN_10DE&DEV_xxxx[&SUBSYS_xxxxxxxx]
        if ($subsys) {
            $pattern = '^\s*%([^%]+)%\s*=\s*([^,]+?)\s*,\s*PCI\\VEN_10DE&DEV_' + [regex]::Escape($dev) + '&SUBSYS_' + [regex]::Escape($subsys) + '\s*$'
        }
        else {
            $pattern = '^\s*%([^%]+)%\s*=\s*([^,]+?)\s*,\s*PCI\\VEN_10DE&DEV_' + [regex]::Escape($dev) + '\s*$'
        }

        $hit = $null
        foreach ($l in $deviceLines) {
            if ($l -match $pattern) { $hit = $Matches; break }
        }

        if (-not $hit) {
            $missing.Add($idLabel)
            continue
        }
        $totalPresent++

        $token = $hit[1].Trim()
        $sectionName = $hit[2].Trim()

        if (-not $sections.ContainsKey($sectionName)) {
            $badSection.Add("$idLabel -> [$sectionName] (section header absent)")
        }
        if (-not $stringsDefined.Contains($token)) {
            $badToken.Add("$idLabel uses %$token% which has no [Strings] definition")
        }
    }

    # Validate that spliced-in sections' own references resolve in this INF.
    $unresolved = New-Object System.Collections.Generic.List[string]
    $unresolvedIncludes = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($k in $sections.Keys) {
        if ($k -notmatch '^SectionExtraGPU') { continue }
        $refs = Get-ReferencedSections -Body $sections[$k]
        foreach ($r in $refs.Sections) {
            if (-not $sections.ContainsKey($r)) { $unresolved.Add("[$k] references missing section [$r]") }
        }
        foreach ($inc in $refs.Includes) {
            if (-not (Test-Path (Join-Path $DisplayDriverPath $inc)) -and -not $packageInfNames.Contains($inc)) {
                [void]$unresolvedIncludes.Add($inc)
            }
        }
    }
    if ($unresolvedIncludes.Count -gt 0) {
        $warnings.Add("${infName}: CopyINF/Include target(s) not found in this package tree: $(($unresolvedIncludes | Sort-Object) -join ', '). Stock INFs reference these the same way and Windows resolves them from other subpackages or its own INF store, so this is informational - just confirm those subpackages are present if the install misbehaves.")
    }

    $spliced = @($sections.Keys | Where-Object { $_ -match '^SectionExtraGPU' }).Count
    Write-Host ("  {0,-16} {1}/{2} whitelisted, {3} device block(s), {4} spliced section(s){5}" -f `
        $infName, ($entries.Count - $missing.Count), $entries.Count, $deviceBlockCount, $spliced, $aka)

    foreach ($m in $badSection)  { $errors.Add("${infName}: $m") }
    foreach ($m in $badToken)    { $errors.Add("${infName}: $m") }
    foreach ($m in $unresolved)  { $errors.Add("${infName}: $m") }
    if ($missing.Count -gt 0) {
        $shown = ($missing | Select-Object -First 8) -join ', '
        $more = if ($missing.Count -gt 8) { " (+$($missing.Count - 8) more)" } else { "" }
        $errors.Add("${infName}: $($missing.Count) whitelist entr(y/ies) not present: $shown$more")
    }
}

# --- RM override check ------------------------------------------------------------------------
if (-not $SkipRmOverrideCheck) {
    $rmSectionsTotal = 0
    $rmSectionsMissing = New-Object System.Collections.Generic.List[string]
    $infsWithRmSections = 0

    Get-ChildItem -Path $DisplayDriverPath -Filter "*.inf" | ForEach-Object {
        $sections = Get-InfSections -Lines (Get-Content -Path $_.FullName -Encoding UTF8)
        $found = 0
        foreach ($k in $sections.Keys) {
            if ($k -notmatch '^nv_miscBase_addreg__\d+$') { continue }
            $found++
            $rmSectionsTotal++
            $hasKey = $false
            foreach ($l in $sections[$k]) { if ($l -match 'RM1457588') { $hasKey = $true; break } }
            if (-not $hasKey) { $rmSectionsMissing.Add("$($_.Name) [$k]") }
        }
        if ($found -gt 0) { $infsWithRmSections++ }
    }

    Write-Host ("  {0,-16} {1}/{2} sections carry RM1457588, across {3} INF(s)" -f `
        "RM override", ($rmSectionsTotal - $rmSectionsMissing.Count), $rmSectionsTotal, $infsWithRmSections)

    if ($rmSectionsTotal -eq 0) {
        $errors.Add("No [nv_miscBase_addreg__NN] section exists anywhere in the package. The RM-override patcher had nothing to match, so VRAM size and compute will be wrong on unlocked GPUs. This package's INF layout is not what the patcher expects.")
    }
    elseif ($rmSectionsMissing.Count -gt 0) {
        $shown = ($rmSectionsMissing | Select-Object -First 8) -join ', '
        $more = if ($rmSectionsMissing.Count -gt 8) { " (+$($rmSectionsMissing.Count - 8) more)" } else { "" }
        $errors.Add("$($rmSectionsMissing.Count) nv_miscBase_addreg section(s) are missing RM1457588: $shown$more")
    }
}

# --- Verdict ----------------------------------------------------------------------------------
Write-Host ""
foreach ($w in $warnings) { Write-Warning $w }

if ($errors.Count -eq 0) {
    Write-Host "Patch verification PASSED - $totalPresent/$totalChecked whitelist entries in place, references resolve, RM override applied." -ForegroundColor Green
}
else {
    Write-Host "Patch verification FAILED - $($errors.Count) problem(s):" -ForegroundColor Red
    foreach ($e in $errors) { Write-Host "  - $e" -ForegroundColor Red }
    Write-Host ""
    if (-not $ReportOnly) {
        throw "This package is NOT correctly patched. Refusing to continue - signing it would produce a package that looks finished but has no working unlock. Re-run the patch steps against a fresh copy of the stock package, or investigate the findings above (pass -ReportOnly to inspect without failing)."
    }
}
