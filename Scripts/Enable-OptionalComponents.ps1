<#
.SYNOPSIS
  Makes PhysX and the NVIDIA App offered-and-tickable for the GPUs this toolkit unlocks, instead
  of being silently dropped by the installer.

.DESCRIPTION
  Whether setup.exe offers "PhysX System Software" and the NVIDIA App is not a fixed property of
  the installer. Both are gated by constraints in setup.cfg that read per-device feature flags out
  of the driver INF:

    Display.PhysX  <property name="Display.Driver!Feature.Physx" level="silent" .../>
    Display.NvApp  a CheckIfInfSupported / CheckIfGPUIsSupported constraint set

  Those flags are the INF's own `NVSupportPhysx = 1` and `NVSupportGFExperienceUDA = 1` lines,
  written per device install section. NVIDIA varies them by GPU family - in stock 616.64's main
  INF only 55 of 105 install sections carry the PhysX flag and only 28 carry the App flag - which
  is exactly why the installer offers these components on some hardware and not others. Because
  the constraints are `level="silent"`, a GPU without the flag makes the component vanish with no
  message at all.

  This script makes the flags consistent for the devices in whitelist.json. It resolves each
  whitelisted device line to the install Section it points at, and ensures that Section carries
  both flags.

  WHY IT EDITS SECTIONS IN PLACE. Most whitelisted devices get a freshly spliced
  SectionExtraGPU* section, and the captured template already contains both flags, so nothing
  needs doing there. A handful of entries instead REUSE an existing stock section, because
  Add-ExtraGpuSupport.ps1 prefers a section already valid for that chip in this driver version
  over a template captured from an older one. Measured on 616.64 and 616.86, every such section is
  referenced only by the very GPU family being unlocked, so adding a flag there does not spill
  onto unrelated hardware. The script prints how many device lines share each section it touches,
  so if a future release breaks that assumption you will see it rather than discover it later.

  It does NOT remove the setup.cfg constraints. Deleting those would force the components on for
  every GPU including ones NVIDIA flagged as unsupported, which is a much broader change than
  making the unlocked GPUs behave like first-class ones.

.PARAMETER PackageRoot
  Root of the patched package. Must contain setup.cfg and Display.Driver.

.PARAMETER WhitelistPath
  Defaults to whitelist.json next to this script.

.PARAMETER Flags
  The INF feature flags to ensure. Defaults to the PhysX and NVIDIA App ones.

.PARAMETER SkipInstallerSelectable
  Leave setup.cfg alone. The INF flags are still applied, but the NVIDIA App stays locked on
  rather than becoming a row the user can untick.

.EXAMPLE
  .\Enable-OptionalComponents.ps1 -PackageRoot "610.88_Patched"
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$PackageRoot,

    [string]$WhitelistPath,

    [string[]]$Flags = @('NVSupportPhysx', 'NVSupportGFExperienceUDA'),

    [switch]$SkipInstallerSelectable
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not $WhitelistPath) { $WhitelistPath = Join-Path $PSScriptRoot "whitelist.json" }
if (-not (Test-Path $WhitelistPath)) { throw "whitelist.json not found: $WhitelistPath" }

$displayDriver = Join-Path $PackageRoot "Display.Driver"
$setupCfg      = Join-Path $PackageRoot "setup.cfg"
if (-not (Test-Path $displayDriver)) { throw "Display.Driver not found under $PackageRoot" }

$whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

# --- 1. INF feature flags -----------------------------------------------------------------------
$totalAdded = 0
$sectionsTouched = 0
$infsSeen = 0

