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
function Save-ArcBoxBootstrapArtifact([string]$RelativePath,[string]$Destination) {
    Invoke-ArcBoxOperation artifacts 'Download artifact' $RelativePath {
        Invoke-WebRequest ($templateBaseUrl + "artifacts/$RelativePath") -OutFile $Destination
    }
}
Save-ArcBoxBootstrapArtifact 'ArcBox.Machine.ps1' (Join-Path $work 'ArcBox.Machine.ps1')
. (Join-Path $work 'ArcBox.Machine.ps1')
Write-ArcBoxJournal artifacts INFO 'Machine package helper loaded; no installer has been dispatched.' -Owner 'ArcBox.Machine.ps1'
$fallback = 'winget-setup'
Assert-ArcBoxMachinePackages $options.machinePackages
$fallback = 'artifact-download'
$bootMarker = Join-Path $work 'PreparedOnBoot.txt'
Invoke-ArcBoxOperation artifacts 'Receive pinned script' 'ArcServersLogonScript.ps1' {
    Receive-ArcBoxPinnedScript $templateBaseUrl 'ArcServersLogonScript.ps1' $privateScript
}
Invoke-ArcBoxOperation artifacts 'Receive pinned script' 'testDefenderForSQL.ps1' {
    Receive-ArcBoxPinnedScript $templateBaseUrl 'testDefenderForSQL.ps1' (Join-Path $work 'testDefenderForSQL.ps1')
}
Invoke-ArcBoxOperation artifacts 'Receive pinned script' 'SqlAdvancedThreatProtectionShell.psm1' {
    Receive-ArcBoxPinnedScript $templateBaseUrl 'SqlAdvancedThreatProtectionShell.psm1' (Join-Path $Env:ArcBoxDir 'SqlAdvancedThreatProtectionShell.psm1')
}
Invoke-ArcBoxOperation artifacts 'Save protected worker inputs' 'Inputs.json' {
    [IO.File]::WriteAllText((Join-Path $work 'Inputs.json'), ([ordered]@{
        disk = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dataDiskIdBase64))
        machinePackages = $options.machinePackages
    } | ConvertTo-Json -Depth 6 -Compress))
}
# The startup worker is a service task, not a desktop logon.
$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
Invoke-ArcBoxOperation bootstrap 'Disable automatic logon' 'Winlogon' {
    Set-ItemProperty -LiteralPath $winlogon -Name AutoAdminLogon -Value '0'
}
if ((Get-Item -LiteralPath $winlogon).Property -contains 'DefaultPassword') {
    Invoke-ArcBoxOperation bootstrap 'Remove obsolete automatic logon value' 'Winlogon' {
        Remove-ItemProperty -LiteralPath $winlogon -Name DefaultPassword
    }
}

# Copy PowerShell Profile and Reload
$stage = 'artifacts'
$fallback = 'artifact-download'
$profileFile = Join-Path $PSHOME 'Profile.ps1'
Save-ArcBoxBootstrapArtifact 'PSProfile.ps1' $profileFile
Write-ArcBoxJournal artifacts INFO 'Loading the lab PowerShell profile.' -Owner 'PSProfile.ps1'
$profileOperation = Start-ArcBoxOperation artifacts 'Load Windows PowerShell profile' 'PSProfile.ps1'
try { . $profileFile }
catch {
    $profileLoadFailed = $true
    $profileFailure = $_
    try { Complete-ArcBoxOperation artifacts $profileOperation -Failure $profileFailure }
    catch { Write-Warning 'Profile load failed; paired operation result was not verified.' }
    Write-ArcBoxJournal artifacts ERROR 'The Windows PowerShell lab profile could not load. Bootstrap stopped before PowerShell installation or reboot; check the profile source and Bootstrap transcript.' `
        -Owner 'PSProfile.ps1' -Failure $profileFailure -Operation 'Load Windows PowerShell lab profile' `
        -Detail @{profile='Profile.ps1'; engine='Windows PowerShell 5.1'; outcome='load-failed'} -LastConfirmed 'The profile was staged; it did not finish loading.'
    throw $profileFailure
}
Complete-ArcBoxOperation artifacts $profileOperation
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
    $afterSize = Invoke-ArcBoxOperation os-volume 'Resize and verify OS partition' 'C:' {
        Resize-Partition -DriveLetter C -Size $osSize
        $size = (Get-Partition -DriveLetter C -ErrorAction Stop).Size
        if ($size -ne $osSize) { throw 'C: expansion returned but the requested capacity did not verify.' }
        $size
    }
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
Invoke-ArcBoxOperation powershell 'Install lab profile' 'PowerShell 7 Profile.ps1' {
    Copy-Item -LiteralPath $profileFile -Destination (Join-Path (Split-Path -Parent $pwsh) 'Profile.ps1') -Force
}
Write-ArcBoxHostEvent powershell ok

