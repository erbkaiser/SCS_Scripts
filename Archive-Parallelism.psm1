function Resolve-ArchiveThrottleLimit {
    param(
        [int]$Requested,
        [bool]$IsFolderInput
    )

    if ($Requested -gt 0) {
        return $Requested
    }

    if ($IsFolderInput) { return 4 }
    return 1
}

function Enter-ArchivePathLock {
    param([string]$Path)

    $normalizedPath = [System.IO.Path]::GetFullPath($Path).ToUpperInvariant()
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = [System.BitConverter]::ToString($sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($normalizedPath))).Replace('-', '')
    } finally {
        $sha256.Dispose()
    }

    $mutex = [System.Threading.Mutex]::new($false, "Local\ATSArchive_$hash")
    try {
        $null = $mutex.WaitOne()
    } catch [System.Threading.AbandonedMutexException] {
    }

    return $mutex
}

function Exit-ArchivePathLock {
    param([System.Threading.Mutex]$Mutex)

    if ($Mutex) {
        try { $Mutex.ReleaseMutex() } finally { $Mutex.Dispose() }
    }
}

function Test-ArchiveOperationApproval {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Operation,
        [switch]$ApplyFixes
    )

    if (-not $ApplyFixes.IsPresent) { return $false }
    return $PSCmdlet.ShouldProcess($Target, $Operation)
}

function Invoke-ArchiveWorkerBatch {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string[]]$ArchivePaths,
        [hashtable]$WorkerParameters = @{},
        [string]$PathParameterName = 'Folder',
        [string]$Operation = 'Process archive',
        [ValidateRange(1, 64)][int]$ThrottleLimit = 4,
        [switch]$ApplyFixes
    )

    $workItems = [System.Collections.Generic.List[PSCustomObject]]::new()
    $declinedPaths = [System.Collections.Generic.List[string]]::new()

    foreach ($archivePath in $ArchivePaths) {
        $approved = Test-ArchiveOperationApproval -Target $archivePath -Operation $Operation -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
        if ($ApplyFixes.IsPresent -and -not $approved -and -not $WhatIfPreference) {
            $declinedPaths.Add($archivePath)
            continue
        }

        $workerArguments = @{}
        foreach ($key in $WorkerParameters.Keys) {
            $workerArguments[$key] = $WorkerParameters[$key]
        }
        $workerArguments[$PathParameterName] = $archivePath
        $workerArguments.WorkerMode = $true
        $workerArguments.ThrottleLimit = 1
        if ($approved) {
            $workerArguments.ApplyFixes = $true
        } else {
            $workerArguments.Remove('ApplyFixes')
        }

        $workItems.Add([PSCustomObject]@{
            Path = $archivePath
            Arguments = $workerArguments
        })
    }

    $results = @()
    if ($workItems.Count -gt 0) {
        $results = @(Invoke-ArchiveWorkerPool -ScriptPath $ScriptPath -WorkItems $workItems.ToArray() -ThrottleLimit $ThrottleLimit)
    }
    return [PSCustomObject]@{
        Results = $results
        DeclinedPaths = $declinedPaths.ToArray()
    }
}

