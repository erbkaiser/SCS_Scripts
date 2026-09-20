<#  
    Update-EnvProfiles.ps1
    -----------------------
    Updates day_in_year, its date comment, and summer_time for ETS2 and ATS env_profile files.
#>

function Get-NextWednesday {
    $today = Get-Date
    $daysUntilWed = ([DayOfWeek]::Wednesday - $today.DayOfWeek + 7) % 7
    if ($daysUntilWed -eq 0) { $daysUntilWed = 7 }
    return $today.AddDays($daysUntilWed)
}

function Get-DstRange {
    param(
        [string]$TimeZoneId,
        [int]$Year
    )

    $timeZone = [System.TimeZoneInfo]::FindSystemTimeZoneById($TimeZoneId)
    $startDate = [datetime]::Parse("$Year-01-01")
    $endDate = [datetime]::Parse("$Year-12-31")

    $dstStart = $null
    $dstEnd = $null
    $wasDst = $timeZone.IsDaylightSavingTime($startDate)

    for ($date = $startDate.AddDays(1); $date -le $endDate; $date = $date.AddDays(1)) {
        $isDst = $timeZone.IsDaylightSavingTime($date)

        if (-not $wasDst -and $isDst -and $null -eq $dstStart) {
            $dstStart = $date
        }

        if ($wasDst -and -not $isDst -and $null -eq $dstEnd) {
            $dstEnd = $date.AddDays(-1)
            break
        }

        $wasDst = $isDst
    }

    if ($null -eq $dstStart) {
        return [pscustomobject]@{
            StartDate = $null
            EndDate = $null
        }
    }

    if ($null -eq $dstEnd) {
        $dstEnd = $endDate
    }

    return [pscustomobject]@{
        StartDate = $dstStart
        EndDate = $dstEnd
    }
}

function Get-ThunderstormProbability {
    param(
        [int]$DayOfYear,
        [datetime]$ReferenceDate
    )

    $midsummerDay = 175
    $midwinterDay = 355
    if ([DateTime]::IsLeapYear($ReferenceDate.Year)) {
        $midsummerDay = 176
        $midwinterDay = 356
    }

    if ($DayOfYear -eq $midsummerDay) {
        return 0.37
    }

    if ($DayOfYear -eq $midwinterDay) {
        return 0.01
    }

    if ($DayOfYear -lt $midsummerDay) {
        $startDay = 1
        $endDay = $midsummerDay - 1
        $progress = ($DayOfYear - $startDay) / ($endDay - $startDay)
        $value = 0.01 + ($progress * (0.37 - 0.01))
        return [math]::Round($value, 2)
    }

    if ($DayOfYear -gt $midsummerDay -and $DayOfYear -lt $midwinterDay) {
        $startDay = $midsummerDay + 1
        $endDay = $midwinterDay - 1
        $progress = ($DayOfYear - $startDay) / ($endDay - $startDay)
        $value = 0.37 + ($progress * (0.01 - 0.37))
        return [math]::Round($value, 2)
    }

    $startDay = $midwinterDay + 1
    $endDay = 365
    if ([DateTime]::IsLeapYear($ReferenceDate.Year)) {
        $endDay = 366
    }

    if ($DayOfYear -gt $midwinterDay) {
        $progress = ($DayOfYear - $startDay) / ($endDay - $startDay)
        $value = 0.01 + ($progress * (0.37 - 0.01))
        return [math]::Round($value, 2)
    }

    return 0.01
}