foreach ($key in $whitelist.PSObject.Properties.Name) {
    $entries = $whitelist.$key
    $resolved = @(Resolve-WhitelistInf -DisplayDriverPath $displayDriver -InfName $key)
    if ($resolved.Count -eq 0) {
        Write-Warning "Neither $key nor a same-stem variant is present - skipping its $($entries.Count) entries."
        continue
    }

    foreach ($r in $resolved) {
        $infsSeen++
        $lines = [System.Collections.Generic.List[string]](Get-Content -Path $r.Path -Encoding UTF8)

        # Index section bounds, and count how many device lines point at each section.
        $bounds = @{}
        $usage  = @{}
        $current = $null
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*\[([^\]]+)\]\s*$') {
                if ($current) { $bounds[$current].End = $i }
                $current = $Matches[1].Trim()
                if (-not $bounds.ContainsKey($current)) {
                    $bounds[$current] = [PSCustomObject]@{ Start = $i; End = $lines.Count }
                }
                continue
            }
            if ($lines[$i] -match '=\s*([^,]+?)\s*,\s*PCI\\VEN_10DE&DEV_') {
                $t = $Matches[1].Trim()
                if (-not $usage.ContainsKey($t)) { $usage[$t] = 0 }
                $usage[$t]++
            }
        }
        if ($current) { $bounds[$current].End = $lines.Count }

        # Which sections do the whitelisted devices actually point at?
        $targets = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($e in $entries) {
            if ($e.subsys) {
                $pat = '^\s*%[^%]+%\s*=\s*([^,]+?)\s*,\s*PCI\\VEN_10DE&DEV_' + [regex]::Escape($e.dev) + '&SUBSYS_' + [regex]::Escape($e.subsys) + '\s*$'
            }
            else {
                $pat = '^\s*%[^%]+%\s*=\s*([^,]+?)\s*,\s*PCI\\VEN_10DE&DEV_' + [regex]::Escape($e.dev) + '\s*$'
            }
            foreach ($l in $lines) {
                if ($l -match $pat) { [void]$targets.Add($Matches[1].Trim()); break }
            }
        }

        if ($targets.Count -eq 0) {
            Write-Warning "$($r.Name): none of the whitelisted devices are present. Run Add-ExtraGpuSupport.ps1 first."
            continue
        }

        Write-Host "`n=== $($r.Name) ===" -ForegroundColor Cyan
        Write-Host ("  $($targets.Count) install section(s) referenced by whitelisted devices")

        # Insert bottom-up so earlier indices stay valid.
        $ordered = @($targets | Where-Object { $bounds.ContainsKey($_) } |
                     Sort-Object -Property @{Expression = { $bounds[$_].Start }} -Descending)
        foreach ($t in @($targets | Where-Object { -not $bounds.ContainsKey($_) })) {
            Write-Warning "$($r.Name): device line points at [$t] but no such section exists - skipping."
        }

        $addedHere = 0
        foreach ($t in $ordered) {
            $start = $bounds[$t].Start
            $end   = $bounds[$t].End

            $missing = @()
            foreach ($f in $Flags) {
                $have = $false
                for ($j = $start + 1; $j -lt $end; $j++) {
                    if ($lines[$j] -match ('^\s*' + [regex]::Escape($f) + '\s*=')) { $have = $true; break }
                }
                if (-not $have) { $missing += $f }
            }
            if ($missing.Count -eq 0) { continue }

            $insertAt = $end
            while ($insertAt -gt $start + 1 -and $lines[$insertAt - 1].Trim() -eq '') { $insertAt-- }
            foreach ($f in $missing) { $lines.Insert($insertAt, "$f = 1") }

            $shared = 0
            if ($usage.ContainsKey($t)) { $shared = $usage[$t] }
            Write-Host ("  + [$t] gained " + ($missing -join ', ') + "   (section referenced by $shared device line(s))")
            $addedHere += $missing.Count
            $sectionsTouched++
        }

        if ($addedHere -gt 0) {
            if ($PSCmdlet.ShouldProcess($r.Path, "Write component feature flags")) {
                Set-Content -Path $r.Path -Value $lines -Encoding UTF8
            }
            $totalAdded += $addedHere
        }
        else {
            Write-Host "  all referenced sections already carry every flag - nothing to do" -ForegroundColor DarkGray
        }
    }
}

if ($infsSeen -eq 0) {
    throw "None of the whitelist's INFs (or same-stem variants) exist under `"$displayDriver`" - check the path, or run Add-ExtraGpuSupport.ps1 first."
}

Write-Host ""
Write-Host "Added $totalAdded flag line(s) across $sectionsTouched section(s)." -ForegroundColor Green

# --- 2. Let the user untick the NVIDIA App ------------------------------------------------------
# Display.NvApp ships disposition="default" userSelectable="false": pre-ticked and locked. PhysX
# is already disposition="default" with no userSelectable restriction, so it needs nothing here -
# once its feature flag is set it appears pre-ticked and can be unticked like any other row.
if (-not $SkipInstallerSelectable) {
    if (-not (Test-Path $setupCfg)) {
        Write-Warning "setup.cfg not found under $PackageRoot - skipping the NVIDIA App selectability change."
    }
    else {
        $cfg = Get-Content $setupCfg -Raw -Encoding UTF8
        $rx = [regex]'(?<open><sub-package\b[^>]*?\bname\s*=\s*"Display\.NvApp"[^>]*?>)'
        $m = $rx.Match($cfg)
        if (-not $m.Success) {
            Write-Warning "Could not find the Display.NvApp sub-package in setup.cfg - leaving it alone. The INF flags above still apply."
        }
        else {
            $open = $m.Groups['open'].Value
            if ($open -match 'userSelectable\s*=\s*"true"') {
                Write-Host "NVIDIA App is already user-selectable in setup.cfg - nothing to do." -ForegroundColor DarkGray
            }
            else {
                if ($open -match 'userSelectable\s*=\s*"[^"]*"') {
                    $newOpen = [regex]::Replace($open, 'userSelectable\s*=\s*"[^"]*"', 'userSelectable="true"')
                }
                else {
                    # No such attribute: add it just before the closing bracket.
                    $newOpen = $open -replace '\s*>$', ' userSelectable="true">'
                }
                if ($PSCmdlet.ShouldProcess($setupCfg, "Make Display.NvApp user-selectable")) {
                    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
                    [System.IO.File]::WriteAllText($setupCfg, $cfg.Remove($m.Index, $open.Length).Insert($m.Index, $newOpen), $utf8NoBom)

                    # Verify structurally rather than trusting the replace.
                    try { $xml = [xml](Get-Content $setupCfg -Raw -Encoding UTF8) }
                    catch { throw "setup.cfg is no longer valid XML after the edit - restore from source. $_" }
                    $node = @($xml.GetElementsByTagName('sub-package')) | Where-Object { $_.name -eq 'Display.NvApp' } | Select-Object -First 1
                    if (-not $node) { throw "setup.cfg parses but Display.NvApp is gone - restore from source." }
                    if ($node.userSelectable -ne 'true') { throw "Display.NvApp userSelectable is '$($node.userSelectable)', expected 'true'." }
                    Write-Host "NVIDIA App is now a row the user can untick (disposition stays 'default', so it starts ticked)." -ForegroundColor Green
                }
            }
        }
    }
}

Write-Host ""
Write-Host "PhysX and the NVIDIA App will now be offered for the whitelisted GPUs, both ticked by" -ForegroundColor Green
Write-Host "default and both possible to untick under Custom Installation Options." -ForegroundColor Green
Write-Host "Not verified through a real install - confirm on your own hardware." -ForegroundColor Yellow