$stage = 'modules'
$fallback = 'module-setup'
Write-ArcBoxHostEvent modules start
$moduleHelper = Join-Path $work 'ArcBox.Modules.ps1'
$moduleLock = Join-Path $work 'ArcBox.Modules.lock.json'
Save-ArcBoxBootstrapArtifact 'ArcBox.Modules.ps1' $moduleHelper
Save-ArcBoxBootstrapArtifact 'ArcBox.Modules.lock.json' $moduleLock
. $moduleHelper
Install-ArcBoxLockedModules -LockPath $moduleLock -Work $work -Pwsh $pwsh
Write-ArcBoxHostEvent modules ok

$stage = 'disk'
$fallback = 'disk-discovery'
Write-ArcBoxHostEvent disk start
$diskId = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($dataDiskIdBase64))
Initialize-ArcBoxDataDrive -ExpectedId $diskId
Invoke-ArcBoxOperation disk 'Create guest storage directory' 'F: Virtual Machines' {
    New-Item -Path $Env:ArcBoxVMDir -ItemType directory -Force | Out-Null
}
Invoke-ArcBoxOperation disk 'Protect guest storage directory' 'F: Virtual Machines' {
    Protect-ArcBoxDirectory -Path $Env:ArcBoxVMDir
}
Write-ArcBoxHostEvent disk ok
if ($performanceDir) {
    try { [IO.File]::WriteAllText("$performanceDir\disk-ready.txt", 'F:') }
    catch { Write-ArcBoxHostEvent performance failed performance }
}

# Installing DHCP service
$stage = 'features'
$fallback = 'windows-features'
Write-Output "Installing DHCP service"
Invoke-ArcBoxOperation features 'Install Windows feature' 'DHCP' {
    if (-not (Install-WindowsFeature -Name DHCP -IncludeManagementTools).Success) {
        throw 'DHCP feature installation failed.'
    }
}
# PowerShell SSH remoting needs a machine client, not one registered in a student profile.
$openSsh = 'OpenSSH.Client~~~~0.0.1.0'
if ((Get-WindowsCapability -Online -Name $openSsh).State -ne 'Installed') {
    Invoke-ArcBoxOperation features 'Install Windows capability' 'OpenSSH.Client' {
        Add-WindowsCapability -Online -Name $openSsh | Out-Null
    }
}

$stage = 'artifacts'
$fallback = 'artifact-download'
Write-ArcBoxHostEvent artifacts start
Write-Header "Fetching GitHub Artifacts"

