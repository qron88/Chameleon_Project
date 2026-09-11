<#
.SYNOPSIS
  Lists and removes driver-patch signing certificates from this machine's certificate stores -
  the counterpart to Approve-DriverPatchCert.ps1.

.DESCRIPTION
  Every run of New-DriverSigningCert.ps1 mints a new certificate, and every run of
  Approve-DriverPatchCert.ps1 trusts one machine-wide. Nothing ever removed them, so repeated use
  leaves a growing pile of self-signed trusted roots, each of which can sign ANY code (kernel
  drivers included) that this machine will then accept. This script is how you get that back down
  to the one certificate you actually use.

  It is read-only until you ask it to remove something. With no -Thumbprint and no -AllPatchCerts
  it just prints an inventory.

  Stores inspected:
    Root, CA, TrustedPublisher   - trust. Removing an entry here withdraws trust.
    My                           - your own cert+key pairs. Only touched with -IncludePrivateKeys.

  A CurrentUser trust store is a MERGED VIEW: it lists that user's own entries plus everything
  inherited from the matching LocalMachine store. An inherited entry cannot be deleted through the
  user view (the attempt fails with access-denied, even elevated) - it has to be removed from
  LocalMachine. This script detects that case, skips it, and prints the elevated command to run
  instead, so "present in CurrentUser\Root" does not mean "removable from CurrentUser\Root".

  IMPORTANT: withdrawing trust from a certificate means catalogs it signed stop validating, so an
  already-patched driver package signed by that certificate can no longer be installed (an
  already-INSTALLED driver keeps running). Run with no arguments first, see what signed what, and
  use -KeepThumbprint to protect the certificate you still sign with.

.PARAMETER Thumbprint
  Remove exactly these certificates, wherever they appear in the inspected stores.

.PARAMETER AllPatchCerts
  Remove every certificate whose subject matches -SubjectPattern, except those in -KeepThumbprint.

.PARAMETER KeepThumbprint
  Thumbprints to protect when using -AllPatchCerts.

.PARAMETER SubjectPattern
  Wildcard patterns identifying "patch" certificates. Defaults cover the project's current name,
  the older "Local NVIDIA Driver Patch" name, and the hand-patched "FrankenDriver" certificates,
  so a store holding certificates from several eras is still fully inventoried.

.PARAMETER Scope
  Which store location(s) to act on. LocalMachine needs an elevated session.

.PARAMETER IncludePrivateKeys
  Also remove matching cert+key pairs from Cert:\CurrentUser\My. Irreversible for a
  non-exportable key: you cannot sign with that certificate again afterwards.

.EXAMPLE
  .\Remove-DriverPatchCert.ps1
  Inventory only - shows every patch certificate and which stores it sits in.

.EXAMPLE
  .\Remove-DriverPatchCert.ps1 -AllPatchCerts -KeepThumbprint 2A4A4A0C6666E4CD1E59E04CBF4EAFCB06843EA8
  Prune every patch certificate except the one you currently sign with.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string[]]$Thumbprint,

    [switch]$AllPatchCerts,

    [string[]]$KeepThumbprint = @(),

    # Must cover every name this project has ever issued certificates under, or a renamed
    # certificate becomes invisible to the very tool meant to clean it up, and quietly
    # accumulates as an untracked trusted root. '*Chameleon*' is the current name,
    # '*Driver Patch*' the previous one, '*FrankenDriver*' the hand-patched package this was
    # reverse-engineered from. Add to this list rather than replacing it.
    [string[]]$SubjectPattern = @('*Chameleon*', '*Driver Patch*', '*FrankenDriver*'),

    [ValidateSet('CurrentUser', 'LocalMachine', 'Both')]
    [string]$Scope = 'Both',

    [switch]$IncludePrivateKeys
)

$ErrorActionPreference = 'Stop'

