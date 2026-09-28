#Requires -Version 5.1

#Version: 2.1.0
#Updated: 2026-09-28

Function Repair-ScsTrafficVariants {
    <#
        .SYNOPSIS
        Repairs malformed traffic variant identifiers in ETS2/ATS unit definitions.

        .DESCRIPTION
        Corrects invalid leading-dot prefixes in:
          - variant[]
          - slave_trailer
          - traffic_vehicle
          - traffic_trailer

        Works on directories or on .scs/.zip archives. In archive mode it extracts to a temp folder,
        repairs files, and repacks the archive if any changes were made.

        By default it runs in dry-run mode and only reports findings. Use -ApplyFixes to write files.
        Archive workers default to four for folder input and one for a single archive; override with -ThrottleLimit.
    #>

    [CmdletBinding(SupportsShouldProcess = $True, ConfirmImpact = 'Medium')]
    [OutputType([Void], [PSCustomObject[]])]

    Param (
        [Parameter(Mandatory, Position = 0)]
        [Alias('Path', 'Root', 'Folder')]
        [string[]]$RootPath,

        [Parameter(Position = 1)]
        [ValidateSet('variant', 'slave_trailer', 'traffic_vehicle', 'traffic_trailer')]
        [Alias('Repair', 'Attrib')]
        [string[]]$Attribute,

        [Parameter(Position = 2)]
        [string]$ToolsFolder = (Get-Location).Path,

        [Alias('Apply', 'Fix')]
        [switch]$ApplyFixes,

        [switch]$NoBackup,

        [Alias('Full')]
        [switch]$FullScan,

        [Alias('Silent', 'Q')]
        [switch]$Quiet,

        [Parameter(HelpMessage = 'Maximum simultaneous archive workers; defaults to four for folders and one for a single archive.')]
        [ValidateRange(0, 64)]
        [int]$ThrottleLimit = 0,

        [switch]$WorkerMode
    )

    $IsQuiet = $Quiet.IsPresent
    $parallelHelper = Join-Path $PSScriptRoot 'Archive-Parallelism.psm1'
    Import-Module -Name $parallelHelper -Force
    $archiveOperations = Join-Path $PSScriptRoot 'Archive-Operations.psm1'
    Import-Module -Name $archiveOperations -Force

    if ($Attribute.Count -eq 0) {
        $TargetAttributes = @('variant', 'slave_trailer', 'traffic_vehicle', 'traffic_trailer')
    } else {
        $TargetAttributes = ($Attribute | ForEach-Object { $_.ToLower() }) | Select-Object -Unique
    }

    # Resolve tool paths
    $ScriptDir = $PSScriptRoot
    if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Path $MyInvocation.MyCommand.Path -Parent }
    if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Path (Get-Item -Path $MyInvocation.InvocationName).FullName -Parent }
    if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Split-Path -Path $MyInvocation.PSCommandPath -Parent }
    if ([string]::IsNullOrEmpty($ScriptDir)) { $ScriptDir = Get-Location }

    $ExtractorExe = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('scs_extractor.exe')
    $PackerExe    = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('scs_packer.exe')
    $SevenZipExe  = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('7z.exe', '7za.exe', '7z')

    $Patterns = @{
        'variant'         = [Regex]::New('(?<=variant\[\][ \t]*:[ \t]*)\.[^\s]+', 520)
        'slave_trailer'   = [Regex]::New('(?<=slave_trailer[ \t]*:[ \t]*)\.[^\s]+', 520)
        'traffic_vehicle' = [Regex]::New('(?<=traffic_vehicle[ \t]*:[ \t]*)\.[^\s]+', 520)
        'traffic_trailer' = [Regex]::New('(?<=traffic_trailer[ \t]*:[ \t]*)\.[^\s]+', 520)
        'LeadingDot'      = [Regex]::New('^\.', 520)
    }

    $AllProblems = [System.Collections.Generic.List[PSCustomObject]]::new()
    $Summary = [PSCustomObject]@{
        UnitFilesRepaired = 0
        ArchivesUpdated = 0
        ZipFallbackArchives = 0
        WouldRepair = 0
        WouldUpdateArchives = 0
        SkippedArchives = 0
        UnreadableArchives = 0
        FailedRepack = 0
        DeclinedOperations = 0
        ArchiveReports = [System.Collections.Generic.List[PSCustomObject]]::new()
    }

    function Add-ArchiveReport {
        param(
            [string]$ArchivePath,
            [int]$DefinitionCount,
            [int]$ReferenceCount,
            [string]$Outcome
        )

        $Summary.ArchiveReports.Add([PSCustomObject]@{
            ArchivePath = $ArchivePath
            DefinitionCount = $DefinitionCount
            ReferenceCount = $ReferenceCount
            Outcome = $Outcome
        })
    }

    $PathSuffix = if ($FullScan.IsPresent) { '' } else { '\def' }

    function Process-RootTarget {
        param(
            [System.IO.FileSystemInfo]$InputItem
        )

        $WorkingPath = $InputItem
        $IsArchive = $false
        $UsesZipFallback = $false
        $AnyRepairs = $false
        $AnyAppliedRepairs = $false
        $OriginalArchivePath = $null
        $ArchiveDefinitionCount = 0
        $ArchiveReferenceCount = 0
        $ArchiveDeclinedCount = 0
        $ArchiveVerificationFailures = 0

        if ($InputItem -is [System.IO.FileInfo]) {
            if ($InputItem.Extension -notin '.scs', '.zip') {
                Write-Error "The path '$($InputItem.FullName)' is not a directory or a supported archive file (.scs or .zip)."
                return
            }

            $OriginalArchivePath = $InputItem.FullName
            $IsArchive = $true

            $detectedKind = Get-SCSArchiveKind -Path $InputItem.FullName
            if ($detectedKind -eq 'Unreadable') {
                $Summary.UnreadableArchives++
                Add-ArchiveReport -ArchivePath $InputItem.FullName -DefinitionCount 0 -ReferenceCount 0 -Outcome 'could not be read; left unchanged'
                Write-Error "Cannot read '$($InputItem.Name)'. Aborting without modifying the original file."
                return
            }
            $archiveType = if ($InputItem.Extension -eq '.zip' -or $detectedKind -ne 'HashFS') { 'zipfs' } else { 'hashfs' }

            $TempDir = Join-Path -Path $env:TEMP -ChildPath ([System.Guid]::NewGuid().ToString())
            $TempFolder = New-Item -ItemType Directory -Path $TempDir -Force -WhatIf:$false

            try {
                if ($archiveType -eq 'zipfs') {
                    Expand-ZIPFSArchive -ArchivePath $InputItem.FullName -DestinationPath $TempFolder.FullName -SevenZip $SevenZipExe
                    $UsesZipFallback = $true
                } else {
                    if (-not [string]::IsNullOrEmpty($ExtractorExe)) {
                        Expand-HashFSArchive -ArchivePath $InputItem.FullName -DestinationPath $TempFolder.FullName -Extractor $ExtractorExe
                    } else {
                        throw "scs_extractor.exe not found."
                    }
                }

                $WorkingPath = $TempFolder
                if (-not $IsQuiet) {
                    Write-Host "Detected archive: $($InputItem.Name) [$archiveType]" -ForegroundColor DarkGray
                    Write-Host "Extracting to temporary folder..." -ForegroundColor Cyan
                    if ($archiveType -eq 'zipfs') {
                        Write-Host "Repack path: ZIPFS" -ForegroundColor DarkGray
                    } else {
                        Write-Host "Repack path: HashFS -> ZIP fallback if needed" -ForegroundColor DarkGray
                    }
                }
            } catch {
                Remove-Item -Path $TempFolder.FullName -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
                $Summary.UnreadableArchives++
                Add-ArchiveReport -ArchivePath $InputItem.FullName -DefinitionCount 0 -ReferenceCount 0 -Outcome 'could not be read; left unchanged'
                Write-Error "Cannot read '$($InputItem.Name)'. Aborting without modifying the original file.`nError: $_"
                return
            }
        }

        $ScanRoot = $WorkingPath.FullName
        if (-not $FullScan.IsPresent -and -not $IsArchive) {
            $ScanRoot = Join-Path -Path $WorkingPath.FullName -ChildPath 'def'
        }

        if (-not (Test-Path -Path $ScanRoot)) {
            if ($IsArchive) {
                if (-not $IsQuiet) { Write-Host -ForegroundColor Yellow "No def directory found under archive '$($InputItem.Name)'. Cleaning up temporary extraction folder." }
                $Summary.SkippedArchives++
                Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount 0 -ReferenceCount 0 -Outcome 'no definition directory found; skipped'
                Remove-Item -Path $WorkingPath.FullName -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
            } else {
                if (-not $IsQuiet) { Write-Host -ForegroundColor Yellow "No def directory found under '$($WorkingPath.FullName)'. Skipping." }
            }
            return
        }

        $UnitFiles = Get-ChildItem -Path $ScanRoot -Include '*.sii', '*.sui' -File -Recurse -ErrorAction SilentlyContinue

        foreach ($UnitFile in $UnitFiles) {
            $Content = [System.IO.File]::ReadAllText($UnitFile.FullName)
            $MalformedValues = @{ 'Total' = 0 }

            foreach ($Attrib in $TargetAttributes) {
                if ($Patterns[$Attrib].IsMatch($Content)) {
                    $Matches = @($Patterns[$Attrib].Matches($Content).Value)
                    $MalformedValues[$Attrib] = [System.Collections.Generic.List[string]]::new()
                    foreach ($MatchValue in $Matches) {
                        $MalformedValues[$Attrib].Add($MatchValue)
                    }
                    $MalformedValues['Total'] += $Matches.Count
                }
            }

            if ($MalformedValues['Total'] -eq 0) { continue }

            $RelativePath = $UnitFile.FullName.Substring($WorkingPath.FullName.Length).TrimStart('\', '/')
            $RelativePath = $RelativePath -replace [regex]::Escape([System.IO.Path]::DirectorySeparatorChar), '/'

            $FileProblems = [System.Collections.Generic.List[PSCustomObject]]::new()

            foreach ($Attrib in $TargetAttributes) {
                if (-not $MalformedValues.ContainsKey($Attrib)) { continue }
                foreach ($Value in $MalformedValues[$Attrib]) {
                    $AllProblems.Add([PSCustomObject]@{
                        File = $RelativePath
                        'Attribute/Class' = $Attrib
                        Value = $Value
                    })
                    $FileProblems.Add([PSCustomObject]@{
                        'Attribute/Class' = $Attrib
                        Value = $Value
                    })
                }
            }

            if (-not $IsQuiet -and -not $IsArchive) {
                Write-Host $InputItem.BaseName -ForegroundColor DarkGray
                Write-Host " > $RelativePath" -ForegroundColor White
                Write-Host ($FileProblems | Format-Table -Property 'Attribute/Class', 'Value' -AutoSize | Out-String) -ForegroundColor Red
            }

            $NewContent = $Content

            foreach ($Attrib in $TargetAttributes) {
                if (-not $MalformedValues.ContainsKey($Attrib)) { continue }

                foreach ($Value in $MalformedValues[$Attrib]) {
                    $FixedValue = $Patterns['LeadingDot'].Replace($Value, '')
                    $NewContent = [Regex]::Replace($NewContent, [Regex]::Escape($Value), $FixedValue)
                }
            }

            if ($NewContent -eq $Content) {
                if (-not $IsQuiet -and -not $IsArchive) { Write-Host -ForegroundColor Yellow "   No changes produced.`n" }
                continue
            }

            $FailedFixes = @()

            foreach ($Attrib in $TargetAttributes) {
                if ($MalformedValues.ContainsKey($Attrib) -and $Patterns[$Attrib].IsMatch($NewContent)) {
                    $FailedFixes += $Attrib
                }
            }

            if ($FailedFixes.Count -gt 0) {
                if ($IsArchive) { $ArchiveVerificationFailures++ }
                if (-not $IsQuiet) {
                    Write-Host -ForegroundColor Red "   Repair verification failed for '$($FailedFixes -join "', '")'.`n"
                }
                continue
            }

            if ($IsArchive) {
                $ArchiveDefinitionCount++
                $ArchiveReferenceCount += $MalformedValues['Total']
            }

            $writeApproved = $ApplyFixes.IsPresent -and ($WorkerMode.IsPresent -or $PSCmdlet.ShouldProcess($UnitFile.FullName, 'Write repaired content'))
            if ($writeApproved) {
                $AnyRepairs = $true
                if (-not $IsArchive -and -not $NoBackup.IsPresent) {
                    Copy-Item -LiteralPath $UnitFile.FullName -Destination "$($UnitFile.FullName).bak" -Force -ErrorAction Stop
                }
                [System.IO.File]::WriteAllText($UnitFile.FullName, $NewContent)
                $AnyAppliedRepairs = $true
                if (-not $IsQuiet -and -not $IsArchive) {
                    Write-Host -ForegroundColor Green "   $($UnitFile.Name) repaired successfully.`n"
                }
                $Summary.UnitFilesRepaired++
            } elseif (-not $ApplyFixes.IsPresent -or $WhatIfPreference) {
                $AnyRepairs = $true
                $Summary.WouldRepair++
                if (-not $IsQuiet -and -not $IsArchive) {
                    Write-Host -ForegroundColor Cyan "   Dry run: use -ApplyFixes to write changes to $($UnitFile.Name).`n"
                }
            } else {
                $Summary.DeclinedOperations++
                $ArchiveDeclinedCount++
            }
        }

        if ($IsArchive) {
            if (-not $AnyRepairs) {
                if (-not $IsQuiet) {
                    Write-Host -ForegroundColor Yellow "No repairs were needed for '$($InputItem.Name)'. Leaving the original archive intact.`n"
                    Write-Host "Status: skipped" -ForegroundColor DarkYellow
                }
                $Summary.SkippedArchives++
                if ($ArchiveDeclinedCount -gt 0) {
                    $outcome = 'repair declined; left unchanged'
                } elseif ($ArchiveVerificationFailures -gt 0) {
                    $outcome = "repair verification failed for $ArchiveVerificationFailures definition(s); left unchanged"
                } else {
                    $outcome = 'no malformed references found'
                }
                Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome $outcome
                Remove-Item -Path $WorkingPath.FullName -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
                return
            }

            if (-not $ApplyFixes.IsPresent -or -not $AnyAppliedRepairs) {
                if (-not $ApplyFixes.IsPresent -or $WhatIfPreference) {
                    $Summary.WouldUpdateArchives++
                    Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome 'would be updated'
                } else {
                    Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome 'partially declined; left unchanged'
                }
                Remove-Item -Path $WorkingPath.FullName -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
                return
            }

            if (-not $IsQuiet) {
                Write-Host "Repacking archive..." -ForegroundColor Cyan
            }

            try {
                if ($archiveType -eq 'zipfs') {
                    $replacement = "$($OriginalArchivePath).new"
                    if (Test-Path -LiteralPath $replacement) {
                        Remove-Item -LiteralPath $replacement -Force -ErrorAction SilentlyContinue -WhatIf:$false
                    }
                    if (-not $IsQuiet) { Write-Host "Using ZIPFS repack path for $($InputItem.Name)" -ForegroundColor DarkGray }
                    New-ZIPFSArchive -SourceDirectory $WorkingPath.FullName -DestinationPath $replacement -SevenZip $SevenZipExe
                    if (-not $NoBackup.IsPresent) {
                        Copy-Item -LiteralPath $OriginalArchivePath -Destination "$OriginalArchivePath.bak" -Force -ErrorAction Stop
                    }
                    Move-Item -LiteralPath $replacement -Destination $OriginalArchivePath -Force
                    if (-not $IsQuiet) { Write-Host -ForegroundColor Green "Successfully repacked ZIPFS archive: $($InputItem.Name)`n" }
                    if (-not $IsQuiet) { Write-Host "Status: updated" -ForegroundColor Green }
                    $Summary.ArchivesUpdated++
                    $outcome = if ($ArchiveVerificationFailures -gt 0) { "updated; $ArchiveVerificationFailures definition(s) failed verification" } else { 'updated' }
                    Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome $outcome
                } else {
                    try {
                        $replacement = "$($OriginalArchivePath).zip.new"
                        if (-not $IsQuiet) { Write-Host "Using HashFS repack path for $($InputItem.Name)" -ForegroundColor DarkGray }
                        if (Test-Path -LiteralPath $replacement) {
                            Remove-Item -LiteralPath $replacement -Force -ErrorAction SilentlyContinue -WhatIf:$false
                        }

                        $repackResult = New-SCSArchiveWithFallback -SourceDirectory $WorkingPath.FullName -DestinationPath $replacement -Packer $PackerExe -SevenZip $SevenZipExe -AllowZIPFallback

                        if (-not $NoBackup.IsPresent) {
                            Copy-Item -LiteralPath $OriginalArchivePath -Destination "$OriginalArchivePath.bak" -Force -ErrorAction Stop
                        }
                        Move-Item -LiteralPath $replacement -Destination $OriginalArchivePath -Force
                        $Summary.ArchivesUpdated++
                        if ($repackResult.UsedFallback) {
                            if (-not $IsQuiet) {
                                Write-Host "HashFS repack failed; ZIP fallback succeeded for $($InputItem.Name)" -ForegroundColor Yellow
                                Write-Host "Status: updated via ZIP fallback" -ForegroundColor Yellow
                            }
                            $Summary.ZipFallbackArchives++
                        } else {
                            if (-not $IsQuiet) { Write-Host "Status: updated" -ForegroundColor Green }
                        }
                        $outcome = if ($repackResult.UsedFallback) { 'updated via ZIP fallback' } else { 'updated' }
                        if ($ArchiveVerificationFailures -gt 0) { $outcome += "; $ArchiveVerificationFailures definition(s) failed verification" }
                        Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome $outcome
                        if (-not $IsQuiet) { Write-Host -ForegroundColor Green "Successfully repacked HashFS archive as ZIP fallback: $($InputItem.Name)`n" }
                    } catch {
                        if (-not $IsQuiet) {
                            Write-Host -ForegroundColor Yellow "HashFS archive detected: automatic repack failed for '$($InputItem.Name)'.`nThe original archive was left untouched.`n"
                        } else {
                            $AllProblems.Add([PSCustomObject]@{
                                File = $InputItem.Name
                                'Attribute/Class' = 'ArchiveRepackSkipped'
                                Value = 'HashFS repack failed and ZIP fallback also failed'
                            })
                        }
                        if (-not $IsQuiet) { Write-Host "Status: repack failed" -ForegroundColor Red }
                        $Summary.FailedRepack++
                        Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome 'repack failed; original left unchanged'
                        Remove-Item -Path $WorkingPath.FullName -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
                        return
                    }
                }
            } catch {
                $Summary.FailedRepack++
                Add-ArchiveReport -ArchivePath $OriginalArchivePath -DefinitionCount $ArchiveDefinitionCount -ReferenceCount $ArchiveReferenceCount -Outcome 'repack failed; original left unchanged'
                if (-not $IsQuiet) { Write-Host "Status: repack failed" -ForegroundColor Red }
                Write-Error "Failed to repack '$($InputItem.Name)'.`nError: $_"
            } finally {
                Remove-Item -Path $WorkingPath.FullName -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
            }
        }
    }

    function Invoke-LockedArchiveTarget {
        param([System.IO.FileInfo]$ArchiveFile)

        $archiveLock = Enter-ArchivePathLock -Path $ArchiveFile.FullName
        try {
            Process-RootTarget -InputItem $ArchiveFile
        } finally {
            Exit-ArchivePathLock -Mutex $archiveLock
        }
    }

    $ArchiveTargets = [System.Collections.Generic.List[System.IO.FileInfo]]::new()
    $SeenArchivePaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $IsFolderInput = $false

    foreach ($Root in ($RootPath | Sort-Object -Unique)) {
        $Resolved = Resolve-Path -Path $Root -ErrorAction SilentlyContinue
        if (-not $Resolved) {
            if (-not [System.IO.Path]::IsPathRooted($Root)) {
                $Alt = Join-Path -Path $ScriptDir -ChildPath $Root
                if (Test-Path -Path $Alt) { $Resolved = Resolve-Path -Path $Alt -ErrorAction SilentlyContinue }
            }
        }

        if (-not $Resolved) {
            Write-Error "The path '$Root' does not exist."
            continue
        }

        $InputItem = Get-Item -Path $Resolved.Path -ErrorAction SilentlyContinue
        if (-not $InputItem) {
            Write-Error "Failed to access '$Root'."
            continue
        }

        if ($InputItem -is [System.IO.DirectoryInfo]) {
            $IsFolderInput = $true
            Process-RootTarget -InputItem $InputItem

            $ArchiveFiles = Get-ChildItem -Path $InputItem.FullName -Include '*.scs', '*.zip' -File -Recurse -ErrorAction SilentlyContinue
            foreach ($ArchiveFile in $ArchiveFiles) {
                $normalizedArchivePath = [System.IO.Path]::GetFullPath($ArchiveFile.FullName)
                if ($SeenArchivePaths.Add($normalizedArchivePath)) {
                    $ArchiveTargets.Add($ArchiveFile)
                }
            }
            continue
        }

        if ($InputItem -is [System.IO.FileInfo]) {
            if ($InputItem.Extension -in '.scs', '.zip') {
                $normalizedArchivePath = [System.IO.Path]::GetFullPath($InputItem.FullName)
                if ($SeenArchivePaths.Add($normalizedArchivePath)) {
                    $ArchiveTargets.Add($InputItem)
                }
                continue
            }

            Write-Error "The path '$($InputItem.FullName)' is not a directory or a supported archive file (.scs or .zip)."
            continue
        }
    }

    $ThrottleLimit = Resolve-ArchiveThrottleLimit -Requested $ThrottleLimit -IsFolderInput $IsFolderInput
    if ($WorkerMode.IsPresent) {
        foreach ($ArchiveFile in $ArchiveTargets) {
            Invoke-LockedArchiveTarget -ArchiveFile $ArchiveFile
        }
    } elseif ($ArchiveTargets.Count -gt 1 -and $ThrottleLimit -gt 1) {
        $workerParameters = @{
            ToolsFolder = $ToolsFolder
            Attribute = $TargetAttributes
        }
        if ($NoBackup.IsPresent) { $workerParameters.NoBackup = $true }
        if ($FullScan.IsPresent) { $workerParameters.FullScan = $true }
        if ($Quiet.IsPresent) { $workerParameters.Quiet = $true }
        if (-not $IsQuiet) {
            Write-Host "Processing $($ArchiveTargets.Count) archives with up to $ThrottleLimit workers. Each archive is processed as one unit.`n" -ForegroundColor Cyan
        }
        $workerBatch = Invoke-ArchiveWorkerBatch -ScriptPath $PSCommandPath -ArchivePaths @($ArchiveTargets | ForEach-Object { $_.FullName }) -WorkerParameters $workerParameters -PathParameterName 'RootPath' -Operation 'Repair and replace archive' -ThrottleLimit $ThrottleLimit -ApplyFixes:$ApplyFixes.IsPresent -WhatIf:$WhatIfPreference
        $Summary.DeclinedOperations += $workerBatch.DeclinedPaths.Count
        foreach ($worker in $workerBatch.Results) {
            if ($worker.Result) {
                foreach ($counter in @('UnitFilesRepaired', 'ArchivesUpdated', 'ZipFallbackArchives', 'WouldRepair', 'WouldUpdateArchives', 'SkippedArchives', 'UnreadableArchives', 'FailedRepack', 'DeclinedOperations')) {
                    $Summary.$counter += $worker.Result.Summary.$counter
                }
                foreach ($problem in $worker.Result.Problems) {
                    $AllProblems.Add($problem)
                }
                foreach ($archiveReport in $worker.Result.ArchiveReports) {
                    $Summary.ArchiveReports.Add($archiveReport)
                }
            } else {
                $Summary.UnreadableArchives++
                $Summary.ArchiveReports.Add([PSCustomObject]@{
                    ArchivePath = $worker.Path
                    DefinitionCount = 0
                    ReferenceCount = 0
                    Outcome = 'worker failed; left unchanged'
                })
                if (-not $IsQuiet) {
                    Write-Host "Worker failed for '$($worker.Path)': $($worker.Errors -join '; ')" -ForegroundColor Red
                }
            }
        }
    } else {
        foreach ($ArchiveFile in $ArchiveTargets) {
            Invoke-LockedArchiveTarget -ArchiveFile $ArchiveFile
        }
    }

    if ($WorkerMode.IsPresent) {
        return [PSCustomObject]@{
            WorkerResult = $true
            Summary = $Summary
            Problems = $AllProblems.ToArray()
            ArchiveReports = $Summary.ArchiveReports.ToArray()
        }
    }

    if (-not $IsQuiet) {
        foreach ($archiveReport in $Summary.ArchiveReports) {
            $archiveName = [System.IO.Path]::GetFileName($archiveReport.ArchivePath)
            if ($archiveReport.DefinitionCount -gt 0) {
                if ($archiveReport.Outcome -eq 'would be updated') {
                    Write-Host "Archive ${archiveName}: $($archiveReport.DefinitionCount) unit definition(s), $($archiveReport.ReferenceCount) malformed reference(s) would be repaired; archive would be updated."
                } elseif ($archiveReport.Outcome -match 'repack failed') {
                    Write-Host "Archive ${archiveName}: $($archiveReport.DefinitionCount) unit definition(s), $($archiveReport.ReferenceCount) malformed reference(s) repaired in staging; $($archiveReport.Outcome)."
                } elseif ($archiveReport.Outcome -match 'declined') {
                    Write-Host "Archive ${archiveName}: $($archiveReport.DefinitionCount) unit definition(s), $($archiveReport.ReferenceCount) malformed reference(s) matched; $($archiveReport.Outcome)."
                } else {
                    Write-Host "Archive ${archiveName}: repaired $($archiveReport.DefinitionCount) unit definition(s), fixing $($archiveReport.ReferenceCount) malformed reference(s); $($archiveReport.Outcome)."
                }
            } else {
                Write-Host "Archive ${archiveName}: $($archiveReport.Outcome)."
            }
        }
    }

    Write-Host "`nSummary: $($Summary.UnitFilesRepaired) unit file(s) repaired; $($Summary.ArchivesUpdated) archive(s) updated ($($Summary.ZipFallbackArchives) via ZIP fallback); $($Summary.WouldRepair) unit file(s) would be repaired; $($Summary.WouldUpdateArchives) archive(s) would be updated; $($Summary.SkippedArchives) archive(s) skipped; $($Summary.UnreadableArchives) unreadable archive(s); $($Summary.FailedRepack) repack failure(s); $($Summary.DeclinedOperations) operation(s) declined.`n"

    if ($IsQuiet) {
        return $AllProblems
    }
}

# Run when invoked directly
if ($MyInvocation.InvocationName -ne '.') {
    Repair-ScsTrafficVariants @args
}