#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 3 - Configure LAB-ROOTCA as a Standalone Offline Root CA.
    Called by Deploy-PKI-Lab.ps1 -Phase 3.

.DESCRIPTION
    LAB-ROOTCA is intentionally NOT joined to the domain (offline root CA
    best practice). This script:
      1. Sets static IP + computer name (should already be done by unattend)
      2. Installs ADCS role
      3. Configures a Standalone Root CA with a 4096-bit RSA key / SHA256
      4. Sets a 10-year CA cert validity and a 2-year CRL schedule
      5. Exports the Root CA certificate
      6. Copies the Root CA cert + CRL to a share path for the SubCA
      7. Creates a CAPolicy.inf for proper extensions

    After this script runs you will have:
      - C:\RootCA\RootCA.crt   (the root cert to publish in AD + SubCA)
      - C:\RootCA\RootCA.crl   (base CRL)
      - A pending SubCA certificate request file placed in C:\RootCA\Requests\
        (generated in Phase 4 and copied back here for signing)
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

$localCred = New-Object pscredential('Administrator',
                 (ConvertTo-SecureString $Lab.AdminPassword -AsPlainText -Force))

$vmName   = $Lab.VMs.RootCA.Name
$rootName = $Lab.RootCAName
$subCAIP  = $Lab.VMs.SubCA.IP
$dcIP     = $Lab.VMs.DC.IP

# -- Wait for VM --------------------------------------------------------------
Write-Status "Waiting for '$vmName' PowerShell Direct..."
$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
    try { Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock { $true } -ErrorAction Stop | Out-Null; break }
    catch { Start-Sleep 20 }
}
Write-OK "$vmName reachable."

# -- Step 1: CAPolicy.inf -----------------------------------------------------
Write-Status "Writing CAPolicy.inf on $vmName..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    param($rootName)
    $policy = @"
[Version]
Signature="`$Windows NT$"

[PolicyStatementExtension]
Policies=AllIssuancePolicy

[AllIssuancePolicy]
OID=2.5.29.32.0

[BasicConstraintsExtension]
PathLength=1
Critical=Yes

[CertSrv_Server]
RenewalKeyLength=4096
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=10
CRLPeriod=Weeks
CRLPeriodUnits=52
CRLDeltaPeriod=Days
CRLDeltaPeriodUnits=0
LoadDefaultTemplates=0
AlternateSignatureAlgorithm=0
"@
    $policy | Out-File -FilePath 'C:\Windows\CAPolicy.inf' -Encoding ascii -Force
    Write-Host "  CAPolicy.inf written."
} -ArgumentList $rootName

# -- Step 2: Install ADCS role ------------------------------------------------
Write-Status "Installing ADCS role on $vmName..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    if (-not (Get-WindowsFeature 'AD-Certificate').Installed) {
        Install-WindowsFeature -Name AD-Certificate, ADCS-Cert-Authority `
                               -IncludeManagementTools | Out-Null
        Write-Host "  ADCS role installed."
    } else {
        Write-Host "  ADCS role already installed."
    }
}
Write-OK "ADCS role ready."

# -- Step 3: Configure Standalone Root CA -------------------------------------
Write-Status "Configuring Standalone Root CA '$rootName'..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    param($caName)

    # Check if CA is already configured
    $svc = Get-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host "  CertSvc already running - CA already configured."
        return
    }

    Import-Module ADCSDeployment

    Install-AdcsCertificationAuthority `
        -CAType                 StandaloneRootCA `
        -CACommonName           $caName `
        -KeyLength              4096 `
        -HashAlgorithmName      SHA256 `
        -CryptoProviderName     'RSA#Microsoft Software Key Storage Provider' `
        -ValidityPeriod         Years `
        -ValidityPeriodUnits    10 `
        -DatabaseDirectory      'C:\Windows\System32\CertLog' `
        -LogDirectory           'C:\Windows\System32\CertLog' `
        -Force                  $true `
        -Confirm:               $false

    Write-Host "  Root CA '$caName' installed."
} -ArgumentList $rootName
Write-OK "Root CA configured."

