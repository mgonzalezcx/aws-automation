# Force TLS 1.2+ and hide progress bars to prevent slow downloads
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; 
$ProgressPreference = "SilentlyContinue"
$InformationPreference = "continue"
Start-Transcript -Path "C:\provision-checkmarx.log" -Append
. $PSScriptRoot\CheckmarxAWS.ps1
$config = Import-PowerShellDataFile -Path C:\checkmarx-config.psd1

[Logger] $log = [Logger]::new("provision-checkmarx.ps1")

$log.Info("-------------------------------------------------------------------------")
$log.Info("-------------------------------------------------------------------------")
$log.Info("-------------------------------------------------------------------------")
$log.Info("provision-checkmarx.ps1 script execution beginning")

###############################################################################
#  Create Folders
###############################################################################
$log.Info("Creating Checkmarx folders")
$env:CheckmarxHome = if ($env:CheckmarxHome -eq $null) { "C:\programdata\checkmarx" } Else { $env:CheckmarxHome }
md -Force "$($env:CheckmarxHome)" | Out-Null

###############################################################################
# Get secrets
###############################################################################
$secrets = ""
if ($config.Secrets.Source.ToUpper() -eq "SSM") { 
    $secrets = [AwsSsmSecrets]::new($config)
} elseif ($config.Secrets.Source.ToUpper() -eq "SECRETSMANAGER") {
   $secrets = [AwsSecretManagerSecrets]::new($config) 
} else {
    log.Warn("Secrets source $($config.Secrets.Source) is unknown. Expect exceptions later if secrets are needed")
}

###############################################################################
#  Debug Info
###############################################################################
if (!([Utility]::Exists("$($env:CheckmarxHome)\systeminfo.lock"))) {
    Write-Host "################################"
    Write-Host "  System Info"
    Write-Host "################################"
    systeminfo.exe > c:\systeminfo.log
    cat c:\systeminfo.log

    Write-Host "################################"
    Write-Host " Checking for all installed updates"
    Write-Host "################################"
    Wmic qfe list  | Format-Table

    Write-Host "################################"
    Write-Host " Host Info "
    Write-Host "################################"
    Get-Host | Format-Table
    
    Write-Host "################################"
    Write-Host " Powershell Info "
    Write-Host "################################"
    (Get-Host).Version  | Format-Table

    Write-Host "################################"
    Write-Host " OS Info "
    Write-Host "################################"
    Get-WmiObject Win32_OperatingSystem | Select PSComputerName, Caption, OSArchitecture, Version, BuildNumber | Format-Table

    Write-Host "################################"
    Write-Host " whoami "
    Write-Host "################################"
    whoami
    
    Write-Host "################################"
    Write-Host " env:TEMP "
    Write-Host "################################"
    Write-Host "$env:TEMP"

    $log.Info("env:CheckmarxBucket = $env:CheckmarxBucket")
    $log.Info("checkmarx-config.psd1 configuration:")
    cat C:\checkmarx-config.psd1    

    "completed" | Set-Content "$($env:CheckmarxHome)\systeminfo.lock"
}


###############################################################################
#  Domain Join
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager")  {
    if ((Get-WmiObject -Class Win32_ComputerSystem | Select -ExpandProperty PartOfDomain) -eq $True) {
        $log.Info("The computer is joined to a domain")
    } else {
        $log.Info("The computer is not joined to a domain")
        try {
            if (!([String]::IsNullOrEmpty($config.ActiveDirectory.Username))) {  # If the domain info is set in SSM parameters then join the domain
                $log.Info("Joining the computer to the domain. A reboot will occur.")
                & C:\programdata\checkmarx\aws-automation\scripts\configure\domain-join.ps1 -domainJoinUserName "$config.ActiveDirectory.Username" -domainJoinUserPassword "$($config.aws.SsmPath)/domain/admin/password" -primaryDns $config.ActiveDirectory.PrimaryDns -secondaryDns $config.ActiveDirectory.SecondaryDns -domainName $config.ActiveDirectory.DomainName
                # In case the implicit restart does not occur or is overridden
                Restart-Computer -Force
                Sleep 30
            }    
        } catch {
            $log.Info("An error occured while joining to domain. Is the ${ssmprefix}/domain/name ssm parameter set? Assuming that no domain join was intended.")
            $_
        }    
    }
}


###############################################################################
#  Fetch Checkmarx Installation Media and Unzip
###############################################################################

