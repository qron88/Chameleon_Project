<#
.SYNOPSIS
  Shared discovery for the external tools the patch pipeline shells out to
  (a 7z-compatible CLI, Inf2Cat.exe, signtool.exe), plus a safe native-command runner.

.DESCRIPTION
  Dot-source this from any script in this folder:

      . (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

  Provides:
    Find-SevenZip            - locate a 7z-compatible CLI
    Find-WdkTool             - locate a Windows Kits tool (Inf2Cat.exe / signtool.exe)
    Assert-PatchTools        - resolve everything up front so a missing tool fails in seconds
                               instead of after a multi-GB unpack/copy
    Invoke-NativeTool        - run a native exe and return its exit code, without letting its
                               stderr become a terminating error
    Resolve-WhitelistInf     - map a whitelist.json INF name onto the file this driver release
                               actually ships, since NVIDIA renames them between builds
    Resolve-SigningCertificate - work out which certificate to sign with, preferring a
                               passwordless key already in the certificate store
    Get-LocalNvidiaGpu       - the display-class NVIDIA GPUs in this machine, with DEV/SUBSYS
                               already parsed out
    Test-WhitelistCoversLocalGpu - whether any GPU in this machine is one whitelist.json
                               actually unlocks, which is what a pruned build depends on

  Resolution is memoized for the lifetime of the dot-sourcing script and re-validated with
  Test-Path on each hit, so an SDK that is updated or removed mid-run cannot leave a stale
  path behind. Paths are deliberately NOT persisted between runs for that same reason.
#>

$script:PatchToolCache = @{}

function Invoke-NativeTool {
    <#
      Runs a native executable and returns its exit code.

      Native-command stderr is NOT redirected here on purpose. Under Windows PowerShell 5.1
      with $ErrorActionPreference='Stop', redirecting a native command's stderr (2>&1) wraps
      each stderr line in a NativeCommandError ErrorRecord and aborts the script even when the
      exe returns 0 - that is exactly the confirmed bug the old Sign-DriverPackage.ps1 had to
      work around for `signtool verify`. ErrorActionPreference is relaxed for the duration of
      the call as a second safety net, and success/failure is decided solely by the exit code.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $FilePath @Arguments | Out-Host
        return $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Find-SevenZip {
    param([string]$ExplicitPath)

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "7z CLI not found at the path you passed: $ExplicitPath" }
        return (Resolve-Path $ExplicitPath).Path
    }

    $cacheKey = '7z'
    if ($script:PatchToolCache.ContainsKey($cacheKey)) {
        $cached = $script:PatchToolCache[$cacheKey]
        if ($cached -and (Test-Path $cached)) { return $cached }
        $script:PatchToolCache.Remove($cacheKey)
    }

    $candidates = @(
        "$env:LOCALAPPDATA\Microsoft\WindowsApps\7z.exe",
        "${env:ProgramFiles}\7-Zip\7z.exe",
        "${env:ProgramFiles(x86)}\7-Zip\7z.exe",
        "${env:ProgramFiles}\NanaZip\7z.exe"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $script:PatchToolCache[$cacheKey] = $c; return $c }
    }
    $cmd = Get-Command 7z.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:PatchToolCache[$cacheKey] = $cmd.Source; return $cmd.Source }

    throw "No 7z-compatible CLI found (checked the WindowsApps alias, 7-Zip/NanaZip under Program Files, and PATH). Install 7-Zip or NanaZip."
}