function Invoke-ArchiveWorkerPool {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath,
        [Parameter(Mandatory)]
        [object[]]$WorkItems,
        [ValidateRange(1, 64)]
        [int]$ThrottleLimit
    )

    function Receive-CompletedArchiveWorker {
        param([PSCustomObject]$Entry)

        $jobOutput = @(Receive-Job -Job $Entry.Job -ErrorAction SilentlyContinue)
        $envelope = $jobOutput | Where-Object {
            $_ -and $_.PSObject.Properties['WorkerEnvelope'] -and $_.WorkerEnvelope
        } | Select-Object -First 1

        $silentWorker = $Entry.Arguments -and (
            ($Entry.Arguments.ContainsKey('Silent') -and [bool]$Entry.Arguments.Silent) -or
            ($Entry.Arguments.ContainsKey('Quiet') -and [bool]$Entry.Arguments.Quiet)
        )

        if ($envelope) {
            if (-not $silentWorker) {
            foreach ($log in $envelope.Logs) {
                if ($log.HasForegroundColor) {
                    Write-Host "[$($Entry.Path)] $($log.Message)" -ForegroundColor $log.ForegroundColor
                } else {
                    Write-Host "[$($Entry.Path)] $($log.Message)"
                }
            }
            }
            $workerResult = $envelope.Output | Where-Object {
                $_ -and $_.PSObject.Properties['WorkerResult'] -and $_.WorkerResult
            } | Select-Object -First 1
        } else {
            $workerResult = $null
        }

        $workerErrors = @()
        if ($envelope -and $envelope.Failed) { $workerErrors += $envelope.Error }
        $workerErrors += @($Entry.Job.ChildJobs[0].Error | ForEach-Object { $_.ToString() })
        $result = [PSCustomObject]@{
            Path = $Entry.Path
            Result = $workerResult
            Failed = ($null -eq $workerResult)
            Errors = $workerErrors
        }
        Remove-Job -Job $Entry.Job -Force -ErrorAction SilentlyContinue -WhatIf:$false
        return $result
    }

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()
    $activeWorkers = [System.Collections.Generic.List[PSCustomObject]]::new()
    $nextWorkItem = 0

    while ($nextWorkItem -lt $WorkItems.Count -or $activeWorkers.Count -gt 0) {
        while ($nextWorkItem -lt $WorkItems.Count -and $activeWorkers.Count -lt $ThrottleLimit) {
            $item = $WorkItems[$nextWorkItem]
            $job = Start-Job -ArgumentList $ScriptPath, $item.Arguments -ScriptBlock {
                param($WorkerScriptPath, $WorkerArguments)
                $global:workerLogs = [System.Collections.Generic.List[PSCustomObject]]::new()
                function Write-Host {
                    [CmdletBinding()]
                    param(
                        [Parameter(Position = 0, ValueFromPipeline = $true)]
                        [object]$Object,
                        [System.ConsoleColor]$ForegroundColor,
                        [System.ConsoleColor]$BackgroundColor,
                        [switch]$NoNewline
                    )
                    process {
                        $global:workerLogs.Add([PSCustomObject]@{
                            Message = [string]$Object
                            ForegroundColor = $ForegroundColor
                            HasForegroundColor = $PSBoundParameters.ContainsKey('ForegroundColor')
                            BackgroundColor = $BackgroundColor
                            NoNewline = $NoNewline.IsPresent
                        })
                    }
                }
                try {
                    $capturedOutput = @(& $WorkerScriptPath @WorkerArguments *>&1)
                    [PSCustomObject]@{
                        WorkerEnvelope = $true
                        Failed = $false
                        Logs = $global:workerLogs.ToArray()
                        Output = $capturedOutput
                    }
                } catch {
                    [PSCustomObject]@{
                        WorkerEnvelope = $true
                        Failed = $true
                        Error = $_.ToString()
                        Logs = $global:workerLogs.ToArray()
                        Output = @()
                    }
                }
            }
            $activeWorkers.Add([PSCustomObject]@{ Path = $item.Path; Job = $job; Arguments = $item.Arguments })
            $nextWorkItem++
        }

        $completedJob = Wait-Job -Job @($activeWorkers | ForEach-Object { $_.Job }) -Any | Select-Object -First 1
        $completedEntry = $activeWorkers | Where-Object { $_.Job.Id -eq $completedJob.Id } | Select-Object -First 1
        $results.Add((Receive-CompletedArchiveWorker -Entry $completedEntry))
        [void]$activeWorkers.Remove($completedEntry)
    }

    return $results.ToArray()
}

Export-ModuleMember -Function Resolve-ArchiveThrottleLimit, Enter-ArchivePathLock, Exit-ArchivePathLock, Test-ArchiveOperationApproval, Invoke-ArchiveWorkerPool, Invoke-ArchiveWorkerBatch