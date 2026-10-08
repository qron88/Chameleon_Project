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
    1. Skips it if every [NVIDIA_Devices...] block already whitelists that exact DEV+SUBSYS
       combo (NVIDIA may add it upstream in a later release). A block that lacks it gets it, even
       if another block already has it.
    2. If another block already lists the entry, or the same DEV id appears under a different
       subsystem, reuses that line's Section (guaranteed valid/current for that chip in this
       driver version).
    3. Otherwise creates a new, uniquely-named Section by copying the section body captured from the
       reference "Franken" package, and points the new match line at it.
  Then adds the matching [Strings] description if missing. What counts as a match is decided by
  Test-InfDeviceIdMatch in PatchToolDiscovery.ps1, the same rule the verification gate applies.

.PARAMETER DisplayDriverPath
  Path to the "Display.Driver" folder of a stock NVIDIA driver package (any version).

.PARAMETER WhitelistPath
  Path to whitelist.json (defaults to the copy next to this script).

.PARAMETER PrunedInf
  Whitelist INF names (as keyed in whitelist.json) that the prune step removed on purpose. Their
  absence is reported as a note rather than a warning. The pipeline passes this; standalone use
  can leave it out.

.PARAMETER WhatIf
  Show what would change without writing files.

.EXAMPLE
  .\Add-ExtraGpuSupport.ps1 -DisplayDriverPath "D:\NVIDIA\610.xx\Display.Driver"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DisplayDriverPath,

    [string]$WhitelistPath,

    [string[]]$PrunedInf = @()
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

        # Presence is judged PER [NVIDIA_Devices...] block, with the shared matching rule the
        # verification gate also uses (Test-InfDeviceIdMatch -Mode Entry). Each block serves a
        # different OS target, so an entry NVIDIA lists in only one of them is still missing from
        # the others, and a line carrying an extra qualifier such as &REV_A1 is not the entry.
        $blocks = Find-DeviceBlocks -Lines $lines
        $lacking = @()
        $existingSection = $null
        foreach ($block in $blocks) {
            $hit = Find-InfDeviceLine -Lines $lines -Start $block.StartIndex -End $block.EndIndex -Dev $dev -Subsys $subsys -Mode Entry
            if ($hit) {
                if (-not $existingSection) { $existingSection = $hit.Parsed.Section }
            }
            else {
                $lacking += $block
            }
        }
        if ($lacking.Count -eq 0) {
            $skippedCount++
            continue
        }

        # Section to point the new line at, best first:
        #   1. the section another block already uses for this exact entry,
        #   2. the section of any line for the same chip (other subsystem, extra qualifiers) -
        #      guaranteed valid for that chip in this driver version,
        #   3. a fresh section family built from the template captured in whitelist.json.
        $targetSection = $existingSection
        if (-not $targetSection) {
            foreach ($block in $blocks) {
                $same = Find-InfDeviceLine -Lines $lines -Start $block.StartIndex -End $block.EndIndex -Dev $dev -Mode Device
                if ($same) { $targetSection = $same.Parsed.Section; break }
            }
        }
        if (-not $targetSection) {
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

        # Only the blocks that lack the entry get the line. The template sections above were
        # appended at the END of the file, so the block indices found before are still valid.
        # Insert from the bottom-most block upward so earlier indices stay valid too.
        foreach ($block in ($lacking | Sort-Object EndIndex -Descending)) {
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
        $partial = if ($lacking.Count -lt $blocks.Count) { " [added to $($lacking.Count) of $($blocks.Count) device blocks; the rest already had it]" } else { "" }
        Write-Host "  + DEV_$dev$(if($subsys){"&SUBSYS_$subsys"}) -> $targetSection ($($entry.description))$partial"
    }

    Write-Host "  Added: $addedCount, already present: $skippedCount" -ForegroundColor Green

    if ($addedCount -gt 0) {
        if ($PSCmdlet.ShouldProcess($Path, "Write patched INF")) {
            Write-InfLines -Path $Path -Lines $lines
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
        if ($PrunedInf -contains $infName) {
            Write-Host "  $infName was pruned from this package (none of its entries names hardware in this PC) - its $($entries.Count) entries do not apply." -ForegroundColor DarkGray
        }
        else {
            Write-Warning "Target contains neither $infName nor any '$([System.IO.Path]::GetFileNameWithoutExtension($infName))*.inf' variant of it - skipping ($($entries.Count) entries not applied)."
        }
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
    $allKeys = @($whitelist.PSObject.Properties | ForEach-Object { $_.Name })
    if (@($allKeys | Where-Object { $PrunedInf -notcontains $_ }).Count -eq 0) {
        throw "Every INF named in the whitelist ($($allKeys -join ', ')) was pruned from this package, because none of their entries names a GPU in this PC - there is nothing to unlock here. Build without -PruneForeignOemInfs to make a package for the machine that has the locked GPU."
    }
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
