Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-DriverHubLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet('Info', 'Warn', 'Error')]
        [string]$Level = 'Info'
    )

    $prefix = switch ($Level) {
        'Warn' { '[WARN]' }
        'Error' { '[ERROR]' }
        default { '[INFO]' }
    }

    Write-Host "$prefix $Message"
}

function Test-DriverHubAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-DriverHubPath {
    param(
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [string]$RelativePath
    )

    return [System.IO.Path]::GetFullPath((Join-Path $BaseDirectory $RelativePath))
}

function Read-DriverHubJson {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "File not found: $Path"
    }

    Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Test-DriverHubManifest {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Manifest
    )

    $required = 'Name', 'Version', 'Steps'
    foreach ($property in $required) {
        if (-not ($Manifest.PSObject.Properties.Name -contains $property)) {
            throw "Manifest is missing required property: $property"
        }
    }

    if (-not $Manifest.Steps -or $Manifest.Steps.Count -lt 1) {
        throw 'Manifest must define at least one install step.'
    }
}

function Test-DriverHubStep {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Step
    )

    $required = 'Name', 'Path'
    foreach ($property in $required) {
        if (-not ($Step.PSObject.Properties.Name -contains $property)) {
            throw "Manifest step is missing required property: $property"
        }
    }

    if (-not $Step.InstallMode) {
        throw "Manifest step '$($Step.Name)' is missing InstallMode."
    }

    if ($Step.InstallMode -notin @('pnputil', 'exe')) {
        throw "Unsupported InstallMode '$($Step.InstallMode)' for step '$($Step.Name)'."
    }
}

function Read-DriverHubPackageDescriptor {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Package descriptor not found: $Path"
    }

    Read-DriverHubJson -Path $Path
}

function Test-DriverHubPackageDescriptor {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Descriptor
    )

    $required = 'Name', 'InstallMode'
    foreach ($property in $required) {
        if (-not ($Descriptor.PSObject.Properties.Name -contains $property)) {
            throw "Package descriptor is missing required property: $property"
        }
    }

    if ($Descriptor.InstallMode -notin @('pnputil', 'exe')) {
        throw "Package descriptor install mode '$($Descriptor.InstallMode)' is not supported."
    }

    if ($Descriptor.InstallMode -eq 'pnputil' -and (-not $Descriptor.PrimaryFiles -or $Descriptor.PrimaryFiles.Count -lt 1)) {
        throw 'PNPUtil package descriptor must define at least one primary file.'
    }

    if ($Descriptor.InstallMode -eq 'exe' -and -not $Descriptor.Installer) {
        throw 'Executable package descriptor must define Installer.'
    }
}

function Get-DriverHubStatePath {
    $stateRoot = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'Drivershub'
    return Join-Path $stateRoot 'install-state.json'
}

function Read-DriverHubInstallState {
    $statePath = Get-DriverHubStatePath
    if (-not (Test-Path -LiteralPath $statePath)) {
        return [pscustomobject]@{
            CompletedSteps = @()
            FailedSteps    = @()
            RunHistory     = @()
            UpdatedAt      = $null
        }
    }

    Read-DriverHubJson -Path $statePath
}

function Save-DriverHubInstallState {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State
    )

    $statePath = Get-DriverHubStatePath
    $stateDirectory = Split-Path -Parent $statePath
    if (-not (Test-Path -LiteralPath $stateDirectory)) {
        New-Item -ItemType Directory -Path $stateDirectory -Force | Out-Null
    }

    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $statePath -Encoding UTF8
}

