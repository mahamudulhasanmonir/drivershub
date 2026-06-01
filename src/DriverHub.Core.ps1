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
        [switch]$DryRun
    )

    $stepPath = Resolve-DriverHubPath -BaseDirectory $BaseDirectory -RelativePath $Step.Path
    if (-not (Test-Path -LiteralPath $stepPath)) {
        throw "Driver path not found for '$($Step.Name)': $stepPath"
    }

    $infs = Get-ChildItem -LiteralPath $stepPath -Recurse -Filter '*.inf' -File
    if (-not $infs) {
        throw "No INF files found for '$($Step.Name)' in $stepPath"
    }

    foreach ($inf in $infs) {
        $args = @('/add-driver', $inf.FullName, '/install')
        if ($DryRun) {
            Write-DriverHubLog "Dry-run: pnputil $($args -join ' ')" 'Warn'
            continue
        }

        Write-DriverHubLog "Installing $($Step.Name): $($inf.Name)"
        $process = Start-Process -FilePath 'pnputil.exe' -ArgumentList $args -Wait -PassThru -NoNewWindow
        if ($process.ExitCode -ne 0) {
            throw "pnputil failed for '$($Step.Name)' with exit code $($process.ExitCode)"
        }
    }
}
