<#
.SYNOPSIS
  Re-applies the "extra GPU / mobile subsystem" device-ID whitelist (originally reverse-engineered
  from a hand-patched 595.79 "Franken" package) to ANY stock NVIDIA Display.Driver folder.

.DESCRIPTION
  NVIDIA's desktop DCH driver INFs (nv_dispi.inf, nvami.inf, ...) whitelist PCI device+subsystem
  ID combinations. Some laptop dGPUs are only whitelisted under the laptop OEM's own subsystem ID,
  which locks them to OEM-provided drivers. This script adds the missing device/subsystem entries
  (data-driven from whitelist.json) to a target driver package so the standard desktop package
  recognizes those chips too.

  Designed to be re-run against future NVIDIA driver dumps: it does NOT hardcode section numbers.
  For each whitelist entry it:
    1. Skips it if the target INF already whitelists that exact DEV+SUBSYS combo (NVIDIA may add
       it upstream in a later release).
    2. If the same bare DEV id already has an entry under a different subsystem in the target file,
       reuses that entry's Section (guaranteed valid/current for that chip in this driver version).
    3. Otherwise creates a new, uniquely-named Section by copying the section body captured from the
       reference "Franken" package, and points the new match line at it.
  Then adds the matching [Strings] description if missing.

.PARAMETER DisplayDriverPath
  Path to the "Display.Driver" folder of a stock NVIDIA driver package (any version).

.PARAMETER WhitelistPath
  Path to whitelist.json (defaults to the copy next to this script).

.PARAMETER WhatIf
  Show what would change without writing files.

.EXAMPLE
  .\Add-ExtraGpuSupport.ps1 -DisplayDriverPath "D:\NVIDIA\610.xx\Display.Driver"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DisplayDriverPath,

    [string]$WhitelistPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

# $PSScriptRoot is unreliable inside a param() default value when this script is launched as a
# fresh process (powershell.exe -File ..., e.g. double-clicked or run via "Run with PowerShell")
# - confirmed empty there even though it's reliably set by this point in the script body.
if (-not $WhitelistPath) {
    $WhitelistPath = Join-Path $PSScriptRoot "whitelist.json"
}

if (-not (Test-Path $DisplayDriverPath)) {
    throw "Display.Driver path not found: $DisplayDriverPath"
}
if (-not (Test-Path $WhitelistPath)) {
    throw "whitelist.json not found: $WhitelistPath"
}

$whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

function Get-MatchLinePattern {
    param([string]$Dev, [string]$Subsys)
    if ($Subsys) {
        return "PCI\\VEN_10DE&DEV_$Dev&SUBSYS_$Subsys"
    }
    else {
        # Bare device line: must not be followed by &SUBSYS (that would be a different, more specific entry)
        return "PCI\\VEN_10DE&DEV_$Dev(\s|$)"
    }
}

function Find-DeviceBlocks {
    param([string[]]$Lines)
    # Returns list of @{StartIndex; EndIndex} for each [NVIDIA_Devices...] section (end = index of blank/next-header line, exclusive)
    $blocks = @()
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\[NVIDIA_Devices[^\]]*\]\s*$') {
            $start = $i + 1
            $end = $Lines.Count
            for ($j = $start; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j] -match '^\[.+\]\s*$') { $end = $j; break }
            }
            $blocks += [PSCustomObject]@{ StartIndex = $start; EndIndex = $end }
        }
    }
    return $blocks
}

function Find-SectionBounds {
    param([string[]]$Lines, [string]$SectionName)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq "[$SectionName]") {
            $end = $Lines.Count
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j] -match '^\[.+\]\s*$') { $end = $j; break }
            }
            return [PSCustomObject]@{ HeaderIndex = $i; EndIndex = $end }
        }
    }
    return $null
}

function Get-StringsSectionBounds {
    param([string[]]$Lines)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i].Trim() -eq '[Strings]') {
            $end = $Lines.Count
            for ($j = $i + 1; $j -lt $Lines.Count; $j++) {
                if ($Lines[$j] -match '^\[.+\]\s*$') { $end = $j; break }
            }
            return [PSCustomObject]@{ HeaderIndex = $i; EndIndex = $end }
        }
    }
    return $null
}