# First install 7zip so it can unzip password protected zip files.
[SevenZipInstaller]::new([DependencyFetcher]::new($config.Dependencies.Sevenzip).Fetch()).Install()

# Download/Unzip the Checkmarx installer. 
# Many dependencies (cpp redists, dotnet core, sql server express) comes from this zip so it must be unzipped early in the process. 
$installer_zip = [DependencyFetcher]::new($config.Checkmarx.Installer.Url).Fetch()  
$installer_name = $($installer_zip.Replace(".zip", "")).Split("\")[-1]
$log.Info("Unzipping c:\programdata\checkmarx\artifacts\${installer_zip}")
Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"${installer_zip}`" -aos -o`"C:\programdata\checkmarx\artifacts\${installer_name}`" -p`"$($config.Checkmarx.Installer.ZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\installer7z.err -RedirectStandardOutput .\installer7z.out
cat .\installer7z.err
cat .\installer7z.out
 

# Download/Unzip the Checkmarx Hotfix
$hfinstaller = [DependencyFetcher]::new($config.Checkmarx.Hotfix.Url).Fetch()  
$hotfix_name = $($hfinstaller.Replace(".zip", "")).Split("\")[-1]
$log.Info("Unzipping c:\programdata\checkmarx\artifacts\${hotfix_zip}")
Start-Process "C:\Program Files\7-Zip\7z.exe" -ArgumentList "x `"$hfinstaller`" -aos -o`"C:\programdata\checkmarx\artifacts\${hotfix_name}`" -p`"$($config.Checkmarx.Hotfix.ZipKey)`"" -Wait -NoNewWindow -RedirectStandardError .\hotfix7z.err -RedirectStandardOutput .\hotfix7z.out
cat .\hotfix7z.err
cat .\hotfix7z.out


###############################################################################
#  Dependencies
###############################################################################
# Only install if it was unzipped from the installation package
$cpp2010 = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "vcredist_x64.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
if (!([String]::IsNullOrEmpty($cpp2010))) {
    [Cpp2010RedistInstaller]::new([DependencyFetcher]::new($cpp2010).Fetch()).Install()
}  

# Only install if it was unzipped from the installation package
$cpp2015 = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "vc_redist2015.x64.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
if (!([String]::IsNullOrEmpty($cpp2015))) {
    [Cpp2015RedistInstaller]::new([DependencyFetcher]::new($cpp2015).Fetch()).Install()
}
 
[AdoptOpenJdkInstaller]::new([DependencyFetcher]::new($config.Dependencies.AdoptOpenJdk).Fetch()).Install()
[DotnetFrameworkInstaller]::new([DependencyFetcher]::new($config.Dependencies.DotnetFramework).Fetch()).Install()


if ($config.Checkmarx.ComponentType -eq "Manager") {
    [GitInstaller]::new([DependencyFetcher]::new($config.Dependencies.Git).Fetch()).Install()
    [IisInstaller]::new().Install()
    [IisUrlRewriteInstaller]::new([DependencyFetcher]::new($config.Dependencies.IisRewriteModule).Fetch()).Install()
    [IisApplicationRequestRoutingInstaller]::new([DependencyFetcher]::new($config.Dependencies.IisApplicationRequestRoutingModule).Fetch()).Install()

    # Only install if it was unzipped from the installation package
    $dotnetcore = $(Get-ChildItem "$($env:CheckmarxHome)" -Recurse -Filter "dotnet-hosting-2.1.16-win.exe" | Sort -Descending | Select -First 1 -ExpandProperty FullName)  
    if (!([String]::IsNullOrEmpty($dotnetcore))) {
        [DotnetCoreHostingInstaller]::new([DependencyFetcher]::new($dotnetcore).Fetch()).Install()
    } 

    if ($config.MsSql.UseLocalSqlExpress -eq "True") {
        [MsSqlServerExpressInstaller]::new([DependencyFetcher]::new("SQLEXPR*.exe").Fetch()).Install()
    }
}


###############################################################################
# Generate Checkmarx License
###############################################################################
if ($config.Checkmarx.License.Url -eq $null) {
    $log.Warn("No license url specified")
} elseif ($config.Checkmarx.License.Url.EndsWith(".cxl")) {
    $log.Info("License file provided and will be downloaded.")
    [Utility]::Fetch($config.Checkmarx.License.Url)
} elseif ($config.Checkmarx.License.Url -eq "ALG") {
    $log.Info("Running automatic license generator")
    C:\programdata\checkmarx\aws-automation\scripts\configure\license-from-alg.ps1
    $log.Info("... finished running automatic license generator")
} elseif (!([String]::IsNullOrEmpty($config.Checkmarx.License.Url))) {
    $log.Warn("config.Checkmarx.License.Url value provided ($($config.Checkmarx.License.Url)) but not sure how to handle. Valid values are 'ALG' and 's3://bucket/keyprefix/somelicensefile.cxl' (must end in .cxl)")
} else {
    $log.Info("No license url provided for config.Checkmarx.License.Url")
}

# Update the installation command line arguments to specify the license file
$license_file = [Utility]::Find("*.cxl")
if ([Utility]::Exists($license_file)) {
    $log.Info("Using $license_file")
    $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) LIC=""$($license_file)"""
} 


###############################################################################
# Install Checkmarx
###############################################################################
# Augment the installer augments with known configuration

# Add the database connections to the install arguments
$config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) SQLSERVER=""$($config.MsSql.Host)"" CXARM_DB_HOST=""$($config.MsSql.Host)"""

# Add sql server authentication to the install arguments
if ($config.MsSql.UseSqlAuth -eq "True") {
    #Add the sql server authentication
    $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) SQLAUTH=1 SQLUSER=($config.MsSql.Username) SQLPWD=""$($secrets.sql_password)"""
    $config.Checkmarx.Installer.Args = "$($config.Checkmarx.Installer.Args) CXARM_SQLAUTH=1 CXARM_DB_USER=($config.MsSql.Username) CXARM_DB_PASSWORD=""$($secrets.sql_password)"""
}

# Install Checkmarx and the Hotfix
[CxSastInstaller]::new([Utility]::Find("CxSetup.exe"), $config.Checkmarx.Installer.Args).Install()
[CxSastHotfixInstaller]::new([Utility]::Find("*HF*.exe")).Install()


###############################################################################
# Post Install Windows Configuration
#
# After Checkmarx is installed there are a number of things to configure. 
#
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    $log.Info("Hardening IIS")
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-iis-hardening.ps1
    $log.Info("...finished hardening IIS")

    $log.Info("Configuring windows defender")
    # Add exclusions
    Add-MpPreference -ExclusionPath "C:\Program Files\Checkmarx\*"
    Add-MpPreference -ExclusionPath "C:\CxSrc\*"  
    Add-MpPreference -ExclusionPath "C:\ExtSrc\*"  
    $log.Info("...finished configuring windows defender")
}

###############################################################################
# Reverse proxy CxARM
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager" -and ($config.Checkmarx.Installer.Args.contains("BI=1"))) {
    $log.Info("Configuring IIS to reverse proxy CxARM")
    $arm_server = "http://localhost:8080"
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST'  -filter "system.webServer/proxy" -name "enabled" -value "True"
    $log.Info("Adding rewrite-rule for /cxarm -> ${arm_server}")
    $site = "iis:\sites\Default Web Site"
    $filterRoot = "system.webServer/rewrite/rules/rule[@name='cxarm']"
    Add-WebConfigurationProperty -pspath $site -filter "system.webServer/rewrite/rules" -name "." -value @{name='cxarm';patternSyntax='Regular Expressions';stopProcessing='False'}
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/match" -name "url" -value "^(cxarm/.*)"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "type" -value "Rewrite"
    Set-WebConfigurationProperty -pspath $site -filter "$filterRoot/action" -name "url" -value "${arm_server}/{R:0}"
    $log.Info("finished configuring IIS to reverse proxy CxARM")
}