function Update-EnvProfileFile {
    param(
        [string]$Path,
        [string]$TimeZoneId,
        [int]$NewDay,
        [datetime]$NewDate
    )

    try {
        if (-not (Test-Path -Path $Path -PathType Leaf)) {
            throw "File not found: $Path"
        }

        $content = Get-Content -Path $Path -Raw -ErrorAction Stop

        $dayPattern = 'day_in_year:\s*\d+\s*//\s*\d{4}-\d{2}-\d{2}'
        $content = [regex]::Replace($content, $dayPattern, "day_in_year: $NewDay    // $($NewDate.ToString('yyyy-MM-dd'))", 1)

        $dstRange = Get-DstRange -TimeZoneId $TimeZoneId -Year $NewDate.Year
        if ($null -eq $dstRange.StartDate -or $null -eq $dstRange.EndDate) {
            throw "Could not determine DST range for $TimeZoneId in $($NewDate.Year)."
        }

        $isDstActive = $NewDate -ge $dstRange.StartDate -and $NewDate -le $dstRange.EndDate
        $summerTimeValue = if ($isDstActive) { 1 } else { 0 }
        $summerTimeComment = "DST is $($dstRange.StartDate.ToString('yyyy-MM-dd')) to $($dstRange.EndDate.ToString('yyyy-MM-dd'))"

        $summerPattern = '(?m)^(\s*)summer_time:\s*(\d+)\s*(//.*)?$'
        $summerMatch = [regex]::Match($content, $summerPattern)
        if (-not $summerMatch.Success) {
            throw "summer_time line not found in $Path"
        }

        $summerIndent = $summerMatch.Groups[1].Value
        $summerCurrentValue = [int]$summerMatch.Groups[2].Value
        $summerCurrentComment = if ($summerMatch.Groups[3].Success) { $summerMatch.Groups[3].Value.Trim() } else { '' }
        $expectedSummerComment = "// $summerTimeComment"

        if ($summerCurrentValue -ne $summerTimeValue -or $summerCurrentComment -ne $expectedSummerComment) {
            $summerReplacement = "{0}summer_time: {1}`t`t// {2}" -f $summerIndent, $summerTimeValue, $summerTimeComment
            $content = [regex]::Replace($content, [regex]::Escape($summerMatch.Value), $summerReplacement, 1)
        }

        $thunderstormValue = Get-ThunderstormProbability -DayOfYear $NewDay -ReferenceDate $NewDate
        $thunderstormPattern = '(?m)^(\s*)thunderstorm_probability:.*$'
        $thunderstormMatch = [regex]::Match($content, $thunderstormPattern)
        if (-not $thunderstormMatch.Success) {
            throw "thunderstorm_probability line not found in $Path"
        }

        $thunderstormIndent = $thunderstormMatch.Groups[1].Value
        $thunderstormComment = ''
        if ($thunderstormMatch.Value -match '(//.*)$') {
            $thunderstormComment = $matches[1]
        }

        $thunderstormReplacement = "{0}thunderstorm_probability: {1}{2}" -f $thunderstormIndent, ($thunderstormValue.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture)), $thunderstormComment
        $content = [regex]::Replace($content, $thunderstormPattern, $thunderstormReplacement, 1)

        Set-Content -Path $Path -Value $content -Encoding UTF8 -ErrorAction Stop
    }
    catch {
        throw "Failed to update ${Path}: $($_.Exception.Message)"
    }
}

# --- MAIN EXECUTION ---

function Show-ExitPrompt {
    if ($MyInvocation.InvocationName -ne '.') {
        Write-Host ""
        Write-Host "Press any key to exit..."
        [System.Console]::ReadKey($true) | Out-Null
    }
}

try {
    $nextWed = Get-NextWednesday
    $day = $nextWed.DayOfYear

    $ets2File = "C:\Users\erbka\OneDrive\Documents\SCS Workshop Uploader\ETS2 Daytime\latest\def\env_data.sii"
    $atsFile  = "C:\Users\erbka\OneDrive\Documents\SCS Workshop Uploader\ATS Daytime\latest\def\env_data.sii"

    Update-EnvProfileFile -Path $ets2File -TimeZoneId "W. Europe Standard Time" -NewDay $day -NewDate $nextWed
    Update-EnvProfileFile -Path $atsFile  -TimeZoneId "Eastern Standard Time" -NewDay $day -NewDate $nextWed

    Write-Host "Updated ETS2 and ATS:"
    Write-Host "  day_in_year: $day"
    Write-Host "  date:        $($nextWed.ToString('yyyy-MM-dd'))"
}
catch {
    Write-Error $_.Exception.Message
    Show-ExitPrompt
    exit 1
}

Show-ExitPrompt
