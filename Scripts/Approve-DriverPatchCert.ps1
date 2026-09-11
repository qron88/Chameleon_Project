<#
.SYNOPSIS
  Explicitly trusts the driver-patch signing certificate on THIS machine.

.DESCRIPTION
  Kept deliberately separate from setup.exe / setup.cfg - this changes what your machine treats
  as a trusted certificate authority, machine-wide, for everything, not just this driver. That
  should be something you consciously run and see happen, not a side effect of installing a
  graphics driver. Nothing else in this toolkit calls this automatically.

  WHICH STORES, AND WHY:

    Root             Required. A self-signed certificate IS its own root, so this is what makes
                     the signature chain at all.
    TrustedPublisher Optional but recommended. Without it, installing the driver pops a
                     "Would you like to install this device software?" trust prompt; with it,
                     Windows already considers the publisher trusted and installs quietly.

  This deliberately no longer writes to the intermediate "CA" store. Earlier versions of this
  script did, but for a self-signed certificate there is no intermediate to chain through - the
  Root entry is what does the work, so the CA copy was a redundant second trusted-authority
  entry with no benefit. If a previous run put one there, Remove-DriverPatchCert.ps1 cleans it up.

  Requires an elevated PowerShell session (writing machine trust stores needs admin rights).

.PARAMETER CerPath
  Path to the certificate to trust. Defaults to DriverPatchSigning.cer in the "Certificates"
  folder next to "Scripts".

.PARAMETER SkipTrustedPublisher
  Only add the Root entry. You will get a device-software trust prompt during install.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string]$CerPath,
    [switch]$SkipTrustedPublisher
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is unreliable inside a param() default value when this script is launched as a
# fresh process (powershell.exe -File ..., e.g. double-clicked or run via "Run with PowerShell")
# - confirmed empty there even though it's reliably set by this point in the script body. This
# script is specifically meant to be run standalone/directly, so this would otherwise bite real
# usage every time.
if (-not $CerPath) {
    $CerPath = Join-Path (Split-Path $PSScriptRoot -Parent) "Certificates\DriverPatchSigning.cer"
}

if (-not (Test-Path $CerPath)) { throw "Certificate not found: $CerPath" }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "This needs an elevated session - machine trust stores can't be written without admin rights. Re-run from an Administrator PowerShell."
}

$cert = Get-PfxCertificate -FilePath $CerPath

$stores = @('Root')
if (-not $SkipTrustedPublisher) { $stores += 'TrustedPublisher' }

Write-Host "About to trust this certificate machine-wide:" -ForegroundColor Yellow
Write-Host "  Subject:    $($cert.Subject)"
Write-Host "  Issuer:     $($cert.Issuer)"
Write-Host "  Thumbprint: $($cert.Thumbprint)"
Write-Host "  Expires:    $($cert.NotAfter)"
Write-Host "  Stores:     $($stores -join ', ') (LocalMachine)"
Write-Host ""
Write-Host "Adding to Root means ALL software on this machine will accept code signed by this" -ForegroundColor Yellow
Write-Host "certificate, not just the patched driver, for as long as it stays in the store." -ForegroundColor Yellow
Write-Host ""

if ($PSCmdlet.ShouldProcess("$($stores -join ' and ') certificate store(s) on this machine", "Add certificate $($cert.Thumbprint)")) {
    foreach ($store in $stores) {
        certutil -addstore $store $CerPath
        if ($LASTEXITCODE -ne 0) { throw "certutil -addstore $store failed with exit code $LASTEXITCODE." }
    }
    Write-Host "`nDone. The driver catalog signed with this certificate will now pass signature" -ForegroundColor Green
    Write-Host "verification (you still need driver signature enforcement disabled, or Windows" -ForegroundColor Green
    Write-Host "Test Signing mode on, for the driver itself to load - see README.md)." -ForegroundColor Green
    Write-Host ""
    Write-Host "To undo this later, including any stores older versions of this script wrote to:" -ForegroundColor DarkGray
    Write-Host "  .\Remove-DriverPatchCert.ps1 -Thumbprint $($cert.Thumbprint)"
}
else {
    Write-Host "Cancelled - no changes made." -ForegroundColor Yellow
}