# All flavors
Write-Host "Fetching Artifacts for All Flavors"
Invoke-ArcBoxOperation artifacts 'Download lab wallpaper' 'arcbox_wallpaper_dark.png' {
    Invoke-WebRequest 'https://raw.githubusercontent.com/azure/arc_jumpstart_docs/main/img/wallpaper/arcbox_wallpaper_dark.png' -OutFile $Env:ArcBoxDir\wallpaper.png
}
Save-ArcBoxBootstrapArtifact 'MonitorWorkbookLogonScript.ps1' (Join-Path $work 'MonitorWorkbookLogonScript.ps1')
Save-ArcBoxBootstrapArtifact 'mgmtMonitorWorkbook.parameters.json' "$Env:ArcBoxDir\mgmtMonitorWorkbook.parameters.json"
Save-ArcBoxBootstrapArtifact 'monitoring/arc-inventory-workbook.json' "$Env:ArcBoxDir\arc-inventory-workbook.json"
Save-ArcBoxBootstrapArtifact 'monitoring/arc-osperformance-workbook.json' "$Env:ArcBoxDir\arc-osperformance-workbook.json"
Save-ArcBoxBootstrapArtifact 'LogInstructions.txt' "$Env:ArcBoxLogsDir\LogInstructions.txt"
Save-ArcBoxBootstrapArtifact 'dsc/common.dsc.yml' "$Env:ArcBoxDscDir\common.dsc.yml"
Save-ArcBoxBootstrapArtifact 'WinGet.ps1' (Join-Path $work 'WinGet.ps1')
Invoke-ArcBoxOperation artifacts 'Stage worker helper' 'ArcBox.Host.ps1' {
    Copy-Item -LiteralPath $hostHelper -Destination (Join-Path $work 'ArcBox.Host.ps1')
}
Save-ArcBoxBootstrapArtifact 'squid.conf' "$Env:ArcBoxDir\squid.conf"
Save-ArcBoxBootstrapArtifact 'whitelist.txt' "$Env:ArcBoxDir\whitelist.txt"
Save-ArcBoxBootstrapArtifact 'ct.txt' "$Env:ArcBoxDir\ct.txt"

# Workbook template
Save-ArcBoxBootstrapArtifact 'mgmtMonitorWorkbookITPro.json' "$Env:ArcBoxDir\mgmtMonitorWorkbook.json"

Write-Host "Fetching Artifacts"
Save-ArcBoxBootstrapArtifact 'installArcAgent.ps1' "$Env:ArcBoxDir\agentScript\installArcAgent.ps1"
Save-ArcBoxBootstrapArtifact 'installArcAgentUbuntu.sh' "$Env:ArcBoxDir\agentScript\installArcAgentUbuntu.sh"
Save-ArcBoxBootstrapArtifact 'testDefenderForServers.cmd' "$Env:ArcBoxDir\agentScript\testDefenderForServers.cmd"
Save-ArcBoxBootstrapArtifact 'InstallArcSQLExtensionAtScale.ps1' "$Env:ArcBoxDir\InstallArcSQLExtensionAtScale.ps1"
Save-ArcBoxBootstrapArtifact 'AdventureWorksLT2019.bak' "$Env:ArcBoxDir\AdventureWorksLT2019.bak"
Save-ArcBoxBootstrapArtifact 'dsc/itpro.dsc.yml' "$Env:ArcBoxDscDir\itpro.dsc.yml"
Save-ArcBoxBootstrapArtifact 'dsc/virtual_machines_itpro.dsc.yml' "$Env:ArcBoxDscDir\virtual_machines_itpro.dsc.yml"
Write-ArcBoxHostEvent artifacts ok

$stage = 'features'
$fallback = 'windows-features'
$RegistryPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
if (-not (Test-Path -LiteralPath $RegistryPath)) {
    Invoke-ArcBoxOperation features 'Create browser policy key' 'Microsoft Edge' {
        New-Item -Path $RegistryPath -Force | Out-Null
    }
}
Invoke-ArcBoxOperation features 'Disable browser sidebar' 'Microsoft Edge' {
    New-ItemProperty -Path $RegistryPath -Name HubsSidebarEnabled -Value '00000000' -PropertyType DWORD -Force | Out-Null
}
Invoke-ArcBoxOperation features 'Hide browser first-run experience' 'Microsoft Edge' {
    New-ItemProperty -Path $RegistryPath -Name HideFirstRunExperience -Value '00000001' -PropertyType DWORD -Force | Out-Null
}
$serverManagerTask = Get-ScheduledTask -TaskName ServerManager -ErrorAction SilentlyContinue
if ($serverManagerTask) {
    Invoke-ArcBoxOperation tasks 'Disable scheduled task' 'ServerManager' {
        $serverManagerTask | Disable-ScheduledTask | Out-Null
    }
}

