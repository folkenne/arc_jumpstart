$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
. (Join-Path $PSScriptRoot 'ArcBox.Host.ps1')
. (Join-Path $PSScriptRoot 'ArcBox.Machine.ps1')

$attempt = [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine')
$privateScript = Get-ArcBoxPrivateScriptPath -Attempt $attempt
$work = Split-Path -Parent $privateScript
$pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
if ($PSScriptRoot -ine $work -or [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18' -or
    $PSVersionTable.PSVersion.ToString() -cne '7.6.10') {
    Stop-ArcBoxHostStep task-dispatch 'Expected the reviewed startup worker as SYSTEM under PowerShell 7.6.10.'
}
# The file handle is a process-wide gate, not a phase-completion marker. It is released on interruption.
try { $lock = [IO.File]::Open((Join-Path $work 'startup.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch [IO.IOException] { Stop-ArcBoxHostStep checkpoint 'Another startup worker owns the attempt lock.' }
$transcribing = $false
try {
    if (Test-Path -LiteralPath (Join-Path $work 'post-reboot.ok')) { return }
    Start-Transcript -Path "C:\ArcBox\Logs\WinGet-provisioning-$attempt.log" -Append | Out-Null
    $transcribing = $true
    $boot = Get-ArcBoxBootTime
    $artifactBase = [Environment]::GetEnvironmentVariable('templateBaseUrl', 'Machine')
    Start-ArcBoxJournal -ScriptName 'WinGet.ps1' -Boot $boot -Release (($artifactBase -split '/')[5])
    Write-ArcBoxJournal post-reboot INFO 'SYSTEM startup worker entered. Checking the registered task and Hyper-V reboot.'
    Write-ArcBoxJournal artifacts INFO 'Loading the PowerShell 7 lab profile.' -Owner 'PSProfile.ps1'
    try { . (Join-Path $PSHOME 'Profile.ps1') }
    catch {
        Write-ArcBoxJournal artifacts ERROR 'PowerShell 7 lab profile stopped before the startup worker could continue.' `
            -Owner 'PSProfile.ps1' -Failure $_ -Operation 'Load PowerShell lab profile'
        throw
    }
    Write-ArcBoxJournal artifacts INFO 'PowerShell 7 lab profile loaded.' -Owner 'PSProfile.ps1'
    $task = Get-ScheduledTask -TaskPath '\' -TaskName 'ArcBox-PostReboot'
    $action = @($task.Actions)
    if ($task.Principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18') -or
        $action.Count -ne 1 -or $action[0].Execute -ine $pwsh -or
        $action[0].Arguments -cne (Get-ArcBoxStartupArguments $work) -or $action[0].WorkingDirectory -ine $work -or
        $task.Principal.LogonType -ne 'ServiceAccount') {
        Stop-ArcBoxHostStep task-dispatch 'The registered SYSTEM startup task does not match the reviewed worker.'
    }
    $prepared = (Get-Content -LiteralPath (Join-Path $work 'PreparedOnBoot.txt') -Raw).Trim()
    # Startup can precede vmms; wait only for service readiness, not for a desktop.
    (Get-Service -Name vmms).WaitForStatus('Running', (New-TimeSpan -Minutes 3))
    Assert-ArcBoxPostReboot -PreparedOnBoot $prepared -CurrentBoot $boot -HyperVRunning $true
    Write-ArcBoxHostEvent reboot ok
    $inputFile = Get-Content -LiteralPath (Join-Path $work 'Inputs.json') -Raw | ConvertFrom-Json
    $pins = Get-ArcBoxScriptPins -TemplateBaseUrl $artifactBase
    $sqlHelper = Join-Path $work 'testDefenderForSQL.ps1'
    $sqlModule = 'C:\ArcBox\SqlAdvancedThreatProtectionShell.psm1'
    # Revalidate the attachment and already-prepared drive before doing any guest work.
    Initialize-ArcBoxDataDrive -ExpectedId $inputFile.disk -VerifyOnly
    Assert-ArcBoxMachinePackages $inputFile.machinePackages
    Write-ArcBoxHostEvent post-reboot start
    Invoke-ArcBoxCheckpoint $work dsc-common winget-setup {
        Invoke-ArcBoxLoggedScript 'ArcBox.Machine.ps1' 'Packages' {
            Install-ArcBoxMachinePackages -Packages $inputFile.machinePackages -Work $work
        }
    }
    Invoke-ArcBoxCheckpoint $work dsc-itpro dsc-config {
        Invoke-ArcBoxLoggedScript 'ArcBox.Machine.ps1' 'Hyper-V configuration' { Set-ArcBoxHyperVHost }
    }
    # Rehydrate the machine PATH even when the package checkpoints were already complete.
    $openSsh = Join-Path $env:SystemRoot 'System32\OpenSSH'
    if (-not (Test-Path -LiteralPath (Join-Path $openSsh 'ssh.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $openSsh 'ssh-keygen.exe') -PathType Leaf)) {
        Stop-ArcBoxHostStep guest-access 'Windows OpenSSH Client is missing after reboot.'
    }
    $env:Path = "$openSsh;" + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ";$env:ProgramFiles\ArcBoxTools"
    Invoke-ArcBoxCheckpoint $work servers guest-access {
        . (Join-Path $work 'ArcBox.Modules.ps1')
        $moduleRoot = Join-Path $env:ProgramFiles 'PowerShell\Modules'
        Set-ArcBoxProvisioningModulePath $moduleRoot
        $moduleLock = Read-ArcBoxModuleLock (Join-Path $work 'ArcBox.Modules.lock.json')
        foreach ($pin in Get-ArcBoxProvisioningPins $moduleLock) {
            $manifest = Join-Path $moduleRoot "$($pin.name)\$($pin.version)\$($pin.name).psd1"
            Invoke-ArcBoxOperation modules 'Import locked module' $pin.name {
                Import-ArcBoxProvisioningModule $pin $manifest $moduleRoot
            } -Version $pin.version -Repository 'Verified machine modules'
        }
        Assert-ArcBoxPrivateScript $privateScript $pins['ArcServersLogonScript.ps1'].Sha256
        Assert-ArcBoxPrivateScript $sqlHelper $pins['testDefenderForSQL.ps1'].Sha256
        Assert-ArcBoxPrivateScript $sqlModule $pins['SqlAdvancedThreatProtectionShell.psm1'].Sha256
        # Preserve the upstream WorkshopPLUS lab credential for nested PowerShell Direct.
        $nestedWindowsUsername = "Administrator"
        $nestedWindowsPassword = "JS123!!"
        $credential = [pscredential]::new($nestedWindowsUsername,
            (ConvertTo-SecureString -String $nestedWindowsPassword -AsPlainText -Force))
        $nestedWindowsPassword = $null
        try {
            Invoke-ArcBoxLoggedScript 'ArcServersLogonScript.ps1' 'Nested guest setup' {
                & $privateScript -SqlHelperPath $sqlHelper -SqlHelperSha256 $pins['testDefenderForSQL.ps1'].Sha256 -WindowsCredential $credential
            }
        } finally {
            $credential.Password.Dispose()
        }
    }
    Invoke-ArcBoxCheckpoint $work workbook workbook {
        Invoke-ArcBoxLoggedScript 'MonitorWorkbookLogonScript.ps1' 'Workbook setup' {
            & (Join-Path $work 'MonitorWorkbookLogonScript.ps1')
        }
    }
    $finished = (Get-Date).ToUniversalTime().ToString('o')
    $completion = [ordered]@{
        attempt = $attempt
        run = [Environment]::GetEnvironmentVariable('ArcBoxRunId', 'Machine')
        preparedOnBoot = $prepared
        boot = $boot
        completedAt = $finished
    }
    [IO.File]::WriteAllText((Join-Path $work 'post-reboot.pending'), ($completion | ConvertTo-Json -Compress))
    [IO.File]::Move((Join-Path $work 'post-reboot.pending'), (Join-Path $work 'post-reboot.ok'))
    Write-ArcBoxHostEvent post-reboot ok
    Write-ArcBoxJournal post-reboot INFO 'SYSTEM completion marker written for this attempt and boot. The six-guest handoff still requires independent verification.'
} catch {
    Write-ArcBoxJournal post-reboot ERROR 'SYSTEM worker stopped. Unreached or externally dispatched stages are not verified; inspect the worker log and checkpoints.' `
        -Failure $_ -Operation 'SYSTEM startup worker' -LastConfirmed 'See the last completed checkpoint for this attempt.'
    Write-ArcBoxHostEvent post-reboot failed (Get-ArcBoxHostFailureCode $_ 'checkpoint')
    throw
} finally {
    $lock.Dispose()
    if ($transcribing) {
        try { Stop-Transcript | Out-Null }
        catch { Write-Warning 'The SYSTEM worker could not close its transcript; check the administrator journals.' -WarningAction Continue }
    }
}