$trustStores = @('Root', 'CA', 'TrustedPublisher')
$locations = switch ($Scope) {
    'CurrentUser'  { @('CurrentUser') }
    'LocalMachine' { @('LocalMachine') }
    default        { @('CurrentUser', 'LocalMachine') }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

function Get-StoreEntries {
    param([string]$Location, [string]$StoreName)
    $result = @()
    try {
        $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($StoreName, $Location)
        $st.Open('ReadOnly')
        foreach ($c in @($st.Certificates)) {
            $result += [PSCustomObject]@{
                Location   = $Location
                StoreName  = $StoreName
                Subject    = $c.Subject
                Thumbprint = $c.Thumbprint
                NotAfter   = $c.NotAfter
                HasKey     = $c.HasPrivateKey
                Cert       = $c
            }
        }
        $st.Close()
    }
    catch {
        Write-Verbose "Could not read $Location\$StoreName : $($_.Exception.Message)"
    }
    return $result
}

function Test-SubjectMatch {
    param([string]$Subject)
    foreach ($p in $SubjectPattern) { if ($Subject -like $p) { return $true } }
    return $false
}

# --- Inventory --------------------------------------------------------------------------------
$storesToScan = $trustStores
if ($IncludePrivateKeys -or (-not $Thumbprint -and -not $AllPatchCerts)) { $storesToScan = $trustStores + 'My' }

$all = @()
foreach ($loc in $locations) {
    foreach ($sn in $storesToScan) {
        $all += Get-StoreEntries -Location $loc -StoreName $sn
    }
}
$patch = @($all | Where-Object { Test-SubjectMatch $_.Subject })

if ($patch.Count -eq 0) {
    Write-Host "No patch certificates found in $($locations -join '/') stores." -ForegroundColor Green
    return
}

Write-Host "Patch certificates currently present:" -ForegroundColor Cyan
$patch | Group-Object Thumbprint | Sort-Object Name | ForEach-Object {
    $first = $_.Group[0]
    $where = ($_.Group | ForEach-Object { "$($_.Location)\$($_.StoreName)" } | Sort-Object) -join ', '
    $keyNote = if ($_.Group | Where-Object { $_.StoreName -eq 'My' -and $_.HasKey }) { '  [has private key]' } else { '' }
    Write-Host ""
    Write-Host ("  " + $first.Thumbprint + $keyNote) -ForegroundColor White
    Write-Host ("    subject: " + $first.Subject)
    Write-Host ("    expires: " + $first.NotAfter)
    Write-Host ("    in:      " + $where)
}
Write-Host ""
Write-Host ("Total: " + ($patch | Group-Object Thumbprint).Count + " distinct certificate(s), " + $patch.Count + " store entr(y/ies).") -ForegroundColor Cyan

# --- Decide what to remove --------------------------------------------------------------------
if (-not $Thumbprint -and -not $AllPatchCerts) {
    Write-Host ""
    Write-Host "Inventory only - nothing removed. To prune, re-run with either:" -ForegroundColor Yellow
    Write-Host "  -Thumbprint <thumb>[,<thumb>]"
    Write-Host "  -AllPatchCerts -KeepThumbprint <the one you still sign with>"
    return
}

$normalizedKeep = @($KeepThumbprint | ForEach-Object { ($_ -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() })

if ($AllPatchCerts) {
    $targets = @($patch | Where-Object { $normalizedKeep -notcontains $_.Thumbprint })
}
else {
    $normalizedWanted = @($Thumbprint | ForEach-Object { ($_ -replace '[^0-9A-Fa-f]', '').ToUpperInvariant() })
    $targets = @($patch | Where-Object { $normalizedWanted -contains $_.Thumbprint })
    $notFound = @($normalizedWanted | Where-Object { $t = $_; -not ($patch | Where-Object { $_.Thumbprint -eq $t }) })
    foreach ($nf in $notFound) { Write-Warning "Not present in any inspected store: $nf" }
}

if (-not $IncludePrivateKeys) {
    $targets = @($targets | Where-Object { $_.StoreName -ne 'My' })
}

if ($targets.Count -eq 0) {
    Write-Host ""
    Write-Host "Nothing matched for removal." -ForegroundColor Green
    return
}

$needsAdmin = @($targets | Where-Object { $_.Location -eq 'LocalMachine' }).Count -gt 0
if ($needsAdmin -and -not $isAdmin) {
    throw "Removing LocalMachine entries needs an elevated session. Re-run from an Administrator PowerShell, or pass -Scope CurrentUser to clean up just the per-user stores."
}

Write-Host ""
Write-Host "About to REMOVE these store entries:" -ForegroundColor Red
$targets | Sort-Object Location, StoreName, Thumbprint | ForEach-Object {
    Write-Host ("  " + $_.Location + "\" + $_.StoreName + "  " + $_.Thumbprint + "  " + $_.Subject)
}
Write-Host ""
Write-Host "Removing a trust entry means catalogs signed by that certificate stop validating," -ForegroundColor Yellow
Write-Host "so patched packages signed with it can no longer be installed." -ForegroundColor Yellow
Write-Host ""

# Windows presents CurrentUser\Root, CurrentUser\CA and CurrentUser\TrustedPublisher as a MERGED
# view: they list the per-user entries plus everything inherited from the corresponding
# LocalMachine store. An inherited entry cannot be deleted through the user view - the attempt
# fails with access-denied even in an elevated session - it has to be removed from LocalMachine.
# Detect that up front so it reads as "remove it elsewhere", not as a mysterious failure.
$machineIndex = @{}
foreach ($sn in $trustStores) {
    $machineIndex[$sn] = @(Get-StoreEntries -Location 'LocalMachine' -StoreName $sn | ForEach-Object { $_.Thumbprint })
}

$removed = 0
$failed = 0
$inherited = @()

foreach ($t in $targets) {
    $desc = "$($t.Location)\$($t.StoreName): $($t.Thumbprint)"

    if ($t.Location -eq 'CurrentUser' -and $machineIndex.ContainsKey($t.StoreName) -and
        $machineIndex[$t.StoreName] -contains $t.Thumbprint) {
        Write-Host ("  inherited " + $desc + " - lives in LocalMachine\" + $t.StoreName + ", remove it there") -ForegroundColor DarkGray
        $inherited += $t
        continue
    }

    if ($PSCmdlet.ShouldProcess($desc, "Remove certificate")) {
        try {
            $st = New-Object System.Security.Cryptography.X509Certificates.X509Store($t.StoreName, $t.Location)
            $st.Open('ReadWrite')
            $st.Remove($t.Cert)
            $st.Close()
            Write-Host ("  removed  " + $desc) -ForegroundColor Green
            $removed++
        }
        catch {
            Write-Warning ("  FAILED   " + $desc + " : " + $_.Exception.Message)
            $failed++
        }
    }
}

Write-Host ""
Write-Host ("Done. Removed $removed store entr(y/ies)" + $(if ($failed) { ", $failed failed" } else { "" }) + ".") -ForegroundColor Green
if ($normalizedKeep.Count -gt 0) {
    Write-Host ("Kept: " + ($normalizedKeep -join ', ')) -ForegroundColor DarkGray
}
if ($inherited.Count -gt 0) {
    $inheritedThumbs = @($inherited | ForEach-Object { $_.Thumbprint } | Sort-Object -Unique)
    Write-Host ""
    Write-Host ("$($inherited.Count) entr(y/ies) were inherited from LocalMachine and left alone.") -ForegroundColor Yellow
    Write-Host "Remove them from an ELEVATED PowerShell with:" -ForegroundColor Yellow
    Write-Host ("  .\Remove-DriverPatchCert.ps1 -Scope LocalMachine -Thumbprint " + ($inheritedThumbs -join ',')) -ForegroundColor White
}
