#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Deploys a 3-VM Hyper-V lab for PKI / OCSP testing on Windows Server 2025.

.DESCRIPTION
    Creates and configures three VMs:
      - LAB-DC01    : Active Directory Domain Controller + DNS
      - LAB-ROOTCA  : Standalone Offline Root CA (never domain-joined)
      - LAB-SUBCA01 : Enterprise Subordinate / Issuing CA + OCSP Responder

    Workflow (run each phase after the previous one completes):
      Phase 1  - Create virtual switch + VMs, inject unattend.xml, boot to install
      Phase 2  - Configure DC  (run AFTER Windows setup finishes on LAB-DC01)
      Phase 3  - Configure RootCA  (run AFTER Windows setup finishes on LAB-ROOTCA)
      Phase 4  - Configure SubCA   (run AFTER LAB-DC01 is fully promoted)
      Phase 5  - Configure OCSP    (run AFTER SubCA cert is issued)

.PARAMETER Phase
    Which phase to execute: 1 | 2 | 3 | 4 | 5

.PARAMETER ISOPath
    Full path to the Windows Server 2025 ISO.

.EXAMPLE
    # Step 1 - create the VMs
    .\Deploy-PKI-Lab.ps1 -Phase 1 -ISOPath "D:\ISO\WinSrv2025.iso"

    # Step 2 - configure the DC (run after OS install completes)
    .\Deploy-PKI-Lab.ps1 -Phase 2

    # Step 3 - configure Root CA
    .\Deploy-PKI-Lab.ps1 -Phase 3

    # Step 4 - configure Subordinate CA
    .\Deploy-PKI-Lab.ps1 -Phase 4

    # Step 5 - configure OCSP Responder
    .\Deploy-PKI-Lab.ps1 -Phase 5
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet(1,2,3,4,5)]
    [int]$Phase,

    [Parameter()]
    [string]$ISOPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# LAB CONFIGURATION  -  edit this block to suit your environment
# ---------------------------------------------------------------------------
$Lab = @{
    # Hyper-V host paths
    VMStorePath     = 'C:\HyperV\VMs'
    VHDStorePath    = 'C:\HyperV\VHDs'
    UnattendPath    = 'C:\HyperV\Unattend'   # temp folder for unattend files

    # Virtual switch
    SwitchName      = 'LAB-Internal'
    SwitchType      = 'Internal'              # Internal = host can reach VMs

    # Common VM settings
    VMMemoryGB      = 4
    VMCpuCount      = 2
    VHDSizeGB       = 80

    # Network (static IPs assigned inside the guest via unattend)
    SubnetMask      = '255.255.255.0'
    DefaultGateway  = '192.168.100.1'         # host vNIC if you set it up
    DNSServer       = '192.168.100.10'        # DC IP

    # VM names + IPs
    VMs = @{
        DC = @{
            Name = 'LAB-DC01'
            IP   = '192.168.100.10'
        }
        RootCA = @{
            Name = 'LAB-ROOTCA'
            IP   = '192.168.100.20'
        }
        SubCA = @{
            Name = 'LAB-SUBCA01'
            IP   = '192.168.100.30'
        }
    }

    # Domain
    DomainName      = 'lab.local'
    DomainNetbios   = 'LAB'
    DomainDN        = 'DC=lab,DC=local'

    # CA names
    RootCAName      = 'LAB-Root-CA'
    SubCAName       = 'LAB-Issuing-CA'

    # Passwords  (change before use!)
    AdminPassword   = 'P@ssw0rd123!'     # local admin on all VMs
    DSRMPassword    = 'P@ssw0rd123!'     # DC DSRM
    DomainAdminPass = 'P@ssw0rd123!'     # domain admin after promotion
}
# ---------------------------------------------------------------------------

# Helper: coloured status output
function Write-Status {
    param([string]$Msg, [string]$Color = 'Cyan')
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Msg" -ForegroundColor $Color
}

function Write-OK    { param([string]$M) Write-Status "OK  $M" 'Green'  }
function Write-Info  { param([string]$M) Write-Status "    $M" 'Cyan'   }
function Write-Warn  { param([string]$M) Write-Status "!   $M" 'Yellow' }
function Write-Fail  { param([string]$M) Write-Status "ERR $M" 'Red'    }

