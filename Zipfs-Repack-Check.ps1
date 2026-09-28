#Requires -Version 5.1

<#
.SYNOPSIS
Checks ZIPFS mod archives and tests repacking them as HashFS.

.DESCRIPTION
Scans a folder recursively or processes one .zip/.scs archive. It skips HashFS, unreadable,
encrypted, and broken archives, extracts readable ZIPFS archives, then attempts a HashFS repack.
The original is replaced only after a successful repack.

Runs in dry-run mode by default. Use -ApplyFixes to replace archives; a .bak backup is created
unless -NoBackup is specified. -WhatIf previews apply operations. Archive workers default to
four for folder input and one for a single archive; override with -ThrottleLimit.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder = (Get-Location).Path,
    [string]$ToolsFolder = (Get-Location).Path,
    [Alias('Apply', 'Fix')]
    [switch]$ApplyFixes,
    [switch]$NoBackup,
    [Parameter(HelpMessage = 'Maximum simultaneous archive workers; defaults to four for folders and one for a single archive.')]
    [ValidateRange(0, 64)]
    [int]$ThrottleLimit = 0,
    [switch]$WorkerMode
)

$ErrorActionPreference = 'Stop'
$parallelHelper = Join-Path $PSScriptRoot 'Archive-Parallelism.psm1'
Import-Module -Name $parallelHelper -Force
$archiveOperations = Join-Path $PSScriptRoot 'Archive-Operations.psm1'
Import-Module -Name $archiveOperations -Force
$ModeLabel = if (-not $ApplyFixes.IsPresent) { 'Dry run' } elseif ($WhatIfPreference) { 'WhatIf dry run' } else { 'Apply fixes' }
Write-Host "Mode: $ModeLabel.`n" -ForegroundColor Cyan

$PackerExe = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('scs_packer.exe')
$SevenZipExe = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('7z.exe', '7za.exe', '7z')

if (-not $PackerExe) {
    throw "scs_packer.exe was not found in '$ToolsFolder' or PATH."
}

if (-not (Test-Path -LiteralPath $Folder)) {
    throw "Path '$Folder' does not exist."
}

$isFolderInput = Test-Path -LiteralPath $Folder -PathType Container
if ($isFolderInput) {
    $files = @(Get-ChildItem -LiteralPath $Folder -Recurse -File | Where-Object { $_.Extension -in '.zip', '.scs' } | Sort-Object -Property FullName)
} else {
    $singleFile = Get-Item -LiteralPath $Folder
    if ($singleFile.Extension -notin '.zip', '.scs') {
        throw "File '$Folder' is not a supported archive (.zip or .scs)."
    }
    $files = @($singleFile)
}

$ThrottleLimit = Resolve-ArchiveThrottleLimit -Requested $ThrottleLimit -IsFolderInput $isFolderInput

$replacedCount = 0
$wouldReplaceCount = 0
$skippedCount = 0
$failedCount = 0
$declinedCount = 0

if (-not $WorkerMode.IsPresent -and $files.Count -gt 1 -and $ThrottleLimit -gt 1) {
    $workerParameters = @{ ToolsFolder = $ToolsFolder }
    if ($NoBackup.IsPresent) { $workerParameters.NoBackup = $true }
    Write-Host "Processing $($files.Count) archives with up to $ThrottleLimit workers.`n" -ForegroundColor Cyan
    $workerBatch = Invoke-ArchiveWorkerBatch -ScriptPath $PSCommandPath -ArchivePaths @($files | ForEach-Object { $_.FullName }) -WorkerParameters $workerParameters -Operation 'Replace original with repacked HashFS archive' -ThrottleLimit $ThrottleLimit -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
    $declinedCount += $workerBatch.DeclinedPaths.Count

    foreach ($worker in $workerBatch.Results) {
        if ($worker.Result) {
            $replacedCount += $worker.Result.Replaced
            $wouldReplaceCount += $worker.Result.WouldReplace
            $skippedCount += $worker.Result.Skipped
            $failedCount += $worker.Result.Failed
            $declinedCount += $worker.Result.Declined
        } else {
            $failedCount++
            Write-Host "Worker failed for '$($worker.Path)': $($worker.Errors -join '; ')" -ForegroundColor Red
        }
    }

    Write-Host "`nSummary: $replacedCount replaced, $wouldReplaceCount would replace, $skippedCount skipped, $failedCount repack failed, $declinedCount declined.`n" -ForegroundColor Cyan
    return
}

