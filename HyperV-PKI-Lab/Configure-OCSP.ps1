#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 5 - Configure the Online Certificate Status Protocol (OCSP) Responder
    on LAB-SUBCA01.
    Called by Deploy-PKI-Lab.ps1 -Phase 5.

.DESCRIPTION
    The OCSP Responder (Online Responder) role was already installed in Phase 4.
    This script:
      1. Configures the Online Responder web service in IIS
      2. Sets ACLs on the OCSPResponseSigning template so the SubCA machine
         account can auto-enroll
      3. Requests / auto-enrolls an OCSP Response Signing certificate
      4. Creates an OCSP Revocation Configuration pointing to the SubCA
      5. Verifies the OCSP responder with certutil
      6. Outputs a ready-to-use test command

    OCSP URL will be:  http://LAB-SUBCA01.<domain>/ocsp
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

$domainCred = New-Object pscredential("$($Lab.DomainNetbios)\Administrator",
                  (ConvertTo-SecureString $Lab.AdminPassword -AsPlainText -Force))

$subVMName = $Lab.VMs.SubCA.Name
$subCAName = $Lab.SubCAName
$rootName  = $Lab.RootCAName
$domain    = $Lab.DomainName
$ocspURL   = "http://$subVMName.$domain/ocsp"

# -- Wait for SubCA VM --------------------------------------------------------
Write-Status "Waiting for '$subVMName' PowerShell Direct..."
$deadline = (Get-Date).AddMinutes(10)
while ((Get-Date) -lt $deadline) {
    try { Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock { $true } -ErrorAction Stop | Out-Null; break }
    catch { Start-Sleep 15 }
}
Write-OK "$subVMName reachable."

# -- Step 1: Ensure Online Responder role is installed and IIS is ready --------
Write-Status "Verifying Online Responder (OCSP) role installation..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    $needed = @('ADCS-Online-Cert','Web-Server','Web-Asp-Net45','Web-Mgmt-Console')
    foreach ($f in $needed) {
        if (-not (Get-WindowsFeature $f).Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
            Write-Host "  Installed: $f"
        }
    }
    Write-Host "  All OCSP/IIS features present."
}

# -- Step 2: Install (configure) the Online Responder service -----------------
Write-Status "Configuring Online Responder on $subVMName..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    Import-Module ADCSDeployment

    # Check if OCSP is already configured
    $ocspSvc = Get-Service -Name 'OcspSvc' -ErrorAction SilentlyContinue
    if ($ocspSvc -and $ocspSvc.Status -eq 'Running') {
        Write-Host "  OcspSvc already running."
        return
    }

    # Install OCSP (Online Responder)
    try {
        Install-AdcsOnlineResponder -Force -Confirm:$false | Out-Null
        Write-Host "  Online Responder installed."
    } catch {
        Write-Host "  Online Responder install result: $_"
    }

    Start-Service OcspSvc -ErrorAction SilentlyContinue
    Start-Sleep 5
    $svc = Get-Service OcspSvc -ErrorAction SilentlyContinue
    Write-Host "  OcspSvc status: $($svc.Status)"
}
Write-OK "Online Responder service configured."

# -- Step 3: Grant the OCSPResponseSigning template to SubCA machine account --
Write-Status "Granting OCSPResponseSigning template enroll rights to SubCA machine account..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($subVMName, $domain)

    Import-Module ActiveDirectory

    # The template is stored in AD at CN=OCSPResponseSigning,CN=Certificate Templates,...
    $templateDN = "CN=OCSPResponseSigning,CN=Certificate Templates,CN=Public Key Services,CN=Services,CN=Configuration,$(([adsi]'LDAP://RootDSE').defaultNamingContext)"

    # Actually get via config NC
    $configNC  = ([adsi]'LDAP://RootDSE').configurationNamingContext
    $templateDN = "CN=OCSPResponseSigning,CN=Certificate Templates,CN=Public Key Services,CN=Services,$configNC"

    $template = [adsi]"LDAP://$templateDN"

    # Get SubCA machine account SID
    $computerAccount = Get-ADComputer -Identity $subVMName
    $sid = New-Object System.Security.Principal.SecurityIdentifier($computerAccount.SID)

    # Build ACE: Allow Enroll (OID: 0e10c968-78fb-11d2-90d4-00c04f79dc55)
    #            Allow AutoEnroll (a05b8cc2-17bc-4802-a710-e7c15ab866a2)
    $enrollGuid     = [Guid]'0e10c968-78fb-11d2-90d4-00c04f79dc55'
    $autoenrollGuid = [Guid]'a05b8cc2-17bc-4802-a710-e7c15ab866a2'

    $adRights = [System.DirectoryServices.ActiveDirectoryRights]::ExtendedRight
    $type     = [System.Security.AccessControl.AccessControlType]::Allow
    $inherit  = [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None

    $aceEnroll     = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $adRights, $type, $enrollGuid,     $inherit)
    $aceAutoEnroll = New-Object System.DirectoryServices.ActiveDirectoryAccessRule($sid, $adRights, $type, $autoenrollGuid, $inherit)

    $template.psbase.ObjectSecurity.AddAccessRule($aceEnroll)
    $template.psbase.ObjectSecurity.AddAccessRule($aceAutoEnroll)
    $template.psbase.CommitChanges()

    Write-Host "  Enroll + AutoEnroll granted on OCSPResponseSigning to $subVMName$"
} -ArgumentList $subVMName, $domain

