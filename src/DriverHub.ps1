[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\assets\driver-manifest.json'),
    [string]$AppMetadataPath = (Join-Path $PSScriptRoot '..\assets\app-metadata.json'),
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\DriverHub.Core.ps1"

function Invoke-DriverHub {
    param(
        [Parameter(Mandatory)]
        [string]$ManifestPath,
        [Parameter(Mandatory)]
        [string]$AppMetadataPath,
        [switch]$DryRun
    )

    if (-not (Test-DriverHubAdministrator)) {
        throw 'Administrator privileges are required to install drivers.'
    }

    $manifest = Read-DriverHubJson -Path $ManifestPath
    Test-DriverHubManifest -Manifest $manifest
    $appMetadata = Read-DriverHubJson -Path $AppMetadataPath
    $baseDirectory = Split-Path -Parent $ManifestPath

    Show-DriverHubSummary -AppMetadata $appMetadata -Manifest $manifest
    if ($appMetadata.LogoPath) {
        $logoPath = Resolve-DriverHubPath -BaseDirectory (Split-Path -Parent $AppMetadataPath) -RelativePath $appMetadata.LogoPath
        if (Test-Path -LiteralPath $logoPath) {
            Write-DriverHubLog "Logo asset found: $($appMetadata.LogoPath)" 'Info'
        }
        else {
            Write-DriverHubLog "Logo asset expected at: $($appMetadata.LogoPath)" 'Warn'
        }
    }

    foreach ($step in $manifest.Steps) {
        Write-DriverHubLog "Starting step: $($step.Name)"
        Invoke-DriverHubStep -Step $step -BaseDirectory $baseDirectory -DryRun:$DryRun
        Write-DriverHubLog "Completed step: $($step.Name)"
    }

    Write-DriverHubLog 'All driver steps completed.'
}

try {
    Invoke-DriverHub -ManifestPath $ManifestPath -AppMetadataPath $AppMetadataPath -DryRun:$DryRun
}
catch {
    Write-DriverHubLog $_.Exception.Message 'Error'
    exit 1
}
