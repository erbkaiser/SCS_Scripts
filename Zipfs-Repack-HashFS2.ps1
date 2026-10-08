#Requires -Version 5.1

<#
.SYNOPSIS
Checks ZIPFS mod archives and tests repacking them as HashFS.

.DESCRIPTION
Scans a folder recursively or processes one .zip/.scs archive. It skips HashFS, unreadable,
encrypted, and broken archives, extracts readable ZIPFS archives, then attempts a HashFS repack.
Successful .zip conversions are written with a .scs extension. ZIPFS .scs inputs are replaced
in place. Existing .scs destinations are not overwritten.

Runs in dry-run mode by default. Use -ApplyFixes to replace archives; a .bak backup is created
unless -NoBackup is specified. -WhatIf previews apply operations. Archive workers default to
four for folder input and one for a single archive; override with -ThrottleLimit. Use -Silent
(or -Q) to suppress status output.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder = (Get-Location).Path,
    [string]$ToolsFolder = (Get-Location).Path,
    [Alias('Apply', 'Fix')]
    [switch]$ApplyFixes,
    [switch]$NoBackup,
    [Alias('Q')]
    [switch]$Silent,
    [Parameter(HelpMessage = 'Maximum simultaneous archive workers; defaults to four for folders and one for a single archive.')]
    [ValidateRange(0, 64)]
    [int]$ThrottleLimit = 0,
    [switch]$WorkerMode
)

$ErrorActionPreference = 'Stop'
$Quiet = $Silent
function Write-Status {
    param(
        [Parameter(Position = 0)][object]$Object,
        [System.ConsoleColor]$ForegroundColor,
        [System.ConsoleColor]$BackgroundColor,
        [switch]$NoNewline
    )

    if (-not $Quiet.IsPresent) {
        $hostParameters = @{ Object = $Object }
        if ($PSBoundParameters.ContainsKey('ForegroundColor')) { $hostParameters.ForegroundColor = $ForegroundColor }
        if ($PSBoundParameters.ContainsKey('BackgroundColor')) { $hostParameters.BackgroundColor = $BackgroundColor }
        if ($NoNewline.IsPresent) { $hostParameters.NoNewline = $true }
        Write-Host @hostParameters
    }
}

$parallelHelper = Join-Path $PSScriptRoot 'Archive-Parallelism.psm1'
Import-Module -Name $parallelHelper -Force
$archiveOperations = Join-Path $PSScriptRoot 'Archive-Operations.psm1'
Import-Module -Name $archiveOperations -Force
$ModeLabel = if (-not $ApplyFixes.IsPresent) { 'Dry run' } elseif ($WhatIfPreference) { 'WhatIf dry run' } else { 'Apply fixes' }
Write-Status "Mode: $ModeLabel.`n" -ForegroundColor Cyan

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
    if ($Quiet.IsPresent) { $workerParameters.Silent = $true }
    Write-Status "Processing $($files.Count) archives with up to $ThrottleLimit workers.`n" -ForegroundColor Cyan
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
            Write-Status "Worker failed for '$($worker.Path)': $($worker.Errors -join '; ')" -ForegroundColor Red
        }
    }

    Microsoft.PowerShell.Utility\Write-Host "`nSummary: $replacedCount replaced, $wouldReplaceCount would replace, $skippedCount skipped, $failedCount repack failed, $declinedCount declined.`n" -ForegroundColor Cyan
    return
}

