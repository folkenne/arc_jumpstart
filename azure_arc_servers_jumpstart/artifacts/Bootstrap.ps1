param (
    [string]$adminUsername,
    [string]$spnTenantId,
    [string]$spnAuthority,
    [string]$subscriptionId,
    [string]$resourceGroup,
    [string]$acceptEula,
    [string]$azureLocation,
    [string]$stagingStorageAccountName,
    [string]$workspaceName,
    [string]$templateBaseUrl,
    [string]$rdpPort,
    [string]$sshPort,
    [string]$changeTrackingDCR,
    [string]$vmInsightsDCR,
    [string]$dataDiskIdBase64,
    [string]$bootstrapOptionsBase64
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSDefaultParameterValues['Invoke-WebRequest:UseBasicParsing'] = $true
$PSDefaultParameterValues['Invoke-WebRequest:TimeoutSec'] = 120
$earlyStage = 'reviewed source and access checks'
try {
if ($templateBaseUrl -cnotmatch '\Ahttps://raw\.githubusercontent\.com/folkenne/arc_jumpstart/[a-f0-9]{40}/azure_arc_servers_jumpstart/\z') {
    throw 'Supply the full commit SHA of the reviewed Level Up artifacts.'
}
if ($rdpPort -ne '3389') { throw 'Workshop access requires RDP port 3389.' }
$earlyStage = 'loading the shared helper'
. (Join-Path $PSScriptRoot 'ArcBox.Host.ps1')
$earlyStage = 'checking and claiming the attempt'
if ((Get-ScheduledTask -TaskName 'ArcBox-PostReboot' -ErrorAction SilentlyContinue) -or
    [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine')) {
    Stop-ArcBoxHostStep checkpoint 'A previous attempt exists. Recover from its checkpoints; do not rerun Bootstrap.'
}
$attempt = [guid]::NewGuid().ToString('N')
$work = Split-Path -Parent (Get-ArcBoxPrivateScriptPath -Attempt $attempt)
New-ArcBoxPrivateScriptDirectory -Path $work
$claim = Join-Path (Split-Path -Parent $work) 'bootstrap.started'
# Refuse a concurrent CSE invocation even before the attempt's machine environment is set.
try { $handle = [IO.File]::Open($claim, 'CreateNew', 'Write', 'None') }
catch [IO.IOException] { Stop-ArcBoxHostStep checkpoint 'The bootstrap attempt was already claimed. Inspect it before recovery.' }
try {
    $bytes = [Text.Encoding]::ASCII.GetBytes($attempt)
    $handle.Write($bytes, 0, $bytes.Length)
    $handle.Flush($true)
} finally { $handle.Dispose() }
[Environment]::SetEnvironmentVariable('ArcBoxAttemptId', $attempt, 'Machine')

$earlyStage = 'preparing protected paths and the transcript'
[System.Environment]::SetEnvironmentVariable('adminUsername', $adminUsername, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnTenantId', $spnTenantId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('spnAuthority', $spnAuthority, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_TENANT_ID', $spnTenantId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('SPN_AUTHORITY', $spnAuthority, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('resourceGroup', $resourceGroup, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('ACCEPT_EULA', $acceptEula, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('subscriptionId', $subscriptionId, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('azureLocation', $azureLocation, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('stagingStorageAccountName', $stagingStorageAccountName, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('workspaceName', $workspaceName, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('templateBaseUrl', $templateBaseUrl, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('ArcBoxDir', "C:\ArcBox", [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('changeTrackingDCR', $changeTrackingDCR, [System.EnvironmentVariableTarget]::Machine)
[System.Environment]::SetEnvironmentVariable('vmInsightsDCR', $vmInsightsDCR, [System.EnvironmentVariableTarget]::Machine)

# Creating ArcBox path
Write-Output "Creating ArcBox path"
$Env:ArcBoxDir = "C:\ArcBox"
$Env:ArcBoxDscDir = "$Env:ArcBoxDir\DSC"
$Env:ArcBoxLogsDir = "$Env:ArcBoxDir\Logs"
$Env:ArcBoxVMDir = "F:\Virtual Machines"
$Env:ArcBoxKVDir = "$Env:ArcBoxDir\KeyVault"
$Env:ArcBoxIconDir = "$Env:ArcBoxDir\Icons"
$Env:agentScript = "$Env:ArcBoxDir\agentScript"
$Env:ToolsDir = "C:\Tools"
$Env:tempDir = "C:\Temp"

New-Item -Path $Env:ArcBoxDir -ItemType directory -Force
New-Item -Path $Env:ArcBoxDscDir -ItemType directory -Force
New-Item -Path $Env:ArcBoxLogsDir -ItemType directory -Force
New-Item -Path $Env:ArcBoxKVDir -ItemType directory -Force
New-Item -Path $Env:ArcBoxIconDir -ItemType directory -Force
New-Item -Path $Env:ToolsDir -ItemType Directory -Force
New-Item -Path $Env:tempDir -ItemType directory -Force
New-Item -Path $Env:agentScript -ItemType directory -Force

$hostHelper = Join-Path $Env:ArcBoxDir 'ArcBox.Host.ps1'
Protect-ArcBoxDirectory -Path $Env:ArcBoxDir -LabRead
Protect-ArcBoxDirectory -Path $Env:ArcBoxLogsDir
Initialize-ArcBoxJournalLayout -Root $Env:ArcBoxLogsDir
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ArcBox.Host.ps1') -Destination $hostHelper -Force

[Environment]::SetEnvironmentVariable('ArcBoxRunId', $null, 'Machine')
$clientBoot = Get-ArcBoxBootTime
$transcript = Join-Path $Env:ArcBoxLogsDir 'Bootstrap.log'
Start-Transcript -Path $transcript -Append | Out-Null
} catch {
    $type = $_.Exception.GetType().Name
    $line = $_.InvocationInfo.ScriptLineNumber
    Write-Warning "Bootstrap stopped before the journal initialized: $earlyStage ($type, line $line). Check the Bootstrap extension handler output; do not replay an existing claim." -WarningAction Continue
    throw "Bootstrap could not initialize ($earlyStage). See the Bootstrap extension handler output."
}
$stage = 'bootstrap'
$fallback = 'artifact-download'
$profileLoadFailed = $false
try {
Start-ArcBoxJournal -ScriptName 'Bootstrap.ps1' -Boot $clientBoot -Release ($templateBaseUrl.Split('/')[5])
$stage = 'artifacts'
$fallback = 'artifact-pin'
$options = ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bootstrapOptionsBase64)))
Assert-ArcBoxSuccessorOptions $options
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
    Stop-ArcBoxHostStep task-dispatch 'Expected SYSTEM Bootstrap.'
}
if (($options.PSObject.Properties['performance'] -and $options.performance -isnot [bool]) -or
    ($options.PSObject.Properties['runId'] -and $options.runId -cnotmatch '\A[a-f0-9]{32}\z') -or
    ($options.performance -and -not $options.runId)) {
    throw 'Performance requires a boolean opt-in and a 32-character lowercase hexadecimal run ID.'
}
$runId = if ($options.runId) { $options.runId } else { $attempt }
[Environment]::SetEnvironmentVariable('ArcBoxRunId', $runId, 'Machine')
$script:ArcBoxJournal.run = $runId
Write-ArcBoxHostEvent bootstrap start
$performanceDir = $null
if ($options.performance) {
    try {
        $performanceDir = Start-ArcBoxHostBaseline -TemplateBaseUrl $templateBaseUrl -Attempt $attempt
        Write-ArcBoxHostEvent performance requested
    } catch {
        Write-ArcBoxJournal performance WARNING 'Host sampler dispatch failed; Bootstrap will continue without verified samples.' `
            -Failure $_ -Operation 'Stage and request ArcBox-HostBaseline'
        Write-ArcBoxHostEvent performance failed performance
    }
} else {
    Write-ArcBoxJournal performance INFO 'Host sampler skipped: performance collection was not requested.'
}
$stage = 'artifacts'
$privateScript = Get-ArcBoxPrivateScriptPath -Attempt $attempt
$fallback = 'artifact-download'
Invoke-WebRequest ($templateBaseUrl + "artifacts/ArcBox.Machine.ps1") -OutFile (Join-Path $work 'ArcBox.Machine.ps1')
. (Join-Path $work 'ArcBox.Machine.ps1')
Write-ArcBoxJournal artifacts INFO 'Machine package helper loaded; no installer has been dispatched.' -Owner 'ArcBox.Machine.ps1'
$fallback = 'winget-setup'
Assert-ArcBoxMachinePackages $options.machinePackages
$fallback = 'artifact-download'
$bootMarker = Join-Path $work 'PreparedOnBoot.txt'
Receive-ArcBoxPinnedScript $templateBaseUrl 'ArcServersLogonScript.ps1' $privateScript
Receive-ArcBoxPinnedScript $templateBaseUrl 'testDefenderForSQL.ps1' (Join-Path $work 'testDefenderForSQL.ps1')
Receive-ArcBoxPinnedScript $templateBaseUrl 'SqlAdvancedThreatProtectionShell.psm1' (Join-Path $Env:ArcBoxDir 'SqlAdvancedThreatProtectionShell.psm1')
[IO.File]::WriteAllText((Join-Path $work 'Inputs.json'), ([ordered]@{
    disk = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dataDiskIdBase64))
    machinePackages = $options.machinePackages
} | ConvertTo-Json -Depth 6 -Compress))
$stage = 'disk'
$fallback = 'disk-discovery'
Write-ArcBoxHostEvent disk start
$diskId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dataDiskIdBase64))
Initialize-ArcBoxDataDrive -ExpectedId $diskId
New-Item -Path $Env:ArcBoxVMDir -ItemType directory -Force
Protect-ArcBoxDirectory -Path $Env:ArcBoxVMDir
Write-ArcBoxHostEvent disk ok
if ($performanceDir) {
    try { [IO.File]::WriteAllText("$performanceDir\disk-ready.txt", 'F:') }
    catch { Write-ArcBoxHostEvent performance failed performance }
}

# The startup worker is a service task, not a desktop logon.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0'
if ((Get-Item -LiteralPath $winlogon).Property -contains 'DefaultPassword') {
    Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword
}

# Copy PowerShell Profile and Reload
$stage = 'artifacts'
$fallback = 'artifact-download'
Invoke-WebRequest ($templateBaseUrl + "artifacts/PSProfile.ps1") -OutFile $PsHome\Profile.ps1
Write-ArcBoxJournal artifacts INFO 'Loading the lab PowerShell profile.' -Owner 'PSProfile.ps1'
try { . (Join-Path $PSHOME 'Profile.ps1') }
catch {
    $profileLoadFailed = $true
    Write-ArcBoxJournal artifacts ERROR 'The Windows PowerShell lab profile could not load. Bootstrap stopped before PowerShell installation or reboot; check the profile source and Bootstrap transcript.' `
        -Owner 'PSProfile.ps1' -Failure $_ -Operation 'Load Windows PowerShell lab profile' `
        -Detail @{profile='Profile.ps1'; engine='Windows PowerShell 5.1'; outcome='load-failed'} -LastConfirmed 'The profile was staged; it did not finish loading.'
    throw
}
Write-ArcBoxJournal artifacts INFO 'Lab PowerShell profile loaded.' -Owner 'PSProfile.ps1'

# Extending C:\ partition to the maximum size
$stage = 'features'
$fallback = 'windows-features'
$stage = 'os-volume'
$osWatch = [Diagnostics.Stopwatch]::StartNew()
$osPartition = Get-Partition -DriveLetter C
$osSize = (Get-PartitionSupportedSize -DriveLetter C).SizeMax
if ($osSize -gt $osPartition.Size) {
    Write-ArcBoxJournal os-volume INFO 'Expanding C: separately from lab disk initialization.' `
        -Operation 'Resize-Partition C:' -Detail @{currentBytes=$osPartition.Size; requestedBytes=$osSize}
    Resize-Partition -DriveLetter C -Size $osSize
    $afterSize = (Get-Partition -DriveLetter C -ErrorAction Stop).Size
    if ($afterSize -ne $osSize) { throw 'C: expansion returned but the requested capacity did not verify.' }
    Write-ArcBoxJournal os-volume INFO 'OS volume C: expansion verified.' -ElapsedMs $osWatch.ElapsedMilliseconds `
        -Detail @{previousBytes=$osPartition.Size; observedBytes=$afterSize}
} else {
    Write-ArcBoxJournal os-volume INFO 'C: expansion skipped: Windows reports no additional supported capacity.' `
        -ElapsedMs $osWatch.ElapsedMilliseconds -Detail @{currentBytes=$osPartition.Size; supportedBytes=$osSize}
}

$stage = 'powershell'
$fallback = 'ps-probe'
Write-ArcBoxHostEvent powershell start
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
Install-ArcBoxPowerShell -Executable $pwsh -RecoveryMsi (Join-Path $Env:ArcBoxDir 'PowerShell-7.6.10-win-x64.msi')
Copy-Item $PsHome\Profile.ps1 -Destination (Join-Path (Split-Path -Parent $pwsh) 'Profile.ps1') -Force
Write-ArcBoxHostEvent powershell ok

$stage = 'modules'
$fallback = 'module-setup'
Write-ArcBoxHostEvent modules start
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force
Install-Module -Name Microsoft.PowerShell.PSResourceGet -Force -Scope AllUsers
Import-Module Microsoft.PowerShell.PSResourceGet
$modules = @('Az', 'Az.ConnectedMachine', 'Microsoft.PowerShell.SecretManagement', 'Azure.Arc.Jumpstart.Common', 'Pester')
foreach ($module in $modules) {
    Install-PSResource -Name $module -Scope AllUsers -Quiet -AcceptLicense -TrustRepository
}
& $pwsh -NoLogo -NoProfile -NonInteractive -Command '$ErrorActionPreference = "Stop"; Import-Module Microsoft.PowerShell.PSResourceGet, Az.Accounts, Az.ConnectedMachine, Azure.Arc.Jumpstart.Common'
if ($LASTEXITCODE -ne 0) { throw 'Required modules failed to import in the PowerShell 7 task host.' }
Write-ArcBoxHostEvent modules ok

# Installing DHCP service
$stage = 'features'
$fallback = 'windows-features'
Write-Output "Installing DHCP service"
if (-not (Install-WindowsFeature -Name DHCP -IncludeManagementTools).Success) {
    throw 'DHCP feature installation failed.'
}
# PowerShell SSH remoting needs a machine client, not one registered in a student profile.
$openSsh = 'OpenSSH.Client~~~~0.0.1.0'
if ((Get-WindowsCapability -Online -Name $openSsh).State -ne 'Installed') {
    Add-WindowsCapability -Online -Name $openSsh | Out-Null
}

$stage = 'artifacts'
$fallback = 'artifact-download'
Write-ArcBoxHostEvent artifacts start
Write-Header "Fetching GitHub Artifacts"

# All flavors
Write-Host "Fetching Artifacts for All Flavors"
Invoke-WebRequest "https://raw.githubusercontent.com/azure/arc_jumpstart_docs/main/img/wallpaper/arcbox_wallpaper_dark.png" -OutFile $Env:ArcBoxDir\wallpaper.png
Invoke-WebRequest ($templateBaseUrl + "artifacts/MonitorWorkbookLogonScript.ps1") -OutFile (Join-Path $work 'MonitorWorkbookLogonScript.ps1')
Invoke-WebRequest ($templateBaseUrl + "artifacts/mgmtMonitorWorkbook.parameters.json") -OutFile $Env:ArcBoxDir\mgmtMonitorWorkbook.parameters.json
Invoke-WebRequest ($templateBaseUrl + "artifacts/monitoring/arc-inventory-workbook.json") -OutFile "$Env:ArcBoxDir\arc-inventory-workbook.json"
Invoke-WebRequest ($templateBaseUrl + "artifacts/monitoring/arc-osperformance-workbook.json") -OutFile "$Env:ArcBoxDir\arc-osperformance-workbook.json"
Invoke-WebRequest ($templateBaseUrl + "artifacts/LogInstructions.txt") -OutFile $Env:ArcBoxLogsDir\LogInstructions.txt
Invoke-WebRequest ($templateBaseUrl + "artifacts/dsc/common.dsc.yml") -OutFile $Env:ArcBoxDscDir\common.dsc.yml
Invoke-WebRequest ($templateBaseUrl + "artifacts/WinGet.ps1") -OutFile (Join-Path $work 'WinGet.ps1')
Copy-Item -LiteralPath $hostHelper -Destination (Join-Path $work 'ArcBox.Host.ps1')
Invoke-WebRequest ($templateBaseUrl + "artifacts/squid.conf") -OutFile $Env:ArcBoxDir\squid.conf
Invoke-WebRequest ($templateBaseUrl + "artifacts/whitelist.txt") -OutFile $Env:ArcBoxDir\whitelist.txt
Invoke-WebRequest ($templateBaseUrl + "artifacts/ct.txt") -OutFile $Env:ArcBoxDir\ct.txt

# Workbook template
Invoke-WebRequest ($templateBaseUrl + "artifacts/mgmtMonitorWorkbookITPro.json") -OutFile $Env:ArcBoxDir\mgmtMonitorWorkbook.json

Write-Host "Fetching Artifacts"
Invoke-WebRequest ($templateBaseUrl + "artifacts/installArcAgent.ps1") -OutFile $Env:ArcBoxDir\agentScript\installArcAgent.ps1
Invoke-WebRequest ($templateBaseUrl + "artifacts/installArcAgentUbuntu.sh") -OutFile $Env:ArcBoxDir\agentScript\installArcAgentUbuntu.sh
Invoke-WebRequest ($templateBaseUrl + "artifacts/testDefenderForServers.cmd") -OutFile $Env:ArcBoxDir\agentScript\testDefenderForServers.cmd
Invoke-WebRequest ($templateBaseUrl + "artifacts/InstallArcSQLExtensionAtScale.ps1") -OutFile $Env:ArcBoxDir\InstallArcSQLExtensionAtScale.ps1
Invoke-WebRequest ($templateBaseUrl + "artifacts/AdventureWorksLT2019.bak") -OutFile "$Env:ArcBoxDir\AdventureWorksLT2019.bak"
Invoke-WebRequest ($templateBaseUrl + "artifacts/dsc/itpro.dsc.yml") -OutFile $Env:ArcBoxDscDir\itpro.dsc.yml
Invoke-WebRequest ($templateBaseUrl + "artifacts/dsc/virtual_machines_itpro.dsc.yml") -OutFile $Env:ArcBoxDscDir\virtual_machines_itpro.dsc.yml
Write-ArcBoxHostEvent artifacts ok

$stage = 'features'
$fallback = 'windows-features'
# Disable Microsoft Edge sidebar
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$Name = 'HubsSidebarEnabled'
$Value = '00000000'
# Create the key if it does not exist
If (-NOT (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

# Disable Microsoft Edge first-run Welcome screen
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
$Name = 'HideFirstRunExperience'
$Value = '00000001'
# Create the key if it does not exist
If (-NOT (Test-Path $RegistryPath)) {
    New-Item -Path $RegistryPath -Force | Out-Null
}
New-ItemProperty -Path $RegistryPath -Name $Name -Value $Value -PropertyType DWORD -Force

# Disabling Windows Server Manager Scheduled Task
Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue | Disable-ScheduledTask | Out-Null

Write-Header "Installing Hyper-V"
Write-ArcBoxHostEvent features start
Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
if (-not (Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools).Success) {
    throw 'Hyper-V feature installation failed.'
}
Write-ArcBoxHostEvent features ok

$stage = 'tasks'
$fallback = 'task-register'
Write-ArcBoxHostEvent tasks start
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$action = New-ScheduledTaskAction -Execute $pwsh -Argument (Get-ArcBoxStartupArguments $work) -WorkingDirectory $work
Register-ScheduledTask -TaskName 'ArcBox-PostReboot' -TaskPath '\' -Principal $principal -Settings $settings `
    -Trigger (New-ScheduledTaskTrigger -AtStartup) -Action $action -ErrorAction Stop | Out-Null
# Presentation only; this logon task cannot provision or determine readiness.
$labUser = "$env:COMPUTERNAME\$adminUsername"
$desktop = New-ScheduledTaskAction -Execute $pwsh -Argument '-NoProfile -NonInteractive -Command "Import-Module Azure.Arc.Jumpstart.Common -ErrorAction Stop; Set-JSDesktopBackground -ImagePath C:\ArcBox\wallpaper.bmp"'
Register-ScheduledTask -TaskName 'ArcBox-Presentation' -TaskPath '\' `
    -Principal (New-ScheduledTaskPrincipal -UserId $labUser -LogonType Interactive) `
    -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $labUser) -Action $desktop -ErrorAction Stop | Out-Null
Write-ArcBoxJournal tasks INFO 'Student presentation task registered. It has not run; it waits for student sign-in and is not part of unattended readiness.'
Write-ArcBoxHostEvent tasks ok

$stage = 'reboot'
$fallback = 'task-register'
# A separate one-shot task gives CSE time to return; WinGet independently checks the subsequent boot.
$rebootAt = (Get-Date).AddMinutes(2)
$reboot = New-ScheduledTaskTrigger -Once -At $rebootAt
$reboot.EndBoundary = $rebootAt.AddMinutes(5).ToString('s')
$rebootSettings = New-ScheduledTaskSettingsSet -DeleteExpiredTaskAfter (New-TimeSpan -Minutes 1)
$rebootAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\shutdown.exe" -Argument '/r /t 0'
Set-Content -LiteralPath $bootMarker -Value $clientBoot -Encoding ASCII
Register-ScheduledTask -TaskName 'ArcBoxClientReboot' -TaskPath '\' -User SYSTEM -RunLevel Highest -Trigger $reboot -Action $rebootAction -Settings $rebootSettings -Force | Out-Null
Write-ArcBoxHostEvent reboot requested
Write-ArcBoxHostEvent bootstrap ok
} catch {
    $reason = Get-ArcBoxHostFailureCode $_ $fallback
    if (-not $profileLoadFailed) {
        Write-ArcBoxJournal $stage ERROR "Bootstrap stopped in $stage ($reason). $($script:ArcBoxHostReasons[$reason])" `
            -Failure $_ -Operation $stage -LastConfirmed 'See the last completed stage in this attempt; no technical handoff was verified.'
    }
    $failure = $_
    try {
        $detail = "Bootstrap stage: $stage; decision: $reason; error: $($failure.Exception.GetType().FullName); line: $($failure.InvocationInfo.ScriptLineNumber). See the paired administrator log."
        Set-Content -LiteralPath (Join-Path $Env:ArcBoxLogsDir "Bootstrap-error-$attempt.log") -Value $detail -ErrorAction Stop
    } catch { Write-Warning 'Bootstrap failure receipt could not be written; check the administrator log and extension output.' -WarningAction Continue }
    if ($stage -eq 'disk') {
        Write-ArcBoxJournal bootstrap INFO 'After the disk failure, OS expansion, PowerShell installation, Hyper-V reboot and the SYSTEM worker were not reached in this attempt.'
    }
    if ($stage -eq 'os-volume') { $stage = 'features' }
    Write-ArcBoxHostEvent $stage failed $reason -LegacyOnly:$profileLoadFailed
    throw "ArcBox bootstrap failed [$reason]. See the local Bootstrap transcript."
} finally {
    try { Stop-Transcript | Out-Null }
    catch { Write-Warning 'Bootstrap could not close its transcript. Check the journal and extension output.' -WarningAction Continue }
}