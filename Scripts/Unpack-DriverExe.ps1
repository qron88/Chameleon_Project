<#
.SYNOPSIS
  Extracts an NVIDIA driver self-extracting installer (.exe) into a plain folder.

.DESCRIPTION
  NVIDIA driver downloads are a 7-Zip SFX: a small stub/config block followed by a plain 7z
  archive. This just shells out to a 7z-compatible CLI to extract it - no custom offset math
  needed.

.PARAMETER ExePath
  Path to the downloaded driver .exe.

.PARAMETER OutputPath
  Folder to extract into. Must not already exist.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ExePath,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'

# Reuse the shared 7z discovery instead of a second, simpler copy. That copy used to skip the
# NanaZip candidate, so a NanaZip-only machine passed the pipeline's preflight (which does check
# NanaZip) but then failed here, after the run had already started.
. (Join-Path $PSScriptRoot "PatchToolDiscovery.ps1")

if (-not (Test-Path $ExePath)) { throw "Not found: $ExePath" }
if (Test-Path $OutputPath) { throw "Output path already exists: $OutputPath - remove it or choose a different path." }

$sevenZip = Find-SevenZip
Write-Host "Using: $sevenZip"

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null

Write-Host "Extracting $ExePath ..." -ForegroundColor Cyan
& $sevenZip x $ExePath "-o$OutputPath" -y | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "7z extraction failed with exit code $LASTEXITCODE"
}

$hasSetup = Test-Path (Join-Path $OutputPath "setup.exe")
$hasCfg = Test-Path (Join-Path $OutputPath "setup.cfg")
$hasDD = Test-Path (Join-Path $OutputPath "Display.Driver")
if (-not ($hasSetup -and $hasCfg -and $hasDD)) {
    throw "Extraction completed but $OutputPath doesn't look like an NVIDIA driver package (missing setup.exe/setup.cfg/Display.Driver). Wrong file, or NVIDIA changed their packaging format."
}

Write-Host "Extracted to $OutputPath" -ForegroundColor Green