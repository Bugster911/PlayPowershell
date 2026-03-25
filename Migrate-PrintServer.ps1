<#
.SYNOPSIS
    Migrates print drivers and complete print server configuration from
    Windows Server 2016 to Windows Server 2019.

.DESCRIPTION
    This script has two modes:
      Export  - Run on the SOURCE server (WS2016). Backs up all printers,
                printer drivers, printer ports, and permissions using
                PrintBRM.exe plus supplemental XML exports.
      Import  - Run on the DESTINATION server (WS2019). Restores the full
                configuration from the export package.

    The primary mechanism is the built-in Windows Print Migration tool
    (PrintBRM.exe), supplemented by PowerShell exports for auditing and
    fallback.

.PARAMETER Mode
    Export or Import.

.PARAMETER ExportPath
    Folder where the export package will be written (Export mode) or read
    from (Import mode).

.PARAMETER SkipPrintBRM
    Skip PrintBRM.exe and use only the PowerShell-based method.
    Use this if PrintBRM is unavailable or the .printerExport file is
    already available from another source.

.EXAMPLE
    # --- On Windows Server 2016 ---
    .\Migrate-PrintServer.ps1 -Mode Export -ExportPath "C:\PrintMigration"

    # Copy C:\PrintMigration to the WS2019 server, then:

    # --- On Windows Server 2019 ---
    .\Migrate-PrintServer.ps1 -Mode Import -ExportPath "C:\PrintMigration"

.NOTES
    Requires:
      - PowerShell 5.1+
      - Print and Document Services role (for PrintBRM.exe)
      - Run as Administrator
      - PrintManagement module (included in RSAT / Print Services role)
#>

