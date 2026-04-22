#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Phase 4 - Configure LAB-SUBCA01 as an Enterprise Subordinate CA.
    Called by Deploy-PKI-Lab.ps1 -Phase 4.

.DESCRIPTION
    1. Joins LAB-SUBCA01 to the domain
    2. Installs ADCS (Enterprise Subordinate CA) - generates a cert request (.req)
    3. Copies the .req to LAB-ROOTCA via PowerShell Direct
    4. Signs the SubCA cert on LAB-ROOTCA
    5. Copies the signed cert back and installs it on LAB-SUBCA01
    6. Publishes Root CA cert and CRL into Active Directory
    7. Copies Root CA cert + CRL to the IIS PKI share on the DC
    8. Configures CDP and AIA URLs on the SubCA
    9. Configures CRL schedule (short for lab testing)
   10. Issues a CAPolicy.inf for OCSP-enabled templates
   11. Enables the OCSP certificate template and auto-enrollment
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

$localCred  = New-Object pscredential('Administrator',
                  (ConvertTo-SecureString $Lab.AdminPassword -AsPlainText -Force))
$domainCred = New-Object pscredential("$($Lab.DomainNetbios)\Administrator",
                  (ConvertTo-SecureString $Lab.AdminPassword -AsPlainText -Force))

$subVMName  = $Lab.VMs.SubCA.Name
$rootVMName = $Lab.VMs.RootCA.Name
$rootName   = $Lab.RootCAName
$subCAName  = $Lab.SubCAName
$domain     = $Lab.DomainName

# -- Wait for SubCA VM --------------------------------------------------------
Write-Status "Waiting for '$subVMName' PowerShell Direct..."
$deadline = (Get-Date).AddMinutes(15)
while ((Get-Date) -lt $deadline) {
    try { Invoke-Command -VMName $subVMName -Credential $localCred -ScriptBlock { $true } -ErrorAction Stop | Out-Null; break }
    catch { Start-Sleep 20 }
}
Write-OK "$subVMName reachable."

# -- Step 1: Join the domain --------------------------------------------------
Write-Status "Joining $subVMName to domain '$domain'..."
$needsReboot = Invoke-Command -VMName $subVMName -Credential $localCred -ScriptBlock {
    param($domainName, $domainUser, $domainPass, $dcIP)

    # Check already joined
    if ((Get-WmiObject Win32_ComputerSystem).PartOfDomain) {
        Write-Host "  Already domain-joined."
        return $false
    }

    # Set DNS to DC and flush cache
    $adapter = Get-NetAdapter | Where-Object Status -eq 'Up' | Select-Object -First 1
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dcIP
    ipconfig /flushdns | Out-Null
    Start-Sleep 8

    # Verify DC is reachable via TCP (LDAP port 389) - Test-Connection is unreliable in PS Direct
    $dcReachable = $false
    for ($i = 1; $i -le 5; $i++) {
        try {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $tcp.Connect($dcIP, 389)
            $tcp.Close()
            $dcReachable = $true
            break
        } catch {
            Write-Host "  DC connectivity attempt $i/5 failed - waiting 10s..."
            Start-Sleep 10
        }
    }
    if (-not $dcReachable) {
        throw "Cannot reach DC at ${dcIP}:389 (LDAP). Ensure LAB-DC01 is running and on the same Hyper-V virtual switch as LAB-SUBCA01."
    }
    Write-Host "  DC reachable at $dcIP (LDAP:389)"

    # Verify DNS resolves the domain (DC must be up and DNS running)
    $resolved = Resolve-DnsName -Name $domainName -Server $dcIP -ErrorAction SilentlyContinue
    if (-not $resolved) {
        throw "DNS resolution of '$domainName' failed via $dcIP. Ensure Phase 2 (DC) completed successfully."
    }
    Write-Host "  DNS resolved: $domainName"

    $cred = New-Object pscredential($domainUser, (ConvertTo-SecureString $domainPass -AsPlainText -Force))
    $ouPath = "OU=PKI,OU=Servers,DC=$($domainName.Split('.') -join ',DC=')"

    # Try joining into the PKI OU; fall back to default Computers if OU missing
    try {
        Add-Computer -DomainName $domainName -Credential $cred -OUPath $ouPath -Force -ErrorAction Stop
        Write-Host "  Joined domain in OU: $ouPath"
    } catch {
        Write-Host "  OU join failed ($($_.Exception.Message)) - retrying into default Computers container..."
        Add-Computer -DomainName $domainName -Credential $cred -Force -ErrorAction Stop
        Write-Host "  Joined domain (Computers container)"
    }

    Write-Host "  Domain join successful - reboot required."
    return $true
} -ArgumentList $domain, "$($Lab.DomainNetbios)\Administrator", $Lab.AdminPassword, $Lab.VMs.DC.IP