# ---------------------------------------------------------------------------
# PHASE 1 - Create VMs
# ---------------------------------------------------------------------------
function Invoke-Phase1 {
    param([string]$ISO)

    if (-not $ISO -or -not (Test-Path $ISO)) {
        throw "Phase 1 requires a valid -ISOPath. '$ISO' not found."
    }

    Write-Status "=== PHASE 1: Creating Hyper-V Lab VMs ===" 'Magenta'

    # -- Folders
    foreach ($dir in @($Lab.VMStorePath, $Lab.VHDStorePath, $Lab.UnattendPath)) {
        if (-not (Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Info "Created folder: $dir"
        }
    }

    # -- Virtual switch
    if (-not (Get-VMSwitch -Name $Lab.SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $Lab.SwitchName -SwitchType $Lab.SwitchType | Out-Null
        Write-OK "Created virtual switch '$($Lab.SwitchName)'"
    } else {
        Write-Info "Virtual switch '$($Lab.SwitchName)' already exists."
    }

    # -- Create each VM
    foreach ($role in @('DC','RootCA','SubCA')) {
        $vmCfg = $Lab.VMs[$role]
        New-LabVM -Role $role -VMConfig $vmCfg -ISO $ISO
    }

    Write-Status "=== PHASE 1 COMPLETE ===" 'Magenta'
    Write-Host ""
    Write-Host "Next steps:" -ForegroundColor Yellow
    Write-Host "  1. Start each VM and complete the Windows Server 2025 installation." -ForegroundColor Yellow
    Write-Host "     The unattend.xml will automate most of it (product key, locale, admin password)." -ForegroundColor Yellow
    Write-Host "  2. Once LAB-DC01 OS install is done, run Phase 2:" -ForegroundColor Yellow
    Write-Host "       .\Deploy-PKI-Lab.ps1 -Phase 2" -ForegroundColor Yellow
}

function New-LabVM {
    param(
        [string]$Role,
        [hashtable]$VMConfig,
        [string]$ISO
    )

    $name    = $VMConfig.Name
    $ip      = $VMConfig.IP
    $vhdPath = Join-Path $Lab.VHDStorePath "$name-OS.vhdx"

    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        Write-Warn "VM '$name' already exists - skipping creation."
        return
    }

    Write-Status "Creating VM: $name ($ip)" 'White'

    # VHD
    if (-not (Test-Path $vhdPath)) {
        New-VHD -Path $vhdPath -SizeBytes ($Lab.VHDSizeGB * 1GB) -Dynamic | Out-Null
        Write-Info "  VHD created: $vhdPath"
    }

    # VM
    $vm = New-VM -Name $name `
                 -MemoryStartupBytes ($Lab.VMMemoryGB * 1GB) `
                 -VHDPath $vhdPath `
                 -Generation 2 `
                 -SwitchName $Lab.SwitchName `
                 -Path $Lab.VMStorePath

    Set-VM -VM $vm `
           -ProcessorCount $Lab.VMCpuCount `
           -DynamicMemory `
           -MemoryMinimumBytes 1GB `
           -MemoryMaximumBytes ($Lab.VMMemoryGB * 1GB) `
           -AutomaticCheckpointsEnabled $false

    # Attach ISO
    $dvd = Add-VMDvdDrive -VM $vm -Path $ISO -Passthru
    Write-Info "  ISO attached: $ISO"

    # Boot order: DVD first so it installs, then HDD
    $bootOrder = @(
        (Get-VMFirmware -VM $vm).BootOrder | Where-Object { $_.BootType -eq 'Drive' -and $_.Device -is [Microsoft.HyperV.PowerShell.DvdDrive] }
        (Get-VMFirmware -VM $vm).BootOrder | Where-Object { $_.BootType -eq 'Drive' -and $_.Device -is [Microsoft.HyperV.PowerShell.HardDiskDrive] }
        (Get-VMFirmware -VM $vm).BootOrder | Where-Object { $_.BootType -ne 'Drive' }
    )
    # Simpler: just set DVD as first
    Set-VMFirmware -VM $vm -FirstBootDevice $dvd

    # Secure Boot with Microsoft UEFI cert (required for WS2025 Gen2)
    Set-VMFirmware -VM $vm -EnableSecureBoot On -SecureBootTemplate 'MicrosoftWindows'

    # Enable Guest Services (for file copy via PowerShell Direct)
    Enable-VMIntegrationService -VMName $name -Name 'Guest Service Interface'

    # Inject unattend.xml into VHD
    $unattendFile = New-UnattendXml -VMName $name -IPAddress $ip -Role $Role
    Inject-UnattendToVHD -VHDPath $vhdPath -UnattendFile $unattendFile

    Write-OK "VM '$name' created. Start it to begin OS installation."
}

# ---------------------------------------------------------------------------
# Unattend.xml generation  (loads unattend_template.xml - no here-string)
# ---------------------------------------------------------------------------
function New-UnattendXml {
    param(
        [string]$VMName,
        [string]$IPAddress,
        [string]$Role
    )

    $templatePath = Join-Path $PSScriptRoot 'unattend_template.xml'
    if (-not (Test-Path $templatePath)) {
        throw "unattend_template.xml not found at: $templatePath`nDownload it alongside Deploy-PKI-Lab.ps1"
    }

    $encodedPass = [Convert]::ToBase64String(
                       [Text.Encoding]::Unicode.GetBytes($Lab.AdminPassword + 'AdministratorPassword'))

    $dns = if ($Role -eq 'DC') { '127.0.0.1' } else { $Lab.DNSServer }

    $xml = (Get-Content -Path $templatePath -Raw) `
        -replace '%%COMPUTERNAME%%', $VMName `
        -replace '%%IPADDRESS%%',    $IPAddress `
        -replace '%%GATEWAY%%',      $Lab.DefaultGateway `
        -replace '%%DNSSERVER%%',    $dns `
        -replace '%%DOMAINNAME%%',   $Lab.DomainName `
        -replace '%%ENCODEDPASS%%',  $encodedPass

    $outFile = Join-Path $Lab.UnattendPath "unattend_$VMName.xml"
    [System.IO.File]::WriteAllText($outFile, $xml, [System.Text.Encoding]::UTF8)
    Write-Info "  Unattend XML written: $outFile"
    return $outFile
}

# ---------------------------------------------------------------------------
# Inject unattend.xml into the VHD's \Windows\Panther\ folder
# ---------------------------------------------------------------------------
function Inject-UnattendToVHD {
    param(
        [string]$VHDPath,
        [string]$UnattendFile
    )

    Write-Info "  Injecting unattend.xml into VHD..."

    # Mount the VHD
    $mountResult = Mount-VHD -Path $VHDPath -Passthru
    $disk        = $mountResult | Get-Disk
    $partition   = $disk | Get-Partition | Where-Object { $_.Type -eq 'Basic' -and $_.Size -gt 5GB } | Select-Object -First 1

    if (-not $partition) {
        # VHD is blank (no OS yet) - we cannot inject into an unpartitioned disk.
        # The unattend will need to be placed differently. We'll use a secondary VHD approach.
        Dismount-VHD -Path $VHDPath
        Write-Warn "  VHD is blank - skipping unattend injection (will be picked up from floppy/secondary drive)."
        New-UnattendFloppy -UnattendFile $UnattendFile -VHDPath $VHDPath
        return
    }

    $driveLetter = $partition.DriveLetter
    if (-not $driveLetter) {
        $partition | Add-PartitionAccessPath -AssignDriveLetter
        $driveLetter = ($partition | Get-Partition).DriveLetter
    }

    $pantherPath = "${driveLetter}:\Windows\Panther"
    if (-not (Test-Path $pantherPath)) { New-Item -ItemType Directory -Path $pantherPath -Force | Out-Null }
    Copy-Item -Path $UnattendFile -Destination "$pantherPath\unattend.xml" -Force

    Dismount-VHD -Path $VHDPath
    Write-OK "  unattend.xml injected into VHD."
}

# ---------------------------------------------------------------------------
# Fallback: create a small "floppy" VHD with the unattend.xml
# Windows Setup looks for unattend.xml on all removable drives.
# ---------------------------------------------------------------------------
function New-UnattendFloppy {
    param(
        [string]$UnattendFile,
        [string]$VHDPath
    )

    $floppyPath = $VHDPath -replace '-OS\.vhdx$', '-Unattend.vhdx'

    if (Test-Path $floppyPath) { Remove-Item $floppyPath -Force }

    # 50 MB FAT32 VHD
    $floppy = New-VHD -Path $floppyPath -SizeBytes 50MB -Fixed
    $mountF = Mount-VHD -Path $floppyPath -Passthru
    $diskF  = $mountF | Get-Disk
    $diskF | Initialize-Disk -PartitionStyle MBR -PassThru |
             New-Partition -UseMaximumSize -AssignDriveLetter |
             Format-Volume -FileSystem FAT32 -Confirm:$false | Out-Null
    $dl = (Get-Partition -DiskNumber $diskF.Number | Where-Object DriveLetter).DriveLetter
    Copy-Item -Path $UnattendFile -Destination "${dl}:\autounattend.xml" -Force
    Dismount-VHD -Path $floppyPath

    # Attach this VHD as a second SCSI drive on the VM (Windows Setup will find autounattend.xml)
    $vmName = [System.IO.Path]::GetFileNameWithoutExtension($VHDPath) -replace '-OS$',''
    $scsi   = Get-VMScsiController -VMName $vmName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $scsi) { Add-VMScsiController -VMName $vmName }
    Add-VMHardDiskDrive -VMName $vmName -Path $floppyPath -ControllerType SCSI -ControllerNumber 0
    Write-OK "  Unattend floppy VHD attached: $floppyPath"
}