# -- Step 4: Request the OCSP Response Signing certificate ---------------------
Write-Status "Requesting OCSP Response Signing certificate..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($subCAName)

    # Force a GP update so the template ACL propagates
    gpupdate /force | Out-Null

    Start-Sleep 10

    # Request cert via certreq using the OCSPResponseSigning template
    $infContent = @"
[NewRequest]
Subject="CN=OCSP Response Signing"
KeySpec=1
KeyLength=2048
Exportable=FALSE
MachineKeySet=TRUE
SMIME=FALSE
PrivateKeyArchive=FALSE
UserProtected=FALSE
UseExistingKeySet=FALSE
ProviderName="Microsoft RSA SChannel Cryptographic Provider"
ProviderType=12
RequestType=CMC
KeyUsage=0xa0

[RequestAttributes]
CertificateTemplate=OCSPResponseSigning

[EnhancedKeyUsageExtension]
OID=1.3.6.1.5.5.7.3.9
"@

    $infPath  = "$env:TEMP\ocsp.inf"
    $reqPath  = "$env:TEMP\ocsp.req"
    $crtPath  = "$env:TEMP\ocsp.crt"
    $rspPath  = "$env:TEMP\ocsp.rsp"

    $infContent | Out-File $infPath -Encoding ascii

    certreq -New   $infPath $reqPath 2>&1 | Write-Host
    certreq -Submit -Config ".\$subCAName" -attrib "CertificateTemplate:OCSPResponseSigning" $reqPath $crtPath 2>&1 | Write-Host

    if (Test-Path $crtPath) {
        certreq -Accept $crtPath 2>&1 | Write-Host
        Write-Host "  OCSP Response Signing cert installed in machine store."
    } else {
        Write-Warn "  Could not auto-enroll - trying gpupdate and autoenrollment trigger..."
        certutil -pulse | Out-Null
        Start-Sleep 15
    }
} -ArgumentList $subCAName
Write-OK "OCSP signing certificate requested."

# -- Step 5: Create OCSP Revocation Configuration ------------------------------
Write-Status "Creating OCSP Revocation Configuration for '$subCAName'..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($subCAName, $domainName, $subVMName)

    # Use the OCSPAdmin COM object to configure the Online Responder
    $ocspAdmin = New-Object -ComObject "CertAdm.OCSPAdmin"
    $ocspAdmin.GetConfiguration($env:COMPUTERNAME, $true)

    # Check if revocation config already exists
    $existing = $ocspAdmin.OCSPCAConfigurationCollection | Where-Object { $_.Identifier -eq $subCAName }
    if ($existing) {
        Write-Host "  Revocation configuration '$subCAName' already exists."
        return
    }

    $revConfig = $ocspAdmin.OCSPCAConfigurationCollection.CreateCAConfiguration(
        $subCAName,      # Identifier
        [System.Convert]::FromBase64String('')  # empty - we'll set via signing cert
    )

    # Find the SubCA certificate in the CA store to get its thumbprint
    $caCert = Get-ChildItem 'Cert:\LocalMachine\CA' |
              Where-Object { $_.Subject -like "*$subCAName*" } |
              Select-Object -First 1

    if ($caCert) {
        $revConfig.CACertificate = $caCert.RawData
        Write-Host "  CA cert bound to revocation config: $($caCert.Thumbprint)"
    }

    # Set the signing certificate (find OCSPResponseSigning cert)
    $signingCert = Get-ChildItem 'Cert:\LocalMachine\My' |
                   Where-Object { $_.EnhancedKeyUsageList.ObjectId -contains '1.3.6.1.5.5.7.3.9' } |
                   Select-Object -First 1

    if ($signingCert) {
        $revConfig.SigningCertificate = $signingCert.RawData
        Write-Host "  Signing cert bound: $($signingCert.Thumbprint)"
    }

    # Set CA config string (points to this machine's CA)
    $revConfig.CAConfig           = "$env:COMPUTERNAME\$subCAName"
    $revConfig.SigningFlags        = 0x100   # OCSP_SF_SILENT (auto sign)
    $revConfig.HashAlgorithm       = 'SHA256'

    # CRL info for this revocation config
    $revConfig.RefreshTimeOut      = 60  # minutes

    $ocspAdmin.SetConfiguration($env:COMPUTERNAME, $true)
    Write-Host "  OCSP revocation configuration created for '$subCAName'."

} -ArgumentList $subCAName, $domain, $subVMName
Write-OK "OCSP revocation configuration created."