function Find-WdkTool {
    <#
      Locates a Windows Kits tool, preferring the NEWEST SDK version and, within that version,
      the x64 build when one exists (Inf2Cat.exe only ships as x86, signtool.exe ships as
      x86/x64/arm64).

      Selection is by parsed [version], not by string-sorting the full path. Older SDK layouts
      put signtool directly under bin\x64\ with no version folder, and a descending string sort
      ranks "...\bin\x64\..." above "...\bin\10.0.26100.0\x64\..." because 'x' > '1' - which on
      a machine carrying both layouts would silently select the OLDER tool. Paths with no
      parseable version segment get a sentinel 0.0 so they rank last but stay usable as a
      fallback.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$ExeName,
        [string]$ExplicitPath
    )

    if ($ExplicitPath) {
        if (-not (Test-Path $ExplicitPath)) { throw "$ExeName not found at the path you passed: $ExplicitPath" }
        return (Resolve-Path $ExplicitPath).Path
    }

    $cacheKey = "wdk:$ExeName"
    if ($script:PatchToolCache.ContainsKey($cacheKey)) {
        $cached = $script:PatchToolCache[$cacheKey]
        if ($cached -and (Test-Path $cached)) { return $cached }
        $script:PatchToolCache.Remove($cacheKey)
    }

    $roots = @()
    if ($env:WDKContentRoot) { $roots += (Join-Path $env:WDKContentRoot 'bin') }
    $roots += "${env:ProgramFiles(x86)}\Windows Kits\10\bin"
    $roots += "${env:ProgramFiles}\Windows Kits\10\bin"

    $candidates = @()
    foreach ($root in $roots) {
        if (Test-Path $root) {
            $candidates += Get-ChildItem -Path $root -Filter $ExeName -Recurse -ErrorAction SilentlyContinue
        }
    }

    if ($candidates.Count -gt 0) {
        $ranked = foreach ($c in $candidates) {
            $ver = [version]'0.0'
            if ($c.FullName -match '\\(\d+\.\d+\.\d+\.\d+)\\') {
                try { $ver = [version]$Matches[1] } catch { $ver = [version]'0.0' }
            }
            [PSCustomObject]@{
                Path    = $c.FullName
                Version = $ver
                IsX64   = [bool]($c.FullName -match '\\x64\\')
            }
        }
        $best = $ranked |
            Sort-Object -Property @{Expression = 'Version'; Descending = $true},
                                  @{Expression = 'IsX64';   Descending = $true} |
            Select-Object -First 1
        if ($best) {
            $script:PatchToolCache[$cacheKey] = $best.Path
            return $best.Path
        }
    }

    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { $script:PatchToolCache[$cacheKey] = $cmd.Source; return $cmd.Source }

    throw "$ExeName not found under Windows Kits (checked `$env:WDKContentRoot, Program Files (x86)/Program Files Windows Kits\10\bin, and PATH). Install the Windows Driver Kit / SDK, or pass an explicit path."
}

function Assert-PatchTools {
    <#
      Resolves every external tool a run will need BEFORE any unpacking/copying happens, so a
      missing SDK fails in seconds rather than after a multi-GB extraction. Returns a hashtable
      of the resolved paths.
    #>
    param(
        [switch]$NeedSevenZip,
        [string]$SevenZipPath,
        [string]$Inf2CatPath,
        [string]$SignToolPath
    )

    $resolved = @{}
    if ($NeedSevenZip) {
        $resolved['SevenZip'] = Find-SevenZip -ExplicitPath $SevenZipPath
    }
    $resolved['Inf2Cat']  = Find-WdkTool -ExeName 'Inf2Cat.exe'  -ExplicitPath $Inf2CatPath
    $resolved['SignTool'] = Find-WdkTool -ExeName 'signtool.exe' -ExplicitPath $SignToolPath
    return $resolved
}