# ---------------------------------------------------------------------------
# Shared helper: wait for PowerShell Direct to become available
# ---------------------------------------------------------------------------
function Wait-VMReady {
    param(
        [string]$VMName,
        [pscredential]$Cred,
        [int]$TimeoutSec = 600
    )

    Write-Info "Waiting for PowerShell Direct on '$VMName' (timeout: ${TimeoutSec}s)..."
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    while ((Get-Date) -lt $deadline) {
        try {
            $result = Invoke-Command -VMName $VMName -Credential $Cred -ScriptBlock { $env:COMPUTERNAME } -ErrorAction Stop
            Write-OK "VM '$VMName' is ready (hostname: $result)."
            return $true
        } catch {
            Start-Sleep -Seconds 15
        }
    }

    throw "Timed out waiting for VM '$VMName' to become ready via PowerShell Direct."
}

# ---------------------------------------------------------------------------
# Entry point - dispatch phases
# ---------------------------------------------------------------------------
switch ($Phase) {
    1 { Invoke-Phase1 -ISO $ISOPath }
    2 {
        Write-Status "=== PHASE 2: Configuring Domain Controller ===" 'Magenta'
        $scriptPath = Join-Path $PSScriptRoot 'Configure-DC.ps1'
        if (-not (Test-Path $scriptPath)) { throw "Configure-DC.ps1 not found in $PSScriptRoot" }
        & $scriptPath -Lab $Lab
    }
    3 {
        Write-Status "=== PHASE 3: Configuring Root CA ===" 'Magenta'
        $scriptPath = Join-Path $PSScriptRoot 'Configure-RootCA.ps1'
        if (-not (Test-Path $scriptPath)) { throw "Configure-RootCA.ps1 not found in $PSScriptRoot" }
        & $scriptPath -Lab $Lab
    }
    4 {
        Write-Status "=== PHASE 4: Configuring Subordinate CA ===" 'Magenta'
        $scriptPath = Join-Path $PSScriptRoot 'Configure-SubCA.ps1'
        if (-not (Test-Path $scriptPath)) { throw "Configure-SubCA.ps1 not found in $PSScriptRoot" }
        & $scriptPath -Lab $Lab
    }
    5 {
        Write-Status "=== PHASE 5: Configuring OCSP Responder ===" 'Magenta'
        $scriptPath = Join-Path $PSScriptRoot 'Configure-OCSP.ps1'
        if (-not (Test-Path $scriptPath)) { throw "Configure-OCSP.ps1 not found in $PSScriptRoot" }
        & $scriptPath -Lab $Lab
    }
}
