# PowerShell User Restore Script
# Copyright (c) 2026 Arthur Taft

$username = $env:USERNAME
$localRoot = "C:\Users\$username"
$sizeCheckEnabled = $true # Enabled by default
$largeFileAuditEnabled = $true # Enabled by default

# --- TUI MENU ENGINE FUNCTION (SINGLE SELECTION) ---
function Show-TuiMenu {
    param (
        [string]$Title = "Script Menu",
        [string[]]$Options = @()
    )

    $currentIndex = 0
    $key = $null
    Clear-Host

    while ($true) {
        [Console]::SetCursorPosition(0, 0)
        Write-Host "=====================================================================" -ForegroundColor Cyan
        Write-Host "  $Title" -ForegroundColor Yellow
        Write-Host "=====================================================================" -ForegroundColor Cyan
        Write-Host " Navigation: [↑/↓] | Select: [Enter] | Back: [Esc] | Quit: [Q]`n"

        for ($i = 0; $i -lt $Options.Count; $i++) {
            if ($i -eq $currentIndex) {
                Write-Host "  -> [ X ] $($Options[$i]) " -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host "     [   ] $($Options[$i]) "
            }
        }
        Write-Host "`n=====================================================================" -ForegroundColor Cyan

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { $currentIndex--; if ($currentIndex -lt 0) { $currentIndex = $Options.Count - 1 } } # Up
            40 { $currentIndex++; if ($currentIndex -ge $Options.Count) { $currentIndex = 0 } }     # Down
            13 { Clear-Host; return $Options[$currentIndex] }                                       # Enter
            27 { Clear-Host; return "CANCEL" }                                                      # Esc
            81 { Clear-Host; Write-Host "`nOperation aborted by user (Q pressed)." -ForegroundColor Red; exit 0 } # Q
        }
    }
}

# --- TUI CHECKLIST ENGINE FUNCTION (MULTI-SELECTION) ---
function Show-TuiChecklist {
    param (
        [string]$Title = "Select Locations to Restore",
        [System.Collections.Generic.List[PSCustomObject]]$Items
    )

    $initialState = @{}
    foreach ($item in $Items) {
        $initialState[$item.Name] = $item.Enabled
    }

    $currentIndex = 0
    $key = $null
    Clear-Host

    while ($true) {
        [Console]::SetCursorPosition(0, 0)
        Write-Host "=====================================================================" -ForegroundColor Cyan
        Write-Host "  $Title" -ForegroundColor Yellow
        Write-Host "=====================================================================" -ForegroundColor Cyan
        Write-Host " Navigation: [↑/↓] | Toggle: [Space] | Save: [Enter] | Cancel: [Esc] | Quit: [Q]`n"

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            $check = if ($item.Enabled) { "[X]" } else { "[ ]" }
            
            if ($i -eq $currentIndex) {
                Write-Host "  -> $check $($item.Name) " -ForegroundColor Black -BackgroundColor Cyan
            } else {
                Write-Host "     $check $($item.Name) " -ForegroundColor Gray
            }
        }
        
        if ($currentIndex -eq $Items.Count) {
            Write-Host "`n  -> [ CONFIRM SELECTION AND RETURN ] " -ForegroundColor Black -BackgroundColor Green
        } else {
            Write-Host "`n     [ CONFIRM SELECTION AND RETURN ] " -ForegroundColor Green
        }
        Write-Host "`n=====================================================================" -ForegroundColor Cyan

        $key = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        switch ($key.VirtualKeyCode) {
            38 { $currentIndex--; if ($currentIndex -lt 0) { $currentIndex = $Items.Count } } # Up
            40 { $currentIndex++; if ($currentIndex -gt $Items.Count) { $currentIndex = 0 } } # Down
            32 { if ($currentIndex -lt $Items.Count) { $Items[$currentIndex].Enabled = -not $Items[$currentIndex].Enabled } } # Spacebar
            13 { if ($currentIndex -eq $Items.Count) { Clear-Host; return $true } } # Enter
            27 { 
                foreach ($item in $Items) { $item.Enabled = $initialState[$item.Name] }
                Clear-Host; return $false 
            } 
            81 { Clear-Host; Write-Host "`nOperation aborted by user (Q pressed)." -ForegroundColor Red; exit 0 } # Q
        }
    }
}

