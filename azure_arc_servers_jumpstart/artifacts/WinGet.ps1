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
    . (Join-Path $PSHOME 'Profile.ps1')
    $task = Get-ScheduledTask -TaskPath '\' -TaskName 'ArcBox-PostReboot'
    $action = @($task.Actions)
    if ($task.Principal.UserId -notin @('SYSTEM','NT AUTHORITY\SYSTEM','S-1-5-18') -or
        $action.Count -ne 1 -or $action[0].Execute -ine $pwsh -or
        $action[0].Arguments -cne (Get-ArcBoxStartupArguments $work) -or $action[0].WorkingDirectory -ine $work -or
        $task.Principal.LogonType -ne 'ServiceAccount') {
        Stop-ArcBoxHostStep task-dispatch 'The registered SYSTEM startup task does not match the reviewed worker.'
    }
    $boot = Get-ArcBoxBootTime
    $prepared = (Get-Content -LiteralPath (Join-Path $work 'PreparedOnBoot.txt') -Raw).Trim()
    # Startup can precede vmms; wait only for service readiness, not for a desktop.
    (Get-Service -Name vmms).WaitForStatus('Running', (New-TimeSpan -Minutes 3))
    Assert-ArcBoxPostReboot -PreparedOnBoot $prepared -CurrentBoot $boot -HyperVRunning $true
    Write-ArcBoxHostEvent reboot ok
    $inputFile = Get-Content -LiteralPath (Join-Path $work 'Inputs.json') -Raw | ConvertFrom-Json
    $sqlHelper = Join-Path $work 'testDefenderForSQL.ps1'
    Assert-ArcBoxPrivateScript $privateScript $inputFile.serversHash
    Assert-ArcBoxPrivateScript $sqlHelper $inputFile.sqlHelperHash
    # Revalidate the attachment and already-prepared drive before doing any guest work.
    Initialize-ArcBoxDataDrive -ExpectedId $inputFile.disk -VerifyOnly
    Assert-ArcBoxMachinePackages $inputFile.machinePackages
    Write-ArcBoxHostEvent post-reboot start
    Invoke-ArcBoxCheckpoint $work dsc-common winget-setup {
        Install-ArcBoxMachinePackages -Packages $inputFile.machinePackages -Work $work
    }
    Invoke-ArcBoxCheckpoint $work dsc-itpro dsc-config {
        Install-ArcBoxMachinePackages -Packages $inputFile.machinePackages -Work $work -ItPro
        Set-ArcBoxHyperVHost
    }
    # Rehydrate the machine PATH even when the package checkpoints were already complete.
    $openSsh = Join-Path $env:SystemRoot 'System32\OpenSSH'
    if (-not (Test-Path -LiteralPath (Join-Path $openSsh 'ssh.exe') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $openSsh 'ssh-keygen.exe') -PathType Leaf)) {
        Stop-ArcBoxHostStep guest-access 'Windows OpenSSH Client is missing after reboot.'
    }
    $env:Path = "$openSsh;" + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ";$env:ProgramFiles\ArcBoxTools"
    Invoke-ArcBoxCheckpoint $work servers guest-access {
        Assert-ArcBoxPrivateScript $privateScript $inputFile.serversHash
        $credential = Get-ArcBoxNestedCredential $inputFile.nestedWindowsCredentialUri
        try {
            & $privateScript -SqlHelperPath $sqlHelper -SqlHelperSha256 $inputFile.sqlHelperHash -WindowsCredential $credential
        } finally {
            $credential.Password.Dispose()
        }
    }
    Invoke-ArcBoxCheckpoint $work workbook workbook {
        & (Join-Path $work 'MonitorWorkbookLogonScript.ps1')
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
    Write-ArcBoxHostEvent post-reboot ok
    [IO.File]::Move((Join-Path $work 'post-reboot.pending'), (Join-Path $work 'post-reboot.ok'))
} catch {
    Write-ArcBoxHostEvent post-reboot failed (Get-ArcBoxHostFailureCode $_ 'checkpoint')
    throw
} finally {
    $lock.Dispose()
    if ($transcribing) { Stop-Transcript | Out-Null }
}