function Get-LocalNvidiaGpu {
    <#
      Every NVIDIA GPU in this machine, as objects carrying the DeviceID, the friendly name, and
      the DEV/SUBSYS already parsed out and upper-cased.

      Display-class only. An NVIDIA GPU also exposes an HD Audio function on the same PCI device
      (e.g. DEV_2291 alongside DEV_25B8), driven by HDAudBus and the HDAudio subpackage, never by
      a display INF - so including it would just produce a device that matches nothing and a
      pointless warning.

      $WhatIfPreference is forced off around the read. Get-CimInstance has no -WhatIf of its own,
      but under -WhatIf the CimCmdlets module autoloads with the preference set and reports a
      dozen "What if: Set Alias" lines, burying the actual dry-run output.

      -AllowNonDisplayFallback keeps NVIDIA PCI devices that report no Display class when NONE of
      them does, on the theory that a machine with an NVIDIA device and an odd PNPClass is better
      served by a guess than by "no GPU found". Callers that only want a label pass it off, so a
      stray audio function can never end up named in an output folder.
    #>
    param([switch]$AllowNonDisplayFallback)

    $prevWhatIf = $WhatIfPreference
    $WhatIfPreference = $false
    try {
        $pnp = @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue |
                 Where-Object { $_.DeviceID -like 'PCI\VEN_10DE*' })
    }
    catch { $pnp = @() }
    finally { $WhatIfPreference = $prevWhatIf }

    $display = @($pnp | Where-Object { $_.PNPClass -eq 'Display' -or $_.Service -eq 'nvlddmkm' })
    if ($display.Count -eq 0 -and $pnp.Count -gt 0 -and $AllowNonDisplayFallback) {
        Write-Warning "Found NVIDIA PCI devices but none of Display class - falling back to all of them."
        $display = $pnp
    }

    return @($display | ForEach-Object {
        $dev = $null; $sub = $null
        if ($_.DeviceID -match 'DEV_([0-9A-Fa-f]{4})')    { $dev = $Matches[1].ToUpperInvariant() }
        if ($_.DeviceID -match 'SUBSYS_([0-9A-Fa-f]{8})') { $sub = $Matches[1].ToUpperInvariant() }
        [PSCustomObject]@{
            DeviceID = $_.DeviceID
            Name     = $_.Name
            Dev      = $dev
            Subsys   = $sub
            Label    = $(
                $id = "DEV_$dev"
                if ($sub) { $id += "&SUBSYS_$sub" }
                if ($_.Name) { "$($_.Name) ($id)" } else { $id }
            )
        }
    } | Where-Object { $_.Dev })
}

function Test-WhitelistCoversLocalGpu {
    <#
      Is any GPU in this machine one that whitelist.json actually unlocks?

      This is the question a PRUNED build turns on. Pruning cuts the package down to the INFs that
      can match this machine, so if none of this machine's GPUs is a whitelist target, what comes
      out is a driver for hardware that never needed unlocking: the whitelist entries are spliced
      into an INF where nothing present can match them, and the package is then re-signed with a
      certificate Windows does not trust. Confirmed on a box with an RTX 5070 Ti (DEV_2C05), which
      the stock generic INF already carries a bare DEV line for - the run completed, reported
      "verification PASSED", and had unlocked nothing.

      A UNIVERSAL build is a different question and this must not be applied to it. There the
      whole package is kept, every whitelist entry lands in it, and the machine doing the building
      is irrelevant - patching on a 5070 Ti box for a laptop with a locked GPU is a perfectly
      ordinary thing to do.

      Coverage follows the same rule as the prune step: a whitelist entry with no subsystem covers
      every subsystem of that device, otherwise both halves must match.

      Detected=$false means no GPU could be read at all (no NVIDIA device, a WMI failure, a
      driverless PCI device). That is NOT the same as "not a target" and callers must not treat it
      as one - there is simply nothing to judge.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$WhitelistPath
    )

    if (-not (Test-Path $WhitelistPath)) { throw "whitelist.json not found: $WhitelistPath" }
    $whitelist = Get-Content $WhitelistPath -Raw | ConvertFrom-Json

    $gpus = @(Get-LocalNvidiaGpu -AllowNonDisplayFallback)
    # Plain arrays, not List[object]: a machine has a handful of GPUs so += costs nothing, and
    # under Windows PowerShell 5.1 `[PSCustomObject]@{ K = @($list) }` throws "argument types do
    # not match" for a generic List, which is a needlessly obscure way to fail.
    $covered = @()
    $uncovered = @()
    $entryCount = 0

    foreach ($key in $whitelist.PSObject.Properties.Name) {
        $entryCount += @($whitelist.$key).Count
    }

    foreach ($g in $gpus) {
        $hit = $null
        foreach ($key in $whitelist.PSObject.Properties.Name) {
            foreach ($e in $whitelist.$key) {
                if ($e.dev -ne $g.Dev) { continue }
                if ((-not $e.subsys) -or ($g.Subsys -and $e.subsys -eq $g.Subsys)) {
                    $hit = "DEV_$($e.dev)"
                    if ($e.subsys) { $hit += "&SUBSYS_$($e.subsys)" }
                    if ($e.description) { $hit += " ($($e.description))" }
                    break
                }
            }
            if ($hit) { break }
        }
        if ($hit) { $covered   += [PSCustomObject]@{ Gpu = $g; Entry = $hit } }
        else      { $uncovered += $g }
    }

    return [PSCustomObject]@{
        Detected      = ($gpus.Count -gt 0)
        Gpus          = $gpus
        Covered       = $covered
        Uncovered     = $uncovered
        AnyCovered    = ($covered.Count -gt 0)
        EntryCount    = $entryCount
        WhitelistPath = $WhitelistPath
    }
}

