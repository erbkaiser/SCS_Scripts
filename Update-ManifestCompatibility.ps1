<#
.SYNOPSIS
Updates manifest compatibility versions in ATS/ETS2 mod archives.

.DESCRIPTION
Finds compatible_versions entries for the previous game version and updates ZIPFS or HashFS
archives to the configured target version. Accepts a folder or one .scs/.zip archive.

Runs in dry-run mode by default. Use -ApplyFixes to repack changed archives; a .bak backup is
created before replacement unless -NoBackup is specified. -WhatIf previews apply operations.
Archive workers default to four for folder input and one for a single archive; override with
-ThrottleLimit. Use -Silent, -Quiet, or -Q to suppress status output. Archive tools are resolved
from the script folder by default, then from PATH.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Alias('Path', 'Root')]
    [string]$Folder = (Get-Location).Path,
    [string]$ToolsFolder = $PSScriptRoot,
    [switch]$NoBackup,
    [Alias('Quiet', 'Q')]
    [switch]$Silent,
    [Alias('Apply', 'Fix')]
    [switch]$ApplyFixes,
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

    Write-ArchiveStatus @PSBoundParameters -Quiet:$Quiet.IsPresent
}

$parallelHelper = Join-Path $PSScriptRoot 'Archive-Parallelism.psm1'
Import-Module -Name $parallelHelper -Force
$archiveOperations = Join-Path $PSScriptRoot 'Archive-Operations.psm1'
Import-Module -Name $archiveOperations -Force
$version = '1.62'
$previousVersion = ([decimal]$version - 0.01).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
#$previousVersion = '1.60'

if (($version -notmatch '^\d+\.\d{2}$') -or ($previousVersion -notmatch '^\d+\.\d{2}$')) {
    throw '$version must use the major.minor format, for example 1.61'
}

if ($version -eq $previousVersion -or [decimal]$version -lt [decimal]$previousVersion) {
    throw '$version must be newer than $previousVersion'
}

function Get-ManifestChanges {
    param([string]$Path)

    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        [void]$lines.Add($line)
    }

    $activeCompatibility = @($lines | Where-Object { $_ -match '^\s*compatible_versions\[\]' })
    $previousPattern = [regex]::Escape($previousVersion)
    $targetPattern = [regex]::Escape($version)
    $previousLinePattern = '^\s*compatible_versions\[\]\s*:\s*"' + $previousPattern + '\.\*"\s*$'
    $targetLinePattern = '^\s*compatible_versions\[\]\s*:\s*"' + $targetPattern + '\.\*"\s*$'
    $activePrevious = @($lines | Where-Object { $_ -match $previousLinePattern })
    $activeTarget = @($lines | Where-Object { $_ -match $targetLinePattern })

    if ($activePrevious.Count -eq 0 -or $activeTarget.Count -gt 0) {
        return $null
    }

    if ($activeCompatibility.Count -eq 1) {
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match ('^(\s*)compatible_versions\[\]\s*:\s*"' + $previousPattern + '\.\*"\s*$')) {
                $indent = $Matches[1]
                $lines[$index] = '{0}#compatible_versions[]: "{1}.*"' -f $indent, $previousVersion
                break
            }
        }
    } else {
        $insertAt = -1
        for ($index = 0; $index -lt $lines.Count; $index++) {
            if ($lines[$index] -match '^\s*compatible_versions\[\]') {
                $insertAt = $index + 1
            }
        }

        if ($insertAt -lt 0) {
            return $null
        }

        $indent = ([regex]::Match($lines[$insertAt - 1], '^\s*')).Value
        $lines.Insert($insertAt, '{0}compatible_versions[]: "{1}.*"' -f $indent, $version)
    }

    return $lines.ToArray()
}

function Update-Manifest {
    param(
        [string]$ManifestPath,
        [switch]$ApplyFixes
    )

    $updatedLines = Get-ManifestChanges $ManifestPath
    if ($null -eq $updatedLines) {
        return $false
    }

    if ($ApplyFixes.IsPresent) {
        [System.IO.File]::WriteAllLines($ManifestPath, $updatedLines, [System.Text.UTF8Encoding]::new($false))
    }
    return $true
}