###############################################################################
# Set ASP.Net Session Timeout for the Portal
###############################################################################
if ($config.Checkmarx.Installer.Args.Contains("WEB=1")) {
    $log.Info("Configuring Timeout for CxSAST Web Portal to: $($config.Checkmarx.PortalSessionTimeout)")
    # Session timeout if you wish to change it. Default is 1440 minutes (1 day) 
    # Set-WebConfigurationProperty cmdlet is smart enough to convert it into minutes, which is what .net uses
    # See https://checkmarx.atlassian.net/wiki/spaces/PTS/pages/85229666/Configuring+session+timeout+in+Checkmarx
    # See https://blogs.iis.net/jeonghwan/iis-powershell-user-guide-comparing-representative-iis-ui-tasks for examples
    # $sessionTimeoutInMinutes = "01:20:00" # 1 hour 20 minutes - must use timespan format here (HH:MM:SS) and do NOT set any seconds as seconds are invalid options.
    # Prefer this over direct XML file access to support variety of session state providers
    Set-WebConfigurationProperty -pspath 'MACHINE/WEBROOT/APPHOST/Default Web Site/CxWebClient' -filter "system.web/sessionState" -name "timeout" -value "$($config.Checkmarx.PortalSessionTimeout)"
    $log.Info("... finished configuring timeout")
}