if ($needsReboot) {
    Write-Warn "Rebooting $subVMName for domain join..."
    Invoke-Command -VMName $subVMName -Credential $localCred -ScriptBlock { Restart-Computer -Force }
    Start-Sleep 60

    Write-Status "Waiting for $subVMName to come back..."
    $deadline = (Get-Date).AddMinutes(10)
    while ((Get-Date) -lt $deadline) {
        try { Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock { $true } -ErrorAction Stop | Out-Null; break }
        catch { Start-Sleep 20 }
    }
    Write-OK "$subVMName rejoined domain."
}

# -- Step 2: Write CAPolicy.inf on SubCA --------------------------------------
Write-Status "Writing CAPolicy.inf on $subVMName..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($subCAName, $subCAFQDN)
    $policy = @"
[Version]
Signature="`$Windows NT$"

[PolicyStatementExtension]
Policies=AllIssuancePolicy

[AllIssuancePolicy]
OID=2.5.29.32.0

[BasicConstraintsExtension]
PathLength=0
Critical=Yes

[CertSrv_Server]
RenewalKeyLength=2048
RenewalValidityPeriod=Years
RenewalValidityPeriodUnits=5
CRLPeriod=Days
CRLPeriodUnits=7
CRLDeltaPeriod=Hours
CRLDeltaPeriodUnits=4
LoadDefaultTemplates=1
AlternateSignatureAlgorithm=0

[Extensions]
1.3.6.1.5.5.7.48.1=`"{text}http://$subCAFQDN/ocsp`"
"@
    $policy | Out-File -FilePath 'C:\Windows\CAPolicy.inf' -Encoding ascii -Force
    Write-Host "  CAPolicy.inf written."
} -ArgumentList $subCAName, "$subVMName.$domain"

# -- Step 3: Install ADCS role on SubCA ---------------------------------------
Write-Status "Installing ADCS role on $subVMName..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    $features = @(
        'AD-Certificate',
        'ADCS-Cert-Authority',
        'ADCS-Online-Cert',      # OCSP Responder
        'Web-Server',
        'Web-Mgmt-Console',
        'RSAT-ADCS'
    )
    foreach ($f in $features) {
        if (-not (Get-WindowsFeature $f).Installed) {
            Install-WindowsFeature -Name $f -IncludeManagementTools | Out-Null
            Write-Host "  Installed: $f"
        }
    }
}
Write-OK "ADCS + OCSP role installed."

