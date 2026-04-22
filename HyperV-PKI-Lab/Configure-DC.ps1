#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 2 - Configure LAB-DC01 as Active Directory Domain Controller.
    Called by Deploy-PKI-Lab.ps1 -Phase 2.

.DESCRIPTION
    Uses PowerShell Direct (no network needed) to:
      1. Rename NIC and set static IP (if not already done by unattend)
      2. Install AD DS + DNS roles
      3. Promote to forest root DC
      4. Create a domain admin account used by SubCA join
      5. Add DNS A-records for the CA machines
      6. Create the PKI-related OUs and a CRL distribution point folder
#>

param(
    [Parameter(Mandatory)]
    [hashtable]$Lab
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Status { param([string]$M,[string]$C='Cyan')  Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $M" -ForegroundColor $C }
function Write-OK     { param([string]$M) Write-Status "OK  $M" 'Green'  }
function Write-Info   { param([string]$M) Write-Status "    $M" 'Cyan'   }
function Write-Warn   { param([string]$M) Write-Status "!   $M" 'Yellow' }

# Credentials
$localCred  = New-Object pscredential('Administrator',
                  (ConvertTo-SecureString $Lab.AdminPassword -AsPlainText -Force))

$vmName = $Lab.VMs.DC.Name

# -- Wait for the VM to accept PowerShell Direct connections ------------------
Write-Status "Waiting for '$vmName' to be reachable via PowerShell Direct..."
$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
    try {
        Invoke-Command -VMName $vmName -Credential $localCred `
            -ScriptBlock { $true } -ErrorAction Stop | Out-Null
        break
    } catch { Start-Sleep 20 }
}
Write-OK "'$vmName' is reachable."

# -- Step 1: Verify / fix static IP -------------------------------------------
Write-Status "Verifying static IP on $vmName..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    param($ip, $gw, $dns, $prefix)
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    $existing = Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue

    if (-not $existing -or $existing.IPAddress -ne $ip) {
        Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        Remove-NetRoute     -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Confirm:$false -ErrorAction SilentlyContinue
        New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $ip -PrefixLength $prefix -DefaultGateway $gw | Out-Null
        Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses '127.0.0.1'
        Write-Host "  Static IP set: $ip"
    } else {
        Write-Host "  Static IP already set: $ip"
    }
} -ArgumentList $Lab.VMs.DC.IP, $Lab.DefaultGateway, $Lab.VMs.DC.IP, 24

# -- Step 2: Install AD DS + DNS roles ----------------------------------------
Write-Status "Installing AD DS and DNS roles on $vmName..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    $features = @('AD-Domain-Services','DNS','RSAT-AD-Tools','RSAT-DNS-Server')
    foreach ($f in $features) {
        if (-not (Get-WindowsFeature $f).Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
            Write-Host "  Installed: $f"
        } else {
            Write-Host "  Already installed: $f"
        }
    }
}
Write-OK "Roles installed."

# -- Step 3: Promote to Domain Controller -------------------------------------
Write-Status "Promoting $vmName to forest root DC for domain '$($Lab.DomainName)'..."

Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    param($domain, $netbios, $dsrmPass, $adminPass)

    # Check if already promoted
    try {
        $existing = Get-ADDomain -ErrorAction Stop
        Write-Host "  Already a DC for domain: $($existing.DNSRoot)"
        return
    } catch {}

    Import-Module ADDSDeployment

    $dsrmSec = ConvertTo-SecureString $dsrmPass -AsPlainText -Force

    Install-ADDSForest `
        -DomainName            $domain `
        -DomainNetbiosName     $netbios `
        -SafeModeAdministratorPassword $dsrmSec `
        -InstallDns `
        -CreateDnsDelegation:  $false `
        -DatabasePath          'C:\Windows\NTDS' `
        -SysvolPath            'C:\Windows\SYSVOL' `
        -LogPath               'C:\Windows\NTDS' `
        -NoRebootOnCompletion: $false `
        -Force

} -ArgumentList $Lab.DomainName, $Lab.DomainNetbios, $Lab.DSRMPassword, $Lab.AdminPassword

Write-Warn "DC is rebooting after promotion. Waiting 90 seconds before reconnecting..."
Start-Sleep -Seconds 90

# -- Wait for DC to come back up with domain credentials ----------------------
$domainCred = New-Object pscredential("$($Lab.DomainNetbios)\Administrator",
                  (ConvertTo-SecureString $Lab.AdminPassword -AsPlainText -Force))

Write-Status "Waiting for DC to rejoin after reboot..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    try {
        Invoke-Command -VMName $vmName -Credential $domainCred `
            -ScriptBlock { Get-ADDomain } -ErrorAction Stop | Out-Null
        break
    } catch { Start-Sleep 20 }
}
Write-OK "DC is back online."

# -- Step 4: Create domain accounts and groups ---------------------------------
Write-Status "Creating lab user accounts and OUs..."
Invoke-Command -VMName $vmName -Credential $domainCred -ScriptBlock {
    param($dn, $adminPass, $domainName)
    Import-Module ActiveDirectory

    # OUs
    $ouPKI = "OU=PKI,OU=Servers,$dn"
    if (-not (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$ouPKI'" -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name 'Servers' -Path $dn -ErrorAction SilentlyContinue | Out-Null
        New-ADOrganizationalUnit -Name 'PKI' -Path "OU=Servers,$dn" | Out-Null
        Write-Host "  Created OU: PKI"
    }

    # PKI Admin account
    $pass = ConvertTo-SecureString $adminPass -AsPlainText -Force
    if (-not (Get-ADUser -Filter "SamAccountName -eq 'pkiadmin'" -ErrorAction SilentlyContinue)) {
        New-ADUser -Name 'PKI Admin' `
                   -SamAccountName 'pkiadmin' `
                   -UserPrincipalName "pkiadmin@$domainName" `
                   -AccountPassword $pass `
                   -PasswordNeverExpires $true `
                   -Enabled $true
        Add-ADGroupMember -Identity 'Domain Admins' -Members 'pkiadmin'
        Add-ADGroupMember -Identity 'Enterprise Admins' -Members 'pkiadmin'
        Write-Host "  Created user: pkiadmin (Domain Admin + Enterprise Admin)"
    }

} -ArgumentList $Lab.DomainDN, $Lab.AdminPassword, $Lab.DomainName

# -- Step 5: Add DNS records for CA machines -----------------------------------
Write-Status "Adding DNS A-records for CA machines..."
Invoke-Command -VMName $vmName -Credential $domainCred -ScriptBlock {
    param($zone, $rootCAName, $rootCAIP, $subCAName, $subCAIP)
    Import-Module DnsServer

    foreach ($pair in @(
        @{ Name=$rootCAName; IP=$rootCAIP },
        @{ Name=$subCAName;  IP=$subCAIP  }
    )) {
        $existing = Get-DnsServerResourceRecord -ZoneName $zone -Name $pair.Name -RRType A -ErrorAction SilentlyContinue
        if (-not $existing) {
            Add-DnsServerResourceRecordA -ZoneName $zone -Name $pair.Name -IPv4Address $pair.IP
            Write-Host "  DNS A record added: $($pair.Name) -> $($pair.IP)"
        } else {
            Write-Host "  DNS A record already exists: $($pair.Name)"
        }
    }
} -ArgumentList $Lab.DomainName, $Lab.VMs.RootCA.Name, $Lab.VMs.RootCA.IP, $Lab.VMs.SubCA.Name, $Lab.VMs.SubCA.IP

# -- Step 6: Create CRL / CDP web share folder --------------------------------
Write-Status "Creating PKI web share on DC (CDP/AIA)..."
Invoke-Command -VMName $vmName -Credential $domainCred -ScriptBlock {
    param($subCAName, $domainName)
    $pkiPath = 'C:\PKI'
    if (-not (Test-Path $pkiPath)) { New-Item -ItemType Directory -Path $pkiPath | Out-Null }

    # Install IIS for CRL/AIA distribution
    Install-WindowsFeature -Name Web-Server, Web-Mgmt-Console -IncludeManagementTools | Out-Null

    # Virtual directory for PKI
    Import-Module WebAdministration
    $vdirPath = 'IIS:\Sites\Default Web Site\PKI'
    if (-not (Test-Path $vdirPath)) {
        New-WebVirtualDirectory -Site 'Default Web Site' -Name 'PKI' -PhysicalPath $pkiPath | Out-Null
        Write-Host "  IIS virtual directory /PKI created -> $pkiPath"
    }

    # SMB share so SubCA can write CRL files
    if (-not (Get-SmbShare -Name 'PKI' -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name 'PKI' -Path $pkiPath -FullAccess 'Everyone' | Out-Null
        Write-Host "  SMB share \\$env:COMPUTERNAME\PKI created"
    }

    Write-Host "  CDP/AIA URL will be: http://$subCAName.$domainName/PKI"
} -ArgumentList $Lab.VMs.SubCA.Name, $Lab.DomainName

Write-OK "=== DC configuration complete ==="
Write-Host ""
Write-Host "Next: Wait for LAB-ROOTCA OS install to finish, then run:" -ForegroundColor Yellow
Write-Host "  .\Deploy-PKI-Lab.ps1 -Phase 3" -ForegroundColor Yellow