#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory)]
    [ValidateSet('Export', 'Import')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [string]$ExportPath,

    [switch]$SkipPrintBRM
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step {
    param([string]$Message)
    Write-Host "`n[*] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [!!] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    [ERROR] $Message" -ForegroundColor Red
}

function Get-PrintBRMPath {
    $path = "$env:SystemRoot\System32\spool\tools\PrintBRM.exe"
    if (Test-Path $path) { return $path }
    Write-Warn "PrintBRM.exe not found at '$path'."
    return $null
}

# ---------------------------------------------------------------------------
# Ensure output folder exists
# ---------------------------------------------------------------------------
if (-not (Test-Path $ExportPath)) {
    New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null
}

$printBRMFile  = Join-Path $ExportPath 'PrintServer.printerExport'
$driversXml    = Join-Path $ExportPath 'PrintDrivers.xml'
$printersXml   = Join-Path $ExportPath 'Printers.xml'
$portsXml      = Join-Path $ExportPath 'PrinterPorts.xml'
$permissionsDir = Join-Path $ExportPath 'Permissions'
$driverFilesDir = Join-Path $ExportPath 'DriverFiles'

# ---------------------------------------------------------------------------
# EXPORT MODE
# ---------------------------------------------------------------------------
if ($Mode -eq 'Export') {

    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "  PRINT SERVER EXPORT  (WS2016 Source)" -ForegroundColor Magenta
    Write-Host "========================================`n" -ForegroundColor Magenta

    # --- 1. PrintBRM full backup ------------------------------------------
    if (-not $SkipPrintBRM) {
        Write-Step "Running PrintBRM.exe full print server backup..."
        $brmPath = Get-PrintBRMPath
        if ($brmPath) {
            if ($PSCmdlet.ShouldProcess($printBRMFile, 'PrintBRM backup')) {
                $result = & $brmPath -B -F $printBRMFile 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "PrintBRM backup saved to: $printBRMFile"
                } else {
                    Write-Warn "PrintBRM exited with code $LASTEXITCODE. Output:`n$result"
                    Write-Warn "Falling back to PowerShell-only export."
                }
            }
        } else {
            Write-Warn "Skipping PrintBRM — binary not found. Using PowerShell export only."
        }
    } else {
        Write-Warn "PrintBRM skipped by -SkipPrintBRM switch."
    }

    # --- 2. Export printer drivers (PowerShell) ---------------------------
    Write-Step "Exporting printer driver list..."
    try {
        $drivers = Get-PrinterDriver -ErrorAction Stop
        $drivers | Export-Clixml -Path $driversXml
        Write-Success "Exported $($drivers.Count) driver(s) to: $driversXml"
    } catch {
        Write-Fail "Get-PrinterDriver failed: $_"
    }

    # --- 3. Copy driver INF + binary files --------------------------------
    Write-Step "Copying driver files to export folder..."
    New-Item -ItemType Directory -Path $driverFilesDir -Force | Out-Null
    foreach ($drv in $drivers) {
        try {
            $drvFolder = Join-Path $driverFilesDir ($drv.Name -replace '[\\/:*?"<>|]', '_')
            New-Item -ItemType Directory -Path $drvFolder -Force | Out-Null

            # Collect all file paths reported by the driver object
            $files = @()
            foreach ($prop in 'InfPath','DriverPath','ConfigFile','DataFile','HelpFile','DependentFiles') {
                $val = $drv.$prop
                if ($val) {
                    if ($val -is [System.Array]) { $files += $val }
                    else { $files += $val }
                }
            }

            $copied = 0
            foreach ($f in ($files | Where-Object { $_ -and (Test-Path $_) } | Sort-Object -Unique)) {
                try {
                    Copy-Item -Path $f -Destination $drvFolder -Force
                    $copied++
                } catch {
                    Write-Warn "  Could not copy '$f': $_"
                }
            }
            Write-Success "  '$($drv.Name)' — $copied file(s) copied"
        } catch {
            Write-Fail "  Failed processing driver '$($drv.Name)': $_"
        }
    }

    # --- 4. Export printers -----------------------------------------------
    Write-Step "Exporting printer list..."
    try {
        $printers = Get-Printer -Full -ErrorAction Stop
        $printers | Export-Clixml -Path $printersXml
        Write-Success "Exported $($printers.Count) printer(s) to: $printersXml"
    } catch {
        Write-Fail "Get-Printer failed: $_"
    }

    # --- 5. Export printer ports ------------------------------------------
    Write-Step "Exporting printer port list..."
    try {
        $ports = Get-PrinterPort -ErrorAction Stop
        $ports | Export-Clixml -Path $portsXml
        Write-Success "Exported $($ports.Count) port(s) to: $portsXml"
    } catch {
        Write-Fail "Get-PrinterPort failed: $_"
    }

    # --- 6. Export printer permissions (SDDL) -----------------------------
    Write-Step "Exporting printer permissions..."
    New-Item -ItemType Directory -Path $permissionsDir -Force | Out-Null
    $permErrors = 0
    foreach ($p in $printers) {
        try {
            $sddl = (Get-Printer -Name $p.Name -Full).PermissionSDDL
            if ($sddl) {
                $safeName = $p.Name -replace '[\\/:*?"<>|]', '_'
                $sddl | Out-File -FilePath (Join-Path $permissionsDir "$safeName.sddl") -Encoding UTF8
            }
        } catch {
            $permErrors++
            Write-Warn "  Could not export permissions for '$($p.Name)': $_"
        }
    }
    if ($permErrors -eq 0) {
        Write-Success "Printer permissions exported to: $permissionsDir"
    }

    Write-Host "`n========================================" -ForegroundColor Magenta
    Write-Host "  EXPORT COMPLETE" -ForegroundColor Magenta
    Write-Host "  Package location: $ExportPath" -ForegroundColor Magenta
    Write-Host "========================================`n" -ForegroundColor Magenta
    Write-Host "  Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Copy the entire '$ExportPath' folder to the WS2019 server." -ForegroundColor Yellow
    Write-Host "  2. Run this script on WS2019 with -Mode Import." -ForegroundColor Yellow
}