###############################################################################
# Open Firewall for Engine
###############################################################################
if ($env:CheckmarxComponentType -eq "Engine") {
  # When the engine is installed by itself it can't piggy back on the opening of 80,443 by IIS install, so we need to explicitly open the port
  $log.Info("Adding host firewall rule for for the Engine Server")
  New-NetFirewallRule -DisplayName "CxScanEngine HTTP Port 80" -Direction Inbound -LocalPort 80 -Protocol TCP -Action Allow
  New-NetFirewallRule -DisplayName "CxScanEngine HTTP Port 443" -Direction Inbound -LocalPort 443 -Protocol TCP -Action Allow
}

if (Test-Path -Path "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") {
    # The db.properties file can have a bug where extra spaces are not trimmed off of the DB_HOST line
    # which can cause connection string concatenation to fail due to a space between the host and :port
    # For example:
    #     TARGET_CONNECTION_STRING=jdbc:sqlserver://sqlserverdev.ckbq3owrgyjd.us-east-1.rds.amazonaws.com :1433;DatabaseName=CxARM[class java.lang.String]
    #
    # As a work around we trim the end off of each line in db.properties
    $log.Info("Fixing db.properties")
    (Get-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties") | ForEach-Object {$_.TrimEnd()} | Set-Content "C:\Program Files\Checkmarx\Checkmarx Risk Management\Config\db.properties"
  
    $log.Info("Running the initial ETL sync for CxArm")
    # Todo: figure this out for Windows Auth
    #Start-Process "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL\etl_executor.exe" -ArgumentList "-q -console -VSILENT_FLOW=true -Dinstall4j.logToStderr=true -Dinstall4j.debug=true -Dinstall4j.detailStdout=true" -WorkingDirectory "C:\Program Files\Checkmarx\Checkmarx Risk Management\ETL" -NoNewWindow -Wait #sql server auth vars -VSOURCE_PASS_SILENT=${db_password} -VTARGET_PASS_SILENT=${db_password}
    $log.Info("Finished initial ETL sync")
  }

if ($config.aws.UseCloudwatchLogs) {
    $log.Info("Configuring cloudwatch logs")
    C:\programdata\checkmarx\aws-automation\scripts\configure\configure-cloudwatch-logs.ps1
    $log.Info("... finished configuring cloudwatch logs")
}


###############################################################################
# Configure max scans on engine
###############################################################################
if ($config.Checkmarx.Installer.Args.Contains("ENGINE=1")) {
    $log.Info("Configuring engine MAX_SCANS_PER_MACHINE to $($config.Checkmarx.MaxScansPerMachine)")
    $config_file = "$(Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name 'Path')\CxSourceAnalyzerEngine.WinService.exe.config"
    [Xml]$xml = Get-Content "$config_file"
    $obj = $xml.configuration.appSettings.add | where {$_.Key -eq "MAX_SCANS_PER_MACHINE" }
    $obj.value = "$($config.Checkmarx.MaxScansPerMachine)" 
    $xml.Save("$config_file")     
    $log.Info("... finished configuring engine MAX_SCANS_PER_MACHINE" )
}


###############################################################################
# Activate Git trace logging
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    $log.Info("Enabling Git Trace Logging")
    md -force "c:\program files\checkmarx\logs\git"
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE', 'c:\program files\checkmarx\logs\git\GIT_TRACE.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_PACK_ACCESS', 'c:\program files\checkmarx\logs\git\GIT_TRACE_PACK_ACCESS.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_PACKET', 'c:\program files\checkmarx\logs\git\GIT_TRACE_PACKET.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_PERFORMANCE', 'c:\program files\checkmarx\logs\git\GIT_TRACE_PERFORMANCE.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_SETUP', 'c:\program files\checkmarx\logs\git\GIT_TRACE_SETUP.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_MERGE_VERBOSITY', 'c:\program files\checkmarx\logs\git\GIT_MERGE_VERBOSITY.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_CURL_VERBOSE', 'c:\program files\checkmarx\logs\git\GIT_CURL_VERBOSE.txt', [System.EnvironmentVariableTarget]::Machine)
    [System.Environment]::SetEnvironmentVariable('GIT_TRACE_SHALLOW', 'c:\program files\checkmarx\logs\git\GIT_TRACE_SHALLOW.txt', [System.EnvironmentVariableTarget]::Machine)
}