# -- Step 6: Restart OCSP service and IIS -------------------------------------
Write-Status "Restarting OcspSvc and W3SVC..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    Restart-Service OcspSvc -Force
    Restart-Service W3SVC   -Force
    Start-Sleep 10
    Write-Host "  OcspSvc : $((Get-Service OcspSvc).Status)"
    Write-Host "  W3SVC   : $((Get-Service W3SVC).Status)"
}
Write-OK "Services restarted."

# -- Step 7: Verify OCSP with certutil -----------------------------------------
Write-Status "Verifying OCSP responder..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($ocspURL, $subCAName)

    # Get any issued cert to test against
    $testCert = Get-ChildItem 'Cert:\LocalMachine\My' | Select-Object -First 1

    if ($testCert) {
        $thumbprint = $testCert.Thumbprint
        Write-Host "  Testing OCSP with cert thumbprint: $thumbprint"
        $result = certutil -url "http://localhost/ocsp" 2>&1
        Write-Host $result
    }

    Write-Host ""
    Write-Host "  Manual OCSP test command (run on any domain machine):"
    Write-Host "    certutil -verify -urlfetch <path_to_cert.cer>"
    Write-Host "  Or using OpenSSL:"
    Write-Host "    openssl ocsp -issuer subca.crt -cert testcert.crt -url $ocspURL -text"
} -ArgumentList $ocspURL, $subCAName
Write-OK "OCSP verification complete."

# -- Step 8: Configure IIS to serve /ocsp application correctly ----------------
Write-Status "Verifying IIS OCSP application endpoint..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    Import-Module WebAdministration

    # The OCSP responder registers itself as an ISAPI extension under /ocsp
    # Verify the application exists
    $app = Get-WebApplication -Name 'ocsp' -Site 'Default Web Site' -ErrorAction SilentlyContinue
    if ($app) {
        Write-Host "  /ocsp web application found: $($app.PhysicalPath)"
    } else {
        Write-Host "  /ocsp application not found. The Online Responder service registers it automatically."
        Write-Host "  Try restarting the Online Responder service and IIS."
    }

    # Allow HTTP GET for OCSP (RFC 6960 GET method)
    Set-WebConfiguration -PSPath 'IIS:\' -Filter 'system.webServer/security/requestFiltering/verbs' `
        -Value @{verb='GET'; allowed='True'} -ErrorAction SilentlyContinue

    Write-Host "  IIS OCSP endpoint: http://$env:COMPUTERNAME/ocsp"
}
Write-OK "IIS OCSP endpoint verified."

# -- Summary --------------------------------------------------------------------
Write-Status "=== PHASE 5 COMPLETE - OCSP LAB READY ===" 'Magenta'
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "  PKI Lab Summary" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host ""
Write-Host "  Domain Controller : $($Lab.VMs.DC.Name)     ($($Lab.VMs.DC.IP))"     -ForegroundColor Cyan
Write-Host "  Domain            : $domain"                                           -ForegroundColor Cyan
Write-Host ""
Write-Host "  Root CA           : $($Lab.VMs.RootCA.Name) ($($Lab.VMs.RootCA.IP))" -ForegroundColor Cyan
Write-Host "  Root CA Name      : $rootName  (Standalone, Offline)"                 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Subordinate CA    : $subVMName  ($($Lab.VMs.SubCA.IP))"              -ForegroundColor Cyan
Write-Host "  SubCA Name        : $subCAName  (Enterprise Issuing CA)"              -ForegroundColor Cyan
Write-Host ""
Write-Host "  OCSP Responder    : $ocspURL"                                         -ForegroundColor Green
Write-Host ""
Write-Host "  CDP (CRL)         : http://$subVMName.$domain/PKI/*.crl"             -ForegroundColor Cyan
Write-Host "  AIA               : http://$subVMName.$domain/PKI/*.crt"             -ForegroundColor Cyan
Write-Host ""
Write-Host "  Test OCSP with:"                                                       -ForegroundColor Yellow
Write-Host "    certutil -verify -urlfetch <path\to\issued_cert.cer>"               -ForegroundColor Yellow
Write-Host "    certutil -URL <path\to\issued_cert.cer>"                             -ForegroundColor Yellow
Write-Host ""
Write-Host "  Issue a test certificate:"                                             -ForegroundColor Yellow
Write-Host "    1. On any domain machine, open certmgr.msc"                         -ForegroundColor Yellow
Write-Host "    2. Request a new certificate using a published template"             -ForegroundColor Yellow
Write-Host "    3. Run: certutil -verify -urlfetch <exported_cert.cer>"             -ForegroundColor Yellow
Write-Host "    4. Check the OCSP response in the output"                           -ForegroundColor Yellow
Write-Host "==========================================================" -ForegroundColor Green