foreach ($file in $files) {
    $archiveLock = Enter-ArchivePathLock -Path $file.FullName
    try {
    $applyArchive = if ($WorkerMode.IsPresent) {
        $ApplyFixes.IsPresent
    } else {
        Test-ArchiveOperationApproval -Target $file.FullName -Operation 'Replace original with repacked HashFS archive' -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
    }
    if ($ApplyFixes.IsPresent -and -not $applyArchive -and -not $WhatIfPreference) {
        Write-Host "Replacement declined: $($file.FullName)" -ForegroundColor Yellow
        $declinedCount++
        continue
    }

    $archiveKind = Get-SCSArchiveKind -Path $file.FullName

    if ($archiveKind -eq 'HashFS') {
        Write-Host "Skipping HashFS archive: $($file.Name)" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    if ($archiveKind -ne 'ZIPFS') {
        Write-Host "Skipping unreadable or unsupported archive: $($file.Name)" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    if (-not (Test-ZipArchiveReadable -Path $file.FullName)) {
        Write-Host "Skipping encrypted or broken ZIP archive: $($file.Name)" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zipfs-check-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -WhatIf:$false | Out-Null

    try {
        Write-Host "Extracting: $($file.Name)" -ForegroundColor Cyan

        Expand-ZIPFSArchive -ArchivePath $file.FullName -DestinationPath $tempRoot -SevenZip $SevenZipExe

        $tempOutput = Join-Path -Path $tempRoot -ChildPath ('repacked-' + [System.IO.Path]::GetFileName($file.Name))
        if (Test-Path -LiteralPath $tempOutput) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }

        Write-Host "Trying HashFS repack for: $($file.Name)" -ForegroundColor DarkGray
        try {
            New-HashFSArchive -SourceDirectory $tempRoot -DestinationPath $tempOutput -Packer $PackerExe
        } catch {
            Write-Host "Repack failed; no changes made: $($file.Name)" -ForegroundColor Red
            Write-Host $_.Exception.Message -ForegroundColor Red
            $failedCount++
            continue
        }

        if ($applyArchive) {
            Write-Host "Repack succeeded: $($file.Name)" -ForegroundColor Green
            if (-not $NoBackup.IsPresent) {
                Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force
            }
            Move-Item -LiteralPath $tempOutput -Destination $file.FullName -Force
            $replacedCount++
        }
        else {
            Write-Host "Repack succeeded: $($file.Name)" -ForegroundColor Green
            Write-Host "Would replace: $($file.FullName)" -ForegroundColor Yellow
            $wouldReplaceCount++
        }
    }
    catch {
        Write-Host "Failed to process archive: $($file.Name)" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor Red
        $failedCount++
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
    } finally {
        Exit-ArchivePathLock -Mutex $archiveLock
    }
}

if ($WorkerMode.IsPresent) {
    [PSCustomObject]@{
        WorkerResult = $true
        Replaced = $replacedCount
        WouldReplace = $wouldReplaceCount
        Skipped = $skippedCount
        Failed = $failedCount
        Declined = $declinedCount
    }
    return
}

Write-Host "`nSummary: $replacedCount replaced, $wouldReplaceCount would replace, $skippedCount skipped, $failedCount repack failed, $declinedCount declined.`n" -ForegroundColor Cyan