foreach ($file in $files) {
    $archiveLock = Enter-ArchivePathLock -Path $file.FullName
    $destinationLock = $null
    try {
    $destinationPath = if ($file.Extension -eq '.zip') {
        [System.IO.Path]::ChangeExtension($file.FullName, '.scs')
    } else {
        $file.FullName
    }

    if ($destinationPath -ne $file.FullName) {
        $destinationLock = Enter-ArchivePathLock -Path $destinationPath
        if (Test-Path -LiteralPath $destinationPath) {
            Write-Status "Skipping ZIP conversion because the .scs destination already exists: $destinationPath" -ForegroundColor Yellow
            $skippedCount++
            continue
        }
    }

    $applyArchive = if ($WorkerMode.IsPresent) {
        $ApplyFixes.IsPresent
    } else {
        Test-ArchiveOperationApproval -Target $file.FullName -Operation 'Replace original with repacked HashFS archive' -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
    }
    if ($ApplyFixes.IsPresent -and -not $applyArchive -and -not $WhatIfPreference) {
        Write-Status "Replacement declined: $($file.FullName)" -ForegroundColor Yellow
        $declinedCount++
        continue
    }

    $archiveKind = Get-SCSArchiveKind -Path $file.FullName
    Write-Status "Detected archive: $($file.Name) [$archiveKind]" -ForegroundColor DarkGray

    if ($archiveKind -eq 'HashFS') {
        Write-Status "Skipping HashFS archive: $($file.Name)" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    if ($archiveKind -ne 'ZIPFS') {
        Write-Status "Skipping unreadable or unsupported archive: $($file.Name)" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    if (-not (Test-ZipArchiveReadable -Path $file.FullName)) {
        Write-Status "Skipping encrypted or broken ZIP archive: $($file.Name)" -ForegroundColor Yellow
        $skippedCount++
        continue
    }

    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("zipfs-check-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot -WhatIf:$false | Out-Null

    try {
        Write-Status "Extracting: $($file.Name)" -ForegroundColor Cyan

        Expand-ZIPFSArchive -ArchivePath $file.FullName -DestinationPath $tempRoot -SevenZip $SevenZipExe

        $tempOutput = Join-Path -Path $tempRoot -ChildPath 'repacked-hashfs.scs'
        if (Test-Path -LiteralPath $tempOutput) {
            Remove-Item -LiteralPath $tempOutput -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }

        Write-Status "Trying HashFS repack for: $($file.Name)" -ForegroundColor DarkGray
        try {
            New-HashFSArchive -SourceDirectory $tempRoot -DestinationPath $tempOutput -Packer $PackerExe
        } catch {
            Write-Status "Repack failed; no changes made: $($file.Name)" -ForegroundColor Red
            Write-Status $_.Exception.Message -ForegroundColor Red
            $failedCount++
            continue
        }

        if ($applyArchive) {
            Write-Status "Repack succeeded: $($file.Name)" -ForegroundColor Green
            if (-not $NoBackup.IsPresent) {
                Copy-Item -LiteralPath $file.FullName -Destination "$($file.FullName).bak" -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $tempOutput -Destination $destinationPath -Force
            if ($destinationPath -ne $file.FullName) {
                Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
                Write-Status "Converted: $($file.FullName) -> $destinationPath" -ForegroundColor Green
            }
            elseif ($file.Extension -eq '.scs') {
                Write-Status "Repacked ZIPFS .scs as HashFS in place: $($file.FullName)" -ForegroundColor Green
            }
            $replacedCount++
        }
        else {
            Write-Status "Repack succeeded: $($file.Name)" -ForegroundColor Green
            if ($destinationPath -ne $file.FullName) {
                Write-Status "Would convert: $($file.FullName) -> $destinationPath" -ForegroundColor Yellow
            } elseif ($file.Extension -eq '.scs') {
                Write-Status "Would replace ZIPFS .scs with HashFS .scs: $($file.FullName)" -ForegroundColor Yellow
            } else {
                Write-Status "Would replace: $($file.FullName)" -ForegroundColor Yellow
            }
            $wouldReplaceCount++
        }
    }
    catch {
        Write-Status "Failed to process archive: $($file.Name)" -ForegroundColor Red
        Write-Status $_.Exception.Message -ForegroundColor Red
        $failedCount++
    }
    finally {
        if (Test-Path -LiteralPath $tempRoot) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
        }
    }
    } finally {
        if ($destinationLock) {
            Exit-ArchivePathLock -Mutex $destinationLock
        }
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

Microsoft.PowerShell.Utility\Write-Host "`nSummary: $replacedCount replaced, $wouldReplaceCount would replace, $skippedCount skipped, $failedCount repack failed, $declinedCount declined.`n" -ForegroundColor Cyan
