
$srcDir = Read-Host "Enter the source folder with the sound_move .sui files"
$dstDir = Read-Host "Enter the destination folder that will be updated"

# Normalize folder paths (ensure full path and trailing backslash)
$srcDir = [System.IO.Path]::GetFullPath($srcDir)
if (-not $srcDir.EndsWith('\')) { $srcDir += '\' }
$dstDir = [System.IO.Path]::GetFullPath($dstDir)
if (-not $dstDir.EndsWith('\')) { $dstDir += '\' }

# Failsafe 1: Prevent running if source and destination folders are the same
if ($srcDir -eq $dstDir) {
    Write-Error "Source and destination folders must be different."
    exit
}

# Failsafe 2: Check for .sui files in both folders
# Find .sui files in both folders and all subfolders
$srcAll = Get-ChildItem -Path $srcDir -File -Filter '*.sui' -Recurse -ErrorAction SilentlyContinue
$dstAll = Get-ChildItem -Path $dstDir -File -Filter '*.sui' -Recurse -ErrorAction SilentlyContinue
# Keep compatibility variable names for later use
$srcFiles = $srcAll
$dstFiles = $dstAll
if (!$srcFiles -or $srcFiles.Count -eq 0) {
    Write-Error "No .sui files found in source folder ($srcDir) or its subfolders."
    exit
}
if (!$dstFiles -or $dstFiles.Count -eq 0) {
    Write-Error "No .sui files found in destination folder ($dstDir) or its subfolders."
    exit
}

# Pre-compile regex pattern for performance
$soundMoveRegex = [regex]'^\s*sound_move\[\]:.*$'

# Function for normalization
function Format-Content {
    param([string[]]$lines)
    return ($lines | ForEach-Object { $_.Trim() }) -join "\n"
}

$updatedCount = 0
$skippedCount = 0
$dstFiles | ForEach-Object {
    $dstFile = $_.FullName
    $dstName = $_.Name
    # Compute the relative path of the destination file to try to find the corresponding source file
    $relativePath = $dstFile.Substring($dstDir.Length).TrimStart('\','/')
    $srcFile = Join-Path $srcDir $relativePath

    # If exact relative path doesn't exist, fallback to searching by filename anywhere under source
    if (!(Test-Path $srcFile)) {
        $match = $srcFiles | Where-Object { $_.Name -eq $dstName } | Select-Object -First 1
        if ($match) {
            $srcFile = $match.FullName
        } else {
            $skippedCount++
            return
        }
    }

    # Get all sound_move lines from the source file
    $srcContent = Get-Content $srcFile
    $soundMoveBlock = @()
    $inBlock = $false
    foreach ($line in $srcContent) {
        if ($soundMoveRegex.IsMatch($line)) {
            $soundMoveBlock += $line
            $inBlock = $true
        } elseif ($inBlock) {
            break
        }
    }
    # Remove blank lines from the sound_move block
    $soundMoveBlock = $soundMoveBlock | Where-Object { $_.Trim() -ne "" }
    if (!$soundMoveBlock -or $soundMoveBlock.Count -eq 0) {
        $skippedCount++
        return
    }

    # Read all lines from the destination file
    $dstLines = Get-Content $dstFile


    # Replace every block of consecutive sound_move lines in the destination file with the block from the source file
    $newLines = @()
    $i = 0
    while ($i -lt $dstLines.Count) {
        if ($soundMoveRegex.IsMatch($dstLines[$i])) {
            # Start of a sound_move block
            while ($i -lt $dstLines.Count -and $soundMoveRegex.IsMatch($dstLines[$i])) {
                $i++
            }
            # Insert the source block (only once per block)
            $newLines += $soundMoveBlock
        } else {
            $newLines += $dstLines[$i]
            $i++
        }
    }

    # Only write if changes are made (ignore line endings and whitespace)
    $formattedNew = Format-Content $newLines
    $formattedDst = Format-Content $dstLines
    if ($formattedNew -ne $formattedDst) {
        Set-Content -Path $dstFile -Value $newLines
        $updatedCount++
    } else {
        $skippedCount++
    }
}

# Print summary after all processing is complete
Write-Host "$updatedCount files updated, $skippedCount files skipped."
Write-Host "Copy over all updated files from the new folder to the Workshop folder and upload"
