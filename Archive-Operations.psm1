#Requires -Version 5.1

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Resolve-ArchiveToolPath {
    param(
        [string]$ToolsFolder,
        [string[]]$Names,
        [switch]$Required
    )

    foreach ($name in $Names) {
        if ($ToolsFolder) {
            $candidate = Join-Path $ToolsFolder $name
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Get-Item -LiteralPath $candidate).FullName
            }
        }

        $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }

    if ($Required.IsPresent) {
        throw "Could not find any of: $($Names -join ', ')"
    }

    return $null
}

function Get-SCSArchiveKind {
    param([string]$Path)

    $stream = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        $header = New-Object byte[] 4
        $readCount = $stream.Read($header, 0, $header.Length)
        if ($readCount -ge 4) {
            $signature = [System.Text.Encoding]::ASCII.GetString($header)
            if ($signature -eq 'SCS#') { return 'HashFS' }
            if ($signature.Substring(0, 2) -eq 'PK') { return 'ZIPFS' }
        }
    } catch {
        return 'Unreadable'
    } finally {
        if ($stream) { $stream.Dispose() }
    }

    return 'Unknown'
}

function Test-ZipArchiveReadable {
    param([string]$Path)

    $archive = $null
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        return $true
    } catch {
        return $false
    } finally {
        if ($archive) { $archive.Dispose() }
    }
}

function Invoke-ArchiveTool {
    param(
        [Parameter(Mandatory)]
        [string]$Tool,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 60
    )

    if ([string]::IsNullOrWhiteSpace($Tool)) {
        throw 'An archive tool path is required.'
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $Tool
    if ($WorkingDirectory) { $startInfo.WorkingDirectory = $WorkingDirectory }
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

        $output = $outputTask.GetAwaiter().GetResult()
        $errorOutput = $errorTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) {
            $details = (@($output, $errorOutput) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine
            throw "Archive tool failed with exit code $($process.ExitCode): $Tool $($Arguments -join ' ')`n$details"
        }
    } finally {
        $process.Dispose()
    }
}

function Expand-ZIPFSArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$SevenZip
    )

    if ($SevenZip) {
        Invoke-ArchiveTool -Tool $SevenZip -Arguments @('x', '-y', "-o$DestinationPath", $ArchivePath) -WorkingDirectory $DestinationPath
    } else {
        Expand-Archive -LiteralPath $ArchivePath -DestinationPath $DestinationPath -Force -WhatIf:$false
    }
}

function Expand-HashFSArchive {
    param(
        [Parameter(Mandatory)][string]$ArchivePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$Extractor
    )

    Invoke-ArchiveTool -Tool $Extractor -Arguments @($ArchivePath, $DestinationPath) -WorkingDirectory $DestinationPath
}

function New-ZIPFSArchive {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$SevenZip
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force -WhatIf:$false
    }

    if ($SevenZip) {
        Invoke-ArchiveTool -Tool $SevenZip -Arguments @('a', '-tzip', '-y', $DestinationPath, '*') -WorkingDirectory $SourceDirectory
    } else {
        Compress-Archive -Path (Join-Path $SourceDirectory '*') -DestinationPath $DestinationPath -Force -WhatIf:$false | Out-Null
    }
}

function New-HashFSArchive {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$Packer
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        Remove-Item -LiteralPath $DestinationPath -Force -WhatIf:$false
    }

    Invoke-ArchiveTool -Tool $Packer -Arguments @('create', $DestinationPath, '-root', $SourceDirectory)
}

function New-SCSArchiveWithFallback {
    param(
        [Parameter(Mandatory)][string]$SourceDirectory,
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$Packer,
        [string]$SevenZip,
        [switch]$AllowZIPFallback
    )

    if ($Packer) {
        try {
            New-HashFSArchive -SourceDirectory $SourceDirectory -DestinationPath $DestinationPath -Packer $Packer
            return [PSCustomObject]@{ ArchiveKind = 'HashFS'; UsedFallback = $false }
        } catch {
            if (-not $AllowZIPFallback.IsPresent) { throw }
        }
    } elseif (-not $AllowZIPFallback.IsPresent) {
        throw 'scs_packer.exe was not found and ZIPFS fallback is disabled.'
    }

    New-ZIPFSArchive -SourceDirectory $SourceDirectory -DestinationPath $DestinationPath -SevenZip $SevenZip
    return [PSCustomObject]@{ ArchiveKind = 'ZIPFS'; UsedFallback = $true }
}

Export-ModuleMember -Function Resolve-ArchiveToolPath, Get-SCSArchiveKind, Test-ZipArchiveReadable, Invoke-ArchiveTool, Expand-ZIPFSArchive, Expand-HashFSArchive, New-ZIPFSArchive, New-HashFSArchive, New-SCSArchiveWithFallback