function Get-DriverHubFileFingerprint {
    param(
        [Parameter(Mandatory)]
        [string[]]$Paths
    )

    $hashInput = foreach ($path in ($Paths | Sort-Object)) {
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Fingerprint source not found: $path"
        }

        $fileHash = Get-FileHash -LiteralPath $path -Algorithm SHA256
        "$($fileHash.Hash)"
    }

    $joined = $hashInput -join "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($joined)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        ($sha256.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join ''
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-DriverHubStepFingerprint {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Step,
        [Parameter(Mandatory)]
        [string]$StepPath,
        [Parameter(Mandatory)]
        [pscustomobject]$Descriptor
    )

    if ($Descriptor.InstallMode -eq 'pnputil') {
        $filePaths = @()
        foreach ($primaryFile in $Descriptor.PrimaryFiles) {
            $primaryPath = Join-Path $StepPath $primaryFile
            $filePaths += $primaryPath
        }

        $filePaths += (Get-ChildItem -LiteralPath $StepPath -Recurse -Filter '*.inf' -File | Select-Object -ExpandProperty FullName)
        return Get-DriverHubFileFingerprint -Paths $filePaths
    }

    if ($Descriptor.InstallMode -eq 'exe') {
        $installerPath = Join-Path $StepPath $Descriptor.Installer
        return Get-DriverHubFileFingerprint -Paths @($installerPath)
    }

    throw "Unsupported install mode for fingerprint: $($Descriptor.InstallMode)"
}

function Test-DriverHubStepAlreadyCompleted {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [string]$Fingerprint
    )

    foreach ($entry in @($State.CompletedSteps)) {
        if ($entry.StepName -eq $StepName -and $entry.Fingerprint -eq $Fingerprint) {
            return $true
        }
    }

    return $false
}

function Add-DriverHubCompletedStep {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [string]$Fingerprint
    )

    $completed = @($State.CompletedSteps)
    $completed = @(
        $completed | Where-Object { $_.StepName -ne $StepName }
    )

    $completed += [pscustomobject]@{
        StepName    = $StepName
        Fingerprint = $Fingerprint
        InstalledAt = (Get-Date).ToString('o')
    }

    $State | Add-Member -NotePropertyName CompletedSteps -NotePropertyValue $completed -Force
    $State | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    return $State
}

function Add-DriverHubFailedStep {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [string]$StepName,
        [Parameter(Mandatory)]
        [string]$Message
    )

    $failed = @($State.FailedSteps)
    $failed += [pscustomobject]@{
        StepName  = $StepName
        Message   = $Message
        FailedAt  = (Get-Date).ToString('o')
    }

    $State | Add-Member -NotePropertyName FailedSteps -NotePropertyValue $failed -Force
    $State | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    return $State
}

function Set-DriverHubLastRunSummary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$State,
        [Parameter(Mandatory)]
        [pscustomobject]$Summary
    )

    $history = @($State.RunHistory)
    $history += $Summary

    $State | Add-Member -NotePropertyName RunHistory -NotePropertyValue $history -Force
    $State | Add-Member -NotePropertyName UpdatedAt -NotePropertyValue (Get-Date).ToString('o') -Force
    return $State
}

function Write-DriverHubRunSummary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Summary
    )

    Write-DriverHubLog "Run summary: $($Summary.Completed) completed, $($Summary.Skipped) skipped, $($Summary.DryRun) validated, $($Summary.Failed) failed."
    if ($Summary.FailedDetails -and $Summary.FailedDetails.Count -gt 0) {
        Write-DriverHubLog 'Failed steps:' 'Warn'
        foreach ($failed in $Summary.FailedDetails) {
            Write-DriverHubLog " - $($failed.StepName): $($failed.Message)" 'Warn'
        }
    }
}

function Show-DriverHubSummary {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$AppMetadata,
        [Parameter(Mandatory)]
        [pscustomobject]$Manifest
    )

    Write-DriverHubLog "$($AppMetadata.Name) v$($AppMetadata.Version)"
    Write-DriverHubLog "Publisher: $($AppMetadata.Publisher)"
    Write-DriverHubLog "Driver steps: $($Manifest.Steps.Count)"
}

