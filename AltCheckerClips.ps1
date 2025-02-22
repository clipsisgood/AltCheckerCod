###############################################################################
# Load .NET Assemblies
###############################################################################
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

###############################################################################
# Admin Check
###############################################################################
function Check-Administrator {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
        [System.Windows.Forms.MessageBox]::Show(
            "This script requires administrator privileges. Please restart PowerShell as Administrator and run the script again.",
            "Admin Required",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit
    }
}
Check-Administrator

###############################################################################
# Function: Get the most recent Recycle Bin Modification Date (via filesystem)
###############################################################################
function Get-RecycleBinModificationDate {
    $maxDate = $null
    # Enumerate all local drives (e.g., C:\, D:\, etc.)
    $drives = Get-PSDrive -PSProvider FileSystem | Where-Object { $_.Root -match '^[A-Z]:\\$' }
    foreach ($drive in $drives) {
        $rbPath = Join-Path $drive.Root '$Recycle.Bin'
        if (Test-Path $rbPath) {
            # Use the folder's LastWriteTime
            $modTime = (Get-Item $rbPath).LastWriteTime
            # Also, get the most recent LastWriteTime from any file within the folder recursively
            $childItem = Get-ChildItem $rbPath -Recurse -ErrorAction SilentlyContinue |
                         Sort-Object LastWriteTime -Descending |
                         Select-Object -First 1
            if ($childItem -and $childItem.LastWriteTime -gt $modTime) {
                $modTime = $childItem.LastWriteTime
            }
            if (-not $maxDate -or $modTime -gt $maxDate) {
                $maxDate = $modTime
            }
        }
    }
    if ($maxDate) {
        return $maxDate
    }
    else {
        return "No \$Recycle.Bin folder found on any drive."
    }
}

###############################################################################
# Function: Check Factory Reset Date
###############################################################################
function Check-FactoryResetDate {
    try {
        # Get registry data from Source* and current Windows NT info
        $regInfo = @()
        $regSourcePaths = Get-ChildItem -Path "HKLM:\System\Setup\Source*" -ErrorAction SilentlyContinue
        foreach ($item in $regSourcePaths) {
            $regInfo += Get-ItemProperty -Path $item.PSPath -ErrorAction SilentlyContinue
        }
        $regInfo += Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue

        if (-not $regInfo) {
            $output = "No factory reset registry data found."
        }
        else {
            # Convert InstallDate (epoch seconds) to local time.
            $regData = $regInfo | Select-Object ProductName, ReleaseID, CurrentBuild,
                @{Name='InstallDate'; Expression={[timezone]::CurrentTimeZone.ToLocalTime(([datetime]'1/1/1970').AddSeconds($_.InstallDate))}}
            $sortedData = $regData | Sort-Object InstallDate
            $originalFactoryReset = $sortedData | Select-Object -First 1
            $mostRecentFactoryReset = $sortedData | Select-Object -Last 1

            $systeminfoOutput = systeminfo | find /i "Install date"

            $output = "Original Factory Reset Date:`n" + ($originalFactoryReset | Out-String) +
                      "`nMost Recent Factory Reset Date:`n" + ($mostRecentFactoryReset | Out-String) +
                      "`nSysteminfo Install Date:`n" + $systeminfoOutput
        }
    }
    catch {
        $output = "Error retrieving Factory Reset Date information."
    }
    [System.Windows.Forms.MessageBox]::Show($output, "Factory Reset Date")
}

###############################################################################
# Function: Check Recycle Bin Modification
###############################################################################
function Check-RecycleBinModification {
    $modDate = Get-RecycleBinModificationDate
    [System.Windows.Forms.MessageBox]::Show("Recycle Bin was last modified on: $modDate", "Recycle Bin Modification")
}

###############################################################################
# Function: Get Roblox Username with Retry Logic
###############################################################################
function Get-RobloxUsername {
    param (
        [string]$UserId
    )
    try {
        $retries = 3
        $delay = 5  # seconds
        $response = $null
        for ($i = 0; $i -lt $retries; $i++) {
            try {
                $response = Invoke-RestMethod -Uri "https://users.roblox.com/v1/users/$UserId"
                break
            } catch {
                if ($i -eq $retries - 1) {
                    Write-Warning ("Error retrieving username for User ID {0}: {1}" -f $UserId, $_.Exception.Message)
                    return "Unknown"
                }
                Start-Sleep -Seconds $delay
            }
        }
        return $response.name
    }
    catch {
        Write-Warning ("Error retrieving username for User ID {0}: {1}" -f $UserId, $_.Exception.Message)
        return "Unknown"
    }
}