function Patch-InfFile {
    param(
        [string]$Path,
        [array]$Entries
    )

    Write-Host "`n=== $(Split-Path $Path -Leaf) ===" -ForegroundColor Cyan
    $lines = [System.Collections.Generic.List[string]](Get-Content -Path $Path -Encoding UTF8)

    # Fail fast and loudly if this INF's layout isn't what we expect. Previously a missing
    # [NVIDIA_Devices...] block produced one warning PER ENTRY and then carried on to report
    # success with "0 entries added", which reads as "nothing needed doing" rather than "this
    # patcher no longer understands this file". If NVIDIA ever restructures the device blocks,
    # that difference is the whole ballgame - stopping here is what prevents an unpatched package
    # from being signed and shipped as finished.
    if ((Find-DeviceBlocks -Lines $lines).Count -eq 0) {
        throw "$(Split-Path $Path -Leaf) contains no [NVIDIA_Devices...] block, so no device/subsystem entry can be inserted. This driver release's INF layout differs from what this script understands - inspect the file and update the matching logic rather than shipping an unpatched package."
    }

    $addedCount = 0
    $skippedCount = 0
    $newSectionSuffix = 0

    foreach ($entry in $Entries) {
        $dev = $entry.dev
        $subsys = $entry.subsys
        $pattern = Get-MatchLinePattern -Dev $dev -Subsys $subsys
        $alreadyPresent = $lines | Where-Object { $_ -match $pattern }
        if ($alreadyPresent) {
            $skippedCount++
            continue
        }

        # Does the target already whitelist the SAME bare device id under some other/no subsystem?
        $sameDevPattern = "PCI\\VEN_10DE&DEV_$dev(&SUBSYS_[0-9A-F]{8})?\s*$"
        $sameDevLine = $lines | Where-Object { $_ -match $sameDevPattern } | Select-Object -First 1

        $targetSection = $null
        if ($sameDevLine -and ($sameDevLine -match '=\s*(Section\w+)\s*,')) {
            $targetSection = $Matches[1]
        }
        else {
            # Fall back: create a brand new section family from the captured template.
            # NVIDIA DDInstall sections split AddService into a separate "<Section>.Services"
            # companion (and sometimes .Software/.HW/.GeneralConfigData) - Windows install
            # fails with "No INF AddService directives contained SPSVCINST_ASSOCSERVICE" if
            # only the base section is copied, so every companion must be emitted too.
            $newSectionSuffix++
            $targetSection = "SectionExtraGPU$($dev)_$newSectionSuffix"
            $family = $entry.template_section_family
            if (-not $family -or -not ($family.PSObject.Properties | Where-Object Name -eq '_base')) {
                Write-Warning "No template body captured for DEV_$dev/$subsys - skipping (would create empty section)."
                continue
            }
            foreach ($prop in $family.PSObject.Properties) {
                $suffix = $prop.Name
                $body = $prop.Value
                if (-not $body -or $body.Count -eq 0) { continue }
                $sectionName = if ($suffix -eq '_base') { $targetSection } else { "$targetSection.$suffix" }
                $sectionLines = @("[$sectionName]") + $body + @("")
                $lines.AddRange([string[]]$sectionLines)
            }
        }

        # Build and insert the match line into every [NVIDIA_Devices...] block
        $keyName = $entry.key
        $matchLine = if ($subsys) {
            "%$keyName% = $targetSection, PCI\VEN_10DE&DEV_$dev&SUBSYS_$subsys"
        }
        else {
            "%$keyName% = $targetSection, PCI\VEN_10DE&DEV_$dev"
        }

        # Re-found each iteration because inserting lines shifts every later index.
        $blocks = Find-DeviceBlocks -Lines $lines
        # Insert from bottom-most block upward so earlier indices stay valid
        foreach ($block in ($blocks | Sort-Object EndIndex -Descending)) {
            $lines.Insert($block.EndIndex, $matchLine)
        }

        # Add the [Strings] description if not already defined
        $stringsBounds = Get-StringsSectionBounds -Lines $lines
        if ($stringsBounds) {
            $hasString = $false
            for ($k = $stringsBounds.HeaderIndex + 1; $k -lt $stringsBounds.EndIndex; $k++) {
                if ($lines[$k] -match "^\s*$([regex]::Escape($keyName))\s*=") { $hasString = $true; break }
            }
            if (-not $hasString) {
                $desc = $entry.description
                if (-not $desc) { $desc = "NVIDIA Graphics Device" }
                $lines.Insert($stringsBounds.EndIndex, "$keyName = `"$desc`"")
            }
        }

        $addedCount++
        Write-Host "  + DEV_$dev$(if($subsys){"&SUBSYS_$subsys"}) -> $targetSection ($($entry.description))"
    }

    Write-Host "  Added: $addedCount, already present: $skippedCount" -ForegroundColor Green

    if ($addedCount -gt 0) {
        if ($PSCmdlet.ShouldProcess($Path, "Write patched INF")) {
            Set-Content -Path $Path -Value $lines -Encoding UTF8
        }
    }
    return $addedCount
}

$totalAdded = 0
$infsFound = 0
foreach ($prop in $whitelist.PSObject.Properties) {
    $infName = $prop.Name
    $entries = $prop.Value

    # Resolve the whitelist's INF name onto whatever this release actually calls the file. NVIDIA
    # renames them between builds (616.86 appends 'g' to every stem), and looking them up
    # literally silently applied nothing at all - see Resolve-WhitelistInf for the full story.
    $resolved = @(Resolve-WhitelistInf -DisplayDriverPath $DisplayDriverPath -InfName $infName)
    if ($resolved.Count -eq 0) {
        Write-Warning "Target contains neither $infName nor any '$([System.IO.Path]::GetFileNameWithoutExtension($infName))*.inf' variant of it - skipping ($($entries.Count) entries not applied)."
        continue
    }

    foreach ($r in $resolved) {
        if (-not $r.Exact) {
            Write-Host "  NOTE: this release has no $infName; it ships $($r.Name) instead - patching that." -ForegroundColor Yellow
        }
        $infsFound++
        $totalAdded += Patch-InfFile -Path $r.Path -Entries $entries
    }
}

# None of the whitelist's target INFs existing at all means we were pointed at something that
# isn't a Display.Driver folder, or NVIDIA renamed every INF we know about. Either way, carrying
# on would hand a completely unpatched package to the signing step.
if ($infsFound -eq 0) {
    throw "None of the INFs named in the whitelist ($(($whitelist.PSObject.Properties | ForEach-Object { $_.Name }) -join ', ')) exist under `"$DisplayDriverPath`", and no same-stem variant of them does either. Check the path points at a Display.Driver folder; if it does, this driver release has renamed them beyond a simple suffix and whitelist.json needs updating."
}

Write-Host "`nDone. Total new device/subsystem entries added: $totalAdded" -ForegroundColor Yellow
if ($totalAdded -gt 0) {
    Write-Host "Next step: regenerate + sign the catalog with Sign-DriverPackage.ps1" -ForegroundColor Yellow
}
else {
    Write-Host "Nothing added - every whitelist entry was already present. That's normal when re-running" -ForegroundColor DarkGray
    Write-Host "against an already-patched package, or if NVIDIA now whitelists these devices upstream." -ForegroundColor DarkGray
}