# ---------------------------------------------------------------------------
# IMPORT MODE
# ---------------------------------------------------------------------------
elseif ($Mode -eq 'Import') {

    Write-Host "`n=============================================" -ForegroundColor Magenta
    Write-Host "  PRINT SERVER IMPORT  (WS2019 Destination)" -ForegroundColor Magenta
    Write-Host "=============================================`n" -ForegroundColor Magenta

    # --- 1. PrintBRM restore (preferred) ----------------------------------
    $brmRestored = $false

    if (-not $SkipPrintBRM -and (Test-Path $printBRMFile)) {
        Write-Step "Restoring via PrintBRM.exe..."
        $brmPath = Get-PrintBRMPath
        if ($brmPath) {
            if ($PSCmdlet.ShouldProcess($printBRMFile, 'PrintBRM restore')) {
                $result = & $brmPath -R -F $printBRMFile 2>&1
                if ($LASTEXITCODE -eq 0) {
                    Write-Success "PrintBRM restore completed successfully."
                    $brmRestored = $true
                } else {
                    Write-Warn "PrintBRM restore exited with code $LASTEXITCODE. Output:`n$result"
                    Write-Warn "Will attempt PowerShell fallback import."
                }
            }
        } else {
            Write-Warn "PrintBRM.exe not found. Falling back to PowerShell import."
        }
    } elseif (-not $SkipPrintBRM) {
        Write-Warn "PrintBRM export file not found at '$printBRMFile'. Using PowerShell import."
    }

    # --- 2. PowerShell fallback import ------------------------------------
    if (-not $brmRestored) {

        # 2a. Verify required XML files exist
        foreach ($file in @($driversXml, $printersXml, $portsXml)) {
            if (-not (Test-Path $file)) {
                Write-Fail "Required export file not found: $file"
                Write-Fail "Cannot continue. Ensure the export package is present."
                exit 1
            }
        }

        $importedDrivers = Import-Clixml -Path $driversXml
        $importedPrinters = Import-Clixml -Path $printersXml
        $importedPorts    = Import-Clixml -Path $portsXml

        # 2b. Install printer drivers ----------------------------------------
        Write-Step "Installing printer drivers..."
        foreach ($drv in $importedDrivers) {
            # Skip built-in Microsoft drivers — they ship with WS2019
            if ($drv.Name -like 'Microsoft*') {
                Write-Warn "  Skipping built-in driver: '$($drv.Name)'"
                continue
            }

            # Check if already installed
            $existing = Get-PrinterDriver -Name $drv.Name -ErrorAction SilentlyContinue
            if ($existing) {
                Write-Warn "  Already installed, skipping: '$($drv.Name)'"
                continue
            }

            # Try to install from copied driver files
            $drvFolder = Join-Path $driverFilesDir ($drv.Name -replace '[\\/:*?"<>|]', '_')

            if (Test-Path $driverFilesDir) {
                # Find the .inf inside the driver's subfolder
                $infFile = Get-ChildItem -Path $drvFolder -Filter '*.inf' -ErrorAction SilentlyContinue |
                           Select-Object -First 1

                if ($infFile) {
                    try {
                        if ($PSCmdlet.ShouldProcess($drv.Name, 'Add-PrinterDriver')) {
                            # Stage the driver into the driver store first
                            pnputil.exe /add-driver $infFile.FullName /install | Out-Null
                            Add-PrinterDriver -Name $drv.Name -ErrorAction Stop
                            Write-Success "  Installed: '$($drv.Name)'"
                        }
                    } catch {
                        Write-Fail "  Failed to install '$($drv.Name)': $_"
                    }
                } else {
                    Write-Warn "  No .inf found in '$drvFolder' for driver '$($drv.Name)' — skipping."
                    Write-Warn "  Install this driver manually before adding printers that use it."
                }
            } else {
                Write-Warn "  DriverFiles folder not found. Attempting Add-PrinterDriver directly..."
                try {
                    if ($PSCmdlet.ShouldProcess($drv.Name, 'Add-PrinterDriver')) {
                        Add-PrinterDriver -Name $drv.Name -ErrorAction Stop
                        Write-Success "  Installed (in-box): '$($drv.Name)'"
                    }
                } catch {
                    Write-Fail "  Failed: '$($drv.Name)': $_"
                }
            }
        }

        # 2c. Create printer ports -------------------------------------------
        Write-Step "Creating printer ports..."
        foreach ($port in $importedPorts) {
            # Skip standard local ports
            if ($port.Name -in @('LPT1:', 'LPT2:', 'LPT3:', 'COM1:', 'COM2:', 'COM3:', 'COM4:', 'FILE:', 'PORTPROMPT:', 'NUL:')) {
                Write-Warn "  Skipping standard port: '$($port.Name)'"
                continue
            }

            $existingPort = Get-PrinterPort -Name $port.Name -ErrorAction SilentlyContinue
            if ($existingPort) {
                Write-Warn "  Port already exists, skipping: '$($port.Name)'"
                continue
            }

            try {
                if ($PSCmdlet.ShouldProcess($port.Name, 'Add-PrinterPort')) {
                    $addPortParams = @{ Name = $port.Name }

                    # TCP/IP port
                    if ($port.PrinterHostAddress) {
                        $addPortParams['PrinterHostAddress'] = $port.PrinterHostAddress
                        if ($port.PortNumber) {
                            $addPortParams['PortNumber'] = $port.PortNumber
                        }
                        if ($port.SNMPEnabled -ne $null) {
                            $addPortParams['SNMPEnabled'] = $port.SNMPEnabled
                        }
                        if ($port.SNMPCommunity) {
                            $addPortParams['SNMPCommunity'] = $port.SNMPCommunity
                        }
                    }

                    Add-PrinterPort @addPortParams -ErrorAction Stop
                    Write-Success "  Created port: '$($port.Name)'"
                }
            } catch {
                Write-Fail "  Failed to create port '$($port.Name)': $_"
            }
        }

        # 2d. Add printers ---------------------------------------------------
        Write-Step "Adding printers..."
        foreach ($printer in $importedPrinters) {
            $existingPrinter = Get-Printer -Name $printer.Name -ErrorAction SilentlyContinue
            if ($existingPrinter) {
                Write-Warn "  Printer already exists, skipping: '$($printer.Name)'"
                continue
            }

            try {
                if ($PSCmdlet.ShouldProcess($printer.Name, 'Add-Printer')) {
                    $addParams = @{
                        Name       = $printer.Name
                        DriverName = $printer.DriverName
                        PortName   = $printer.PortName
                    }
                    if ($printer.Comment)  { $addParams['Comment']  = $printer.Comment }
                    if ($printer.Location) { $addParams['Location'] = $printer.Location }
                    if ($printer.Shared)   { $addParams['Shared']   = $printer.Shared }
                    if ($printer.Shared -and $printer.ShareName) {
                        $addParams['ShareName'] = $printer.ShareName
                    }
                    if ($printer.Published) { $addParams['Published'] = $printer.Published }

                    Add-Printer @addParams -ErrorAction Stop
                    Write-Success "  Added printer: '$($printer.Name)'"
                }
            } catch {
                Write-Fail "  Failed to add printer '$($printer.Name)': $_"
            }
        }

        # 2e. Restore printer permissions ------------------------------------
        Write-Step "Restoring printer permissions..."
        if (Test-Path $permissionsDir) {
            foreach ($sddlFile in Get-ChildItem -Path $permissionsDir -Filter '*.sddl') {
                # Reconstruct original printer name from safe filename
                $printerName = $sddlFile.BaseName
                $sddl = Get-Content $sddlFile.FullName -Raw
                $p = Get-Printer -Name $printerName -ErrorAction SilentlyContinue
                if ($p -and $sddl) {
                    try {
                        if ($PSCmdlet.ShouldProcess($printerName, 'Set PermissionSDDL')) {
                            Set-Printer -Name $printerName -PermissionSDDL $sddl.Trim() -ErrorAction Stop
                            Write-Success "  Permissions restored for: '$printerName'"
                        }
                    } catch {
                        Write-Warn "  Could not restore permissions for '$printerName': $_"
                    }
                } else {
                    Write-Warn "  Printer '$printerName' not found — permissions skipped."
                }
            }
        } else {
            Write-Warn "Permissions directory not found, skipping permission restore."
        }
    }

    # --- 3. Verification --------------------------------------------------
    Write-Step "Verifying installed printers..."
    $installed = Get-Printer -ErrorAction SilentlyContinue
    if ($installed) {
        $installed | Format-Table -AutoSize -Property Name, DriverName, PortName, Shared, ShareName, PrinterStatus
    } else {
        Write-Warn "No printers found after import."
    }

    Write-Host "`n=============================================" -ForegroundColor Magenta
    Write-Host "  IMPORT COMPLETE" -ForegroundColor Magenta
    Write-Host "=============================================" -ForegroundColor Magenta
    Write-Host "`n  Post-import checklist:" -ForegroundColor Yellow
    Write-Host "  [ ] Verify printer shares are accessible from clients" -ForegroundColor Yellow
    Write-Host "  [ ] Confirm printer permissions match source server" -ForegroundColor Yellow
    Write-Host "  [ ] Test print a test page from each printer" -ForegroundColor Yellow
    Write-Host "  [ ] Update DNS/GPO printer mappings if IP changed" -ForegroundColor Yellow
    Write-Host "  [ ] Update Group Policy printer deployment objects" -ForegroundColor Yellow
    Write-Host ""
}
