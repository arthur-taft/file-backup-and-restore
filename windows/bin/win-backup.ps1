# PowerShell USB 3.2 Saturation Backup Script
# Copyright (c) 2026 Arthur Taft
$username = $env:USERNAME
$sourceRoot = "C:\Users\$username"

function Get-BrowserProfiles {
    param (
        $browser,
        $profileStr
    )

    # Chrome and Edge are both Chromium browsers,
    # so they share the same profile path
    if (($browser -eq "chrome") -or ($browser -eq "edge")) {
        $profileCheck = Test-Path "$profileStr 1"
    # Firefox is special
    } elseif ($browser -eq "firefox") {
        $profileCheck = Test-Path "$profileStr\*.default-release"
    }

    $browserProfiles = @()

    
    if (($profileCheck -eq $true) -and (($browser -eq "chrome") -or ($browser -eq "edge"))) {
        $i = 1
        do {
            if ($i -ne 1) {
                $browserProfiles += @{ src = "$profile"; dest = "$browser Profile $i" }
            }
            $browserProfile = Join-Path -Path "$profileStr " -ChildPath "$i"
            $browserProfileCheck = Test-Path "$browserProfile"
        } while ($browserProfileCheck -eq $true)
    } elseif (($profileCheck -eq $true) -and ($browser -eq "firefox")) {
        # Firefox likes to be fun with creating profiles,
        # so we have to do some fun logic to grab them all
        $fetchedFirefoxProfiles = Get-ChildItem "$profileStr\*.default-release" -Directory
        $fetchedFirefoxProfile = $fetchedFirefoxProfiles[0]
        $firefoxSplitPath = Split-Path -Path $fetchedFirefoxProfile -Leaf
        $browserProfiles = @(
            @{ src = "$fetchedFirefoxProfile"; dest = "$\$firefoxSplitPath"}
        )
    }
    return $browserProfiles
}

# Detect first mounted USB drive
$usb = Get-Volume | Where-Object { $_.DriveType -eq 'Removable' -and $_.DriveLetter } | Select-Object -First 1
if (-not $usb) { Write-Error "No USB drive found!"; exit 1 }

$destRoot = "$($usb.DriveLetter):\$username"
New-Item -Path $destRoot -ItemType Directory -Force | Out-Null

# List of folders to backup: [ Source Folder, Destination Subfolder ]
$targets = @(
    @{ src = "$sourceRoot\Desktop"; dest = "Desktop" },
    @{ src = "$sourceRoot\Documents"; dest = "Documents" },
    @{ src = "$sourceRoot\Downloads"; dest = "Downloads" },
    @{ src = "$sourceRoot\Pictures"; dest = "Pictures" },
    @{ src = "$sourceRoot\Videos"; dest = "Videos" },
    @{ src = "$sourceRoot\Music"; dest = "Music" }
)

# Check for chrome profiles
$targets += Get-BrowserProfiles "chrome" "$env:LOCALAPPDATA\Google\Chrome\User Data\Profile"

# Check for edge profiles
$targets += Get-BrowserProfiles "edge" "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Profile"

# Check for firefox profiles
$targets += Get-BrowserProfiles "firefox" "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"

foreach ($target in $targets) {
    foreach ($key in $target.Keys) {
        $message = '{0}, {1}' -f $key, $target[$key]
        Write-Output $message
    }
}

$threads = (Get-CimInstance -ClassName Win32_Processor).NumberOfLogicalProcessors

# Robocopy options
# - /MIR Mirrors directory tree
# - /Z Copy in restartable mode (if file copy is interrupted, robocopy can resume without issue)
# - /XA:H Does not copy hidden files
# - /W:1 Seconds to wait between retries
# - /R:1 Number of retries on failed copies
# - /MT:$threads Number of threads to use while copying
$robocopyFlags = @(
    "/MIR",
    "/XA:H",
    "/W:1",
    "/R:1",
    "/Z",
    "/MT:$threads"
) 

# Confirm before backing up data

$val = 0

while ($val -ne 1) {
    Write-Host "The backup drive selected is: $($usb.DriveLetter): $($usb.FileSystemLabel)"
    $confirmation = Read-Host "Do you want to begin the backup operation? (y/n)"

    if ($confirmation -eq "y") {
        $val++
    } elseif ($confirmation -eq "n") {
        exit 1
    } else {
        Write-Host "Response must be y/n!"
    }
}

# Backup each folder in parallel

foreach ($t in $targets) {
    if (-not (Test-Path $t.src)) {
        Write-Host "Skipping (not found): $($t.src)"; continue
    }
    $dst = Join-Path $destRoot $t.dest
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    robocopy.exe $t.src $dst $robocopyFlags
}

Write-Host "Backup complete. You may now eject your USB drive."
Write-Host "Press any key to continue"
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
