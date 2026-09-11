<#
.SYNOPSIS
  Creates a self-signed code-signing certificate for signing the patched NVIDIA driver catalog.

.DESCRIPTION
  This does NOT touch your system trust stores. It only creates a cert+key in your personal
  certificate store (Cert:\CurrentUser\My) and exports the public .cer so you can review/trust it
  deliberately. Trusting it is a separate, explicit step you run yourself - see the README.

  The private key is created NON-EXPORTABLE by default. Signing reads the key straight out of your
  certificate store, so nothing in this toolkit needs a .pfx, and a key that cannot be exported
  cannot be copied off this machine by anything that later gets hold of your user account. It also
  means there is no .pfx password to invent, protect, or type - not here, and not on any later
  driver release.

  Pass -Exportable if you specifically want a portable .pfx backup, e.g. to sign on a second
  machine. That re-introduces a password and a file holding your private key, so only do it if you
  actually need it.

.PARAMETER Subject
  Certificate subject/common name. This is the name Windows shows in its certificate UI, in
  signtool output, and as the publisher on the "Would you like to install this device software?"
  prompt, so it should read as an obviously local, self-issued certificate. The default names the
  project and describes what it is; it deliberately does not pass itself off as NVIDIA, and does
  not reuse the old "FrankenDriver" name either.

  Changing this only affects certificates created from now on. A certificate's subject is bound
  into the signed structure and cannot be edited afterwards, so an existing certificate keeps the
  name it was born with - see the README section on renaming.

.PARAMETER OutputDir
  Where to write the exported .cer (and .pfx, if -Exportable). Defaults to the "Certificates"
  folder next to "Scripts" (created automatically if it doesn't exist yet).

.PARAMETER ValidityYears
  How long the certificate stays valid. Defaults to 3 years rather than 10: this certificate
  becomes a machine-wide trusted root once you trust it, and that is a long time to leave a
  self-signed signing authority in place. Catalogs already signed and timestamped keep validating
  after the certificate expires, so a shorter life costs you nothing except re-running this and
  the trust step every few years.

.PARAMETER Exportable
  Also export a password-protected .pfx, and allow the private key to be exported. Off by default.

.PARAMETER PfxPassword
  Only used with -Exportable. Prompted for if omitted.
#>
[CmdletBinding()]
param(
    [string]$Subject = "CN=Chameleon Project - Customised driver for Nvidia GPU",
    [string]$OutputDir,
    [int]$ValidityYears = 3,
    [switch]$Exportable,
    [securestring]$PfxPassword
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is unreliable inside a param() default value when this script is launched as a
# fresh process (powershell.exe -File ..., e.g. double-clicked or run via "Run with PowerShell")
# - confirmed empty there even though it's reliably set by this point in the script body.
if (-not $OutputDir) {
    $OutputDir = Join-Path (Split-Path $PSScriptRoot -Parent) "Certificates"
}
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

$keyPolicy = if ($Exportable) { 'Exportable' } else { 'NonExportable' }

$cert = New-SelfSignedCertificate `
    -Type CodeSigningCert `
    -Subject $Subject `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyUsage DigitalSignature `
    -KeyExportPolicy $keyPolicy `
    -NotAfter (Get-Date).AddYears($ValidityYears) `
    -TextExtension @("2.5.29.37={text}1.3.6.1.5.5.7.3.3")   # Extended Key Usage: Code Signing

$cerPath = Join-Path $OutputDir "DriverPatchSigning.cer"
Export-Certificate -Cert $cert -FilePath $cerPath | Out-Null

Write-Host "Created certificate: $($cert.Subject)" -ForegroundColor Green
Write-Host "  Thumbprint: $($cert.Thumbprint)"
Write-Host "  Expires:    $($cert.NotAfter)"
Write-Host "  Private key: in Cert:\CurrentUser\My, $keyPolicy"
Write-Host "  Public cert exported to: $cerPath"

if ($Exportable) {
    if (-not $PfxPassword) {
        $PfxPassword = Read-Host -AsSecureString -Prompt "Set a password to protect the exported .pfx private key"
    }
    $pfxPath = Join-Path $OutputDir "DriverPatchSigning.pfx"
    Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $PfxPassword | Out-Null
    Write-Host "  Private key (.pfx) exported to: $pfxPath" -ForegroundColor Yellow
    Write-Host "  Keep that file private - anyone holding it can sign drivers your machine trusts." -ForegroundColor Yellow
}
else {
    Write-Host "  No .pfx written - the key is non-exportable and signing reads it from the store." -ForegroundColor DarkGray
    Write-Host "  (Re-run with -Exportable if you need a portable backup for another machine.)" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "This certificate is NOT trusted by Windows yet. To make a driver signed with it" -ForegroundColor Yellow
Write-Host "installable, YOU must explicitly add it to the trust stores yourself (see README.md)." -ForegroundColor Yellow
Write-Host ""
Write-Host "Signing needs no password on this machine:" -ForegroundColor DarkGray
Write-Host "  Sign-DriverPackage.ps1 -CertThumbprint $($cert.Thumbprint)" -ForegroundColor DarkGray

# Sole pipeline output: the thumbprint. Invoke-DriverPatchPipeline.ps1 captures this so it can
# sign from the certificate store. Everything above is Write-Host (host stream) precisely so this
# stays the only thing on the success output stream.
Write-Output $cert.Thumbprint