# --- FAST ROBOCOPY LOG AUDITING ENGINE ---
function Verify-RobocopyLog {
    param (
        [string[]]$RoboLog,
        [string]$ItemName
    )
    
    Write-Host " -> Parsing transfer summary for: $ItemName..." -ForegroundColor Cyan
    $fileLine = $RoboLog | Where-Object { $_ -match "^\s*Files :" }

    if ($fileLine) {
        $parts = $fileLine -split '\s+' | Where-Object { $_ -ne '' }
        if ($parts.Count -ge 7) {
            $total  = $parts[2]
            $failed = $parts[6]

            if ($failed -eq "0") {
                Write-Host "    [✓] Pass: Data restored. $total file(s) accounted for with 0 failures." -ForegroundColor Green
                return $null
            } else {
                Write-Host "    [!] ALERT: $failed file(s) failed to transfer!" -ForegroundColor Red
                
                $errorLines = $RoboLog | Where-Object { $_ -match "ERROR \d+" }
                
                if (-not $errorLines) {
                    $errorLines = @("    -> Exact file names could not be parsed from the log output. They may be locked system files.")
                }
                
                return $errorLines
            }
        } else {
            Write-Host "    [?] Error: Summary table format unrecognized." -ForegroundColor Yellow
            return $null
        }
    } else {
        Write-Host "    [!] FAILED TO LOCATE ROBOCOPY SUMMARY BLOCK." -ForegroundColor Red
        return $null
    }
}

# --- REVERSE BROWSER PROFILE SCANNER (RESTORE MODE) ---
function Get-RestorableBrowserProfiles {
    param (
        [string]$Browser, 
        [string]$BackupSourcePath,
        [string]$LocalAppTarget
    )

    $browserProfiles = [System.Collections.Generic.List[Hashtable]]::new()
    $browserName = (Get-Culture).TextInfo.ToTitleCase($Browser) 
    $backupBrowserRoot = Join-Path $BackupSourcePath $browserName

    # Check if the backup actually contains this browser
    if (-not (Test-Path $backupBrowserRoot)) { return $browserProfiles }

    $targetFolders = Get-ChildItem -Path $backupBrowserRoot -Directory 
    
    foreach ($folder in $targetFolders) {
        $browserProfiles.Add(@{ 
            name = "$browserName\$($folder.Name)"
            src  = $folder.FullName
            dest = Join-Path $LocalAppTarget $folder.Name 
        })
    }
    
    return $browserProfiles
}


# --- PHASE 1: STORAGE TARGET DETECTION ---
$volumes = Get-Volume | Where-Object { $_.DriveLetter }
if (-not $volumes) {
    Write-Error "Critical Failure: No accessible storage drives found!"
    exit 1
}

$driveOptions = @()
$driveMapping = @{}

foreach ($vol in $volumes) {
    $label = if ($vol.FileSystemLabel) { $vol.FileSystemLabel } else { "Local Volume" }
    $freeGB  = if ($vol.SizeRemaining) { [math]::Round($vol.SizeRemaining / 1GB, 1) } else { 0 }
    $totalGB = if ($vol.Size) { [math]::Round($vol.Size / 1GB, 1) } else { 0 }
    $type    = $vol.DriveType

    $displayText = "Drive $($vol.DriveLetter): [$label] ($freeGB GB Free of $totalGB GB) - $type"
    $driveOptions += $displayText
    $driveMapping[$displayText] = $vol
}

$selectedDriveText = Show-TuiMenu -Title "SELECT SOURCE RESTORE DRIVE" -Options $driveOptions
if ($selectedDriveText -eq "CANCEL") {
    Write-Host "Operation aborted." -ForegroundColor Red
    exit 0
}
$chosenDrive = $driveMapping[$selectedDriveText]
$sourceRoot = "$($chosenDrive.DriveLetter):\$username"

if (-not (Test-Path $sourceRoot)) {
    Write-Host "`n[!] WARNING: Could not find backup folder for '$username' on drive $($chosenDrive.DriveLetter):" -ForegroundColor Red
    Write-Host "If the username changed between computers, please rename the folder on the external drive to match." -ForegroundColor Yellow
    Write-Host "Expected Path: $sourceRoot`n"
    exit 1
}


