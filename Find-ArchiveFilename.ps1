#Requires -Version 5.1

<#
.SYNOPSIS
Finds filenames or .sii/.sui text contents containing a query in folders and archives.

.DESCRIPTION
Searches loose files recursively when Path is a folder. It also searches the text
contents of .sii and .sui files. ZIPFS archives are searched by enumerating their entries;
HashFS archives are extracted to a temporary folder. Folder archives run in parallel.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$Path = (Get-Location).Path,
    [Parameter(Mandatory, Position = 1)]
    [ValidateNotNullOrEmpty()]
    [Alias('FileName')]
    [string]$SearchTerm,
    [string]$ToolsFolder = $PSScriptRoot,
    [ValidateRange(0, 64)]
    [int]$ThrottleLimit = 0,
    [switch]$WorkerMode
)

$ErrorActionPreference = 'Stop'

Import-Module -Name (Join-Path $PSScriptRoot 'Archive-Parallelism.psm1') -Force
Import-Module -Name (Join-Path $PSScriptRoot 'Archive-Operations.psm1') -Force

function Find-TextStreamMatch {
    param(
        [Parameter(Mandatory)][System.IO.Stream]$Stream,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$RelativePath,
        [string]$ArchivePath,
        [Parameter(Mandatory)][string]$ArchiveKind
    )

    $reader = [System.IO.StreamReader]::new($Stream)
    try {
        $lineNumber = 0
        while ($null -ne ($line = $reader.ReadLine())) {
            $lineNumber++
            if ($line.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [PSCustomObject]@{
                    FileName = $Query
                    Archive = $ArchivePath
                    Path = $RelativePath
                    ArchiveKind = $ArchiveKind
                    MatchType = 'Content'
                    LineNumber = $lineNumber
                    Line = $line
                }
            }
        }
    } finally {
        $reader.Dispose()
    }
}

function Find-TextFileMatch {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string]$Query,
        [string]$ArchivePath,
        [string]$RelativePath,
        [Parameter(Mandatory)][string]$ArchiveKind
    )

    $stream = [System.IO.File]::OpenRead($FilePath)
    try {
        Find-TextStreamMatch -Stream $stream -Query $Query -RelativePath $RelativePath -ArchivePath $ArchivePath -ArchiveKind $ArchiveKind
    } finally {
        $stream.Dispose()
    }
}

