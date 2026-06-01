[CmdletBinding()]
param(
    [string]$ManifestPath = (Join-Path $PSScriptRoot '..\assets\driver-manifest.json'),
    [string]$AppMetadataPath = (Join-Path $PSScriptRoot '..\assets\app-metadata.json'),
    [switch]$DryRun,
    [switch]$ContinueOnError
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
        [switch]$DryRun,
        [switch]$ContinueOnError
    )

    if (-not (Test-DriverHubAdministrator)) {
        throw 'Administrator privileges are required to install drivers.'
    }

    $manifest = Read-DriverHubJson -Path $ManifestPath
    Test-DriverHubManifest -Manifest $manifest
    $appMetadata = Read-DriverHubJson -Path $AppMetadataPath
    $baseDirectory = Split-Path -Parent $ManifestPath
    $installState = Read-DriverHubInstallState
    $results = @()
    $failedSteps = @()
    $stepIndex = 0

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
        $stepIndex++
        $percent = [math]::Floor(($stepIndex / [math]::Max(1, $manifest.Steps.Count)) * 100)
        Write-Progress -Id 1 -Activity $appMetadata.Name -Status "Step $stepIndex of $($manifest.Steps.Count): $($step.Name)" -PercentComplete $percent
        Write-DriverHubLog "Starting step: $($step.Name)"

        try {
            $result = Invoke-DriverHubStep -Step $step -BaseDirectory $baseDirectory -InstallState $installState -DryRun:$DryRun
            $results += $result

            switch ($result.Status) {
                'Completed' {
                    $installState = Add-DriverHubCompletedStep -State $installState -StepName $result.StepName -Fingerprint $result.Fingerprint
                    Save-DriverHubInstallState -State $installState
                    Write-DriverHubLog "Completed step: $($step.Name)"
                }
                'Skipped' {
                    Write-DriverHubLog "Skipped step: $($step.Name)" 'Warn'
                }
                'DryRun' {
                    Write-DriverHubLog "Validated step: $($step.Name)" 'Warn'
                }
                default {
                    Write-DriverHubLog "Step returned status '$($result.Status)': $($step.Name)" 'Warn'
                }
            }
        }
        catch {
            $message = $_.Exception.Message
            $failedSteps += [pscustomobject]@{
                StepName = $step.Name
                Message  = $message
            }
            $installState = Add-DriverHubFailedStep -State $installState -StepName $step.Name -Message $message
            Save-DriverHubInstallState -State $installState
            Write-DriverHubLog "Failed step: $($step.Name) - $message" 'Error'

            if (-not $ContinueOnError) {
                break
            }
        }
    }

    Write-Progress -Id 1 -Activity $appMetadata.Name -Completed

    $completedCount = @($results | Where-Object { $_.Status -eq 'Completed' }).Count
    $skippedCount = @($results | Where-Object { $_.Status -eq 'Skipped' }).Count
    $dryRunCount = @($results | Where-Object { $_.Status -eq 'DryRun' }).Count
    $runSummary = [pscustomobject]@{
        Timestamp     = (Get-Date).ToString('o')
        Completed     = $completedCount
        Skipped       = $skippedCount
        DryRun        = $dryRunCount
        Failed        = $failedSteps.Count
        FailedDetails = $failedSteps
    }

    $installState = Set-DriverHubLastRunSummary -State $installState -Summary $runSummary
    Save-DriverHubInstallState -State $installState
    Write-DriverHubRunSummary -Summary $runSummary

    if ($failedSteps.Count -gt 0) {
        throw "One or more driver steps failed. See the log above for details."
    }

    Write-DriverHubLog 'All driver steps completed.'
}

try {
    Invoke-DriverHub -ManifestPath $ManifestPath -AppMetadataPath $AppMetadataPath -DryRun:$DryRun -ContinueOnError:$ContinueOnError
}
catch {
    Write-DriverHubLog $_.Exception.Message 'Error'
    exit 1
}