###############################################################################
# Install Package Managers if Configured (Required for OSA)
###############################################################################
if ($config.Checkmarx.ComponentType -eq "Manager") {
    if ($config.PackageManagers.Python3 -ne $null) {
       [BasicInstaller]::new([DependencyFetcher]::new($config.PackageManagers.Python3).Fetch(),
                      "/quiet InstallAllUsers=1 PrependPath=1 Include_dev=0 Include_test=0").BaseInstall()
    }

    if ($config.PackageManagers.Nodejs -ne $null) {
        [BasicInstaller]::new([DependencyFetcher]::new($config.PackageManagers.Nodejs).Fetch(),
                    "/QN").BaseInstall()
    }

    if ($config.PackageManagers.Nuget -ne $null) {
        $nuget = [Utility]::Fetch($config.PackageManagers.Nuget)
        $log.Info("Installing Nuget from $Nuget")
        md -force "c:\programdata\nuget"
        move $nuget c:\programdata\nuget\nuget.exe
        [Utility]::Addpath("C:\programdata\nuget")
        $log.Info("...finished installing nodejs")
    }

    if ($config.PackageManagers.Maven -ne $null) {
        $maven = [Utility]::Fetch($config.PackageManagers.Maven)
        $log.Info("Installing Maven from $maven")
        Expand-Archive $maven -DestinationPath 'C:\programdata\checkmarx\artifacts' -Force
        $mvnfolder = [Utility]::Basename($maven).Replace("-bin.zip", "")
        [Utility]::Addpath("${mvnfolder}\bin")
        [Environment]::SetEnvironmentVariable('MAVEN_HOME', $mvnfolder, 'Machine')
        $log.Info("...finished installing nodejs")
    }

    if ($config.PackageManagers.Gradle -ne $null) {
        $gradle = [Utility]::Fetch($config.PackageManagers.Gradle)
        $log.Info("Installing Gradle from $gradle")
        Expand-Archive $gradle -DestinationPath 'C:\programdata\checkmarx\artifacts' -Force
        $gradlefolder = [Utility]::Basename($gradle).Replace("-bin.zip", "")
        [Utility]::Addpath("${gradlefolder}\bin")
        $log.Info("...finished installing nodejs")
    }
}

###############################################################################
# SSL Configuration
###############################################################################
$log.Info("Configuring SSL")
$hostname = ([System.Net.Dns]::GetHostByName(($env:computerName))).HostName
$ssl_file = ""
if (!([String]::IsNullOrEmpty($config.Ssl.Url))) {
    $ssl_file = [Utility]::Fetch($config.Ssl.Url)
    if ([Utility]::Basename($ssl_file).EndsWith(".ps1")) {
        $log.Info("SSL URL identified as a powershell script. Executing $ssl_file")
        powershell.exe -Command "$ssl_file -domainName ""$hostname"" -pfxpassword ""$($secrets.sql_password)"""
        $log.Info("... finished executing $ssl_file")
    } elseif ([Utility]::Basename($ssl_File).EndsWith(".pfx")) {
        $log.Info("SSL URL is a .pfx file that has been downloaded"    )    
    }
} 

$log.Info("configuring ssl")
C:\programdata\checkmarx\aws-automation\scripts\ssl\configure-ssl.ps1 -domainName $hostname -pfxpassword $pfx_password
$log.Info("... finished configuring ssl")

###############################################################################
# Disable the provisioning task
###############################################################################
$log.Info("disabling provision-checkmarx scheduled task")
Disable-ScheduledTask -TaskName "provision-checkmarx"
$log.Info("provisioning has completed")


###############################################################################
#  Debug Info
###############################################################################

@"
###############################################################################
# Checking for all installed updates
################################################################################
"@ | Write-Output
Wmic qfe list  | Format-Table
