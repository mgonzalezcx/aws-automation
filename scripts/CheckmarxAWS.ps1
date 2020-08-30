Class DateTimeUtil {
  # Gets timestamp in UTC
  [DateTime] NowUTC() {
      return (Get-Date).ToUniversalTime()
  }
  static [String] GetFileNameTime() {
    $timestamp = Get-Date -Format o | foreach { $_ -replace ":", "" }
    $timestamp = $timestamp.Replace("-", "")
    return $timestamp
  }
}

Class Logger {
  hidden [String] $componentName
  hidden [DateTimeUtil] $dateUtil = [DateTimeUtil]::new()
  hidden [string] $outfile = "C:\CheckmarxSetup.log"

  Logger([String] $componentName) {
    $this.componentName = $componentName
    if (!(test-path $this.outfile)) {New-Item -ItemType "file" -Path $this.outfile}
  }

  AppendName([String] $name) {
    $this.componentName = "$($this.componentName)-$name"
  }

  Info([String] $message) {
    $this.Log("INFO", $message)
  }

  Warn([String] $message) {
    $this.Log("WARN", $message)
  }

  Error ([String] $message) {
    $this.Log("ERROR", $message)
  }

  hidden Log([String] $level, [String] $message) {
    [String] $enhancedMessage = $this.FormatLogMessage($level, $message)

    [String] $color = "White"
    if ($level -eq "WARN"){
      $color = "Yellow"
    } elseif ($level -eq "ERROR") {
      $color = "Red"
    }

    $this.Console($enhancedMessage, $color)
  }

  hidden [String] FormatLogMessage ([String] $level, [String] $message) {
    return $this.dateUtil.NowUTC().ToString("yyyy-MM-ddTHH:mm:ss.fff") + " " + $level.PadLeft(5, " ") + " [" + $this.componentName + "] : " + $message
  }

  hidden Console ([String] $message, $color) {
    Write-Host $message -ForegroundColor $color
    # Add-Content -Path $this.outfile -Value $message
    $message | Out-File $this.outfile -Append -Width 1000
  }
}

Class Base {
  [Logger] $log = [Logger]::new($this.GetType().Fullname)
  [String] $home = "C:\programdata\checkmarx"
  [String] $artifactspath = "C:\programdata\checkmarx\artifacts"
}


Class DbClient {
    hidden [String] $connectionString
    [Int] $sqlTimeout = 60
  
    DbClient([String] $sqlHost, [String] $database, [bool] $useWindowsAuthentication, [String] $username, [String] $password) {
      if ($useWindowsAuthentication) {
          $this.connectionString = "Server={0}; Database={1}; Trusted_Connection=Yes; Integrated Security=SSPI;" -f $sqlHost, $database
      } else {
          $this.connectionString = "Server={0}; Database={1}; User ID={2}; Password={3}" -f $sqlHost, $database, $username, $password
      }
    }
  
    [Object] ExecuteSql([String] $sql) {
      [System.Data.SqlClient.SqlConnection] $sqlConnection = [System.Data.SqlClient.SqlConnection]::new($this.connectionString)
      $table = $null
  
      try {
        $sqlConnection.Open()
  
        #build query object
        $command = $sqlConnection.CreateCommand()
        $command.CommandText = $sql
        $command.CommandTimeout = $this.sqlTimeout
  
        #run query
        $adapter = [System.Data.SqlClient.SqlDataAdapter]::new($command)
        $dataset = [System.Data.DataSet]::new()
        $adapter.Fill($dataset) | out-null
  
        #return the first collection of results or an empty array
        if ($null -ne $dataset.Tables[0]) {$table = $dataset.Tables[0]}
        elseif ($table.Rows.Count -eq 0) { $table = [System.Collections.ArrayList]::new() }
  
        $sqlConnection.Close()
        return $table
  
      } catch {
        log "An error occured executing sql: $sql"
        log "Error message: $($_.Exception.Message))"
        log "Error exception: $($_.Exception))"
        throw $_
      } finally {
        $sqlConnection.Close()
      }
    } 
  }

function  TryGetSSMParameter([String] $parameter) {
    if(!$parameter) { return $null }

    try {
        $ssmParam = Get-SSMParameter -Name $parameter -WithDecryption $True
    
        if($ssmParam) {
        log "Using the value found for $parameter"
        return $ssmParam.value
        } else {
        log "Using argument as provided"
        return $parameter
    }
    } catch {
        $_
        log "An error occured while fetching SSM parameter key"
        log "Using argument as provided"
        return $parameter
    }
}

Class WindowsInfo : Base {
    static [void] Show() {
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
    }
}


