#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads the PKI Lab scripts from GitHub and fixes line endings for
    PowerShell 5.1 compatibility (converts LF to CRLF).

.EXAMPLE
    irm https://raw.githubusercontent.com/Bugster911/PlayPowershell/claude/hyperv-vm-deployment-script-h90d5/HyperV-PKI-Lab/Download-PKILab.ps1 | iex
#>

$destDir = 'C:\HyperV-PKI-Lab'
$branch  = 'claude/hyperv-vm-deployment-script-h90d5'
$baseURL = "https://raw.githubusercontent.com/Bugster911/PlayPowershell/$branch/HyperV-PKI-Lab"

$scripts = @(
    'Deploy-PKI-Lab.ps1',
    'Configure-DC.ps1',
    'Configure-RootCA.ps1',
    'Configure-SubCA.ps1',
    'Configure-OCSP.ps1'
)

New-Item -ItemType Directory -Path $destDir -Force | Out-Null
Write-Host "Downloading PKI Lab scripts to $destDir ..." -ForegroundColor Cyan

foreach ($script in $scripts) {
    $outFile = Join-Path $destDir $script
    Invoke-WebRequest -Uri "$baseURL/$script" -OutFile $outFile -UseBasicParsing

    # Convert LF -> CRLF so PowerShell 5.1 here-strings parse correctly
    $content = [System.IO.File]::ReadAllText($outFile)
    if ($content -notmatch '\r\n') {
        $content = $content -replace '(?<!\r)\n', "`r`n"
        [System.IO.File]::WriteAllText($outFile, $content)
        Write-Host "  Downloaded + CRLF fixed : $script" -ForegroundColor Green
    } else {
        Write-Host "  Downloaded               : $script" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "All scripts ready. Edit the Lab configuration block in Deploy-PKI-Lab.ps1," -ForegroundColor Yellow
Write-Host "then run: .\Deploy-PKI-Lab.ps1 -Phase 1 -ISOPath 'D:\ISO\WinServer2025.iso'" -ForegroundColor Yellow
