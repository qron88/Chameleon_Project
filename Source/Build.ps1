<#
.SYNOPSIS
  Rebuilds Chameleon-Patcher.exe from Chameleon-Patcher.cs.

.DESCRIPTION
  The GUI is a single-file WinForms app compiled by the .NET Framework's own csc.exe, which every
  Windows 10/11 install already has. There is no SDK, no NuGet restore and no internet access
  needed to rebuild it - that is deliberate, since the rest of the toolkit is offline-capable too.

  The output deliberately lands in the PROJECT ROOT, not next to this script. Chameleon-Patcher.exe
  finds Scripts\Invoke-DriverPatchPipeline.ps1 relative to its own folder, so an .exe sitting in
  Source\ would look for Source\Scripts\ and fail at launch.

  The version shown in Explorer's Details tab and in every patch log comes from the assembly
  attributes at the top of Chameleon-Patcher.cs. csc folds them into the PE's Win32 version
  resource on its own; there is no .rc file and nothing to bump here.

.PARAMETER OutputPath
  Where to write the .exe. Defaults to Chameleon-Patcher.exe in the project root.

.PARAMETER CscPath
  Override the compiler location. By default the 64-bit .NET Framework 4.x csc.exe under %WINDIR%.

.EXAMPLE
  .\Build.ps1

.EXAMPLE
  # Build somewhere harmless to inspect before replacing the working copy.
  .\Build.ps1 -OutputPath "$env:TEMP\Chameleon-Patcher.exe"
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$CscPath
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is empty inside a param() default when a script is launched with -File under
# Windows PowerShell 5.1, so every path that depends on it is resolved here instead.
$projectRoot = Split-Path -Parent $PSScriptRoot
$source      = Join-Path $PSScriptRoot 'Chameleon-Patcher.cs'
$icon        = Join-Path $projectRoot  'Assets\Chameleon.ico'

if (-not $OutputPath) { $OutputPath = Join-Path $projectRoot 'Chameleon-Patcher.exe' }
if (-not $CscPath)    { $CscPath    = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe' }

foreach ($required in @(
    @{ Path = $CscPath; What = "csc.exe (.NET Framework 4.x compiler)" },
    @{ Path = $source;  What = "Chameleon-Patcher.cs" },
    @{ Path = $icon;    What = "Assets\Chameleon.ico - regenerate it with Assets\Build-Icon.ps1" }
)) {
    if (-not (Test-Path -LiteralPath $required.Path)) {
        throw "Not found: $($required.What) at $($required.Path)"
    }
}

Write-Host "Compiling $source" -ForegroundColor Cyan
Write-Host "       -> $OutputPath"

& $CscPath /nologo /target:winexe /out:"$OutputPath" /win32icon:"$icon" `
    /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /platform:x64 "$source"

if ($LASTEXITCODE -ne 0) { throw "csc.exe failed with exit code $LASTEXITCODE." }

# Report what the version resource actually came out as. A silent mismatch between the attributes
# in the source and what Explorer shows is exactly the kind of thing that only surfaces after a
# release has shipped.
$info = (Get-Item -LiteralPath $OutputPath).VersionInfo
Write-Host ""
Write-Host ("Built {0:N0} bytes" -f (Get-Item -LiteralPath $OutputPath).Length) -ForegroundColor Green
Write-Host ("  product      : {0}" -f $info.ProductName)
Write-Host ("  file version : {0}" -f $info.FileVersion)
Write-Host ("  product ver. : {0}" -f $info.ProductVersion)
