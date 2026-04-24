<#
.SYNOPSIS
    Creates or updates a Windows Scheduled Task for the backup script.

.DESCRIPTION
    - Registers a scheduled task that runs Backup-RoboCopy.ps1.
    - Uses robust settings:
        * Run whether user is logged on or not
        * Start when available
        * Restart on failure
        * Ignore overlapping runs
    - Can run under SYSTEM or a supplied service/user account.
    - Intended to "keep it alive" by making the task resilient.

.NOTES
    Run this script elevated (as Administrator).
#>

[CmdletBinding()]
param(
    # Name of the scheduled task
    [Parameter(Mandatory = $true)]
    [string]$TaskName,

    # Full path to Backup-RoboCopy.ps1
    [Parameter(Mandatory = $true)]
    [string]$BackupScriptPath,

    # Full path to the JSON config file
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath,

    # How often the backup should run
    [ValidateSet("Daily","Hourly","AtStartup")]
    [string]$ScheduleType = "Daily",

    # For Daily schedule: time of day in 24h format, e.g. 23:00
    [string]$DailyAt = "23:00",

    # For Hourly schedule: repeat every N hours
    [ValidateRange(1,24)]
    [int]$RepeatEveryHours = 4,

    # Optional task description
    [string]$Description = "Automated Robocopy backup to UniFi NAS",

    # Log folder for the backup script
    [string]$LogRoot = "C:\BackupLogs",

    # Run as SYSTEM by default. This is usually best if the NAS share permissions allow it
    # through stored credentials or share access. If not, use a specific user account.
    [switch]$RunAsSystem,

    # Optional domain or local username, e.g. MYPC\BackupUser
    [string]$RunAsUser,

    # Optional password for RunAsUser.
    [System.Security.SecureString]$RunAsPassword
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
    Write-Host "[$timestamp] [$Level] $Message"
}

function Assert-Admin {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw "This script must be run as Administrator."
    }
}

function New-BackupTaskAction {
    param(
        [string]$BackupScriptPath,
        [string]$ConfigPath,
        [string]$LogRoot
    )

    if (-not (Test-Path -LiteralPath $BackupScriptPath)) {
        throw "Backup script not found: $BackupScriptPath"
    }

    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "Config file not found: $ConfigPath"
    }

    $escapedBackupScript = '"' + $BackupScriptPath + '"'
    $escapedConfigPath   = '"' + $ConfigPath + '"'
    $escapedLogRoot      = '"' + $LogRoot + '"'

    $argument = "-NoProfile -ExecutionPolicy Bypass -File $escapedBackupScript -ConfigPath $escapedConfigPath -LogRoot $escapedLogRoot"

    return New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argument
}

function New-BackupTaskTrigger {
    param(
        [string]$ScheduleType,
        [string]$DailyAt,
        [int]$RepeatEveryHours
    )

    switch ($ScheduleType) {
        "Daily" {
            $parsedTime = [datetime]::ParseExact($DailyAt, "HH:mm", $null)
            return New-ScheduledTaskTrigger -Daily -At $parsedTime
        }

        "Hourly" {
            # Start a minute from now so registration works cleanly even if current time is odd.
            $startTime = (Get-Date).AddMinutes(1)
            $trigger = New-ScheduledTaskTrigger -Once -At $startTime `
                -RepetitionInterval (New-TimeSpan -Hours $RepeatEveryHours) `
                -RepetitionDuration ([TimeSpan]::MaxValue)

            return $trigger
        }

        "AtStartup" {
            return New-ScheduledTaskTrigger -AtStartup
        }
    }
}

function Register-OrUpdateBackupTask {
    param(
        [string]$TaskName,
        [string]$Description,
        $Action,
        $Trigger,
        [switch]$RunAsSystem,
        [string]$RunAsUser,
        [System.Security.SecureString]$RunAsPassword
    )

    # Important settings to make it more reliable / "alive"
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 15) `
        -ExecutionTimeLimit (New-TimeSpan -Hours 12) `
        -MultipleInstances IgnoreNew

    if ($RunAsSystem) {
        Write-Log "Registering task '$TaskName' to run as SYSTEM"

        $principal = New-ScheduledTaskPrincipal `
            -UserId "SYSTEM" `
            -LogonType ServiceAccount `
            -RunLevel Highest

        $task = New-ScheduledTask -Action $Action -Trigger $Trigger -Settings $settings -Principal $principal
        Register-ScheduledTask -TaskName $TaskName -InputObject $task -Description $Description -Force | Out-Null
        return
    }

    if ([string]::IsNullOrWhiteSpace($RunAsUser)) {
        throw "Either -RunAsSystem must be used, or -RunAsUser must be provided."
    }

    if ($null -eq $RunAsPassword) {
        throw "When using -RunAsUser, you must also provide -RunAsPassword."
    }

    Write-Log "Registering task '$TaskName' to run as user '$RunAsUser'"

    $credential = New-Object System.Management.Automation.PSCredential($RunAsUser, $RunAsPassword)

    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger $Trigger `
        -Settings $settings `
        -User $credential.UserName `
        -Password ($credential.GetNetworkCredential().Password) `
        -Description $Description `
        -RunLevel Highest `
        -Force | Out-Null
}

# Main
try {
    Assert-Admin

    Write-Log "Preparing scheduled task '$TaskName'"

    $action  = New-BackupTaskAction -BackupScriptPath $BackupScriptPath -ConfigPath $ConfigPath -LogRoot $LogRoot
    $trigger = New-BackupTaskTrigger -ScheduleType $ScheduleType -DailyAt $DailyAt -RepeatEveryHours $RepeatEveryHours

    Register-OrUpdateBackupTask `
        -TaskName $TaskName `
        -Description $Description `
        -Action $action `
        -Trigger $trigger `
        -RunAsSystem:$RunAsSystem `
        -RunAsUser $RunAsUser `
        -RunAsPassword $RunAsPassword

    Write-Log "Scheduled task '$TaskName' has been created/updated successfully."

    Write-Log "You can test it with:"
    Write-Log "Start-ScheduledTask -TaskName `"$TaskName`""
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}