function Invoke-SCSArchive {
    param(
        [System.IO.FileInfo]$Archive,
        [string]$Packer,
        [string]$WorkRoot,
        [switch]$NoBackup,
        [switch]$ApplyFixes
    )

    $work = Join-Path $WorkRoot ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $work -WhatIf:$false | Out-Null
    try {
        Expand-HashFSArchive -ArchivePath $Archive.FullName -DestinationPath $work -Packer $Packer

        $changed = @(Get-ChildItem -Path $work -Filter 'manifest.sii' -File -Recurse | ForEach-Object {
            Update-Manifest $_.FullName -ApplyFixes:$ApplyFixes.IsPresent
        } | Where-Object { $_ }).Count -gt 0

        if (-not $changed) {
            return $false
        }

        if (-not $ApplyFixes.IsPresent) {
            return $true
        }

        $replacement = Join-Path $WorkRoot "$($Archive.Name).new"
        New-HashFSArchive -SourceDirectory $work -DestinationPath $replacement -Packer $Packer
        if (-not $NoBackup.IsPresent) {
            Copy-Item -LiteralPath $Archive.FullName -Destination "$($Archive.FullName).bak" -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $replacement -Destination $Archive.FullName -Force
        return $true
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

function Invoke-ZIPArchive {
    param(
        [System.IO.FileInfo]$Archive,
        [string]$SevenZip,
        [string]$WorkRoot,
        [switch]$NoBackup,
        [switch]$ApplyFixes
    )

    if (Test-ZipArchiveEncrypted -Path $Archive.FullName) {
        Write-Status "Skipping encrypted ZIP archive: $($Archive.Name)" -ForegroundColor Yellow
        return $false
    }

    $work = Join-Path $WorkRoot ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $work -WhatIf:$false | Out-Null
    try {
        Expand-ZIPFSArchive -ArchivePath $Archive.FullName -DestinationPath $work -SevenZip $SevenZip

        $changed = @(Get-ChildItem -Path $work -Filter 'manifest.sii' -File -Recurse | ForEach-Object {
            Update-Manifest $_.FullName -ApplyFixes:$ApplyFixes.IsPresent
        } | Where-Object { $_ }).Count -gt 0

        if (-not $changed) {
            return $false
        }

        if (-not $ApplyFixes.IsPresent) {
            return $true
        }

        $replacement = Join-Path $WorkRoot "$($Archive.Name).new"
        New-ZIPFSArchive -SourceDirectory $work -DestinationPath $replacement -SevenZip $SevenZip
        if (-not $NoBackup.IsPresent) {
            Copy-Item -LiteralPath $Archive.FullName -Destination "$($Archive.FullName).bak" -Force -ErrorAction Stop
        }
        Move-Item -LiteralPath $replacement -Destination $Archive.FullName -Force
        return $true
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

$packer = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('scs_packer.exe') -Required
if (-not (Test-Path -LiteralPath $Folder)) {
    throw "Path '$Folder' does not exist."
}

$isFolderInput = Test-Path -LiteralPath $Folder -PathType Container
if ($isFolderInput) {
    $archives = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object { $_.Extension -in '.scs', '.zip' } | Sort-Object -Property FullName)
} else {
    $singleArchive = Get-Item -LiteralPath $Folder
    if ($singleArchive.Extension -notin '.scs', '.zip') {
        throw "File '$Folder' is not a supported archive (.scs or .zip)."
    }
    $archives = @($singleArchive)
}
$ThrottleLimit = Resolve-ArchiveThrottleLimit -Requested $ThrottleLimit -IsFolderInput $isFolderInput
if ($archives.Count -eq 0) {
    throw 'This file must be run inside the ETS2 or ATS mod folder'
}

$sevenZip = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('7z.exe', '7za.exe', '7z')

$updatedCount = 0
$wouldUpdateCount = 0
$skippedCount = 0
$unreadableCount = 0
$declinedCount = 0

if (-not $WorkerMode.IsPresent -and $archives.Count -gt 1 -and $ThrottleLimit -gt 1) {
    $workerParameters = @{ ToolsFolder = $ToolsFolder }
    if ($NoBackup.IsPresent) { $workerParameters.NoBackup = $true }
    if ($Quiet.IsPresent) { $workerParameters.Silent = $true }
    Write-Status "Processing $($archives.Count) archives with up to $ThrottleLimit workers.`n" -ForegroundColor Cyan
    $workerBatch = Invoke-ArchiveWorkerBatch -ScriptPath $PSCommandPath -ArchivePaths @($archives | ForEach-Object { $_.FullName }) -WorkerParameters $workerParameters -Operation 'Replace archive with updated manifest' -ThrottleLimit $ThrottleLimit -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
    $declinedCount += $workerBatch.DeclinedPaths.Count

    foreach ($worker in $workerBatch.Results) {
        if ($worker.Result) {
            $updatedCount += $worker.Result.Updated
            $wouldUpdateCount += $worker.Result.WouldUpdate
            $skippedCount += $worker.Result.Skipped
            $unreadableCount += $worker.Result.Unreadable
            $declinedCount += $worker.Result.Declined
        } else {
            $unreadableCount++
            Write-Status "Worker failed for '$($worker.Path)': $($worker.Errors -join '; ')" -ForegroundColor Red
        }
    }

    Microsoft.PowerShell.Utility\Write-Host "Summary: $updatedCount updated, $wouldUpdateCount would update, $skippedCount skipped, $unreadableCount could not be read, $declinedCount declined."
    return
}

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "manifest-update-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $workRoot -WhatIf:$false | Out-Null

try {
    foreach ($archive in $archives) {
        $archiveLock = Enter-ArchivePathLock -Path $archive.FullName
        try {
        $applyArchive = if ($WorkerMode.IsPresent) {
            $ApplyFixes.IsPresent
        } else {
            Test-ArchiveOperationApproval -Target $archive.FullName -Operation 'Replace archive with updated manifest' -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
        }
        if ($ApplyFixes.IsPresent -and -not $applyArchive -and -not $WhatIfPreference) {
            $declinedCount++
            continue
        }
        try {
            $isSCS = (Get-SCSArchiveKind -Path $archive.FullName) -eq 'HashFS'

            $changed = $false
            if ($isSCS) {
                try {
                    $changed = Invoke-ZIPArchive $archive $sevenZip $workRoot -NoBackup:$NoBackup.IsPresent -ApplyFixes:$applyArchive
                } catch {
                    $changed = Invoke-SCSArchive $archive $packer $workRoot -NoBackup:$NoBackup.IsPresent -ApplyFixes:$applyArchive
                }
            } else {
                $changed = Invoke-ZIPArchive $archive $sevenZip $workRoot -NoBackup:$NoBackup.IsPresent -ApplyFixes:$applyArchive
            }

            if ($changed) {
                if ($applyArchive) {
                    $updatedCount++
                    Write-Status "Updated: $($archive.Name)"
                } else {
                    $wouldUpdateCount++
                    Write-Status "Would update: $($archive.FullName)" -ForegroundColor Yellow
                }
            } else {
                $skippedCount++
                Write-Status "Skipped: $($archive.Name)"
            }
        } catch {
            $unreadableCount++
            Write-Status "Could not read: $($archive.Name) ($($_.Exception.Message))"
        }
        } finally {
            Exit-ArchivePathLock -Mutex $archiveLock
        }
    }
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
}

if ($WorkerMode.IsPresent) {
    [PSCustomObject]@{
        WorkerResult = $true
        Updated = $updatedCount
        WouldUpdate = $wouldUpdateCount
        Skipped = $skippedCount
        Unreadable = $unreadableCount
        Declined = $declinedCount
    }
    return
}

Microsoft.PowerShell.Utility\Write-Host "Summary: $updatedCount updated, $wouldUpdateCount would update, $skippedCount skipped, $unreadableCount could not be read, $declinedCount declined."