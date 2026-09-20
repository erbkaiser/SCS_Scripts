<#  
    Update-ManifestCompatibility.ps1
    -----------------------
    When run inside an ETS2 or ATS mod folder, updates every compatibility line to $version
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$Folder = (Get-Location).Path,
    [string]$ToolsFolder = (Get-Location).Path,
    #[string]$ToolsFolder = C:\Tools,
    [switch]$NoBackup
)

$ErrorActionPreference = 'Stop'
$version = '1.61'
$archiveToolTimeoutSeconds = 30
$previousVersion = ([decimal]$version - 0.01).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)
#$previousVersion = '1.60'

if (($version -notmatch '^\d+\.\d{2}$') -or ($previousVersion -notmatch '^\d+\.\d{2}$')) {
    throw '$version must use the major.minor format, for example 1.61'
}

if ($version -eq $previousVersion -or [decimal]$version -lt [decimal]$previousVersion) {
    throw '$version must be newer than $previousVersion'
}

function Get-ToolPath {
    param([string[]]$Names)

    foreach ($name in $Names) {
        $candidate = Join-Path $ToolsFolder $name
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return $candidate
        }

        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            return $command.Source
        }
    }

    throw "Could not find any of: $($Names -join ', ')"
}

function Invoke-ArchiveTool {
    param(
        [string]$Tool,
        [string[]]$Arguments,
        [int]$TimeoutSeconds = $archiveToolTimeoutSeconds
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Tool
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Arguments = ($Arguments | ForEach-Object {
        '"{0}"' -f (($_ -replace '(\\*)"', '$1$1\"') -replace '(\\+)$', '$1$1')
    }) -join ' '

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) {
            throw "Could not start archive tool: $Tool"
        }

        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw [System.TimeoutException]::new("Archive tool timed out after $TimeoutSeconds seconds: $Tool $($Arguments -join ' ')")
        }

        $outputTask.GetAwaiter().GetResult() | Out-Null
        $errorTask.GetAwaiter().GetResult() | Out-Null
        if ($process.ExitCode -ne 0) {
            throw "Archive tool failed with exit code $($process.ExitCode): $Tool $($Arguments -join ' ')"
        }
    } finally {
        $process.Dispose()
    }
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
    param([string]$ManifestPath)

    $updatedLines = Get-ManifestChanges $ManifestPath
    if ($null -eq $updatedLines) {
        return $false
    }

    [System.IO.File]::WriteAllLines($ManifestPath, $updatedLines, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Invoke-SCSArchive {
    param(
        [System.IO.FileInfo]$Archive,
        [string]$Extractor,
        [string]$Packer,
        [string]$WorkRoot
    )

    $work = Join-Path $WorkRoot ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Push-Location $work
        try {
            Invoke-ArchiveTool $Extractor @($Archive.FullName)
        } finally {
            Pop-Location
        }

        $changed = @(Get-ChildItem -Path $work -Filter 'manifest.sii' -File -Recurse | ForEach-Object {
            Update-Manifest $_.FullName
        } | Where-Object { $_ }).Count -gt 0

        if (-not $changed) {
            return $false
        }

        $replacement = Join-Path $WorkRoot "$($Archive.Name).new"
        Invoke-ArchiveTool $Packer @('create', $replacement, '-root', $work)
        Move-Item -LiteralPath $replacement -Destination $Archive.FullName -Force
        return $true
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-ZIPArchive {
    param(
        [System.IO.FileInfo]$Archive,
        [string]$SevenZip,
        [string]$WorkRoot
    )

    $work = Join-Path $WorkRoot ([guid]::NewGuid().ToString())
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        Invoke-ArchiveTool $SevenZip @('x', '-y', "-o$work", $Archive.FullName)

        $changed = @(Get-ChildItem -Path $work -Filter 'manifest.sii' -File -Recurse | ForEach-Object {
            Update-Manifest $_.FullName
        } | Where-Object { $_ }).Count -gt 0

        if (-not $changed) {
            return $false
        }

        $replacement = Join-Path $WorkRoot "$($Archive.Name).new"
        $contents = Join-Path $work '*'
        Invoke-ArchiveTool $SevenZip @('a', '-tzip', '-y', $replacement, $contents)
        Move-Item -LiteralPath $replacement -Destination $Archive.FullName -Force
        return $true
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$extractor = Join-Path $ToolsFolder 'scs_extractor.exe'
$packer = Join-Path $ToolsFolder 'scs_packer.exe'
$archives = @(Get-ChildItem -LiteralPath $Folder -File | Where-Object { $_.Extension -in '.scs', '.zip' })
if ($archives.Count -eq 0) {
    throw 'This file must be run inside the ETS2 or ATS mod folder'
}

if (-not (Test-Path -LiteralPath $extractor -PathType Leaf)) { throw "Missing SCS extractor: $extractor" }
if (-not (Test-Path -LiteralPath $packer -PathType Leaf)) { throw "Missing SCS packer: $packer" }
$sevenZip = Get-ToolPath @('7z.exe', '7za.exe', '7z')

$workRoot = Join-Path ([System.IO.Path]::GetTempPath()) "manifest-update-$([guid]::NewGuid())"
New-Item -ItemType Directory -Path $workRoot | Out-Null
$updatedCount = 0
$skippedCount = 0
$unreadableCount = 0

try {
    foreach ($archive in $archives) {
        if ($PSCmdlet.ShouldProcess($archive.Name, 'Inspect and update manifest.sii')) {
            $backupPath = "$($archive.FullName).bak"
            $backupCreated = $false
            try {
                $bytes = [System.IO.File]::ReadAllBytes($archive.FullName)
                $isSCS = $bytes.Length -ge 4 -and [System.Text.Encoding]::ASCII.GetString($bytes[0..3]) -eq 'SCS#'

                if (-not $NoBackup) {
                    Copy-Item -LiteralPath $archive.FullName -Destination $backupPath -Force
                    $backupCreated = $true
                }

                $changed = $false
                if ($isSCS) {
                    try {
                        $changed = Invoke-ZIPArchive $archive $sevenZip $workRoot
                    } catch {
                        $changed = Invoke-SCSArchive $archive $extractor $packer $workRoot
                    }
                } else {
                    $changed = Invoke-ZIPArchive $archive $sevenZip $workRoot
                }

                if ($changed) {
                    $updatedCount++
                    Write-Host "Updated: $($archive.Name)"
                } else {
                    $skippedCount++
                    Write-Host "Skipped: $($archive.Name)"
                    if ($backupCreated) {
                        Remove-Item -LiteralPath $backupPath -Force
                    }
                }
            } catch {
                if ($backupCreated) {
                    Remove-Item -LiteralPath $backupPath -Force -ErrorAction SilentlyContinue
                }
                if ($_.Exception -is [System.TimeoutException]) {
                    $skippedCount++
                    Write-Host "Skipped: $($archive.Name) (archive tool timed out after $archiveToolTimeoutSeconds seconds)"
                } else {
                    $unreadableCount++
                    Write-Host "Could not read: $($archive.Name) ($($_.Exception.Message))"
                }
            }
        }
    }
} finally {
    Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "Summary: $updatedCount updated, $skippedCount skipped, $unreadableCount could not be read."