function Get-LocalGpuTag {
    <#
      A short, filesystem-safe tag naming the GPU(s) in this machine, for labelling a pruned
      output folder: "RTX-A2000m", or "RTX-5070-Ti+RTX-A2000m" on a multi-GPU box.

      A pruned package only installs on the hardware it was built for, so the folder name is the
      only thing distinguishing it from a universal build once you have a few of them side by
      side. Falls back to the device IDs if the friendly names are unusable, and to "ThisPC" if
      no GPU can be read at all - the tag is a label, so it must never be the reason a run fails.

      This is the single source of truth for that tag. The pipeline calls it for the default
      output path, and the GUI gets the same answer by asking the pipeline with -ShowOutputPath
      rather than reimplementing the rule.
    #>
    param([int]$MaxLength = 40)

    $names = @()
    try {
        # No -AllowNonDisplayFallback: a tag is a label, and labelling a folder after the GPU's
        # HD Audio function would be worse than the "ThisPC" fallback below.
        foreach ($d in @(Get-LocalNvidiaGpu)) {
            $n = $d.Name
            if (-not $n) { $n = "DEV" + $d.Dev }
            if (-not $n) { continue }
            # "NVIDIA RTX A2000m" -> "RTX-A2000m"
            $n = $n -replace '(?i)^\s*NVIDIA\s+', ''
            $n = $n -replace '(?i)\((R|TM)\)', ''
            $n = $n -replace '[^A-Za-z0-9]+', '-'
            $n = $n.Trim('-')
            if ($n) { $names += $n }
        }
    }
    catch { }

    $names = @($names | Select-Object -Unique)
    if ($names.Count -eq 0) { return "ThisPC" }

    $tag = $names -join '+'
    if ($tag.Length -gt $MaxLength) {
        # Too long to be a sensible folder name: fall back to the first GPU, then to a plain label.
        $tag = $names[0]
        if ($tag.Length -gt $MaxLength) { $tag = $tag.Substring(0, $MaxLength).Trim('-') }
        if (-not $tag) { $tag = "ThisPC" }
    }
    return $tag
}