# --- PHASE 2: ENVIRONMENT STAGING (ABSOLUTE PATHS) ---
if ("$env:OneDrive" -match "^Southern*") {
    $rawTargets = @(
        @{ name = "Downloads"; src = "$sourceRoot\Downloads"; dest = "$localRoot\Downloads" },
        @{ name = "Pictures";  src = "$sourceRoot\Pictures";  dest = "$localRoot\Pictures" },
        @{ name = "Videos";    src = "$sourceRoot\Videos";    dest = "$localRoot\Videos" },
        @{ name = "Music";     src = "$sourceRoot\Music";     dest = "$localRoot\Music" }
    )
} else
    $rawTargets = @(
        @{ name = "Desktop";   src = "$sourceRoot\Desktop";   dest = "$localRoot\Desktop" },
        @{ name = "Documents"; src = "$sourceRoot\Documents"; dest = "$localRoot\Documents" },
        @{ name = "Downloads"; src = "$sourceRoot\Downloads"; dest = "$localRoot\Downloads" },
        @{ name = "Pictures";  src = "$sourceRoot\Pictures";  dest = "$localRoot\Pictures" },
        @{ name = "Videos";    src = "$sourceRoot\Videos";    dest = "$localRoot\Videos" },
        @{ name = "Music";     src = "$sourceRoot\Music";     dest = "$localRoot\Music" }
    )
}

$rawTargets += Get-RestorableBrowserProfiles "chrome" $sourceRoot "$env:LOCALAPPDATA\Google\Chrome\User Data"
$rawTargets += Get-RestorableBrowserProfiles "edge" $sourceRoot "$env:LOCALAPPDATA\Microsoft\Edge\User Data"
$rawTargets += Get-RestorableBrowserProfiles "firefox" $sourceRoot "$env:APPDATA\Mozilla\Firefox\Profiles"

$backupItems = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($target in $rawTargets) {
    if ($target) {
        $backupItems.Add([PSCustomObject]@{
            Name    = $target.name
            Src     = $target.src
            Dest    = $target.dest
            Enabled = $true
        })
    }
}

$threads = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors
$globalExcludedFiles = @{}