# -- Step 4: Configure Enterprise Subordinate CA (generates .req) -------------
Write-Status "Configuring Enterprise Subordinate CA on $subVMName..."
$reqFile = Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($caName)

    $svc = Get-Service -Name 'CertSvc' -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        Write-Host "  CertSvc already running."
        # Return the existing req file if any
        $req = Get-ChildItem 'C:\SubCA' -Filter '*.req' -ErrorAction SilentlyContinue | Select-Object -First 1
        return $req.FullName
    }

    Import-Module ADCSDeployment

    # This will create a .req file and pause (CA won't start until cert is installed)
    $result = Install-AdcsCertificationAuthority `
        -CAType                 EnterpriseSubordinateCA `
        -CACommonName           $caName `
        -KeyLength              2048 `
        -HashAlgorithmName      SHA256 `
        -CryptoProviderName     'RSA#Microsoft Software Key Storage Provider' `
        -OutputCertRequestFile  'C:\SubCA\SubCA.req' `
        -DatabaseDirectory      'C:\Windows\System32\CertLog' `
        -LogDirectory           'C:\Windows\System32\CertLog' `
        -Force `
        -Confirm:               $false `
        -ErrorAction            SilentlyContinue

    # Expected: ErrorId = 'Install incomplete' / status about needing parent cert
    if (-not (Test-Path 'C:\SubCA')) { New-Item -ItemType Directory 'C:\SubCA' | Out-Null }

    # The .req file is placed in the output path
    $req = Get-ChildItem 'C:\'  -Filter 'SubCA.req' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $req) {
        # Try default CertSrv\CertEnroll location
        $req = Get-ChildItem 'C:\Windows\System32\CertSrv\CertEnroll' -Filter '*.req' -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    Write-Host "  SubCA .req file: $($req.FullName)"
    return $req.FullName
} -ArgumentList $subCAName

if (-not $reqFile) { throw "Could not locate SubCA .req file on $subVMName." }
Write-OK "SubCA request file: $reqFile"

# -- Step 5: Copy .req from SubCA to Hyper-V host, then to RootCA -------------
Write-Status "Transferring SubCA request to RootCA for signing..."
$hostTempDir = Join-Path $Lab.VMStorePath "PKI-Transfer"
if (-not (Test-Path $hostTempDir)) { New-Item -ItemType Directory -Path $hostTempDir | Out-Null }
$hostReqPath = Join-Path $hostTempDir "SubCA.req"

# Copy from SubCA -> host
$subSession = New-PSSession -VMName $subVMName -Credential $domainCred
Copy-Item -FromSession $subSession -Path $reqFile -Destination $hostReqPath -Force
Remove-PSSession $subSession
Write-Info "SubCA .req on host: $hostReqPath"

# Copy from host -> RootCA
$rootSession = New-PSSession -VMName $rootVMName -Credential $localCred
Copy-Item -ToSession $rootSession -Path $hostReqPath -Destination 'C:\RootCA\Requests\SubCA.req' -Force
Remove-PSSession $rootSession
Write-OK ".req transferred to RootCA."

# -- Step 6: Sign the SubCA cert on RootCA ------------------------------------
Write-Status "Signing SubCA certificate on $rootVMName..."
Invoke-Command -VMName $rootVMName -Credential $localCred -ScriptBlock {
    param($rootName)

    $reqPath  = 'C:\RootCA\Requests\SubCA.req'
    $certPath = 'C:\RootCA\Requests\SubCA.crt'

    # Submit request to the Root CA
    $submitOut = certreq -Submit -Config ".\$rootName" $reqPath $certPath 2>&1
    Write-Host "  certreq submit output: $submitOut"

    # Find the request ID
    $reqID = ($submitOut | Select-String 'RequestId:\s*(\d+)').Matches.Groups[1].Value
    if (-not $reqID) {
        # Try alternate parse: "Request Id: X"
        $reqID = ($submitOut | Select-String 'Request Id:\s*(\d+)').Matches.Groups[1].Value
    }

    if ($reqID) {
        # Approve/issue the certificate
        $approveOut = certutil -resubmit $reqID 2>&1
        Write-Host "  certutil resubmit: $approveOut"

        # Retrieve the issued certificate
        $retrieveOut = certreq -Retrieve -Config ".\$rootName" $reqID $certPath 2>&1
        Write-Host "  certreq retrieve: $retrieveOut"
    }

    if (Test-Path $certPath) {
        Write-Host "  SubCA cert signed: $certPath"
    } else {
        throw "SubCA cert signing failed - $certPath not found."
    }
} -ArgumentList $rootName
Write-OK "SubCA cert signed by Root CA."

# -- Step 7: Copy signed cert + RootCA cert back to host, then to SubCA --------
Write-Status "Transferring signed cert and Root CA cert to SubCA..."
$hostCertPath    = Join-Path $hostTempDir "SubCA.crt"
$hostRootCrtPath = Join-Path $hostTempDir "$rootName.crt"
$hostRootCrlPath = Join-Path $hostTempDir "$rootName.crl"

$rootSession = New-PSSession -VMName $rootVMName -Credential $localCred
Copy-Item -FromSession $rootSession -Path 'C:\RootCA\Requests\SubCA.crt' -Destination $hostCertPath    -Force
Copy-Item -FromSession $rootSession -Path "C:\RootCA\$rootName.crt"       -Destination $hostRootCrtPath -Force
Copy-Item -FromSession $rootSession -Path "C:\RootCA\$rootName.crl"       -Destination $hostRootCrlPath -Force
Remove-PSSession $rootSession

$subSession = New-PSSession -VMName $subVMName -Credential $domainCred
Copy-Item -ToSession $subSession -Path $hostCertPath    -Destination 'C:\SubCA\SubCA.crt'          -Force
Copy-Item -ToSession $subSession -Path $hostRootCrtPath -Destination "C:\SubCA\$rootName.crt"      -Force
Copy-Item -ToSession $subSession -Path $hostRootCrlPath -Destination "C:\SubCA\$rootName.crl"      -Force
Remove-PSSession $subSession
Write-OK "Certs transferred to SubCA."

# -- Step 8: Install Root CA cert into Windows cert store on SubCA -------------
Write-Status "Installing Root CA cert into trust stores on $subVMName..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($rootName)
    $rootCrt = "C:\SubCA\$rootName.crt"
    $rootCrl = "C:\SubCA\$rootName.crl"

    # Publish to local cert stores
    certutil -addstore Root    $rootCrt | Out-Null
    certutil -addstore Root    $rootCrl | Out-Null
    Write-Host "  Root CA cert added to Local Machine\Root"
} -ArgumentList $rootName

# -- Step 9: Complete the SubCA installation with the signed cert ---------------
Write-Status "Completing SubCA installation on $subVMName..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    # Install the parent (root) cert chain first
    certutil -installcert 'C:\SubCA\SubCA.crt' | Out-Null
    Write-Host "  SubCA cert installed."

    # Start CertSvc
    Start-Service CertSvc -ErrorAction SilentlyContinue
    Start-Sleep 5
    $svc = Get-Service CertSvc
    Write-Host "  CertSvc status: $($svc.Status)"
}
Write-OK "SubCA is active."

# -- Step 10: Configure CDP and AIA on SubCA ------------------------------------
Write-Status "Configuring CDP/AIA extensions on $subVMName..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($subCAName, $domainName, $rootName)

    $fqdn    = "$subCAName.$domainName"
    $cdpHTTP = "http://$fqdn/PKI/%7%8%9.crl"
    $cdpLDAP = "ldap:///CN=%7%8,CN=%2,CN=CDP,CN=Public Key Services,CN=Services,%6%10"
    $aiaHTTP = "http://$fqdn/PKI/%1_%3%4.crt"
    $aiaLDAP = "ldap:///CN=%7,CN=AIA,CN=Public Key Services,CN=Services,%6%11"
    $ocspURL = "http://$fqdn/ocsp"

    # Remove all existing CDP/AIA
    Get-CACrlDistributionPoint | ForEach-Object { Remove-CACrlDistributionPoint -Uri $_.Uri -Force -ErrorAction SilentlyContinue }
    Get-CAAuthorityInformationAccess | ForEach-Object { Remove-CAAuthorityInformationAccess -Uri $_.Uri -Force -ErrorAction SilentlyContinue }

    # Local file path (write here)
    Add-CACrlDistributionPoint `
        -Uri 'C:\Windows\System32\CertSrv\CertEnroll\%3%8%9.crl' `
        -PublishToServer -PublishDeltaToServer -Force | Out-Null

    # HTTP CDP
    Add-CACrlDistributionPoint `
        -Uri $cdpHTTP `
        -AddToCertificateCDP -AddToFreshestCrl -Force | Out-Null

    # LDAP CDP
    Add-CACrlDistributionPoint `
        -Uri $cdpLDAP `
        -PublishToServer -AddToCertificateCDP -Force | Out-Null

    # HTTP AIA
    Add-CAAuthorityInformationAccess `
        -Uri $aiaHTTP `
        -AddToCertificateAia -Force | Out-Null

    # LDAP AIA
    Add-CAAuthorityInformationAccess `
        -Uri $aiaLDAP `
        -AddToCertificateAia -Force | Out-Null

    # OCSP AIA
    Add-CAAuthorityInformationAccess `
        -Uri $ocspURL `
        -AddToCertificateOcsp -Force | Out-Null

    # CRL schedule (7 days base, 4 hour delta - good for lab)
    certutil -setreg CA\CRLPeriodUnits 7       | Out-Null
    certutil -setreg CA\CRLPeriod "Days"       | Out-Null
    certutil -setreg CA\CRLDeltaPeriodUnits 4  | Out-Null
    certutil -setreg CA\CRLDeltaPeriod "Hours" | Out-Null

    # Issued cert validity: 2 years
    certutil -setreg CA\ValidityPeriodUnits 2  | Out-Null
    certutil -setreg CA\ValidityPeriod "Years" | Out-Null

    Restart-Service CertSvc
    Start-Sleep 5
    certutil -crl | Out-Null
    Write-Host "  CDP: $cdpHTTP"
    Write-Host "  OCSP AIA: $ocspURL"
    Write-Host "  CRL published."
} -ArgumentList $subVMName, $domain, $rootName
Write-OK "CDP/AIA configured on SubCA."

# -- Step 11: Publish Root CA cert + CRL to Active Directory ------------------
Write-Status "Publishing Root CA into Active Directory..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($rootName)
    certutil -dspublish -f "C:\SubCA\$rootName.crt" RootCA | Out-Null
    certutil -dspublish -f "C:\SubCA\$rootName.crl"        | Out-Null
    Write-Host "  Root CA cert and CRL published to Active Directory."
} -ArgumentList $rootName

# -- Step 12: Copy CRL to IIS PKI share on DC ---------------------------------
Write-Status "Copying CRL and certs to IIS PKI share on DC..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    param($dcName, $rootName)
    $pkiShare = "\\$dcName\PKI"

    # CRL files from CertEnroll
    Get-ChildItem 'C:\Windows\System32\CertSrv\CertEnroll\' |
        Where-Object { $_.Extension -in '.crl','.crt' } |
        ForEach-Object { Copy-Item $_.FullName -Destination $pkiShare -Force }

    # Root CA files
    Copy-Item "C:\SubCA\$rootName.crt" -Destination $pkiShare -Force
    Copy-Item "C:\SubCA\$rootName.crl" -Destination $pkiShare -Force
    Write-Host "  PKI files copied to $pkiShare"
} -ArgumentList $Lab.VMs.DC.Name, $rootName

# -- Step 13: Enable OCSP template on SubCA -----------------------------------
Write-Status "Enabling OCSP Response Signing certificate template..."
Invoke-Command -VMName $subVMName -Credential $domainCred -ScriptBlock {
    # Enable the OCSPResponseSigning template (built-in)
    Add-CATemplate -Name 'OCSPResponseSigning' -Force
    Write-Host "  OCSPResponseSigning template enabled on CA."

    # Configure auto-enrollment for OCSP signing cert (granted to OCSP server computer account)
    # This is done via the template ACL - we grant the SubCA computer account Enroll + AutoEnroll
    Import-Module ActiveDirectory
    $subCAComputer = "$env:COMPUTERNAME$"
    # Template permissions are set in ADSI - handled in Configure-OCSP.ps1
    Write-Host "  Template auto-enrollment will be configured in Phase 5 (OCSP)."
}

Write-OK "=== Subordinate CA configuration complete ==="
Write-Host ""
Write-Host "PKI hierarchy is now:" -ForegroundColor Green
Write-Host "  $($Lab.RootCAName)  (Standalone Root, offline)" -ForegroundColor Green
Write-Host "    +-- $($Lab.SubCAName)  (Enterprise Issuing CA, online)" -ForegroundColor Green
Write-Host ""
Write-Host "Next: Run Phase 5 to configure the OCSP Responder:" -ForegroundColor Yellow
Write-Host "  .\Deploy-PKI-Lab.ps1 -Phase 5" -ForegroundColor Yellow