Write-Header "Installing Hyper-V"
Write-ArcBoxHostEvent features start
Invoke-ArcBoxOperation features 'Enable Windows optional feature' 'Containers' {
    Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart
}
Invoke-ArcBoxOperation features 'Enable Windows optional feature' 'VirtualMachinePlatform' {
    Enable-WindowsOptionalFeature -Online -FeatureName VirtualMachinePlatform -NoRestart
}
Invoke-ArcBoxOperation features 'Install Windows feature' 'Hyper-V' {
    if (-not (Install-WindowsFeature -Name Hyper-V -IncludeAllSubFeature -IncludeManagementTools).Success) {
        throw 'Hyper-V feature installation failed.'
    }
}
Write-ArcBoxHostEvent features ok

$stage = 'tasks'
$fallback = 'task-register'
Write-ArcBoxHostEvent tasks start
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4)
$action = New-ScheduledTaskAction -Execute $pwsh -Argument (Get-ArcBoxStartupArguments $work) -WorkingDirectory $work
Invoke-ArcBoxOperation tasks 'Register startup task' 'ArcBox-PostReboot' {
    Register-ScheduledTask -TaskName 'ArcBox-PostReboot' -TaskPath '\' -Principal $principal -Settings $settings `
        -Trigger (New-ScheduledTaskTrigger -AtStartup) -Action $action -ErrorAction Stop | Out-Null
}
# Presentation only; this logon task cannot provision or determine readiness.
$labUser = "$env:COMPUTERNAME\$adminUsername"
$desktop = New-ScheduledTaskAction -Execute $pwsh -Argument '-NoProfile -NonInteractive -Command "Import-Module Azure.Arc.Jumpstart.Common -ErrorAction Stop; Set-JSDesktopBackground -ImagePath C:\ArcBox\wallpaper.bmp"'
Invoke-ArcBoxOperation tasks 'Register student presentation task' 'ArcBox-Presentation' {
    Register-ScheduledTask -TaskName 'ArcBox-Presentation' -TaskPath '\' `
        -Principal (New-ScheduledTaskPrincipal -UserId $labUser -LogonType Interactive) `
        -Trigger (New-ScheduledTaskTrigger -AtLogOn -User $labUser) -Action $desktop -ErrorAction Stop | Out-Null
}
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
Invoke-ArcBoxOperation reboot 'Save prepared boot checkpoint' 'PreparedOnBoot.txt' {
    Set-Content -LiteralPath $bootMarker -Value $clientBoot -Encoding ASCII
}
Invoke-ArcBoxOperation reboot 'Schedule client reboot' 'ArcBoxClientReboot' {
    Register-ScheduledTask -TaskName 'ArcBoxClientReboot' -TaskPath '\' -User SYSTEM -RunLevel Highest -Trigger $reboot -Action $rebootAction -Settings $rebootSettings -Force | Out-Null
}
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
        Write-ArcBoxJournal bootstrap INFO 'The lab data disk did not verify. Hyper-V reboot and the SYSTEM worker were not reached in this attempt.'
    }
    if ($stage -eq 'os-volume') { $stage = 'features' }
    Write-ArcBoxHostEvent $stage failed $reason -LegacyOnly:$profileLoadFailed
    throw "ArcBox bootstrap failed [$reason]. See the local Bootstrap transcript."
} finally {
    try { Stop-Transcript | Out-Null }
    catch { Write-Warning 'Bootstrap could not close its transcript. Check the journal and extension output.' -WarningAction Continue }
}