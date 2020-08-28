<#
.SYNOPSIS
Configures Checkmarx Manager for SSL
  * IIS is configured with a https binding, http binding is removed
  * Resolver is configured to use SSL


.NOTES
If the cert information is not provided then the script will attempt to use Posh-ACME certs if available on the machine
(but it will not request new certs). 

#>
param (
 [Parameter(Mandatory = $False)] [String] $pfxfile = "",
 [Parameter(Mandatory = $False)] [String] $pfxpassword = "",
 [Parameter(Mandatory = $False)] [String] $domainname = ""
 )

# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
function log([string] $msg) { Write-Host "$(Get-Date) [$PSCommandPath] $msg" }

. $PSScriptRoot\..\CheckmarxAWS.ps1
$Secure_String_Pwd = ConvertTo-SecureString $pfxpassword -AsPlainText -Force

if ([String]::IsNullOrEmpty($pfxfile) -and [String]::IsNullOrEmpty($domainname) -and [String]::IsNullOrEmpty($pfxpassword)) {
  log "No certificates provided, attempting to use Posh-ACME certs if available." 
  try {
    $cert = Get-PACertificate
  } catch {
    log $_
  }
  if ($cert -ne $null) {
    log "Posh-ACME cert found."
    $pfxfile = $cert.PfxFile
    $Secure_String_Pwd = $cert.PfxPass
    $domainname = $cert.AllSANs[0]
    $thumbprint = $cert.Thumbprint
  } 
}

if ([String]::IsNullOrEmpty($pfxfile) -and -not [string]::IsNullOrEmpty($pfxpassword)) {
  log "Searching for server.pfx file"
  $pfxfile = $(Get-ChildItem C:\programdata\checkmarx -Recurse -Filter "server.pfx" | Sort -Descending | Select -First 1 -ExpandProperty FullName)
}

log "Validating arguments..."
if ([String]::IsNullOrEmpty($pfxfile) -or [String]::IsNullOrEmpty($domainname)) {
  log "ERROR: All or one of pfxfile, domainname, or thumbprint is empty."
  exit 1
}

# Import the cert to the machine on IIS
log "Importing the certificate into LocalMachine\My"
$cert = Import-PfxCertificate -FilePath $pfxfile -CertStoreLocation Cert:\LocalMachine\My -Password $Secure_String_Pwd
$thumbprint = $cert.Thumbprint
[CxSASTEngineTlsConfigurer]::New($thumbprint).Configure()
[CxManagerIisTlsConfigurer]::New("Default Web Site", "443", $thumbprint).Configure()
[CxWsResolverConfigurer]::New($domainname, "443").Configure()
[CxManagerTlsConfigurer]::New("443", $True).Configure()
[CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()

# Update hosts file
if ($cx.IsSystemManager) {
  log "Updating the hosts file to resolve $domainname to 127.0.0.1 to avoid load balancer round trips for web-to-services web-services"
    "# Checkmarx will resolve the servername to localhost to bypass load balancer hops for inner-app communication" | Add-Content -PassThru "$env:windir\system32\drivers\etc\hosts"
    "127.0.0.1 $domainname" | Add-Content -PassThru "$env:windir\system32\drivers\etc\hosts"
    log "... Finished"
}

try {
    restart-service cx*
    iisreset
    ipconfig /flushdns
} catch {
    log "An error occured restarting services"
}

log "finished"