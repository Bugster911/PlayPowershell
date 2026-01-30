<#
.SYNOPSIS
    Uninstalls the IIS 6 Metabase Compatibility feature from Windows Server.

.DESCRIPTION
    This script removes the IIS 6 Metabase Compatibility Windows feature
    (Web-Metabase) using the appropriate method based on the OS version.

.NOTES
    Requires elevation (Run as Administrator).
#>

#Requires -RunAsAdministrator

$FeatureName = "Web-Metabase"

# Check if the feature is installed
$Feature = Get-WindowsFeature -Name $FeatureName -ErrorAction SilentlyContinue

if ($null -eq $Feature) {
    Write-Warning "Unable to find the feature '$FeatureName'. Ensure this is running on Windows Server with IIS available."
    exit 1
}

if ($Feature.Installed) {
    Write-Host "Uninstalling '$($Feature.DisplayName)'..." -ForegroundColor Yellow
    $Result = Remove-WindowsFeature -Name $FeatureName

    if ($Result.Success) {
        Write-Host "Successfully uninstalled '$($Feature.DisplayName)'." -ForegroundColor Green
        if ($Result.RestartNeeded -eq "Yes") {
            Write-Warning "A restart is required to complete the uninstallation."
        }
    } else {
        Write-Error "Failed to uninstall '$($Feature.DisplayName)'."
        exit 1
    }
} else {
    Write-Host "'$($Feature.DisplayName)' is not installed." -ForegroundColor Cyan
}