function Invoke-DriverHubStep {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Step,
        [Parameter(Mandatory)]
        [string]$BaseDirectory,
        [Parameter(Mandatory)]
        [pscustomobject]$InstallState,
        [switch]$DryRun
    )

    Test-DriverHubStep -Step $Step
    $stepPath = Resolve-DriverHubPath -BaseDirectory $BaseDirectory -RelativePath $Step.Path
    if (-not (Test-Path -LiteralPath $stepPath)) {
        throw "Driver path not found for '$($Step.Name)': $stepPath"
    }

    $descriptorName = if ($Step.Descriptor) { $Step.Descriptor } else { 'driver-package.json' }
    $descriptorPath = Join-Path $stepPath $descriptorName
    $descriptor = Read-DriverHubPackageDescriptor -Path $descriptorPath
    Test-DriverHubPackageDescriptor -Descriptor $descriptor

    Write-DriverHubLog "Package: $($descriptor.Name)"
    Write-DriverHubLog "Install mode: $($descriptor.InstallMode)"

    $fingerprint = Get-DriverHubStepFingerprint -Step $Step -StepPath $stepPath -Descriptor $descriptor
    if (Test-DriverHubStepAlreadyCompleted -State $InstallState -StepName $Step.Name -Fingerprint $fingerprint) {
        Write-DriverHubLog "Skipping '$($Step.Name)' because it is already installed." 'Warn'
        return [pscustomobject]@{
            StepName    = $Step.Name
            Status      = 'Skipped'
            Fingerprint = $fingerprint
            Message     = 'Already installed'
        }
    }

    if ($descriptor.InstallMode -eq 'pnputil') {
        $infs = Get-ChildItem -LiteralPath $stepPath -Recurse -Filter '*.inf' -File
        if (-not $infs) {
            throw "No INF files found for '$($Step.Name)' in $stepPath"
        }

        foreach ($primaryFile in $descriptor.PrimaryFiles) {
            $primaryPath = Join-Path $stepPath $primaryFile
            if (-not (Test-Path -LiteralPath $primaryPath)) {
                Write-DriverHubLog "Expected primary file not found yet: $primaryFile" 'Warn'
            }
        }

        if ($DryRun) {
            return [pscustomobject]@{
                StepName    = $Step.Name
                Status      = 'DryRun'
                Fingerprint = $fingerprint
                Message     = 'Validated package only'
            }
        }

        foreach ($inf in $infs) {
            $args = @('/add-driver', $inf.FullName, '/install')
            Write-DriverHubLog "Installing $($Step.Name): $($inf.Name)"
            $process = Start-Process -FilePath 'pnputil.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
            if ($process.ExitCode -ne 0) {
                throw "pnputil failed for '$($Step.Name)' with exit code $($process.ExitCode)"
            }
        }
    }
    elseif ($descriptor.InstallMode -eq 'exe') {
        $installerPath = Join-Path $stepPath $descriptor.Installer
        if (-not (Test-Path -LiteralPath $installerPath)) {
            throw "Installer not found for '$($Step.Name)': $installerPath"
        }

        $arguments = @()
        if ($descriptor.InstallerArguments) {
            $arguments = @($descriptor.InstallerArguments)
        }

        if ($DryRun) {
            Write-DriverHubLog "Dry-run: start-process `"$installerPath`" $($arguments -join ' ')" 'Warn'
            return [pscustomobject]@{
                StepName    = $Step.Name
                Status      = 'DryRun'
                Fingerprint = $fingerprint
                Message     = 'Validated package only'
            }
        }

        Write-DriverHubLog "Launching installer: $([System.IO.Path]::GetFileName($installerPath))"
        $process = Start-Process -FilePath $installerPath -ArgumentList $arguments -Wait -PassThru
        if ($process.ExitCode -ne 0) {
            throw "Installer failed for '$($Step.Name)' with exit code $($process.ExitCode)"
        }
    }

    return [pscustomobject]@{
        StepName    = $Step.Name
        Status      = 'Completed'
        Fingerprint = $fingerprint
        Message     = 'Installed successfully'
    }
}
