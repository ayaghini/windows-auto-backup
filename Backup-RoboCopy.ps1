<#
.SYNOPSIS
    Runs one or more Robocopy backup jobs defined in a JSON config file.

.DESCRIPTION
    - Supports multiple source/destination pairs.
    - Uses robust Robocopy defaults for SMB/NAS backups.
    - Creates timestamped logs.
    - Writes a summary at the end.
    - Designed to be called manually or from Task Scheduler.

.NOTES
    Best practice:
    - Use UNC paths for NAS destinations, e.g. \\192.168.1.50\Backups\PC01
    - Avoid mapped drives for scheduled tasks.
    - Test each job manually before scheduling.
#>

[CmdletBinding()]
param(
    # Path to the JSON config file that contains one or more backup jobs.
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    # Optional: override the root folder where logs are stored.
    [string]$LogRoot = "C:\BackupLogs",

    # Optional: run in "what if" mode so Robocopy lists actions without copying.
    [switch]$WhatIfOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO","WARN","ERROR")]
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
}

function Test-JobDefinition {
    param(
        [pscustomobject]$Job
    )

    $required = @("Name","Source","Destination")
    foreach ($field in $required) {
        if (-not ($Job.PSObject.Properties.Name -contains $field)) {
            throw "Backup job is missing required field: '$field'"
        }
    }

    if ([string]::IsNullOrWhiteSpace($Job.Name)) {
        throw "Backup job 'Name' cannot be empty."
    }

    if ([string]::IsNullOrWhiteSpace($Job.Source)) {
        throw "Backup job '$($Job.Name)' has an empty Source."
    }

    if ([string]::IsNullOrWhiteSpace($Job.Destination)) {
        throw "Backup job '$($Job.Name)' has an empty Destination."
    }
}

