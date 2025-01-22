# Load Windows Forms assembly
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Function to get the Roblox username from the user ID
function Get-RobloxUsername {
    param (
        [string]$UserId
    )
    
    try {
        $response = Invoke-RestMethod -Uri "https://users.roblox.com/v1/users/$UserId"
        return $response.name
    } catch {
        Write-Warning ("Error retrieving username for User ID {0}: {1}" -f $UserId, $_.Exception.Message)
        return "Unknown"
    }
}

# Function to validate URLs
function Validate-URL {
    param (
        [string]$URL
    )
    try {
        $response = Invoke-WebRequest -Uri $URL -Method Head -TimeoutSec 5
        return $true
    } catch {
        return $false
    }
}

# Check if running with administrator privileges
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    [System.Windows.Forms.MessageBox]::Show("This script requires administrator privileges.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    return
}

# Create form
$form = New-Object System.Windows.Forms.Form
$form.Text = "BBD Alt Checker"
$form.Width = 500
$form.Height = 400
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)

# Create a panel for layout
$panel = New-Object System.Windows.Forms.Panel
$panel.Dock = [System.Windows.Forms.DockStyle]::Fill
$panel.Padding = [System.Windows.Forms.Padding]::new(10)
$panel.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 45)

# Create controls
$processButton = New-Object System.Windows.Forms.Button
$processButton.Text = "Get Logs"
$processButton.Width = 150
$processButton.Height = 30
$processButton.Location = New-Object System.Drawing.Point(10, 10)
$processButton.BackColor = [System.Drawing.Color]::FromArgb(40, 167, 69)
$processButton.ForeColor = [System.Drawing.Color]::White
$processButton.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$processButton.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)

$richTextBox = New-Object System.Windows.Forms.RichTextBox
$richTextBox.Width = 460
$richTextBox.Height = 300
$richTextBox.Location = New-Object System.Drawing.Point(10, 50)
$richTextBox.BackColor = [System.Drawing.Color]::FromArgb(50, 50, 50)
$richTextBox.ForeColor = [System.Drawing.Color]::White
$richTextBox.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$richTextBox.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle

# Add controls to the panel
$panel.Controls.Add($processButton)
$panel.Controls.Add($richTextBox)

$form.Controls.Add($panel)

# Add event handler for Process button click
$processButton.Add_Click({
    # Base directory to search all users
    $baseDirectory = "C:\Users"
    $pattern = [regex]::new('userid:\s*(\d+)', [System.Text.RegularExpressions.RegexOptions]::Compiled)
    $fileCount = 0
    $userIds = @{}
    $maxFileSize = 5MB
    $auditLog = @()
    
    # Recursively search all directories, excluding symbolic links
    $files = Get-ChildItem -Path $baseDirectory -Recurse -File -Force -Include *.txt, *.log -Attributes !ReparsePoint -ErrorAction SilentlyContinue

    if ($files.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("No .txt or .log files found.", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }

    # Progress bar setup
    $progress = 0

    foreach ($file in $files) {
        $progress++
        Write-Progress -Activity "Processing Files" -Status "File $progress of $($files.Count)" -PercentComplete (($progress / $files.Count) * 100)

        # Skip large files
        if ($file.Length -gt $maxFileSize) {
            Write-Warning "Skipping large file: $($file.FullName)"
            $auditLog += "Skipped large file: $($file.FullName)"
            continue
        }

        try {
            $fileContents = Get-Content -Path $file.FullName -ErrorAction SilentlyContinue
            $matches = $pattern.Matches($fileContents)

            foreach ($match in $matches) {
                $userId = $match.Groups[1].Value

                if ($userId -match '^\d+$') {
                    if (-not $userIds.ContainsKey($userId)) {
                        $userIds[$userId] = New-Object 'System.Collections.Generic.HashSet[string]'
                    }
                    $userIds[$userId].Add($file.FullName)
                } else {
                    Write-Warning "Invalid UserId found: $userId in file $($file.FullName)"
                }
            }
            $auditLog += "Processed: $($file.FullName)"
        } catch {
            Write-Warning "Skipping unreadable file: $($file.FullName)"
            $auditLog += "Skipped unreadable file: $($file.FullName) - $_.Exception.Message"
        }
    }

    if ($userIds.Count -eq 0) {
        $richTextBox.Text = "No User IDs found in any file."
    } else {
        $userLinksText = ""
        $exportText = ""
        $num = 1

        foreach ($userId in $userIds.Keys) {
            $username = Get-RobloxUsername -UserId $userId
            $profileLink = "https://www.roblox.com/users/$userId/profile"

            if (Validate-URL $profileLink) {
                $userLinksText += "$num. $profileLink - $username`n"
                $exportText += "$num. $profileLink - $username`nFound in files:`n$($userIds[$userId] -join "`n")`n`n"
            } else {
                Write-Warning "Invalid Roblox profile link: $profileLink"
            }

            $num++
        }

        $richTextBox.Text = "Processed $fileCount .txt and .log files:`n`n$userLinksText"

        $outputFile = [System.IO.Path]::Combine($env:USERPROFILE, 'Desktop', 'AltLogs_AllUsers.txt')
        Set-Content -Path $outputFile -Value $exportText
    }

    # Save audit log
    $auditFile = [System.IO.Path]::Combine($env:USERPROFILE, 'Desktop', 'AuditLog.txt')
    Set-Content -Path $auditFile -Value $auditLog

    [System.Windows.Forms.MessageBox]::Show("Processed $fileCount .txt and .log files. Data exported to Desktop.", "Processing Complete")
})

# Start the form
[System.Windows.Forms.Application]::Run($form)