function Find-ArchiveEntry {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$Query,
        [Parameter(Mandatory)][string]$ToolsFolder
    )

    $archiveKind = Get-SCSArchiveKind -Path $ArchivePath
    if ($archiveKind -eq 'ZIPFS') {
        if (Test-ZipArchiveEncrypted -Path $ArchivePath) {
            Write-Warning "Skipping encrypted ZIP archive: $ArchivePath"
            return
        }
        if (-not (Test-ZipArchiveReadable -Path $ArchivePath)) {
            throw "ZIPFS archive is unreadable: $ArchivePath"
        }

        $archive = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try {
            foreach ($entry in $archive.Entries) {
                if ($entry.Name.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    [PSCustomObject]@{
                        FileName = $Query
                        Archive = $ArchivePath
                        Path = $entry.FullName
                        ArchiveKind = $archiveKind
                        MatchType = 'Filename'
                    }
                }

                if ([System.IO.Path]::GetExtension($entry.Name) -in '.sii', '.sui') {
                    $entryStream = $entry.Open()
                    Find-TextStreamMatch -Stream $entryStream -Query $Query -RelativePath $entry.FullName -ArchivePath $ArchivePath -ArchiveKind $archiveKind
                }
            }
        } finally {
            $archive.Dispose()
        }
        return
    }

    if ($archiveKind -ne 'HashFS') {
        throw "Unsupported or unreadable archive '$ArchivePath' ($archiveKind)."
    }

    $extractor = Resolve-ArchiveToolPath -ToolsFolder $ToolsFolder -Names @('scs_extractor.exe') -Required
    $tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('archive-search-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        Expand-HashFSArchive -ArchivePath $ArchivePath -DestinationPath $tempRoot -Extractor $extractor
        foreach ($file in Get-ChildItem -LiteralPath $tempRoot -File -Recurse) {
            $relativePath = $file.FullName.Substring($tempRoot.Length).TrimStart([char[]]@('\', '/'))
            if ($file.Name.IndexOf($Query, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                [PSCustomObject]@{
                    FileName = $Query
                    Archive = $ArchivePath
                    Path = $relativePath
                    ArchiveKind = $archiveKind
                    MatchType = 'Filename'
                }
            }

            if ($file.Extension -in '.sii', '.sui') {
                Find-TextFileMatch -FilePath $file.FullName -Query $Query -ArchivePath $ArchivePath -RelativePath $relativePath -ArchiveKind $archiveKind
            }
        }
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
    }
}

if ($WorkerMode.IsPresent) {
    $workerMatches = @(Find-ArchiveEntry -ArchivePath $Path -Query $SearchTerm -ToolsFolder $ToolsFolder)
    [PSCustomObject]@{
        WorkerResult = $true
        Matches = $workerMatches
    }
    return
}

if (-not (Test-Path -LiteralPath $Path)) {
    throw "Path '$Path' does not exist."
}

$inputItem = Get-Item -LiteralPath $Path
$isFolderInput = $inputItem.PSIsContainer
$ThrottleLimit = Resolve-ArchiveThrottleLimit -Requested $ThrottleLimit -IsFolderInput $isFolderInput
$matches = [System.Collections.Generic.List[PSCustomObject]]::new()
$archiveFiles = @()

if ($isFolderInput) {
    foreach ($file in Get-ChildItem -LiteralPath $inputItem.FullName -File -Recurse) {
        if ($file.Name.IndexOf($SearchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
            $matches.Add([PSCustomObject]@{
                FileName = $SearchTerm
                Archive = $null
                Path = $file.FullName
                ArchiveKind = 'Loose'
                MatchType = 'Filename'
            })
        }

        if ($file.Extension -in '.sii', '.sui') {
            foreach ($textMatch in Find-TextFileMatch -FilePath $file.FullName -Query $SearchTerm -RelativePath $file.FullName -ArchiveKind 'Loose') {
                $matches.Add($textMatch)
            }
        }
    }

    $archiveFiles = @(Get-ChildItem -LiteralPath $inputItem.FullName -File -Recurse |
        Where-Object { $_.Extension -in '.zip', '.scs' } |
        Sort-Object -Property FullName)
} elseif ($inputItem.Extension -in '.zip', '.scs') {
    $archiveFiles = @($inputItem)
} elseif ($inputItem.Extension -in '.sii', '.sui') {
    if ($inputItem.Name.IndexOf($SearchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
        $matches.Add([PSCustomObject]@{
            FileName = $SearchTerm
            Archive = $null
            Path = $inputItem.FullName
            ArchiveKind = 'Loose'
            MatchType = 'Filename'
        })
    }
    foreach ($textMatch in Find-TextFileMatch -FilePath $inputItem.FullName -Query $SearchTerm -RelativePath $inputItem.FullName -ArchiveKind 'Loose') {
        $matches.Add($textMatch)
    }
} else {
    throw "File '$Path' is not a supported archive (.zip or .scs) or text file (.sii or .sui)."
}

if ($archiveFiles.Count -gt 1) {
    $workerBatch = Invoke-ArchiveWorkerBatch -ScriptPath $PSCommandPath `
        -ArchivePaths @($archiveFiles | ForEach-Object { $_.FullName }) `
        -WorkerParameters @{ SearchTerm = $SearchTerm; ToolsFolder = $ToolsFolder } `
        -PathParameterName 'Path' `
        -Operation "Search for '$SearchTerm' in archive" `
        -ThrottleLimit $ThrottleLimit

    foreach ($worker in $workerBatch.Results) {
        if ($worker.Result) {
            foreach ($match in $worker.Result.Matches) { $matches.Add($match) }
        } else {
            Write-Warning "Could not search '$($worker.Path)': $($worker.Errors -join '; ')"
        }
    }
} else {
    foreach ($archiveFile in $archiveFiles) {
        foreach ($match in Find-ArchiveEntry -ArchivePath $archiveFile.FullName -Query $SearchTerm -ToolsFolder $ToolsFolder) {
            $matches.Add($match)
        }
    }
}

if ($matches.Count -eq 0) {
    Write-Host "No matches found for '$SearchTerm'."
} else {
    $matches | Sort-Object -Property Archive, Path, LineNumber
}