Class CheckmarxSystemInfo {
  [String] $SystemManagerConfigFile
  [String] $JobsManagerConfigFile
  [String] $ScansManagerConfigFile
  [String] $WebConfigFile
  [String] $WebServicesConfigFile
  [String] $RestAPIConfigFile
  [String] $EngineConfigFile

  [bool] $IsEngine
  [bool] $IsWebPortal
  [bool] $IsSystemManager 
  [bool] $IsJobsManager 
  [bool] $IsScansManager

  CheckmarxSystemInfo() {
    $this.SystemManagerConfigFile = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx System Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxSystemManagerService.exe.config')
    $this.JobsManagerConfigFile = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Jobs Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxJobsManagerWinService.exe.config')
    $this.ScansManagerConfigFile = ("{0}\bin\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Scans Manager' -Name "Path" -ErrorAction SilentlyContinue), 'CxScansManagerWinService.exe.config')
    $this.WebConfigFile = ("{0}\web\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\CheckmarxWebPortal' -Name "Path" -ErrorAction SilentlyContinue), 'web.config')
    $this.WebServicesConfigFile = ("{0}\CxWebInterface\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Web Services' -Name "Path" -ErrorAction SilentlyContinue), 'web.config')
    $this.RestAPIConfigFile = ("{0}\CxRestAPI\{1}" -f (Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Web Services' -Name "PathRestAPI" -ErrorAction SilentlyContinue), 'web.config')
    $this.EngineConfigFile = ("{0}\{1}" -f ( Get-ItemPropertyValue -Path 'HKLM:\SOFTWARE\Checkmarx\Installation\Checkmarx Engine Server' -Name 'Path' -ErrorAction SilentlyContinue), 'CxSourceAnalyzerEngine.WinService.exe.config')
  
    $this.IsEngine = ( !([String]::IsNullOrEmpty($this.EngineConfigFile)) -and (Test-Path -Path $this.EngineConfigFile))
    $this.IsWebPortal = ( !([String]::IsNullOrEmpty($this.WebConfigFile)) -and (Test-Path -Path $this.WebConfigFile))
    $this.IsSystemManager = ( !([String]::IsNullOrEmpty($this.isSystemManager)) -and (Test-Path -Path $this.isSystemManager))
    $this.IsJobsManager = ( !([String]::IsNullOrEmpty($this.isJobsManager)) -and (Test-Path -Path $this.isJobsManager))
    $this.IsScansManager = ( !([String]::IsNullOrEmpty($this.isScansManager)) -and (Test-Path -Path $this.isScansManager))
  }
}


Class AwsSsmSecrets : Base {
    [String] $sql_password
    [String] $cxapi_password
    [String] $tomcat_password
    [String] $pfx_password
    AwsSsmSecrets($config) {
        $this.log.Info("Resolving secrets from AWS SSM Parameter Store")
        try {
            $this.sql_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/sql/password" -WithDecryption $True).Value
            $this.cxapi_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/api/password" -WithDecryption $True).Value
            $this.tomcat_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/tomcat/password" -WithDecryption $True).Value
            $this.pfx_password = $(Get-SSMParameter -Name "$($config.Aws.SsmPath)/pfx/password" -WithDecryption $True).Value
       } catch {
            $this.log.Error("An exception occured while resolving secrets from AWS SSM Parameter Store")
            Throw $_
       }
        $this.log.Info("finished fetching secrets")
    }
}

Class AwsSecretManagerSecrets : Base {
    [String] $sql_password
    [String] $cxapi_password
    [String] $tomcat_password
    [String] $pfx_password
    AwsSecretManagerSecrets($config) {
        $this.log.Info("Resolving secrets from AWS Secrets Manager")
        try {
            $this.sql_password  = (Get-SECSecretValue -SecretId "$config.Aws.SsmPath)/sql" | ConvertFrom-Json).password
            $this.cx_api_password  = (Get-SECSecretValue -SecretId "$config.Aws.SsmPath)/api" | ConvertFrom-Json).password
            $this.tomcat_password  = (Get-SECSecretValue -SecretId "$config.Aws.SsmPath)/tomcat" | ConvertFrom-Json).password
            $this.pfx_password  = (Get-SECSecretValue -SecretId "$config.Aws.SsmPath)/pfx" | ConvertFrom-Json).password
        } catch {
            $this.log.Error("An exception occured while resolving secrets from AWS Secrets Manager")
            Throw $_
        }
        $this.log.Info("finished fetching secrets")
    }
}




Class CxSASTEngineTlsConfigurer : Base {
  hidden [String] $tlsPort
  hidden [String] $thumbprint

  CxSASTEngineTlsConfigurer([String] $thumbprint) {
    $this.tlsPort = "443"
  }
  Configure() {
     [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()
     if ($cx.isEngine -eq $False) {
       $this.log.Info("The engine was not found (no engine path), no configuration will take place")
       return
     }

     if ([String]::IsNullOrWhiteSpace($cx.EngineConfigFile) -Or -Not [System.IO.File]::Exists($cx.EngineConfigFile)){
       $this.log.Info("The engine config file was not found (no engine config file), no configuration will take place")
       return
     }

    $this.ConfigureNetsh()
    $this.ConfigureServiceConfigFile()
    Restart-Service -Name CxScanEngine
  }

  hidden [String] GetIp() {
    return (Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -ne $null -and $_.NetAdapter.Status -ne "Disconnected"}).IPv4Address.Ipaddress
  }

  hidden runCmd($cmd, $arguments, $label) {
    $this.log.Info("running command: $cmd $arguments")
    Start-Process "$cmd" -ArgumentList "$arguments" -Wait -NoNewWindow -RedirectStandardError "c:\${label}.err" -RedirectStandardOutput "c:\${label}.out"
    $this.log.Info("finished running command: $cmd $arguments")
    $this.log.Info("Standard output:")
    cat "c:\${label}.out"
    $this.log.Info("Standard error:")
    "c:\${label}.err"
  }

  hidden ConfigureNetsh() {
    # Delete any cert, then register our own
    $appid = "{00112233-4455-6677-8899-AABBCCDDEEFF}"
    $ipport = "0.0.0.0:$($this.tlsPort)"
    $this.runCmd("netsh.exe", ("http delete sslcert ipport={0}" -f $ipport), "netsh-delete")
    $this.runCmd("netsh.exe", ("http add sslcert ipport={0} certhash={1} appid={2}" -f $ipport, $($this.thumbprint) , $appid), "netsh-add-sslcert")
    $this.runCmd("netsh.exe", "http add urlacl url=https://+:$($this.tlsPort)/CxSourceAnalyzerEngineWCF/CxEngineWebServices.svc user=`"NT AUTHORITY\NETWORK SERVICE`"", "netsh-add-urlacl")
  }

  hidden ConfigureServiceConfigFile() {
    [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()
    [Xml]$xml = Get-Content $cx.EngineConfigFile

    $this.log.Info("Adding security mode = Transport")
    $bindingNode = Select-Xml -xml $xml -XPath "/configuration/*/bindings/basicHttpBinding/binding"
    $securityNode = $bindingNode.Node.SelectSingleNode('security')
    if (!$securityNode){
      $securityNode = $xml.CreateElement('security')
      $bindingNode.Node.AppendChild($securityNode)  | Out-Null
    }
    $securityNode.SetAttribute("mode", "Transport")

    $this.log.Info("Setting mexHttpsBinding")
    $mexNode = $xml.SelectSingleNode("/configuration/*/services/service/endpoint[@address='mex']")
    if (!$mexNode){
      $this.log.Error("ERROR: \<endpoint address=""mex"" not found in $($cx.EngineConfigFile) - aborting configuration")
      return
    }
    $mexNode.SetAttribute("binding", "mexHttpsBinding")
    $this.log.Info("Configuring baseAddress")
    $hostNode = $xml.SelectSingleNode("/configuration/*/services/service/host/baseAddresses/add")
    if (!$hostNode){
      $this.log.Error('ERROR: \<baseAddresses\>\<add\>... not found! - aborting configuration')
      return
    }

    [string]$hostAddress = $hostNode.SelectSingleNode("@baseAddress").Value
    $hostAddress = $hostAddress.Replace("http:", "https:").Replace(":80", ":" + $($this.tlsPort)).Replace("localhost", $($this.GetIp()))
    $hostNode.SetAttribute("baseAddress", $hostAddress)

    $serviceNode = $xml.SelectSingleNode("/configuration/*/behaviors/serviceBehaviors/behavior/serviceMetadata")
    if (!$serviceNode){
      $this.log.Error('ERROR: \<serviceMetadata\> not found! - aborting configuration')
      return
    }
    $serviceNode.SetAttribute("httpsGetEnabled", "true")
    $serviceNode.RemoveAttribute("httpGetEnabled")

    $this.log.Info("saving $($cx.EngineConfigFile)")
    $xml.Save($cx.EngineConfigFile)
  }
}

Class CxManagerIisTlsConfigurer : Base {
  hidden [String] $IISWebSite
  hidden [String] $tlsPort
  hidden [String] $thumbprint

  CxManagerIISTlsConfigurer([String] $IISWebSite, [String] $tlsPort, [String] $thumbprint) {
    $this.IISWebSite = $IISWebSite
    $this.tlsPort = $tlsPort
    $this.thumbprint = $thumbprint
  }

  Configure() {
    [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()
    if ($cx.isWebPortal -eq $False -and $cx.isSystemManager -eq $False) {
      $this.log.Warn("The WEB or MANAGER component is not installed. Skipping IIS configuration")
      return
    }
    $this.log.Info("Configuring IIS Bindings")
    $this.log.info("Site: $($this.IISWebSite)")
    $this.log.info("Port: $($this.tlsPort)")
    $bindings = Get-WebBinding -Name $this.IISWebSite -Port $this.tlsPort
    $this.log.info("Current binding: $bindings")
    if ($bindings) {
      $this.UpdateWebBinding()
    } else {
      $this.CreateWebBinding()
    }

    $this.log.Info("Restarting website...")
    try {
      Stop-Website -Name $($this.IISWebSite)
    } catch {
      $this.log.Error("Error stopping $($this.IISWebSite)")
      $this.log.Error("Error message: $($_.Exception.Message)")
      $this.log.Error("Error information: $($_)")
    }

    try {
      Start-Website -Name $($this.IISWebSite)
    } catch {
      $this.log.Error("Error starting $($this.IISWebSite)")
      $this.log.Error("Error message: $($_.Exception.Message)")
      $this.log.Error("Error information: $($_)")
    }
  }

  hidden UpdateWebBinding() {
    $this.log.Info("Updating existing IIS Binding (delete, and add new)")
    # Deleting and Binding new certificate
    try {
        $CxDeleteCertOut = $(cmd.exe /c "netsh.exe http delete sslcert ipport=0.0.0.0:$($this.tlsPort) 2>&1")
        $this.log.info("Cmd output: $CxDeleteCertOut")
        $CertBinding = Get-Item cert:\LocalMachine\My\$($this.thumbprint) | New-Item 0.0.0.0!$($this.tlsPort)
    } catch {
      $this.log.Error("An error occured while updating https binding in IIS")
      $this.log.error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      Throw $_
    }
  }

  hidden CreateWebBinding() {
    $this.log.Info("Creating new IIS Web Binding for website $($this.IISWebSite) on port $($this.tlsPort) with certificate $($this.thumbprint)")
    try {
      $this.log.info("Creating new binding")
      New-WebBinding -Name $($this.IISWebSite) -IP '*' -Port $($this.tlsPort) -Protocol "https"
    } catch {
      $this.log.Error("An error occured while creating https binding in IIS")
      $this.log.error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      Throw $_
    }
    try {
      $this.log.info("Adding SSL Certificate to binding")
      (Get-WebBinding -Name $($this.IISWebSite) -Port $($this.tlsPort) -Protocol "https").AddSslCertificate($($this.thumbprint), "MY")
    } catch {
      $this.log.Error("An error occured while Adding SSL Certificate to binding")
      $this.log.Error("Error message: $($_.Exception.Message))")
      $this.log.Error("Error exception: $($_.Exception))")
      Throw $_
    }
  }
}

Class CxManagerTlsConfigurer : Base {
  [String] $tlsPort
  [bool] $ignoreTlsCertificateValidationErrors
  [String] $domainName

  CxManagerTlsConfigurer([String] $tlsPort, [bool] $ignoreTlsCertificateValidationErrors, [String] $domainName) {
    $this.tlsPort = $tlsPort
    $this.ignoreTlsCertificateValidationErrors = $ignoreTlsCertificateValidationErrors
    $this.domainname = $domainName
  }

  Configure() {
    [CheckmarxSystemInfo] $cx = [CheckmarxSystemInfo]::new()

    $this.ConfigureTransportSecurity($cx.SystemManagerConfigFile)
    $this.ConfigureTransportSecurity($cx.JobsManagerConfigFile)
    $this.ConfigureTransportSecurity($cx.ScansManagerConfigFile)
    $this.ConfigureWebConfig($cx.WebConfigFile)

    if ($this.ignoreTlsCertificateValidationErrors) {
      $this.ConfigureIgnoreCertErr($cx.SystemManagerConfigFile)
      $this.ConfigureIgnoreCertErr($cx.JobsManagerConfigFile)
      $this.ConfigureIgnoreCertErr($cx.ScansManagerConfigFile)
      $this.ConfigureIgnoreCertErr($cx.WebConfigFile)
      $this.ConfigureIgnoreCertErr($cx.WebServicesConfigFile)
      $this.ConfigureIgnoreCertErr($cx.RestAPIConfigFile)
    }
  }

  hidden ConfigureWebConfig([string] $configfile){
    if (-Not [System.IO.File]::Exists($configfile)) {
      $this.log.Info("ConfigureWebConfig: $configfile does not exist - assuming it is not installed")
      return
    }
    $this.log.Info("ConfigureWebConfig: Configuring Web Portal resolver on $configfile")    
    #Update appSettings WebResolver
    [Xml]$xml = Get-Content $configfile
    $obj = $xml.configuration.appSettings.add | where {$_.Key -eq "CxWSResolver.CxWSResolver" }
    $hostAddress = $obj.value
    $hostAddress = $hostAddress.Replace("http:", "https:").Replace(":80", ":" + $($this.tlsPort)).Replace("localhost", $($this.domainName))
    $obj.value = $hostAddress
    $xml.Save($configfile)
}

  hidden ConfigureTransportSecurity([String] $configfile) {
    if (-Not [System.IO.File]::Exists($configfile)) {
      $this.log.Info("ConfigureTransportSecurity: $configfile does not exist - assuming it is not installed")
      return
    }
    $this.log.Info("Configuring transport security on $configfile")

    [Xml]$xml = Get-Content $configfile
    $securityNode = Select-Xml -xml $xml -XPath "/configuration/*/bindings/basicHttpBinding/binding/security"
    if (!$securityNode){
      $this.log.Error("ERROR: <transport> not found, cannot configure transport security")
      return
    }
    $securityNode.Node.SetAttribute("mode", "Transport")
    $xml.Save($configfile)
  }

  hidden ConfigureIgnoreCertErr([String] $configfile) {
    if (-Not [System.IO.File]::Exists($configfile)) {
      $this.log.Info("ConfigureIgnoreCertErr: $configfile does not exist - assuming it is not installed")
      return
    }
    $this.log.Info("Configuring ignore cert validation errors on $configfile")

    # Todo, add a check for if system.net w/ settings/spm already exists and update if it does. Suspect this adds multiple system.net blocks if run more than once which is invalid.
    [xml]$xml = Get-Content $configfile
    $system = $xml.CreateElement("system.net")
    $settings = $xml.CreateElement("settings")
    $spm = $xml.CreateElement("servicePointManager")
    $spm.SetAttribute("checkCertificateName","false")
    $spm.SetAttribute("checkCertificateRevocationList","false")
    $settings.AppendChild($spm)
    $system.AppendChild($settings)
    $xml.configuration.AppendChild($system)
    $xml.Save($configfile)
  }
}

class Utility {
  [bool] static Exists([String] $fpath) {
      return ((![String]::IsNullOrEmpty($fpath)) -and (Test-Path -Path "${fpath}"))
  }
  [String] static Addpath([String] $fpath){
      [Environment]::SetEnvironmentVariable('Path',[Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine) + ";$fpath",[EnvironmentVariableTarget]::Machine)
      return [Environment]::GetEnvironmentVariable("Path", [EnvironmentVariableTarget]::Machine)
  }
  [String] static Basename([String] $fullname) {
      $fullname = "/${fullname}" #ensure there is at least 1 / character before substringing to prevent errors when there is not a path provided
      return $fullname.Substring($fullname.Replace("\","/").LastIndexOf("/") + 1)
  }
  [String] static Find([String] $filename) {
      return $(Get-ChildItem C:\programdata\checkmarx -Recurse -Filter $filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)
  }
  [String] static Find([String] $fpath, [String] $filename) {
      return $(Get-ChildItem "$fpath" -Recurse -Filter $filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)
  }
  [Void] static Debug([String] $stage) {
      sleep 2
      $msiexecs = Get-Process msiexe*
      $cxprocs = Get-Process cx*
      if ($msiexecs.count -gt 0 -or $cxprocs.count -gt 0) {
          Write-Host "#########################################"
          Write-Host "# Debugging ${stage} - found running processes"
          Write-Host "#########################################"
      }
      if ($msiexecs.count -gt 0){ 
          Write-Host "$(Get-Date) Found these running msiexec.exe process:"
          $msiexecs | Format-Table | Out-File -FilePath C:\cx.debug; cat c:\cx.debug
          $msiexecs | % { Get-WmiObject Win32_Process -Filter "ProcessId = $($_.Id)" }#| Select-Object ProcessId, Name, ExecutablePath, CommandLine | FL }
      }
      if ($cxprocs.count -gt 0) {
          Write-Host "$(Get-Date) Found these running cx* processes:"
          $cxprocs | Format-Table | Out-File -FilePath C:\cx.debug; cat c:\cx.debug
          $cxprocs | % { Get-WmiObject Win32_Process -Filter "ProcessId = $($_.Id)" } #| Select-Object ProcessId, Name, ExecutablePath, CommandLine | FL }
          Write-Host "#########################################"
      }
  }
  [String] static Fetch([String] $source) {
      $filename = [Utility]::Basename($source)
      if ($source.StartsWith("https://")) {
          Write-Host "$(Get-Date) Downloading $source"
          (New-Object System.Net.WebClient).DownloadFile("$source", "c:\programdata\checkmarx\artifacts\${filename}")
      } elseif ($source.StartsWith("s3://")) {        
          $bucket = $source.Replace("s3://", "").Split("/")[0]
          $key = $source.Replace("s3://${bucket}", "")
          Write-Host "$(Get-Date) Downloading $source from bucket $bucket with key $key"
          Read-S3Object -BucketName $bucket -Key $key -File "C:\programdata\checkmarx\artifacts\$filename"
      }
      $fullname = [Utility]::Find($filename)
      Write-Host "$(Get-Date) ... found $fullname"
      return $fullname
  }
}

Class DependencyFetcher : Base {
    [String] $url
    [String] $filename 
    [String] $localfilepath
    DependencyFetcher([String] $url) {   
        $this.log.AppendName("/$($url)".Replace("\", "/").Split("/")[-1])     
        $this.log.Info("Instance created with url = $url")        
        
        $this.url = $url
        if ([String]::IsNullOrEmpty($this.url)) {
            $this.log.Warn("The URL is null or empty!")
            throw "The URL is null or empty"
        }

        if ($this.url.ToLower().StartsWith("http://")) {
            $this.log.Warn("http protocol detected - did you mean https?")
        }
        
        # Ensure at least 1 path separator and that they are all / when looking for the base filename
        $this.filename = "/${url}".Replace("\", "/").Split("/")[-1] 
    }

    [String] Fetch() { 
        [bool]$isInitialDownload = $False
        if ($this.IsFilePresent()) {
            $this.log.Info("The file was found locally and will not be downloaded again")                   
        } else {
            $isInitialDownload = $True # do the file hash upon first download only otherwise its wasting time
            if (!(Test-Path -Path $this.artifactspath -PathType Container)) {
                $this.log.Info("$($this.artifactspath) does not exist. It will be created")
                md -Force $this.artifactspath
            }

            # The file was NOT found locally, so try to download it
            $begin = (Get-Date)
            if ($this.url.ToLower().StartsWith("http")) {
                $this.DownloadHttp()
            } elseif ($this.url.ToLower().StartsWith("s3://")) {
                $this.DownloadS3()
            } elseif (Test-Path -Path $this.url -PathType Leaf) {
                $this.CopyToArtifacts()
            }
            $this.log.Info("Fetch time taken: $(New-TimeSpan -Start $begin -end (Get-Date))")

        }

        if ($this.IsFilePresent() -eq $false) {        
            $this.log.Error("$($this.filename) was not found in $($this.home)")
            Throw "$($this.filename) was not found in $($this.home)"
        }

        $this.localfilepath = $this.FindFile()
        $this.log.Info("File is at $($this.localfilepath)")

        if ($isInitialDownload) {
            $this.log.Info("sha256 of $($this.filename) = $((Get-FileHash $this.localfilepath).Hash)")
        }
        return $this.localfilepath
    }

    hidden [String] FindFile() {
        return $(Get-ChildItem $this.home -Recurse -Filter $this.filename | Sort -Descending | Select -First 1 -ExpandProperty FullName)      
    }

    hidden [bool] IsFilePresent() {
        $localfile = $this.FindFile()
        if (!([String]::IsNullOrEmpty($localfile)) -and (Test-Path -Path $localfile -PathType Leaf)) {
            return $True
        }       
        return $False
    }

    hidden DownloadHttp() {
        $this.log.Info("Downloading (http) $($this.url)")
        try {
            (New-Object System.Net.WebClient).DownloadFile($($this.url), "$(Join-Path -Path $this.artifactspath -ChildPath $this.filename)")
        } catch {
            $this.log.Error("An exception occured downloading $($this.url)")
            Throw $_    
        }
        $this.log.Info("Finished downloading file via http")
    }
    hidden DownloadS3() {
        $bucket = $this.url.Replace("s3://", "").Split("/")[0]
        $key = $this.url.Replace("s3://${bucket}", "")
        $this.log.Info("Downloading from bucket $bucket with key $key")
        try {
            Read-S3Object -BucketName $bucket -Key $key -File "$(Join-Path -Path $this.artifactspath -ChildPath $this.filename)"
        } catch {
            $this.log.Error("An exception occured calling Read-S3Object cmdlet. Check IAM Policies and if AWS Powershell is installed")
            Throw $_            
        }
        $this.log.Info("finished downloading from s3")
         
    }
    hidden CopyToArtifacts() {
        # Copy it to our artifacts folder if it somehow exists outside of artifacts
        $this.log.Info("Copyng local file to artifacts location")
        try {
            Copy-Item -Path $this.url -Destination $this.artifactspath -Force
        } catch {
            $this.log.Error("An exception occured copying the file from $($this.url)")
            throw $_
        }
        $this.log.Info("finished copying file to artifacts location")
    }
}

Class BasicInstaller : Base {
    hidden [String] $installer
    hidden [String] $silentInstallArgs
    hidden [String] $logprefix

    BasicInstaller([String] $installer, [String] $silentInstallArgs) {
        $this.installer = $installer
        $this.silentInstallArgs = $silentInstallArgs                
        $this.log.AppendName("/$($installer)".Replace("\", "/").Split("/")[-1])
        $this.log.Info("Instance created with installer = $installer")
        
    }

    BasicInstaller() {

    }
    
    BaseInstall() {
        $this.logprefix = $this.installer.Replace("/", "\").Split("\")[-1]
        $this.log.Info("Attempting silent install")
        $this.IsValidated()
        if ($this.installer.ToLower().EndsWith(".msi")) {
            $this.AdaptForMsi()
        }
        $this.StartProcess()
    }
    hidden [bool] IsValidated() {
        if ([String]::IsNullOrEmpty($this.installer)) {
            $this.log.Error("The installer is null or empty value")
            Throw "The installer is null or empty value"
        }
        if (!(Test-Path -Path $this.installer -PathType Leaf)) {
            $this.log.Error("The installer is not an existing file")
            Throw "The installer is not an existing file"
        }
        $this.log.Info("Validated installer exists")
        return $True
    }
    hidden AdaptForMsi() {
        # MSI files should be passed as an argument to msiexec.exe rather than called directly. 
        $this.log.Info("Adapting for MSI install")
        $msi_args = "/i ""$($this.installer)"" $($this.silentInstallArgs) /L*V ""$($this.installer).log"" /quiet"
        $this.silentInstallArgs = $msi_args
        $this.installer = "$($env:SystemRoot)\system32\msiexec.exe"
    }
    hidden StartProcess() {
        $this.log.Info("Runing installer with args: $($this.silentInstallArgs)")
        $stdout = "$($this.artifactspath)\$($this.logprefix).out.log"
        $stderr = "$($this.artifactspath)\$($this.logprefix).err.log"
        $begin = (Get-Date)
        $process = Start-Process -FilePath $this.installer -ArgumentList "$($this.silentInstallArgs)" -Wait -NoNewWindow -RedirectStandardError "${stderr}" -RedirectStandardOutput "${stdout}" -PassThru
        $this.log.Info("Installation process finished in $(New-TimeSpan -Start $begin -end (Get-Date)) time with exit code: $($process.ExitCode)")
        $this.log.Info("Installer standard output: ")
        cat "$stdout"
        $this.log.Info("Installer standard error: ")
        cat "$stderr"
    }
    [void] AddToPath([String] $pathToAdd) {
        $this.log.Info("Adding $pathToAdd to PATH environment variable")
        [Environment]::SetEnvironmentVariable('Path',[Environment]::GetEnvironmentVariable('Path', [EnvironmentVariableTarget]::Machine) + ";$pathToAdd",[EnvironmentVariableTarget]::Machine)
    }

    [void] CreateEnvironmentVariable([String] $name, [String] $value) {
        $this.log.Info("Setting environment variable $name to $value")
        [Environment]::SetEnvironmentVariable($name, $value, 'Machine')
    }
}

Class SevenZipInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/S"
    SevenZipInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (![String]::IsNullOrEmpty($(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path)))
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
        $this.AddToPath($(Get-ChildItem 'HKLM:\SOFTWARE\7*Zip\' | Get-ItemPropertyValue -Name Path))
    }
}

Class Cpp2010RedistInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/passive /norestart"
    Cpp2010RedistInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (![String]::IsNullOrEmpty($(Get-ChildItem 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\VisualStudio\10*0\VC\VCRedist\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)))
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class Cpp2015RedistInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/passive /norestart"
    Cpp2015RedistInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (![String]::IsNullOrEmpty($(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\VisualStudio\14*0\VC\Runtimes\x64' -ErrorAction SilentlyContinue | Get-ItemPropertyValue -Name Installed -ErrorAction SilentlyContinue)))
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class DotnetFrameworkInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/passive /norestart"
    DotnetFrameworkInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        $dotnet_release = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Release)
        $dotnet_version = $(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full\' | Get-ItemPropertyValue -Name Version)
        $this.log.Info("Found .net version ${dotnet_version}; release string: $dotnet_release")
        # https://docs.microsoft.com/en-us/dotnet/framework/migration-guide/how-to-determine-which-versions-are-installed#to-check-for-a-minimum-required-net-framework-version-by-querying-the-registry-in-powershell-net-framework-45-and-later
        return ($dotnet_release -gt 461308)
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
        $this.log.Info("Finished dotnet framework install. Rebooting.")
        Restart-Computer -Force; 
        sleep 30 # force in case anyone is logged in
    }
}

Class GitInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/VERYSILENT /NORESTART /NOCANCEL /SP- /CLOSEAPPLICATIONS"
    GitInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (Test-Path -Path "C:\Program Files\Git\bin\git.exe")
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class DotnetCoreHostingInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/quiet /install /norestart"
    DotnetCoreHostingInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (Test-Path -Path "C:\Program Files\dotnet")
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class MsSqlServerExpressInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/IACCEPTSQLSERVERLICENSETERMS /Q /ACTION=install /INSTANCEID=SQLEXPRESS /INSTANCENAME=SQLEXPRESS /UPDATEENABLED=FALSE /BROWSERSVCSTARTUPTYPE=Automatic /SQLSVCSTARTUPTYPE=Automatic /TCPENABLED=1"
    MsSqlServerExpressInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return ((get-service sql*).length -eq 0)
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()

        $sqlserverlog = $(Get-ChildItem "C:\Program Files\Microsoft SQL Server\110\Setup Bootstrap\Log" -Recurse -Filter "Summary.txt" | Sort -Descending | Select -First 1 -ExpandProperty FullName) 
        $this.log.Info("finished Installing SQL Server. Summary log is:")
        cat $sqlserverlog    
    }
}


Class AdoptOpenJdkInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJarFileRunWith,FeatureJavaHome INSTALLDIR=`"c:\Program Files\AdoptOpenJDK\`""
    AdoptOpenJdkInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (Test-Path -Path "C:\Program Files\AdoptOpenJDK\bin\java.exe")
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class IisUrlRewriteInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/QN"
    IisUrlRewriteInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (Test-Path -Path "C:\Windows\System32\inetsrv\rewrite.dll")
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class IisApplicationRequestRoutingInstaller : BasicInstaller {
    hidden [String] $silentInstallArgs = "/QN"
    IisApplicationRequestRoutingInstaller([String] $installer) {
        $this.log.Info("instance created with installer = $installer")
        $this.installer = $installer       
    }
    hidden [bool] IsAlreadyInstalled() {
        return (($(C:\Windows\System32\inetsrv\appcmd.exe list modules) | Where  { $_ -match "ApplicationRequestRouting" } | ForEach-Object { echo $_ }).length -gt 1)
    }
    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }
        $this.BaseInstall()
    }
}

Class IisInstaller : Base {
    IisInstaller() {
    }
    hidden [bool] IsAlreadyInstalled() {
        return (Test-Path -Path "$($this.home)\iis.lock")
    }

    Install() {
        if ($this.IsAlreadyInstalled()) {
            $this.log.Info("The package is already installed. Skipping installation.")
            return
        }

        $this.log.Info("Installing IIS")
        Add-WindowsFeature Web-Http-Redirect  
        Install-WindowsFeature -Name  Web-Health -IncludeAllSubFeature
        Install-WindowsFeature -Name  Web-Performance -IncludeAllSubFeature
        Install-WindowsFeature -Name Web-Security -IncludeAllSubFeature
        Install-WindowsFeature -Name  Web-Scripting-Tools -IncludeAllSubFeature
        $this.log.Info("... finished Installing IIS. Rebooting.")
        # the iis.lock file is used to track state and prevent reinstallation and reboots on subsequent script execution
        "IIS completed" | Set-Content "$($this.home)\iis.lock"
        Restart-Computer -Force
        Sleep 30
    }
}


Class CxSastInstaller : Base {
  [String] $url
  [String] $installerArgs
  CxSastInstaller($url, $installerArgs) {
    $this.url = $url
    $this.installerArgs = $installerArgs
  }
  Install() {     
    [Utility]::Debug("pre-cx-uninstall")  
    Start-Process -FilePath "$($this.url)" -ArgumentList "/uninstall /quiet" -Wait -NoNewWindow
    [Utility]::Debug("post-cx-uninstall")  
    # Components should be installed in a certain order or else the install can hang. Order is manager, then web, then engine. 
    # This is accomplished with temp_args and temporarily replacing component choices in order to install in order
    if ($this.installerArgs.Contains("MANAGER=1")){
        $temp_args = $this.installerArgs
        $temp_args = $temp_args.Replace("WEB=1", "WEB=0").Replace("ENGINE=1", "ENGINE=0").Replace("AUDIT=1", "AUDIT=0")
        $this.log.Info("Installing CxSAST with $temp_args")
        [Utility]::Debug("pre-cx-installer-mgr")  
        Start-Process -FilePath "$($this.url)" -ArgumentList "$temp_args" -Wait -NoNewWindow
        [Utility]::Debug("post-cx-installer-mgr")  
        $this.log.Info("...finished installing")
    }

    if ($this.installerArgs.Contains("WEB=1")){
        $temp_args = $this.installerArgs
        $temp_args = $temp_args.Replace("ENGINE=1", "ENGINE=0").Replace("AUDIT=1", "AUDIT=0")
        $this.log.Info("Installing CxSAST with $temp_args")
        [Utility]::Debug("pre-cx-installer-web")  
        Start-Process -FilePath "$($this.url)" -ArgumentList "$temp_args" -Wait -NoNewWindow
        [Utility]::Debug("post-cx-installer-web")  
        $this.log.Info("...finished installing")
    }

    $this.log.Info("Installing CxSAST with $($this.installerArgs)")
    [Utility]::Debug("pre-cx-installer-all")  
    Start-Process -FilePath "$($this.url)" -ArgumentList "$($this.installerArgs)" -Wait -NoNewWindow
    [Utility]::Debug("post-cx-installer-all")  
    $this.log.Info("...finished installing")
  }
}


Class CxSastHotfixInstaller : Base {
  [String] $url

  CxSastHotfixInstaller($url) {
    $this.url = $url
  }
  Install() { 
    $hotfixexe = [Utility]::Fetch($this.url)#
    $this.log.Info("Installing hotfix ${hotfixexe}")
    [Utility]::Debug("pre-cx-hotfix")  
    Start-Process -FilePath "$hotfixexe" -ArgumentList "-cmd ACCEPT_EULA=Y" -Wait -NoNewWindow
    [Utility]::Debug("post-cx-hotfix")  
    $this.log.Info("...finished installing")
  }
}