# --- PHASE 3: MAIN OPERATIONAL TUI LOOP ---
$running = $true
while ($running) {
    $selectedCount = ($backupItems | Where-Object { $_.Enabled -eq $true }).Count
    $driveLabel = if ($chosenDrive.FileSystemLabel) { $chosenDrive.FileSystemLabel } else { "Local Volume" }
    $sizeCheckStatus = if ($sizeCheckEnabled) { "ENABLED" } else { "DISABLED" }
    $largeFileAuditStatus = if ($largeFileAuditEnabled) { "ENABLED" } else { "DISABLED" }
    
    $menuTitle = "USER RESTORE MENU | Source: [$($chosenDrive.DriveLetter):] $driveLabel"
    $menuItems = @(
        "Start Restore Operation ($selectedCount items staged)"
        "Configure Restore Locations"
        "Toggle Pre-Flight Large File Audit (5GB+) [$largeFileAuditStatus]"
        "Toggle Post-Restore Size Auditing [$sizeCheckStatus]"
        "Preview Restore Mapping Path"
        "Change Source Drive Selection"
        "Exit Utility"
    )

    $selection = Show-TuiMenu -Title $menuTitle -Options $menuItems

    switch -Wildcard ($selection) {
        "Start Restore*" {
            if ($selectedCount -eq 0) {
                Write-Host "Error: You must select at least one location to restore!" -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }

            $userCancelled = $false

            # Intercept for 5GB+ File Audit
            if ($largeFileAuditEnabled) {
                foreach ($item in $backupItems | Where-Object { $_.Enabled }) {
                    Clear-Host
                    Write-Host "Scanning $($item.Name) on external drive for files over 5GB. Please wait..." -ForegroundColor Cyan
                    
                    $largeFiles = [System.Collections.Generic.List[PSCustomObject]]::new()
                    $files = Get-ChildItem -Path $item.Src -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 5368709120 }
                    
                    if ($files) {
                        foreach ($f in $files) {
                            $sizeGB = [math]::Round($f.Length / 1GB, 2)
                            $largeFiles.Add([PSCustomObject]@{
                                Name     = "[$sizeGB GB] $($f.FullName)"
                                FileName = $f.Name
                                Enabled  = $true
                            })
                        }
                        
                        $auditResult = Show-TuiChecklist -Title "Review 5GB+ Files in $($item.Name) (Uncheck to Skip)" -Items $largeFiles
                        
                        if ($auditResult -eq $false) {
                            $userCancelled = $true
                            break 
                        }
                        
                        $skipped = $largeFiles | Where-Object { -not $_.Enabled } | Select-Object -ExpandProperty FileName
                        if ($skipped) {
                            $globalExcludedFiles[$item.Name] = $skipped
                        }
                    }
                }
            }

            if ($userCancelled) { continue }
            $running = $false 
        }
        
        "Configure Restore Locations" {
            $null = Show-TuiChecklist -Title "Toggle Locations Using [Spacebar]" -Items $backupItems
        }

        "Toggle Large*" {
            $largeFileAuditEnabled = -not $largeFileAuditEnabled
        }

        "Toggle Post-Restore Size*" {
            $sizeCheckEnabled = -not $sizeCheckEnabled
        }
        
        "Preview Restore Mapping Path" {
            Clear-Host
            Write-Host "=== Dynamic Restore Path Blueprint ===" -ForegroundColor Yellow
            foreach ($item in $backupItems) {
                $status = if ($item.Enabled) { "ACTIVE " } else { "SKIPPED" }
                $color  = if ($item.Enabled) { "Cyan" } else { "DarkGray" }
                Write-Host " [$status] Target: $($item.Name)" -ForegroundColor $color
                Write-Host "          From:   $($item.Src)" -ForegroundColor Gray
                Write-Host "          To:     $($item.Dest)" -ForegroundColor Gray
                Write-Host " -----------------------------------------------------------"
            }
            Write-Host "`nPress any key to return to the main menu..." -ForegroundColor Yellow
            $null = [Console]::ReadKey($true)
            Clear-Host
        }

        "Change Source Drive Selection" {
            $selectedDriveText = Show-TuiMenu -Title "SELECT SOURCE BACKUP DRIVE" -Options $driveOptions
            if ($selectedDriveText -ne "CANCEL") {
                $chosenDrive = $driveMapping[$selectedDriveText]
                $sourceRoot = "$($chosenDrive.DriveLetter):\$username"
            }
        }
        
        "Exit Utility" {
            Write-Host "Operation aborted." -ForegroundColor Red
            exit 0
        }
    }
}


# --- PHASE 4: ROBOCOPY EXECUTION ENGINE ---
Clear-Host
Write-Host "Initializing restore matrix execution across $threads threads..." -ForegroundColor Green

$auditLogs = @{}
$tempLog = Join-Path $env:TEMP "robo_restore.log"