###############################################################################
# Function: Get Roblox Log Check Results and create flags.txt afterward
###############################################################################
function Get-RobloxLogCheckResults {
    # Set up patterns and variables
    $baseDirectory = "C:\Users"
    $robloxPattern = [regex]::new('userid:\s*(\d+)', [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $microsoftPattern = [regex]::new('microsoftid:\s*([\w\-\@\.]+)', [System.Text.RegularExpressions.RegexOptions]::Compiled)

    # Collections for grouping
    $userIds = @{}
    $microsoftIds = @{}
    $msToRobloxMapping = @{}
    $maxFileSize = 5MB

    # Initialize flags file output variable
    $flagsOutput = ""

    Write-Host "Processing files, please wait..." -ForegroundColor Cyan
    $files = Get-ChildItem -Path $baseDirectory -Recurse -File -Force -Filter "*last.log" -Attributes !ReparsePoint -ErrorAction SilentlyContinue
    if ($files.Count -eq 0) {
        return "No files found ending with 'last.log'."
    }

    $progress = 0
    foreach ($file in $files) {
        $progress++
        Write-Progress -Activity "Processing Files" -Status "File $progress of $($files.Count)" -PercentComplete (($progress / $files.Count) * 100)
        
        # Initialize file-specific flags and collections
        $hasBloxstrap = $false
        $hasLoadClientSettings = $false
        $fileUserIDs = @{}
        $fileMicrosoftIDs = @{}
        
        try {
            if ($file.Length -gt $maxFileSize) {
                $stream = [System.IO.StreamReader]::new($file.FullName)
                while (-not $stream.EndOfStream) {
                    $line = $stream.ReadLine()
                    if ($robloxPattern.IsMatch($line)) {
                        foreach ($match in $robloxPattern.Matches($line)) {
                            $userId = $match.Groups[1].Value
                            if ($userId -match '^\d+$') { $fileUserIDs[$userId] = $true }
                        }
                    }
                    if ($microsoftPattern.IsMatch($line)) {
                        foreach ($match in $microsoftPattern.Matches($line)) {
                            $msId = $match.Groups[1].Value
                            $fileMicrosoftIDs[$msId] = $true
                        }
                    }
                    if ($line -match '(?i)bloxstrap') { $hasBloxstrap = $true }
                    if ($line -match '(?i)loadclientsettings') { $hasLoadClientSettings = $true }
                }
                $stream.Close()
            }
            else {
                $fileContents = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
                foreach ($line in $fileContents) {
                    if ($robloxPattern.IsMatch($line)) {
                        foreach ($match in $robloxPattern.Matches($line)) {
                            $userId = $match.Groups[1].Value
                            if ($userId -match '^\d+$') { $fileUserIDs[$userId] = $true }
                        }
                    }
                    if ($microsoftPattern.IsMatch($line)) {
                        foreach ($match in $microsoftPattern.Matches($line)) {
                            $msId = $match.Groups[1].Value
                            $fileMicrosoftIDs[$msId] = $true
                        }
                    }
                    if ($line -match '(?i)bloxstrap') { $hasBloxstrap = $true }
                    if ($line -match '(?i)loadclientsettings') { $hasLoadClientSettings = $true }
                }
            }
        }
        catch {
            Write-Host "Skipping unreadable file: $($file.FullName)" -ForegroundColor Red
            continue
        }
        
        # Determine statuses for display
        $bloxStatus = if ($hasBloxstrap) { "Yes" } else { "No" }
        $loadStatus = if ($hasLoadClientSettings) { "Yes" } else { "No" }

        # Show mini-report in console for each file
        Write-Host "========================================================" -ForegroundColor Gray
        Write-Host "File: $($file.Name)"
        Write-Host "Date: $($file.CreationTime)"
        Write-Host "Bloxstrap Found: $bloxStatus"
        Write-Host "LoadClientSettings Found: $loadStatus"
        Write-Host "========================================================" -ForegroundColor Gray
        
        # Group user IDs
        foreach ($userId in $fileUserIDs.Keys) {
            if ($userIds.ContainsKey($userId)) {
                $userIds[$userId].Bloxstrap = $userIds[$userId].Bloxstrap -or $hasBloxstrap
                $userIds[$userId].LoadClientSettings = $userIds[$userId].LoadClientSettings -or $hasLoadClientSettings
            }
            else {
                $userIds[$userId] = [PSCustomObject]@{
                    Bloxstrap = $hasBloxstrap
                    LoadClientSettings = $hasLoadClientSettings
                }
            }
        }
        
        foreach ($msId in $fileMicrosoftIDs.Keys) {
            if ($microsoftIds.ContainsKey($msId)) {
                if (-not ($microsoftIds[$msId] -contains $file.FullName)) {
                    $microsoftIds[$msId] += $file.FullName
                }
            }
            else {
                $microsoftIds[$msId] = @($file.FullName)
            }
        }
        
        if (($fileMicrosoftIDs.Count -gt 0) -and ($fileUserIDs.Count -gt 0)) {
            foreach ($msId in $fileMicrosoftIDs.Keys) {
                if (-not $msToRobloxMapping.ContainsKey($msId)) {
                    $msToRobloxMapping[$msId] = New-Object 'System.Collections.Generic.HashSet[string]'
                }
                foreach ($userId in $fileUserIDs.Keys) {
                    $msToRobloxMapping[$msId].Add($userId) | Out-Null
                }
            }
        }
        
        # Build the flags text for this file in the desired format
        $bloxFound = if ($hasBloxstrap) { "Yes" } else { "No" }
        $loadFound = if ($hasLoadClientSettings) { "Yes" } else { "No" }
        
        $flagText = "Log Name: " + $file.Name + "`n"
        $flagText += "Date Modified: " + $file.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss") + "`n"
        $flagText += "Bloxstrap Found: " + $bloxFound + "`n"
        $flagText += "LoadClientSettings Found: " + $loadFound + "`n"
        $flagText += "==================================================" + "`n"
        $flagText += "LoadClientSettings Data:" + "`n"
        # Read entire file content as a raw string
        $fileContent = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
        # Use a regex to capture everything inside the first set of curly braces following LoadClientSettingsFromLocal:
        $pattern = 'LoadClientSettingsFromLocal:\s*("(\{[\s\S]*?\})")(?=\s*(\r?\n|$))'
        $match = [regex]::Match($fileContent, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
        if ($match.Success) {
            $lsData = $match.Groups[1].Value
        }
        else {
            $lsData = "{}"
        }
        $flagText += "LoadClientSettingsFromLocal: " + $lsData + "`n`n"
        $flagsOutput += $flagText
    }

    # Write the flags output to "flags.txt" on the Desktop.
    $desktopPath = [System.IO.Path]::Combine($env:USERPROFILE, "Desktop")
    $flagFile = [System.IO.Path]::Combine($desktopPath, "flags.txt")
    $flagsOutput | Out-File -FilePath $flagFile -Encoding UTF8

    # Build the main output for display (regular Roblox log check results)
    $standaloneRobloxOutput = ""
    $counter = 1
    foreach ($userId in $userIds.Keys) {
        $isMapped = $false
        foreach ($msId in $msToRobloxMapping.Keys) {
            if ($msToRobloxMapping[$msId].Contains($userId)) { $isMapped = $true; break }
        }
        if (-not $isMapped) {
            $username = Get-RobloxUsername -UserId $userId
            $profileLink = "https://www.roblox.com/users/$userId/profile"
            $standaloneRobloxOutput += "$counter. Roblox Profile: $profileLink - Username: $username`n`n"
            $counter++
        }
    }

    $msMappingOutput = ""
    foreach ($msId in $msToRobloxMapping.Keys) {
        $msMappingOutput += "Microsoft Profile: $msId`n"
        foreach ($userId in $msToRobloxMapping[$msId]) {
            $username = Get-RobloxUsername -UserId $userId
            $profileLink = "https://www.roblox.com/users/$userId/profile"
            $msMappingOutput += "`t$profileLink - $username`n"
        }
        $msMappingOutput += "`n"
    }

    $finalOutput = @"
Standalone Roblox Accounts (no associated Microsoft Profile):

$standaloneRobloxOutput

$msMappingOutput
"@
    Write-Host $finalOutput
    return $finalOutput
}

###############################################################################
# Function: Show Roblox Log Check Results Dialog using ShowDialog
###############################################################################
function Show-RobloxLogCheckDialog {
    $results = Get-RobloxLogCheckResults

    # Create a bigger auto-resizing window
    $dialogForm = New-Object System.Windows.Forms.Form
    $dialogForm.Text = "Clips Checker - Results"
    $dialogForm.AutoSize = $true
    $dialogForm.AutoSizeMode = [System.Windows.Forms.AutoSizeMode]::GrowAndShrink
    $dialogForm.MinimumSize = New-Object System.Drawing.Size(900,600)
    $dialogForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialogForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialogForm.MaximizeBox = $false
    $dialogForm.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.AutoSize = $true
    $panel.Dock = [System.Windows.Forms.DockStyle]::Top
    $panel.Padding = New-Object System.Windows.Forms.Padding(10)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(45,45,45)

    $richTextBox = New-Object System.Windows.Forms.RichTextBox
    $richTextBox.ReadOnly = $true
    $richTextBox.DetectUrls = $true
    $richTextBox.BackColor = [System.Drawing.Color]::FromArgb(50,50,50)
    $richTextBox.ForeColor = [System.Drawing.Color]::White
    $richTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $richTextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
    $richTextBox.Width = 850
    $richTextBox.Height = 500
    $richTextBox.Anchor = [System.Windows.Forms.AnchorStyles] "Top, Left"
    $richTextBox.add_LinkClicked({
        param($sender, $e)
        Start-Process $e.LinkText
    })
    $richTextBox.Text = $results

    $panel.Controls.Add($richTextBox)
    $dialogForm.Controls.Add($panel)

    $dialogForm.ShowDialog() | Out-Null
}

###############################################################################
# Function: Create Main Menu Form (persistent main window)
###############################################################################
function Get-MainMenuForm {
    $mainForm = New-Object System.Windows.Forms.Form
    $mainForm.Text = "Select an Option"
    $mainForm.Width = 400
    $mainForm.Height = 250
    $mainForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $mainForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $mainForm.MaximizeBox = $false
    $mainForm.BackColor = [System.Drawing.Color]::FromArgb(30,30,30)

    $panel = New-Object System.Windows.Forms.Panel
    $panel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $panel.Padding = New-Object System.Windows.Forms.Padding(10)
    $panel.BackColor = [System.Drawing.Color]::FromArgb(45,45,45)

    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Select an Option"
    $label.ForeColor = [System.Drawing.Color]::White
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $label.AutoSize = $true
    $label.Location = New-Object System.Drawing.Point(130,10)

    # All buttons same size: 150 x 30.
    $btnFactoryReset = New-Object System.Windows.Forms.Button
    $btnFactoryReset.Text = "Check Factory Reset Date"
    $btnFactoryReset.Width = 150
    $btnFactoryReset.Height = 30
    $btnFactoryReset.Location = New-Object System.Drawing.Point(30,60)
    $btnFactoryReset.BackColor = [System.Drawing.Color]::FromArgb(40,167,69)
    $btnFactoryReset.ForeColor = [System.Drawing.Color]::White
    $btnFactoryReset.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnFactoryReset.Font = New-Object System.Drawing.Font("Segoe UI", 8)
    $btnFactoryReset.Add_Click({ Check-FactoryResetDate })

    $btnRobloxLogCheck = New-Object System.Windows.Forms.Button
    $btnRobloxLogCheck.Text = "Roblox Log Check"
    $btnRobloxLogCheck.Width = 150
    $btnRobloxLogCheck.Height = 30
    $btnRobloxLogCheck.Location = New-Object System.Drawing.Point(210,60)
    $btnRobloxLogCheck.BackColor = [System.Drawing.Color]::FromArgb(40,167,69)
    $btnRobloxLogCheck.ForeColor = [System.Drawing.Color]::White
    $btnRobloxLogCheck.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRobloxLogCheck.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $btnRobloxLogCheck.Add_Click({ Show-RobloxLogCheckDialog })

    $btnRecycleBin = New-Object System.Windows.Forms.Button
    $btnRecycleBin.Text = "Recycle Bin Modification"
    $btnRecycleBin.Width = 150
    $btnRecycleBin.Height = 30
    $btnRecycleBin.Location = New-Object System.Drawing.Point(30,110)
    $btnRecycleBin.BackColor = [System.Drawing.Color]::FromArgb(40,167,69)
    $btnRecycleBin.ForeColor = [System.Drawing.Color]::White
    $btnRecycleBin.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnRecycleBin.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $btnRecycleBin.Add_Click({ Check-RecycleBinModification })

    $panel.Controls.Add($label)
    $panel.Controls.Add($btnFactoryReset)
    $panel.Controls.Add($btnRobloxLogCheck)
    $panel.Controls.Add($btnRecycleBin)
    $mainForm.Controls.Add($panel)
    return $mainForm
}

###############################################################################
# Launch the Main Menu using the appropriate method
###############################################################################
$mainMenuForm = Get-MainMenuForm
if ($host.Name -eq "Windows PowerShell ISE Host" -or $psISE) {
    $mainMenuForm.ShowDialog() | Out-Null
}
else {
    [System.Windows.Forms.Application]::Run($mainMenuForm)
}