function Ensure-FolderExists {
    param(
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Normalize-ExcludeArray {
    param(
        $Value
    )

    if ($null -eq $Value) { return @() }
    if ($Value -is [System.Array]) { return $Value }
    return @($Value)
}

function Invoke-RoboCopyJob {
    param(
        [pscustomobject]$Job,
        [string]$LogRoot,
        [switch]$WhatIfOnly
    )

    Test-JobDefinition -Job $Job

    $jobName        = $Job.Name
    $source         = $Job.Source
    $destination    = $Job.Destination
    $mirror         = [bool]($Job.Mirror)
    $copySubfolders = if ($Job.PSObject.Properties.Name -contains "CopySubfolders") { [bool]$Job.CopySubfolders } else { $true }

    $retryCount     = if ($Job.PSObject.Properties.Name -contains "RetryCount") { [int]$Job.RetryCount } else { 3 }
    $retryWaitSec   = if ($Job.PSObject.Properties.Name -contains "RetryWaitSeconds") { [int]$Job.RetryWaitSeconds } else { 10 }
    $threads        = if ($Job.PSObject.Properties.Name -contains "Threads") { [int]$Job.Threads } else { 8 }

    $excludeDirs    = Normalize-ExcludeArray $Job.ExcludeDirs
    $excludeFiles   = Normalize-ExcludeArray $Job.ExcludeFiles

    $timestamp      = Get-Date -Format "yyyyMMdd-HHmmss"
    $jobLogFolder   = Join-Path $LogRoot $jobName
    Ensure-FolderExists -Path $jobLogFolder

    $logFile        = Join-Path $jobLogFolder "robocopy-$timestamp.log"

    Write-Log "Starting job '$jobName'"
    Write-Log "Source      : $source"
    Write-Log "Destination : $destination"
    Write-Log "Log file    : $logFile"

    # Validate source
    if (-not (Test-Path -LiteralPath $source)) {
        throw "Source path does not exist for job '$jobName': $source"
    }

    # Validate destination root. For SMB/UNC paths, Test-Path is a good quick check.
    # If the destination path itself does not exist, Robocopy can create the final folder,
    # but the share/root should still be reachable.
    $destParent = Split-Path -Path $destination -Parent
    if ([string]::IsNullOrWhiteSpace($destParent)) {
        $destParent = $destination
    }

    if (-not (Test-Path -LiteralPath $destParent)) {
        throw "Destination parent/share is not reachable for job '$jobName': $destParent"
    }

    # Build Robocopy arguments
    $args = New-Object System.Collections.Generic.List[string]

    $args.Add($source)
    $args.Add($destination)

    # Copy mode:
    # /E   = include subdirs, including empty
    # /MIR = mirror source to destination (dangerous, deletes extra files at destination)
    if ($mirror) {
        $args.Add("/MIR")
    }
    elseif ($copySubfolders) {
        $args.Add("/E")
    }

    # Recommended reliability / NAS-friendly options
    $args.Add("/Z")                     # restartable mode over network
    $args.Add("/R:$retryCount")         # retries
    $args.Add("/W:$retryWaitSec")       # wait between retries
    $args.Add("/COPY:DAT")              # Data, Attributes, Timestamps
    $args.Add("/DCOPY:DAT")             # Directory Data, Attributes, Timestamps
    $args.Add("/FFT")                   # SMB/NAS time tolerance (2-second granularity)
    $args.Add("/XJ")                    # exclude junction points to avoid loops
    $args.Add("/XA:SH")                 # exclude system and hidden files by default
    $args.Add("/MT:$threads")           # multithreaded copy
    $args.Add("/NP")                    # no progress percentage (smaller logs)
    $args.Add("/TEE")                   # output to console and log
    $args.Add("/V")                     # verbose
    $args.Add("/TS")                    # source timestamps
    $args.Add("/FP")                    # full path names in output
    $args.Add("/UNILOG+:$logFile")      # append unicode log

    # Optional safety / simulation
    if ($WhatIfOnly) {
        $args.Add("/L")                 # list only, do not copy
    }

    # Optional exclusions
    if ($excludeDirs.Count -gt 0) {
        $args.Add("/XD")
        foreach ($dir in $excludeDirs) {
            $args.Add($dir)
        }
    }

    if ($excludeFiles.Count -gt 0) {
        $args.Add("/XF")
        foreach ($file in $excludeFiles) {
            $args.Add($file)
        }
    }

    # Start Robocopy
    Write-Log "Invoking Robocopy for job '$jobName'..."

    $process = Start-Process -FilePath "robocopy.exe" `
                             -ArgumentList $args `
                             -NoNewWindow `
                             -Wait `
                             -PassThru

    $exitCode = $process.ExitCode

    # Robocopy exit code handling:
    # 0 = no files copied
    # 1 = files copied successfully
    # 2..7 = success with some extras/mismatches
    # >= 8 = failure
    if ($exitCode -ge 8) {
        throw "Robocopy job '$jobName' failed with exit code $exitCode. See log: $logFile"
    }

    Write-Log "Completed job '$jobName' successfully with Robocopy exit code $exitCode"
    return [pscustomobject]@{
        Name        = $jobName
        Source      = $source
        Destination = $destination
        ExitCode    = $exitCode
        LogFile     = $logFile
        Success     = $true
    }
}

# Main
try {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    Ensure-FolderExists -Path $LogRoot

    Write-Log "Loading config file: $ConfigPath"

    $rawConfig = Get-Content -LiteralPath $ConfigPath -Raw
    $config = $rawConfig | ConvertFrom-Json

    if (-not ($config.PSObject.Properties.Name -contains "Jobs")) {
        throw "Config file must contain a top-level property named 'Jobs'."
    }

    $jobs = $config.Jobs
    if ($null -eq $jobs -or $jobs.Count -eq 0) {
        throw "No jobs found in config file."
    }

    $results = @()

    foreach ($job in $jobs) {
        try {
            $result = Invoke-RoboCopyJob -Job $job -LogRoot $LogRoot -WhatIfOnly:$WhatIfOnly
            $results += $result
        }
        catch {
            Write-Log "Job '$($job.Name)' failed: $($_.Exception.Message)" "ERROR"
            $results += [pscustomobject]@{
                Name        = $job.Name
                Source      = $job.Source
                Destination = $job.Destination
                ExitCode    = -1
                LogFile     = $null
                Success     = $false
            }
        }
    }

    Write-Log "Backup run summary:"
    foreach ($r in $results) {
        $status = if ($r.Success) { "SUCCESS" } else { "FAILED" }
        Write-Log (" - {0}: {1}" -f $r.Name, $status)
    }

    if ($results.Success -contains $false) {
        exit 1
    }

    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}