function Resolve-WhitelistInf {
    <#
      Maps a whitelist.json key (an INF filename) to the actual file(s) in a Display.Driver folder.

      NVIDIA does not keep INF filenames stable between builds. The 616.86 desktop-notebook hotfix
      appends a 'g' to every stem - nv_dispi.inf becomes nv_dispig.inf, nvami.inf becomes
      nvamig.inf, uniformly across all 43 INFs. Looking the names up literally made the whitelist
      step skip both target INFs and apply nothing at all, while the RM-override step (which globs
      *.inf and so never cared about names) still ran. The package therefore came out installable,
      correctly signed, and with no GPU unlock whatsoever.

      This deliberately is NOT a "notebook builds use g" rule. The 581.94 desktop-notebook hotfix
      uses the ordinary names, so the suffix is a per-build quirk, not a flavour convention, and
      hardcoding it would just fail differently on the next release.

      Nor is the quirk always an APPENDED letter, which is what a plain "<stem>*.inf" glob assumes.
      The 616.92 Studio build (nsd-dch) renames by replacing the trailing flavour letter instead:
      nv_dispi.inf ships as nv_dispsi.inf and nvami.inf as nvamsi.inf, uniformly across all 45.
      Neither starts with "nv_dispi" / "nvami", so the glob matched nothing, and the failure was
      worse than 616.86's: the prune step's own fallback resolves through this function too, so it
      kept zero INFs and deleted all 45 before the whitelist step threw.

      So the lookup runs widest-last, in three tiers:
        1. An exact filename match always wins.
        2. "<stem>*.inf"  - the suffixed case (616.86).
        3. "<stem minus its last character>*.inf" - the substituted-letter case (616.92). Gated on
           a core of at least 4 characters so a short stem can never widen to something like n*.inf.
      Tier 3 only runs when the tighter tiers found nothing, so a release using the ordinary names
      never reaches it. Callers report which file stood in for the requested name rather than
      substituting silently.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$DisplayDriverPath,
        [Parameter(Mandatory = $true)][string]$InfName
    )

    $exact = Join-Path $DisplayDriverPath $InfName
    if (Test-Path $exact) {
        return @([PSCustomObject]@{ Path = (Resolve-Path $exact).Path; Name = $InfName; Exact = $true })
    }

    $stem = [System.IO.Path]::GetFileNameWithoutExtension($InfName)

    # Tier 2, then tier 3. Not $matches - that is an automatic variable populated by -match.
    $globs = @($stem)
    if ($stem.Length -ge 5) { $globs += $stem.Substring(0, $stem.Length - 1) }

    foreach ($g in $globs) {
        $hits = @(Get-ChildItem -LiteralPath $DisplayDriverPath -Filter ($g + '*.inf') -File -ErrorAction SilentlyContinue |
                  Sort-Object Name)
        if ($hits.Count -eq 0) { continue }
        return @($hits | ForEach-Object {
            [PSCustomObject]@{ Path = $_.FullName; Name = $_.Name; Exact = $false }
        })
    }
    return @()
}

function Resolve-SigningCertificate {
    <#
      Works out WHICH certificate this run will sign with, and whether it can be used
      passwordlessly.

      Order of preference:
        1. An explicit thumbprint.
        2. A public .cer whose matching private key is already in Cert:\CurrentUser\My. Reading
           a .cer needs no password at all, so this is what turns a normal re-run into a
           zero-prompt one: New-SelfSignedCertificate always leaves the key in that store, so on
           the machine that generated the cert the .pfx password is simply not needed to sign.
        3. Nothing - caller falls back to a .pfx + password, or generates a fresh cert.

      Returns $null when no usable store certificate was found.
    #>
    param(
        [string]$Thumbprint,
        [string[]]$CerPathCandidates = @()
    )

    if ($Thumbprint) {
        $tp = ($Thumbprint -replace '[^0-9A-Fa-f]', '').ToUpperInvariant()
        $hit = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $tp -and $_.HasPrivateKey } |
            Select-Object -First 1
        if (-not $hit) {
            throw "No certificate with thumbprint $tp (and an available private key) was found in Cert:\CurrentUser\My. Import its .pfx first (Import-PfxCertificate), or pass -PfxPath with its password instead."
        }
        return $hit
    }

    foreach ($cer in $CerPathCandidates) {
        if (-not $cer) { continue }
        if (-not (Test-Path $cer)) { continue }
        try {
            $pub = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cer
        }
        catch { continue }
        $hit = Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Thumbprint -eq $pub.Thumbprint -and
                $_.HasPrivateKey -and
                $_.NotAfter -gt (Get-Date)
            } |
            Select-Object -First 1
        if ($hit) { return $hit }
    }

    return $null
}
