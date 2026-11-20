param(
    [Parameter(Mandatory)][string]$SqlHelperPath,
    [Parameter(Mandatory)][string]$SqlHelperSha256,
    [Parameter(Mandatory)][pscredential]$WindowsCredential
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$Env:ArcBoxDir = "C:\ArcBox"
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = "F:\Virtual Machines"
$Env:ArcBoxIconDir = "$Env:ArcBoxDir\Icons"
$Env:ArcBoxDscDir = "$Env:ArcBoxDir\DSC"
$agentScript = "$Env:ArcBoxDir\agentScript"
. (Join-Path $PSScriptRoot 'ArcBox.Host.ps1')
Import-Module Azure.Arc.Jumpstart.Common -ErrorAction Stop

# Set variables to execute remote powershell scripts on guest VMs
$nestedVMArcBoxDir = $Env:ArcBoxDir
$tenantId = $env:spnTenantId
$subscriptionId = $env:subscriptionId
$azureLocation = $env:azureLocation
$resourceGroup = $env:resourceGroup
$changeTrackingDCR = $env:changeTrackingDCR
$vmInsightsDCR = $env:vmInsightsDCR

# Moved VHD storage account details here to keep only in place to prevent duplicates.
$vhdSourceFolder = "https://jumpstartprodsg.blob.core.windows.net/arcbox/vbd/"

# Archive exising log file and crate new one
$logFilePath = "$Env:ArcBoxLogsDir\ArcServersLogonScript.log"
if ([System.IO.File]::Exists($logFilePath)) {
    $archivefile = "$Env:ArcBoxLogsDir\ArcServersLogonScript-" + (Get-Date -Format "yyyyMMddHHmmss")
    Rename-Item -Path $logFilePath -NewName $archivefile -Force
}

Start-Transcript -Path $logFilePath -Force | Out-Null
try {

################################################
# Setup Hyper-V server before deploying VMs for each flavor
################################################
# Install and configure DHCP service (used by Hyper-V nested VMs)
Write-Host "Configuring DHCP Service"
$dnsClient = Get-DnsClient | Where-Object { $_.InterfaceAlias -eq "Ethernet" }
$dhcpScope = Get-DhcpServerv4Scope
if ($dhcpScope.Name -ne "ArcBox") {
    Add-DhcpServerv4Scope -Name "ArcBox" `
        -StartRange 10.10.1.100 `
        -EndRange 10.10.1.200 `
        -SubnetMask 255.255.255.0 `
        -LeaseDuration 1.00:00:00 `
        -State Active
}

$dhcpOptions = Get-DhcpServerv4OptionValue
if ($dhcpOptions.Count -lt 3) {
    Set-DhcpServerv4OptionValue -ComputerName localhost `
        -DnsDomain $dnsClient.ConnectionSpecificSuffix `
        -DnsServer 168.63.129.16, 10.16.2.100 `
        -Router 10.10.1.1 `
        -Force
}

# Create the NAT network
Write-Host "Creating Internal NAT"
$natName = "InternalNat"
$netNat = Get-NetNat
if ($netNat.Name -ne $natName) {
    New-NetNat -Name $natName -InternalIPInterfaceAddressPrefix 10.10.1.0/24
}

# Creating Hyper-V Manager desktop shortcut
Write-Host "Creating Hyper-V Shortcut"
Copy-Item -Path "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Administrative Tools\Hyper-V Manager.lnk" -Destination "C:\Users\All Users\Desktop" -Force

$cliDir = New-Item -Path (Join-Path $PSScriptRoot 'servers-cli') -ItemType Directory -Force -ErrorAction Stop
$env:AZURE_CONFIG_DIR = $cliDir.FullName
if (-not $($cliDir.Parent.Attributes.HasFlag([System.IO.FileAttributes]::Hidden))) {
    $folder = Get-Item $cliDir.Parent.FullName -ErrorAction SilentlyContinue
    $folder.Attributes += [System.IO.FileAttributes]::Hidden
}

# Install Azure CLI extensions
Write-Header "Az CLI extensions"

az config set extension.use_dynamic_install=yes_without_prompt --only-show-errors

foreach ($extension in 'ssh', 'log-analytics-solution', 'connectedmachine', 'monitor-control-service') {
    Invoke-ArcBoxAz @('extension','add','--name',$extension,'--yes','--only-show-errors')
}

# Required for CLI commands
Write-Header "Az CLI Login"
Invoke-ArcBoxAz @('login', '--identity', '--output', 'none')
Invoke-ArcBoxAz @('account', 'set', '--subscription', $subscriptionId)

Write-Header "Az PowerShell Login"
Disable-AzContextAutosave -Scope Process -ErrorAction Stop | Out-Null
Connect-AzAccount -Identity -Tenant $tenantId -Subscription $subscriptionId -ErrorAction Stop | Out-Null

# Fail before staging guests if the scope already holds a different cohort's Arc resources.
if (@(Get-AzConnectedMachine -ResourceGroupName $resourceGroup -SubscriptionId $subscriptionId -ErrorAction Stop).Count) {
    Write-ArcBoxHostEvent arc-connect failed arc-inventory
    throw 'The first workshop provisioning requires an empty Arc machine inventory in its resource group.'
}

# Enable defender for cloud for SQL Server
# Get workspace information
$workspaceResourceID = (az monitor log-analytics workspace show --resource-group $resourceGroup --workspace-name $Env:workspaceName --query "id" -o tsv)

# Before deploying ArcBox SQL set resource group tag ArcSQLServerExtensionDeployment=Disabled to opt out of automatic SQL onboarding
#az tag create --resource-id "/subscriptions/$subscriptionId/resourceGroups/$resourceGroup" --tags ArcSQLServerExtensionDeployment=Disabled

$vhdImageToDownload = "VBD-ArcBox-SQL-DEV.vhdx"
if ($Env:sqlServerEdition -eq "Standard") {
    $vhdImageToDownload = "VBD-ArcBox-SQL-STD.vhdx"
}
elseif ($Env:sqlServerEdition -eq "Enterprise") {
    $vhdImageToDownload = "VBD-ArcBox-SQL-ENT.vhdx"
}

# Create the nested VMs if not already created
Write-Header "Create Hyper-V VMs"

# Onboard nested Windows and Linux VMs to Azure Arc
Write-Header "Fetching Nested VMs"

$SQLvmvhdPath = "$Env:ArcBoxVMDir\VBD-ArcBox-SQL.vhdx"
$SQLvmName = "ArcBox-SQL"
        
$Win2k25vmName = "ArcBox-Win2K25"
$win2k25vmvhdPath = "${Env:ArcBoxVMDir}\VBD-ArcBox-Win2K25.vhdx"

$Win2k22vmName = "ArcBox-Win2K22"
$Win2k22vmvhdPath = "${Env:ArcBoxVMDir}\VBD-ArcBox-Win2K22.vhdx"

$Ubuntu01vmName = "ArcBox-Ubuntu-01"
$Ubuntu01vmvhdPath = "${Env:ArcBoxVMDir}\VBD-ArcBox-Ubuntu-01.vhdx"

$Ubuntu02vmName = "ArcBox-Ubuntu-02"
$Ubuntu02vmvhdPath = "${Env:ArcBoxVMDir}\VBD-ArcBox-Ubuntu-02.vhdx"

$ProxyvmName = "ArcBox-Proxy"
$ProxyvmvhdPath = "${Env:ArcBoxVMDir}\VBD-ArcBox-Proxy.vhdx"

# The script reads credentials later; do not broaden its artifact publication scope.
$Env:AZCOPY_BUFFER_GB = 8
$azcopy = (Get-Command azcopy.exe -CommandType Application -ErrorAction Stop).Source
$images = [ordered]@{
    $SQLvmvhdPath = $vhdImageToDownload
    $win2k25vmvhdPath = 'VBD-ArcBox-Win2K25.vhdx'
    $Win2k22vmvhdPath = 'VBD-ArcBox-Win2K22.vhdx'
    $Ubuntu01vmvhdPath = 'VBD-ArcBox-Ubuntu-01.vhdx'
    $Ubuntu02vmvhdPath = 'VBD-ArcBox-Ubuntu-02.vhdx'
}
foreach ($image in $images.GetEnumerator()) {
    Receive-ArcBoxVhd -Path $image.Key -SourceUri ($vhdSourceFolder + $image.Value) -AzCopy $azcopy
}
Receive-ArcBoxVhd -Path $ProxyvmvhdPath -CopyFrom $Ubuntu02vmvhdPath

# Create the nested VMs if not already created
Write-Header "Create Hyper-V VMs"
Initialize-ArcBoxGuests -Root $Env:ArcBoxVMDir

Write-Host "Starting VMs"
Get-VM -Name @($Win2k25vmName, $Win2k22vmName, $Ubuntu01vmName, $Ubuntu02vmName, $SQLvmName, $ProxyvmName) |
    Where-Object State -eq 'Off' | Start-VM


# Hard-coded username and password for the nested VMs
$nestedLinuxUsername = "jumpstart"

# Restarting Windows VM Network Adapters
Write-Header "Restarting Network Adapters"
foreach ($name in $Win2k25vmName, $Win2k22vmName, $SQLvmName) {
    $vmSession = Wait-ArcBoxWindowsSession -Name $name -Credential $WindowsCredential
    try { Invoke-Command -Session $vmSession -ScriptBlock { Get-NetAdapter | Restart-NetAdapter -ErrorAction Stop } }
    finally { Remove-PSSession -Session $vmSession }
}

# Resolve usable addresses on the exact switch and never provision two guests through the same address.
Write-ArcBoxHostEvent guest-access start
try {
    $Ubuntu01VmIp = Get-ArcBoxLinuxAddress -Name $Ubuntu01vmName
    $Ubuntu02VmIp = Get-ArcBoxLinuxAddress -Name $Ubuntu02vmName
    $ProxyVmIp = Get-ArcBoxLinuxAddress -Name $ProxyvmName
    if (@(@($Ubuntu01VmIp, $Ubuntu02VmIp, $ProxyVmIp) | Sort-Object -Unique).Count -ne 3) {
        throw 'Ubuntu and Proxy addresses are not distinct.'
    }
    Write-ArcBoxHostEvent guest-access ok
} catch {
    Write-ArcBoxHostEvent guest-access failed guest-access
    throw
}

#Reserve IP address for proxy so it does not change
Get-DhcpServerv4Lease -IPAddress $ProxyVmIp| Add-DhcpServerv4Reservation

# Configuring SSH for accessing Linux VMs
Write-Output "Generating SSH key for accessing nested Linux VMs"

$sshDir = (New-Item -Path (Join-Path $PSScriptRoot 'ssh') -ItemType Directory -Force).FullName
$privateKey = Join-Path $sshDir 'id_rsa'
if (-not (Test-Path -LiteralPath $privateKey -PathType Leaf)) {
    ssh-keygen -q -t rsa -N '' -f $privateKey
}
$sshOptions = @{ StrictHostKeyChecking = 'accept-new'; ConnectTimeout = '10'; BatchMode = 'yes' }
$keyCopy = @{
    SourcePath = "$privateKey.pub"
    DestinationPath = "/home/$nestedLinuxUsername/.ssh/authorized_keys"
    FileSource = 'Host'
    Force = $true
    CreateFullPath = $true
}
$ubuntuGuests = Get-VM -Name @($Ubuntu01vmName, $Ubuntu02vmName)
$ubuntuGuests | Copy-VMFile @keyCopy
# Preserve upstream's second Ubuntu copy: the first guest-service copy can leave an empty file.
$ubuntuGuests | Copy-VMFile @keyCopy
Get-VM -Name $ProxyvmName | Copy-VMFile @keyCopy
    
# Copy installation script to nested Windows VMs
Write-Output "Transferring installation script to nested Windows VMs..."
Copy-VMFile $Win2k25vmName -SourcePath "$agentScript\installArcAgent.ps1" -DestinationPath "$Env:ArcBoxDir\installArcAgent.ps1" -CreateFullPath -FileSource Host -Force

# Copy Change tracking text file to 2025 and 2022 machines
Copy-VMFile $Win2k25vmName -SourcePath "$Env:ArcBoxDir\ct.txt" -DestinationPath "$Env:ArcBoxDir\ct.txt" -CreateFullPath -FileSource Host -Force
Copy-VMFile $Win2k22vmName -SourcePath "$Env:ArcBoxDir\ct.txt" -DestinationPath "$Env:ArcBoxDir\ct.txt" -CreateFullPath -FileSource Host -Force

# Copy required SQL scripts to SQL VM
Assert-ArcBoxPrivateScript $SqlHelperPath $SqlHelperSha256
Copy-VMFile $SQLvmName -SourcePath $SqlHelperPath -DestinationPath "$Env:ArcBoxDir\testDefenderForSQL.ps1" -CreateFullPath -FileSource Host -Force
$sqlModule = Join-Path $Env:ArcBoxDir 'SqlAdvancedThreatProtectionShell.psm1'
$moduleHash = (Get-FileHash -LiteralPath $sqlModule -Algorithm SHA256).Hash
Copy-VMFile $SQLvmName -SourcePath $sqlModule -DestinationPath $sqlModule -CreateFullPath -FileSource Host -Force
Invoke-Command -VMName $SQLvmName -Credential $WindowsCredential -ErrorAction Stop -ArgumentList $SqlHelperSha256,$moduleHash -ScriptBlock {
    param($ExpectedHash,$ExpectedModuleHash)
    if ((Get-FileHash -LiteralPath 'C:\ArcBox\testDefenderForSQL.ps1' -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedHash) {
        throw 'SQL lab helper copy failed its digest check.'
    }
    if ((Get-FileHash -LiteralPath 'C:\ArcBox\SqlAdvancedThreatProtectionShell.psm1' -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedModuleHash) {
        throw 'SQL lab module copy failed its digest check.'
    }
}



# Only Ubuntu-01 gets the installer. No token is written into the lab-readable client directory.
Copy-VMFile -VMName $Ubuntu01vmName -SourcePath "$agentScript\installArcAgentUbuntu.sh" `
    -DestinationPath "/var/tmp/arcbox-install-agent.sh" -FileSource Host -Force

#Installing Squid proxy on the Proxy VM
Write-Output "Installing Squid proxy on the Proxy VM"

$ProxySessions = New-PSSession -HostName $ProxyVmIp -KeyFilePath $privateKey -UserName $nestedLinuxUsername -Options $sshOptions
Invoke-JSSudoCommand -Session $ProxySessions -Command 'sudo hostnamectl set-hostname "proxy"'
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo apt-get update"
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo apt-get install squid -y"
#Copy the squid config file to the proxy vm
Invoke-JSSudoCommand -Session $ProxySessions -Command "sudo cp /etc/squid/squid.conf /etc/squid/squid.conf.default"
Copy-VMFile -VMName $ProxyvmName -SourcePath "$Env:ArcBoxDir\whitelist.txt" -DestinationPath '/etc/squid/whitelist.txt' -FileSource Host -Force -ErrorAction Stop
Copy-VMFile -VMName $ProxyvmName -SourcePath "$Env:ArcBoxDir\squid.conf" -DestinationPath '/etc/squid/squid.conf' -FileSource Host -Force -ErrorAction Stop
# Load the baseline allowlist; the student still adds the Gateway URL and restarts Squid.
Write-ArcBoxHostEvent proxy start
try {
    Invoke-Command -Session $ProxySessions -ErrorAction Stop -ScriptBlock {
        sudo -n squid -k parse
        if ($LASTEXITCODE -ne 0) { throw 'Squid rejected the baseline configuration.' }
        sudo -n systemctl reload squid
        if ($LASTEXITCODE -ne 0) { throw 'Squid could not reload the baseline configuration.' }
        sudo -n systemctl is-active --quiet squid
        if ($LASTEXITCODE -ne 0) { throw 'Squid is not active.' }
    }
    Write-ArcBoxHostEvent proxy ok
} catch {
    Write-ArcBoxHostEvent proxy failed proxy-config
    throw
}
#Remove-PSSession -Session $ProxySessions

#Install net-tools for ifconfig usage and python 3.10 for hybrid worker on Ubuntu-01 and Ubuntu-02
$Ubuntu1Session = New-PSSession -HostName $Ubuntu01VmIp -KeyFilePath $privateKey -UserName $nestedLinuxUsername -Options $sshOptions
Invoke-JSSudoCommand -Session $Ubuntu1Session -Command "sudo apt-get update"
Invoke-JSSudoCommand -Session $Ubuntu1Session -Command "sudo apt install net-tools -y"
# Invoke-JSSudoCommand -Session $Ubuntu1Session -Command "sudo apt install python3.10 -y"
# Invoke-JSSudoCommand -Session $Ubuntu1Session -Command "sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 110"
# Invoke-JSSudoCommand -Session $Ubuntu1Session -Command "sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 120"
# Automatically set Python 3.10 as the default
# Invoke-JSSudoCommand -Session $Ubuntu1Session -Command "sudo update-alternatives --set python3 /usr/bin/python3.10"
#Remove-PSSession -Session $Ubuntu1Session

$Ubuntu2Session = New-PSSession -HostName $Ubuntu02VmIp -KeyFilePath $privateKey -UserName $nestedLinuxUsername -Options $sshOptions
Invoke-JSSudoCommand -Session $Ubuntu2Session -Command "sudo apt-get update"
Invoke-JSSudoCommand -Session $Ubuntu2Session -Command "sudo apt install net-tools -y"
# Invoke-JSSudoCommand -Session $Ubuntu2Session -Command "sudo apt install python3.10 -y"
# Invoke-JSSudoCommand -Session $Ubuntu2Session -Command "sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.10 110"
# Invoke-JSSudoCommand -Session $Ubuntu2Session -Command "sudo update-alternatives --install /usr/bin/python3 python3 /usr/bin/python3.12 120"
# Automatically set Python 3.10 as the default
# Invoke-JSSudoCommand -Session $Ubuntu2Session -Command "sudo update-alternatives --set python3 /usr/bin/python3.10"
#Remove-PSSession -Session $Ubuntu2Session

Write-Header "Onboarding Arc-enabled servers"

Write-ArcBoxHostEvent arc-connect start
$onboardingStarted = [datetimeoffset]::UtcNow

# Onboarding the nested VMs as Azure Arc-enabled servers
Write-Output "Onboarding the nested Windows VMs as Azure Arc-enabled servers"

$accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
Invoke-Command -VMName $Win2k25vmName -Credential $WindowsCredential -ScriptBlock {
    & (Join-Path $using:nestedVMArcBoxDir 'installArcAgent.ps1') -AccessToken $using:accessToken `
        -SpnTenantId $using:tenantId -SubscriptionId $using:subscriptionId -ResourceGroup $using:resourceGroup `
        -AzureLocation $using:azureLocation
}

Write-Output "Onboarding the nested Linux VMs as an Azure Arc-enabled servers"
$accessToken = ConvertFrom-SecureString ((Get-AzAccessToken -AsSecureString).Token) -AsPlainText
try {
    Invoke-Command -Session $Ubuntu1Session -ScriptBlock {
        param($Token, $Group, $Tenant, $Location, $Subscription)
        $Token | sudo -n sh /var/tmp/arcbox-install-agent.sh $Group $Tenant $Location $Subscription
        if ($LASTEXITCODE -ne 0) { throw 'Linux agent setup or registration failed. Inspect the guest agent log.' }
    } -ArgumentList $accessToken, $resourceGroup, $tenantId, $azureLocation, $subscriptionId
} finally {
    $accessToken = $null
}

#WorkshopPlus: adding DCRs and extensins for 2025 and Ubuntu-1
Write-Host "Assigning Data collection rules to Arc-enabled machines"
try {
    $baseline = Wait-ArcBoxBaselineRegistration -Group $resourceGroup -Subscription $subscriptionId -NotBefore $onboardingStarted
    Write-ArcBoxHostEvent arc-connect ok
} catch {
    Write-ArcBoxHostEvent arc-connect failed arc-inventory
    throw
}
$windowsArcMachine = $baseline.Keys | Where-Object { $baseline[$_] -eq $Win2k25vmName }
$linuxArcMachine = $baseline.Keys | Where-Object { $baseline[$_] -eq $Ubuntu01vmName }
Write-ArcBoxHostEvent arc-features start
try {
    # This task runs under verified PowerShell 7; fail on a rejected native CLI request.
    $previousErrorPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Stop'
    $PSNativeCommandUseErrorActionPreference = $true
    az monitor data-collection rule association create --name "vmInsighitsWindows" --rule-id $vmInsightsDCR --resource $windowsArcMachine --only-show-errors
    az monitor data-collection rule association create --name "vmInsighitsLinux" --rule-id $vmInsightsDCR --resource $linuxArcMachine --only-show-errors
    az monitor data-collection rule association create --name "changeTrackingWindows" --rule-id $changeTrackingDCR --resource $windowsArcMachine --only-show-errors
    az monitor data-collection rule association create --name "changeTrackingLinux" --rule-id $changeTrackingDCR --resource $linuxArcMachine --only-show-errors

    Write-Host "Installing the AMA agent on the Arc-enabled machines"
    az connectedmachine extension create --name AzureMonitorWindowsAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorWindowsAgent --machine-name $Win2k25vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade true --no-wait
    az connectedmachine extension create --name AzureMonitorLinuxAgent --publisher Microsoft.Azure.Monitor --type AzureMonitorLinuxAgent --machine-name $Ubuntu01vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade true --no-wait

    Write-Host "Installing the Change Tracking agent on Windows"
    az connectedmachine extension create --name ChangeTracking-Windows --publisher Microsoft.Azure.ChangeTrackingAndInventory --type-handler-version 2.20 --type ChangeTracking-Windows --machine-name $Win2k25vmName --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade --no-wait

    Write-Host "Initializing the Azure Update Manager agents"
    az connectedmachine assess-patches --resource-group $resourceGroup --name $Win2k25vmName --no-wait
    az connectedmachine assess-patches --resource-group $resourceGroup --name $Ubuntu01vmName --no-wait
    Write-Host "Installing the dependency agent on Windows"
    $dependencyAgentSetting = '{\"enableAMA\":\"true\"}'
    az connectedmachine extension create --name DependencyAgent --publisher Microsoft.Azure.Monitoring.DependencyAgent --type-handler-version 9.10 --type DependencyAgentWindows --machine-name $Win2k25vmName --settings $dependencyAgentSetting --resource-group $resourceGroup --location $azureLocation --enable-auto-upgrade --no-wait

    Write-ArcBoxHostEvent arc-features requested
} catch {
    Write-ArcBoxHostEvent arc-features failed arc-feature
    throw
} finally {
    $ErrorActionPreference = $previousErrorPreference
    $PSNativeCommandUseErrorActionPreference = $false
}

#az connectedmachine extension create --name MDE.Windows --machine-name $machine.name $Win2k25vmName --resource-group $resourceGroup --publisher "Microsoft.Azure.Security" --type "MDE.Windows" --type-handler-version "1.0" --location $azureLocation --enable-auto-upgrade --no-wait

# Prepare the wallpaper without using the service account's desktop settings.
Convert-JSImageToBitMap -SourceFilePath "$Env:ArcBoxDir\wallpaper.png" -DestinationFilePath "$Env:ArcBoxDir\wallpaper.bmp"

} finally {
    Get-PSSession | Remove-PSSession -ErrorAction SilentlyContinue
    Stop-Transcript | Out-Null
}

