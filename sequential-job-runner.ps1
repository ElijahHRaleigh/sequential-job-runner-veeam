<#
.SYNOPSIS
    Automates execution of a defined set of Veeam jobs sequentially, while managing job conflicts.

.DESCRIPTION
    - Waits for non-target Veeam jobs to finish running
    - Disables all jobs not in the provided list
    - Runs the listed jobs one-by-one, monitoring every 5 minutes
    - Re-enables previously disabled jobs
    - Logs all events to a local file

.NOTES
    Author: ElijahHRaleigh
    Date: 05/01/2025
    Requires: Access to a VBR server and admin-level permissions

.INSTRUCTIONS
    1. Edit the $jobNames array to include your job names
    2. Run script as a user with permission to execute Veeam jobs
    3. Logs will be saved under C:\ScriptLogs\
#>


# Logging function:
function Write-Log {
    param(
        [string]$Message,
        [string]$Path = "Your log path here",
        [string]$Level = "Info"
    )

    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogEntry = "$Timestamp [$Level] $Message"

    # Extract directory from the full path
    $directory = Split-Path -Path $Path -Parent

    # Create directory if it doesn't exist
    if (-not (Test-Path -Path $directory)) {
        try {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        } catch {
            Write-Host "Failed to create log directory: $directory" -ForegroundColor Red
            return
        }
    }

    # Append log entry
    Add-Content -Path $Path -Value $LogEntry
}

$jobNames = @(
    "Your job names here"
)

Write-Log -Message "Script Started"
Start-Sleep -Seconds 10

# Get the current jobs, if any are running, wait for them to complete. Once they do, disable all except for the stack jobs

Write-Log "Getting currently running jobs"

function Get-UnmatchedVeeamJobsStatus {
    $allJobs = Get-VBRJob

    $filteredJobs = $allJobs | Where-Object { $jobNames -notcontains $_.Name }

    $filteredJobs | ForEach-Object {
        [PSCustomObject]@{
            Name           = $_.Name
            IsRunning      = $_.IsRunning
            LastState      = $_.GetLastState()
            LastResult     = $_.FindLastSession().Result
            LastRunTime    = $_.FindLastSession().CreationTime
        }
    }
}

# Monitor unmatched jobs and wait until all are idle
do {
    $unmatchedJobs = Get-UnmatchedVeeamJobsStatus

    $runningJobs = $unmatchedJobs | Where-Object { $_.IsRunning -eq $true }

    if ($runningJobs.Count -gt 0) {
        foreach ($job in $runningJobs) {
            Write-Log -Message "Job still running: $($job.Name) - LastRunTime: $($job.LastRunTime)" -Level "Warning"
        }

        Write-Host "Detected running unmatched jobs. Waiting 60 seconds..." -ForegroundColor Yellow
        Start-Sleep -Seconds 300
    }

} while ($runningJobs.Count -gt 0)

Write-Log -Message "No unmatched jobs are currently running. Proceeding with script."
Write-Log -Message "Disabling all unmatched jobs..."

$unmatchedJobs | ForEach-Object {
    try {
        Disable-VBRJob -Job (Get-VBRJob -Name $_.Name)
        Write-Log -Message "Disabled Job: $($_.Name)"
    }
    catch {
        Write-Log -Message "Failed to disable job: $($_.Name)> Error: $_" -Level "Error"
    }
}

Write-Log -Message "Verifying job disable status..."
Get-VBRJob | Where-Object { $jobNames -notcontains $_.Name } | ForEach-Object {
    if (-not $_.IsScheduleEnabled) {
        Write-Log -Message "Confirmed disabled: $($_.Name)"
    } else {
        Write-Log -Message "Still enabled: $($_.Name)" -Level "Warning"
    }
}

Write-Log -Message "All unmatched job have been disabled."
Write-Log -Message "Beginning sequential run of stack jobs..." 

foreach ($jobName in $jobNames) {
    try {
        $job = Get-VBRJob -Name $jobName
        if (-not $job) {
            Write-Log -Message "Job not found: $jobName" -Level "Error"
            continue
        }

        Write-Log -Message "Starting job: $jobName"
        Start-VBRJob -Job $job | Out-Null

        #Monitor until job finishes
        do {
            Start-Sleep -Seconds 180
            $job = Get-VBRJob -Name $jobName 
            $isRunning = $job.IsRunning
            Write-Log -Message "Checking status of $jobName... Running: $isRunning"
        } while ($isRunning)

        # Log final result
        $lastSession = $job.FindLastSession()
        Write-Log -Message "Job completed: $jobName - Result: $($lastSession.Result) - End Time: $($lastSession.EndTime)"

    } catch {
        Write-Log -Message "Error while processing job: $jobName - $_" -Level "Error"
    }
}

Write-Log -Message "All stack jobs have been executed sequentially."
Write-Log -Message "Enabling unmatched jobs now"

# Re-enable jobs not in the $jobNames list
Get-VBRJob | Where-Object { $jobNames -notcontains $_.Name } | ForEach-Object {
    try {
        Enable-VBRJob -Job $_
        Write-Log -Message "Re-enabled job: $($_.Name)"
    } catch {
        Write-Log -Message "Failed to re-enable job: $($_.Name) - Error: $_" -Level "Error"
    }
}

Write-Log -Message "All previously disabled unmatched jobs have been re-enabled."