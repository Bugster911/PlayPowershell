# Install-IIS6MetabaseCompatibility.ps1
# Installs the IIS 6 Metabase Compatibility feature on Windows Server / Windows Client

#Requires -RunAsAdministrator

param(
    [switch]$IncludeWMICompatibility,
    [switch]$Restart
)

function Install-IIS6MetabaseCompatibility {
    <#
    .SYNOPSIS
        Installs IIS 6 Metabase Compatibility and optionally IIS 6 WMI Compatibility.
    .DESCRIPTION
        Enables the IIS 6 Metabase Compatibility Windows feature required by applications
        that depend on the legacy IIS metabase (e.g. older versions of SharePoint, SCCM).
    .PARAMETER IncludeWMICompatibility
        Also installs the IIS 6 WMI Compatibility feature.
    .PARAMETER Restart
        Automatically restart the computer if required.
    .EXAMPLE
        .\Install-IIS6MetabaseCompatibility.ps1
    .EXAMPLE
        .\Install-IIS6MetabaseCompatibility.ps1 -IncludeWMICompatibility -Restart
    #>

    $osInfo = Get-CimInstance -ClassName Win32_OperatingSystem
    $isServer = $osInfo.ProductType -ne 1

    Write-Host "Detecting OS type..." -ForegroundColor Cyan

    if ($isServer) {
        Write-Host "Server OS detected. Using Install-WindowsFeature." -ForegroundColor Green

        $features = @("Web-Metabase")
        if ($IncludeWMICompatibility) {
            $features += "Web-WMI"
        }

        try {
            $result = Install-WindowsFeature -Name $features -IncludeManagementTools -ErrorAction Stop
            if ($result.Success) {
                Write-Host "Successfully installed: $($features -join ', ')" -ForegroundColor Green
                if ($result.RestartNeeded -eq "Yes") {
                    Write-Host "A restart is required to complete the installation." -ForegroundColor Yellow
                    if ($Restart) {
                        Write-Host "Restarting computer..." -ForegroundColor Yellow
                        Restart-Computer -Force
                    }
                }
            } else {
                Write-Warning "Installation completed but reported unsuccessful. Check Server Manager for details."
            }
        } catch {
            Write-Error "Failed to install features: $_"
            exit 1
        }
    } else {
        Write-Host "Client OS detected. Using Enable-WindowsOptionalFeature." -ForegroundColor Green

        $features = @("IIS-Metabase")
        if ($IncludeWMICompatibility) {
            $features += "IIS-WMICompatibility"
        }

        foreach ($feature in $features) {
            try {
                $result = Enable-WindowsOptionalFeature -Online -FeatureName $feature -NoRestart -ErrorAction Stop
                Write-Host "Successfully enabled: $feature" -ForegroundColor Green
            } catch {
                Write-Error "Failed to enable ${feature}: $_"
                exit 1
            }
        }

        if ($result.RestartNeeded) {
            Write-Host "A restart is required to complete the installation." -ForegroundColor Yellow
            if ($Restart) {
                Write-Host "Restarting computer..." -ForegroundColor Yellow
                Restart-Computer -Force
            }
        }
    }

    Write-Host "`nIIS 6 Metabase Compatibility installation complete." -ForegroundColor Green
}

Install-IIS6MetabaseCompatibility