# -- Step 4: Configure CRL and CDP/AIA extensions -----------------------------
Write-Status "Configuring CRL schedule and CDP/AIA on $vmName..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    param($rootName, $subCAName, $domainName)

    $cdpURL  = "http://$subCAName.$domainName/PKI/$rootName.crl"
    $aiaURL  = "http://$subCAName.$domainName/PKI/$rootName.crt"

    # Remove default CDP/AIA and add clean ones
    $existingCDPs = Get-CACrlDistributionPoint
    foreach ($cdp in $existingCDPs) { Remove-CACrlDistributionPoint -Uri $cdp.Uri -Force -ErrorAction SilentlyContinue }

    $existingAIAs = Get-CAAuthorityInformationAccess
    foreach ($aia in $existingAIAs) { Remove-CAAuthorityInformationAccess -Uri $aia.Uri -Force -ErrorAction SilentlyContinue }

    # File path (local, for writing CRL)
    Add-CACrlDistributionPoint -Uri 'C:\Windows\System32\CertSrv\CertEnroll\%3%8%9.crl' `
        -PublishToServer -PublishDeltaToServer -Force | Out-Null

    # HTTP path for clients to download CRL
    Add-CACrlDistributionPoint -Uri $cdpURL `
        -AddToCertificateCDP -Force | Out-Null

    # AIA (cert download URL)
    Add-CAAuthorityInformationAccess -Uri $aiaURL `
        -AddToCertificateAia -Force | Out-Null

    # CRL validity: 1 year base, no delta
    certutil -setreg CA\CRLPeriodUnits 52   | Out-Null
    certutil -setreg CA\CRLPeriod "Weeks"   | Out-Null
    certutil -setreg CA\CRLDeltaPeriodUnits 0 | Out-Null
    certutil -setreg CA\CRLDeltaPeriod "Days" | Out-Null

    # Validity period for certs issued by this CA (SubCA cert = 5 years)
    certutil -setreg CA\ValidityPeriodUnits 5 | Out-Null
    certutil -setreg CA\ValidityPeriod "Years" | Out-Null

    Restart-Service CertSvc
    Start-Sleep 5

    # Publish CRL
    certutil -crl | Out-Null
    Write-Host "  CRL published."
    Write-Host "  CDP: $cdpURL"
    Write-Host "  AIA: $aiaURL"
} -ArgumentList $rootName, $Lab.VMs.SubCA.Name, $Lab.DomainName
Write-OK "CDP/AIA configured."

# -- Step 5: Export Root CA cert + CRL to a local folder ----------------------
Write-Status "Exporting Root CA cert and CRL..."
Invoke-Command -VMName $vmName -Credential $localCred -ScriptBlock {
    param($rootName)
    $outDir = 'C:\RootCA'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }

    # Export cert
    $certStore = 'Cert:\LocalMachine\CA'
    $cert = Get-ChildItem $certStore | Where-Object Subject -like "*$rootName*" | Select-Object -First 1
    if (-not $cert) {
        $certStore = 'Cert:\LocalMachine\Root'
        $cert = Get-ChildItem $certStore | Where-Object Subject -like "*$rootName*" | Select-Object -First 1
    }
    if ($cert) {
        Export-Certificate -Cert $cert -FilePath "$outDir\$rootName.crt" -Type CERT -Force | Out-Null
        Write-Host "  Root cert exported: $outDir\$rootName.crt"
    }

    # Copy CRL from CertEnroll
    $crlSource = Get-ChildItem 'C:\Windows\System32\CertSrv\CertEnroll\' -Filter '*.crl' | Select-Object -First 1
    if ($crlSource) {
        Copy-Item -Path $crlSource.FullName -Destination "$outDir\$rootName.crl" -Force
        Write-Host "  CRL copied: $outDir\$rootName.crl"
    }

    # Create requests folder (SubCA will drop .req here via copy in Phase 4)
    $reqDir = "$outDir\Requests"
    if (-not (Test-Path $reqDir)) { New-Item -ItemType Directory -Path $reqDir | Out-Null }
    Write-Host "  Request folder: $reqDir"

    # Share the folder so the Hyper-V host can copy files
    if (-not (Get-SmbShare -Name 'RootCA' -ErrorAction SilentlyContinue)) {
        New-SmbShare -Name 'RootCA' -Path $outDir -FullAccess 'Everyone' | Out-Null
        Write-Host "  SMB share created: \\$env:COMPUTERNAME\RootCA"
    }
} -ArgumentList $rootName
Write-OK "Root CA cert and CRL exported."

# -- Copy Root CA cert + CRL from VM to Hyper-V host via PowerShell Direct ----
Write-Status "Copying Root CA cert and CRL to Hyper-V host..."
$hostOutputDir = Join-Path $Lab.VMStorePath "RootCA-Export"
if (-not (Test-Path $hostOutputDir)) { New-Item -ItemType Directory -Path $hostOutputDir | Out-Null }

$session = New-PSSession -VMName $vmName -Credential $localCred
Copy-Item -FromSession $session -Path "C:\RootCA\$rootName.crt" -Destination $hostOutputDir -Force
Copy-Item -FromSession $session -Path "C:\RootCA\$rootName.crl" -Destination $hostOutputDir -Force
Remove-PSSession $session

Write-OK "Files on Hyper-V host: $hostOutputDir"

Write-OK "=== Root CA configuration complete ==="
Write-Host ""
Write-Host "Root CA cert : $hostOutputDir\$rootName.crt" -ForegroundColor Green
Write-Host "Root CRL     : $hostOutputDir\$rootName.crl" -ForegroundColor Green
Write-Host ""
Write-Host "Next: Wait for LAB-SUBCA01 OS install to finish and DC to be ready, then run:" -ForegroundColor Yellow
Write-Host "  .\Deploy-PKI-Lab.ps1 -Phase 4" -ForegroundColor Yellow
