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

function Test-ZipArchiveEncrypted {
    param([Parameter(Mandatory)][string]$Path)

    $stream = $null
    $reader = $null
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        if ($stream.Length -lt 22) { return $false }

        $reader = [System.IO.BinaryReader]::new($stream)
        $tailLength = [int][Math]::Min([int64]65557, $stream.Length)
        $stream.Position = $stream.Length - $tailLength
        $tail = $reader.ReadBytes($tailLength)
        $eocdIndex = -1

        for ($index = $tail.Length - 22; $index -ge 0; $index--) {
            if ([System.BitConverter]::ToUInt32($tail, $index) -ne 0x06054b50) { continue }
            $commentLength = [System.BitConverter]::ToUInt16($tail, $index + 20)
            if ($index + 22 + $commentLength -eq $tail.Length) {
                $eocdIndex = $index
                break
            }
        }
        if ($eocdIndex -lt 0) { return $false }

        $eocdOffset = $stream.Length - $tailLength + $eocdIndex
        $entriesOnDisk = [uint64][System.BitConverter]::ToUInt16($tail, $eocdIndex + 8)
        $entryCount = [uint64][System.BitConverter]::ToUInt16($tail, $eocdIndex + 10)
        $centralDirectorySize = [uint64][System.BitConverter]::ToUInt32($tail, $eocdIndex + 12)
        $centralDirectoryOffset = [uint64][System.BitConverter]::ToUInt32($tail, $eocdIndex + 16)

        if ([System.BitConverter]::ToUInt16($tail, $eocdIndex + 4) -ne 0 -or
            [System.BitConverter]::ToUInt16($tail, $eocdIndex + 6) -ne 0) {
            return $false
        }

        $zip64Required = $entryCount -eq [uint16]::MaxValue -or
            $centralDirectorySize -eq [uint32]::MaxValue -or
            $centralDirectoryOffset -eq [uint32]::MaxValue
        if ($zip64Required) {
            $locatorOffset = $eocdOffset - 20
            if ($locatorOffset -lt 0) { return $false }
            $stream.Position = $locatorOffset
            $locator = $reader.ReadBytes(20)
            if ($locator.Length -ne 20 -or [System.BitConverter]::ToUInt32($locator, 0) -ne 0x07064b50) { return $false }
            if ([System.BitConverter]::ToUInt32($locator, 4) -ne 0 -or
                [System.BitConverter]::ToUInt32($locator, 16) -ne 1) {
                return $false
            }

            $zip64Offset = [System.BitConverter]::ToUInt64($locator, 8)
            if ($zip64Offset -gt [uint64]($stream.Length - 56)) { return $false }
            $stream.Position = [long]$zip64Offset
            $zip64Eocd = $reader.ReadBytes(56)
            if ($zip64Eocd.Length -ne 56 -or [System.BitConverter]::ToUInt32($zip64Eocd, 0) -ne 0x06064b50) { return $false }
            if ([System.BitConverter]::ToUInt32($zip64Eocd, 16) -ne 0 -or
                [System.BitConverter]::ToUInt32($zip64Eocd, 20) -ne 0) {
                return $false
            }
            $entriesOnDisk = [System.BitConverter]::ToUInt64($zip64Eocd, 24)
            $entryCount = [System.BitConverter]::ToUInt64($zip64Eocd, 32)
            $centralDirectorySize = [System.BitConverter]::ToUInt64($zip64Eocd, 40)
            $centralDirectoryOffset = [System.BitConverter]::ToUInt64($zip64Eocd, 48)
            if ($entriesOnDisk -ne $entryCount -or $centralDirectorySize -gt $zip64Offset) { return $false }
            $centralDirectoryStart = [long]($zip64Offset - $centralDirectorySize)
        } else {
            if ($entriesOnDisk -ne $entryCount -or $centralDirectorySize -gt $eocdOffset) { return $false }
            $centralDirectoryStart = [long]($eocdOffset - $centralDirectorySize)
        }

        if ($entryCount -gt [int]::MaxValue) { return $false }
        $stream.Position = $centralDirectoryStart
        for ($entryNumber = 0; $entryNumber -lt $entryCount; $entryNumber++) {
            $header = $reader.ReadBytes(46)
            if ($header.Length -ne 46 -or [System.BitConverter]::ToUInt32($header, 0) -ne 0x02014b50) { return $false }

            $flags = [System.BitConverter]::ToUInt16($header, 8)
            if (($flags -band 0x41) -ne 0) { return $true }

            $nameLength = [System.BitConverter]::ToUInt16($header, 28)
            $extraLength = [System.BitConverter]::ToUInt16($header, 30)
            $commentLength = [System.BitConverter]::ToUInt16($header, 32)
            if ($reader.ReadBytes($nameLength).Length -ne $nameLength) { return $false }
            $extra = $reader.ReadBytes($extraLength)
            if ($extra.Length -ne $extraLength) { return $false }

            for ($extraOffset = 0; $extraOffset + 4 -le $extra.Length;) {
                $extraId = [System.BitConverter]::ToUInt16($extra, $extraOffset)
                $extraSize = [System.BitConverter]::ToUInt16($extra, $extraOffset + 2)
                if ($extraOffset + 4 + $extraSize -gt $extra.Length) { return $false }
                if ($extraId -eq 0x9901) { return $true }
                $extraOffset += 4 + $extraSize
            }

            if ($reader.ReadBytes($commentLength).Length -ne $commentLength) { return $false }
        }

        return $false
    } catch {
        return $false
    } finally {
        if ($reader) { $reader.Dispose() }
        elseif ($stream) { $stream.Dispose() }
    }
}

function Test-ZipArchiveReadable {
    param([string]$Path)

    if (Test-ZipArchiveEncrypted -Path $Path) { return $false }

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
        [int]$TimeoutSeconds = 90
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

    if (Test-ZipArchiveEncrypted -Path $ArchivePath) {
        throw "Encrypted ZIP archives are not supported: $ArchivePath"
    }

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

Export-ModuleMember -Function Resolve-ArchiveToolPath, Get-SCSArchiveKind, Test-ZipArchiveEncrypted, Test-ZipArchiveReadable, Invoke-ArchiveTool, Expand-ZIPFSArchive, Expand-HashFSArchive, New-ZIPFSArchive, New-HashFSArchive, New-SCSArchiveWithFallback