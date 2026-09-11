<#
.SYNOPSIS
  Adds the RM1457588 registry override to every nv_miscBase_addreg__* section across all driver
  INFs, so newly-whitelisted GPUs get full capability reporting (correct VRAM size, compute/CUDA,
  NVENC, etc.) instead of installing with restricted functionality.

.DESCRIPTION
  Root cause (found by diffing the reference "Franken" package against stock NVIDIA INFs at the
  AddReg-section level, not just the device-ID whitelist level - device-ID diffing alone missed
  this entirely): NVIDIA's driver does a SECOND, internal Resource-Manager-level hardware
  validation check beyond the INF's PCI device/subsystem ID whitelist that Add-ExtraGpuSupport.ps1
  patches. A device can pass the INF-level check (so the driver installs and the device shows up
  fine) and still fail this deeper RM-level check, which manifests as incorrect VRAM size
  reporting and disabled/broken compute paths (CUDA, NVENC, OptiX, etc.) - exactly the reported
  symptom. This also explains why installing the Franken driver first, then this patched driver
  over it, "fixes" it: Franken's installer writes this registry value once during its own
  install, and a driver *update* over an already-installed device does not necessarily clear
  leftover per-device registry values the new INF doesn't mention - so the override silently
  carries over from the earlier install. A clean install has no such leftover value, so the
  restriction stays in effect.

  The reference Franken package adds `HKR,,RM1457588,%REG_DWORD%,1` to a handful of specific
  nv_miscBase_addreg__NN sections per INF - whichever ones happen to be referenced by the exact
  Sections its author patched for their own specific device unlocks.

  NVIDIA SHIPS THIS OVERRIDE THEMSELVES, which is what makes this more than a guess. In the stock
  595.79 package, nvmsoai.inf (an MSI OEM INF) carries HKR,,RM1457588,%REG_DWORD%,1 in BOTH of its
  two nv_miscBase_addreg__NN sections - i.e. in all of them. It is the only stock INF that has it,
  and the key name also appears inside nvlddmkm.sys and the gsp_*.bin GSP firmware images,
  confirming the driver genuinely reads it. NVIDIA's own use is exactly the case this project
  needs: an OEM-specific INF enabling full capability on hardware the generic desktop INF
  restricts. (An earlier version of this comment claimed stock INFs never contain the key. That
  was wrong.)

  This script adds it to
  EVERY nv_miscBase_addreg__* section in EVERY driver INF that has one, rather than trying to
  resolve which specific sections each of the 61 whitelist.json entries' target Section
  references - that resolution is fragile across INF section renumbering between driver versions,
  and Franken's own narrow selection may not even cover all 61 entries, only whichever hardware
  its author personally owned to test with. This key reads as a validation-bypass style override
  with no observed effect on hardware that already passes the check on its own, so applying it
  broadly is the safer and more complete fix.

.PARAMETER DisplayDriverPath
  Path to the (already whitelist-patched) Display.Driver folder.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DisplayDriverPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $DisplayDriverPath)) { throw "Path not found: $DisplayDriverPath" }

$RmKeyLine = "HKR,,RM1457588,%REG_DWORD%,1"
$totalPatched = 0
$totalFiles = 0
$infsWithMiscSections = 0
$infsSeen = 0

Get-ChildItem -Path $DisplayDriverPath -Filter "*.inf" | ForEach-Object {
    $path = $_.FullName
    $lines = [System.Collections.Generic.List[string]](Get-Content -Path $path -Encoding UTF8)

    $miscHeaderIdx = New-Object System.Collections.Generic.List[int]
    $allHeaderIdx = New-Object System.Collections.Generic.List[int]
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^\[.+\]\s*$') {
            $allHeaderIdx.Add($i)
            if ($lines[$i] -match '^\[nv_miscBase_addreg__\d+\]\s*$') {
                $miscHeaderIdx.Add($i)
            }
        }
    }
    $infsSeen++
    if ($miscHeaderIdx.Count -eq 0) { return }
    $infsWithMiscSections++

    $patchedHere = 0
    # Process bottom-up so each Insert() doesn't invalidate the indices still queued above it.
    foreach ($hIdx in ($miscHeaderIdx | Sort-Object -Descending)) {
        $nextHeader = $allHeaderIdx | Where-Object { $_ -gt $hIdx } | Sort-Object | Select-Object -First 1
        $endIdx = if ($nextHeader) { $nextHeader } else { $lines.Count }

        $bodyHasKey = $false
        for ($j = $hIdx + 1; $j -lt $endIdx; $j++) {
            if ($lines[$j] -match 'RM1457588') { $bodyHasKey = $true; break }
        }
        if ($bodyHasKey) { continue }

        $insertAt = $endIdx
        while ($insertAt -gt $hIdx + 1 -and $lines[$insertAt - 1].Trim() -eq '') { $insertAt-- }
        $lines.Insert($insertAt, $RmKeyLine)
        $patchedHere++
    }

    if ($patchedHere -gt 0) {
        Set-Content -Path $path -Value $lines -Encoding UTF8
        Write-Host ("  {0}: added RM1457588 to {1} section(s)" -f $_.Name, $patchedHere)
        $totalPatched += $patchedHere
        $totalFiles++
    }
}

# A package where NOT ONE INF has an [nv_miscBase_addreg__NN] section is not a package this script
# understands. Silently doing nothing here used to be indistinguishable from success, and the
# consequence is specific and invisible until much later: the driver installs, the device shows
# up, and VRAM size plus compute are quietly wrong.
if ($infsSeen -eq 0) {
    throw "No .inf files found under `"$DisplayDriverPath`" - check the path points at a Display.Driver folder."
}
if ($infsWithMiscSections -eq 0) {
    throw "None of the $infsSeen INF(s) under `"$DisplayDriverPath`" contain an [nv_miscBase_addreg__NN] section, so the RM1457588 override could not be applied anywhere. This driver release's INF layout differs from what this script understands - inspect the files and update the matching pattern rather than shipping a package whose VRAM size and compute will be wrong."
}

Write-Host "Done. Added RM1457588 override to $totalPatched section(s) across $totalFiles INF file(s)." -ForegroundColor Green
if ($totalPatched -eq 0) {
    Write-Host "Nothing added - all $infsWithMiscSections INF(s) with such sections already carried the override." -ForegroundColor DarkGray
}