foreach ($item in $backupItems) {
    if (-not $item.Enabled) {
        Write-Host "`nSkipping (Disabled by User): $($item.Name)" -ForegroundColor DarkGray
        continue
    }
    if (-not (Test-Path $item.Src)) {
        Write-Host "`nSkipping (Directory Not Found on Backup Drive): $($item.Src)" -ForegroundColor Yellow
        continue
    }
    
    $dst = $item.Dest
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    
    Write-Host "`nRestoring structure: $($item.Name)" -ForegroundColor Cyan
    
    if (Test-Path $tempLog) { Remove-Item $tempLog -Force }

    # Removed /MIR, replaced with /E to safely merge without deleting local destination files
    $currentRoboFlags = @("/E", "/W:1", "/R:1", "/J", "/MT:$threads", "/NP", "/NDL", "/UNILOG:$tempLog")
    
    if ($globalExcludedFiles.ContainsKey($item.Name)) {
        $currentRoboFlags += "/XF"
        $currentRoboFlags += $globalExcludedFiles[$item.Name]
    }

    $roboArgs = @($item.Src, $dst) + $currentRoboFlags
    $process = Start-Process -FilePath "robocopy.exe" -ArgumentList $roboArgs -WindowStyle Hidden -PassThru
    
    $spinner = @('|', '/', '-', '\')
    $spinIndex = 0

    while (-not $process.HasExited) {
        if (Test-Path $tempLog) {
            $lastLine = Get-Content $tempLog -Tail 5 -ErrorAction SilentlyContinue | Where-Object { $_.Trim() -ne "" } | Select-Object -Last 1
            
            if ($lastLine) {
                $cleanLine = $lastLine.Trim()
                if ($cleanLine.Length -gt 65) { $cleanLine = $cleanLine.Substring(0, 62) + "..." }
                
                $spinChar = $spinner[$spinIndex % 4]
                Write-Host "`r  [$spinChar] Copying: $cleanLine                                      " -NoNewline -ForegroundColor Gray
                $spinIndex++
            }
        }
        Start-Sleep -Milliseconds 150
    }
    
    Write-Host "`r  [✓] Transfer Complete!                                                              " -ForegroundColor Green
    $auditLogs[$item.Name] = Get-Content $tempLog
}


# --- PHASE 5: INTERACTIVE SIZE & COUNT FOOTPRINT AUDIT ---
if ($sizeCheckEnabled) {
    Write-Host "`n=====================================================================" -ForegroundColor Cyan
    Write-Host " Analyzing Post-Restore Robocopy Summaries..." -ForegroundColor Yellow
    Write-Host "=====================================================================" -ForegroundColor Cyan
    
    $failedFilesReport = @{}

    foreach ($item in $backupItems) {
        if ($item.Enabled -and (Test-Path $item.Src) -and $auditLogs.ContainsKey($item.Name)) {
            $errors = Verify-RobocopyLog -RoboLog $auditLogs[$item.Name] -ItemName $item.Name
            
            if ($errors) {
                $failedFilesReport[$item.Name] = $errors
            }
        }
    }

    if ($failedFilesReport.Count -gt 0) {
        Write-Host "`n[?] Would you like to view the detailed list of failed files? (Y/N): " -NoNewline -ForegroundColor Yellow
        $keypress = $null
        
        while (-not ($keypress.Character -match "[YyNn]")) {
            $keypress = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
        }
        Write-Host $keypress.Character -ForegroundColor Yellow
        
        if ($keypress.Character -match "[Yy]") {
            $errorExportPath = Join-Path $localRoot "Desktop\Restore_Failed_Files_$([datetime]::Now.ToString('yyyyMMdd_HHmmss')).txt"
            $errorFileContent = @()
            
            Clear-Host
            Write-Host "=====================================================================" -ForegroundColor Red
            Write-Host "  FAILED FILE RESTORE REPORT" -ForegroundColor Yellow
            Write-Host "=====================================================================" -ForegroundColor Red
            
            foreach ($key in $failedFilesReport.Keys) {
                Write-Host "`n LOCATION: $key " -ForegroundColor Black -BackgroundColor Red
                $errorFileContent += "LOCATION: $key"
                $errorFileContent += "---------------------------------------------------"
                
                foreach ($errLine in $failedFilesReport[$key]) {
                    $cleanErr = $errLine -replace "^\s*\d{4}/\d{2}/\d{2}\s+\d{2}:\d{2}:\d{2}\s+", ""
                    Write-Host " -> $cleanErr" -ForegroundColor Gray
                    $errorFileContent += $cleanErr
                }
                $errorFileContent += ""
            }
            
            $errorFileContent | Out-File -FilePath $errorExportPath -Encoding UTF8
            
            Write-Host "`n=====================================================================" -ForegroundColor Red
            Write-Host " [i] A full copy of this report was saved to: $errorExportPath" -ForegroundColor Cyan
            Write-Host "=====================================================================" -ForegroundColor Red
            Write-Host "Press any key to return to termination sequence..." -ForegroundColor Yellow
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            Write-Host ""
        }
    }
}


# --- PHASE 6: TERMINATION ---
Write-Host "`nRestore operation process sequence finalized." -ForegroundColor Green
Write-Host "Press any key to close this terminal window" -NoNewline

$waitCount = 0
do {
    if ([Console]::KeyAvailable) {
        $keyInfo = [Console]::ReadKey($true)
        break
    }
    Write-Host '.' -NoNewline
    Start-Sleep -Seconds 6
    $waitCount++
} while ($waitCount -ne 10)
