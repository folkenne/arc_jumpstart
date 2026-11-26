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

function Format-ArcBoxWin32Refusal([int]$Code) {
    $message = @{
        2 = 'file not found'; 3 = 'path not found'; 5 = 'access denied'; 32 = 'sharing violation'
        33 = 'lock violation'; 87 = 'invalid parameter'; 193 = 'invalid executable format'; 740 = 'elevation required'
    }[$Code]
    "Windows refused process creation: $message (Win32 $Code)."
}

function New-ArcBoxStartupResult($State, $Code, $Detail) {
    [pscustomobject]@{ state = $State; exitCode = [int]$Code; detail = $Detail }
}

function Format-ArcBoxStartupSummary($Result) {
    $headline = @{
        succeeded = 'Bootstrap started and completed'
        failed = 'Bootstrap started but failed'
        not_started = 'Bootstrap did not start'
        uncertain = 'Bootstrap startup could not be confirmed'
    }[$Result.state]
    $summary = "$headline. Exit code: $($Result.exitCode). $($Result.detail)"
    if ([Text.Encoding]::UTF8.GetByteCount($summary) -gt 480 -or $summary -match '[\r\n]') {
        return "$headline. Exit code: $($Result.exitCode). Review the local startup journal."
    }
    $summary
}

function Get-ArcBoxStartFailure($ErrorRecord) {
    $failure = $ErrorRecord.Exception
    while ($failure -is [System.Management.Automation.MethodInvocationException] -and $failure.InnerException) {
        $failure = $failure.InnerException
    }
    if ($failure -is [ComponentModel.Win32Exception]) {
        $code = $failure.NativeErrorCode
        # With direct CreateProcess (.NET UseShellExecute=false, no redirected pipes), these
        # Win32 faults are synchronous refusals, not evidence of a child that later failed.
        if ($code -in 32, 33) { return @{ kind = 'transient'; code = $code } }
        if ($code -in 2, 3, 5, 87, 193, 740) { return @{ kind = 'definitive'; code = $code } }
    }
    @{ kind = 'unknown'; code = $null }
}

function Invoke-ArcBoxStartupGate {
    param([scriptblock]$Elapsed, [scriptblock]$Wait, [scriptblock]$Occupied, [scriptblock]$Record,
          [scriptblock]$Launch, [scriptblock]$Entered, [scriptblock]$ChildRunning, [scriptblock]$ChildExit,
          [scriptblock]$Claimed, [scriptblock]$FailureDetail)

    $lastTransient = $null
    while ((& $Elapsed) -lt 600000) {
        if (& $Occupied) {
            return (New-ArcBoxStartupResult uncertain 1 'A previous or unresolved attempt exists. Inspect the retained evidence; do not relaunch.')
        }
        & $Record 'DispatchRequested' $null
        if ((& $Elapsed) -ge 600000) { break }
        $response = & $Launch
        & $Record $response.kind $response.code
        switch -CaseSensitive ($response.kind) {
            'definitive' {
                return (New-ArcBoxStartupResult not_started 1 (Format-ArcBoxWin32Refusal $response.code))
            }
            'transient' {
                $lastTransient = $response.code
                $remaining = 600000 - (& $Elapsed)
                if ($remaining -gt 0) { & $Wait ([int][Math]::Min(5000, $remaining)) }
                continue
            }
            'created' {
                while ((& $Elapsed) -lt 600000) {
                    if (& $Entered) {
                        if ((& $Elapsed) -ge 600000) { break }
                        & $Record 'ScriptEntryConfirmed' $null
                        $code = & $ChildExit
                        if ($code -eq 0) {
                            if (-not (& $Claimed)) {
                                return (New-ArcBoxStartupResult uncertain 1 'The child returned success, but its persistent Bootstrap claim did not verify.')
                            }
                            return (New-ArcBoxStartupResult succeeded 0 'The child returned success. Reboot and guest readiness are separate.')
                        }
                        try { $detail = & $FailureDetail }
                        catch { $detail = 'The safe error detail was unavailable. Review the local Bootstrap evidence.' }
                        return (New-ArcBoxStartupResult failed $code $detail)
                    }
                    if (-not (& $ChildRunning)) {
                        # An exit can race the first entry read; allow one final check before declaring a gap.
                        if ((& $Elapsed) -lt 600000 -and (& $Entered)) { continue }
                        $code = & $ChildExit
                        $returnCode = if ($code -eq 0) { 1 } else { $code }
                        return (New-ArcBoxStartupResult uncertain $returnCode "The PowerShell process exited with code $code without verified script-entry evidence. Do not relaunch.")
                    }
                    $remaining = 600000 - (& $Elapsed)
                    if ($remaining -gt 0) { & $Wait ([int][Math]::Min(250, $remaining)) }
                }
                return (New-ArcBoxStartupResult uncertain 1 'No script-entry confirmation within 10 minutes. The process was not stopped or relaunched.')
            }
            default {
                return (New-ArcBoxStartupResult uncertain 1 'Process creation had an uncertain result. Do not relaunch.')
            }
        }
        if ($response.kind -ne 'transient') { break }
    }
    $detail = if ($null -ne $lastTransient) {
        "$(Format-ArcBoxWin32Refusal $lastTransient) The 10-minute window ended."
    } else { 'No process was created before the 10-minute window ended.' }
    New-ArcBoxStartupResult not_started 1 $detail
}

function Get-ArcBoxStartupFile([string]$Path) {
    try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
    catch [System.Management.Automation.ItemNotFoundException] { return }
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'An unexpected object was found at a startup evidence path.'
    }
    $item
}

function Test-ArcBoxStartupReceipt([string]$Path, [string]$Expected) {
    $item = Get-ArcBoxStartupFile $Path
    if (-not $item -or $item.Length -ne $Expected.Length) { return $false }
    try { [IO.File]::ReadAllText($Path) -ceq $Expected }
    catch [IO.IOException] { $false }
}

function Write-ArcBoxStartupRecord($Event, $Code, $Summary) {
    $line = @{ schemaVersion = 1; utc = [datetime]::UtcNow.ToString('o'); runId = $run; attemptId = $attempt
        release = $release; event = $Event; code = $Code; summary = $Summary } | ConvertTo-Json -Compress
    $stream = [IO.File]::Open($startupLog, 'Append', 'Write', 'Read')
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes("$line`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    } finally { $stream.Dispose() }
}

function New-ArcBoxBootstrapProcess($ChildPath, $ChildArguments, $ChildRun, $ChildAttempt) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    $info.WorkingDirectory = Split-Path -Parent $ChildPath
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    # Suppress unfiltered child streams without a pipe that would break if the watchdog returns.
    # Bootstrap still owns its transcript, structured evidence, and exceptions.
    $entry = @'
$ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
try {
    $data = ConvertFrom-Json $env:ARCBOX_CSE_CHILD_ARGUMENTS
    $path = $env:ARCBOX_CSE_CHILD_PATH
    Remove-Item Env:ARCBOX_CSE_CHILD_ARGUMENTS, Env:ARCBOX_CSE_CHILD_PATH
    $parameters = @{}
    foreach ($property in $data.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
    $global:LASTEXITCODE = 0
    & $path @parameters *> $null
    exit $LASTEXITCODE
} catch { exit 1 }
'@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($entry))
    $info.Arguments = "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encoded"
    $info.EnvironmentVariables['ARCBOX_CSE_CHILD_ARGUMENTS'] = ($ChildArguments | ConvertTo-Json -Compress)
    $info.EnvironmentVariables['ARCBOX_CSE_CHILD_PATH'] = $ChildPath
    $info.EnvironmentVariables['ARCBOX_CSE_STARTUP_RUN'] = $ChildRun
    $info.EnvironmentVariables['ARCBOX_CSE_STARTUP_ATTEMPT'] = $ChildAttempt
    $child = [Diagnostics.Process]::new()
    $child.StartInfo = $info
    $child
}

function Get-ArcBoxBootstrapFailureDetail($Logs, $PrivateRoot, $Attempt) {
    $path = Join-Path $Logs "Bootstrap-error-$Attempt.log"
    $file = Get-ArcBoxStartupFile $path
    if ($file -and $file.Length -le 512) {
        $match = [regex]::Match([IO.File]::ReadAllText($path),
            '\ABootstrap stage: ([a-z0-9-]{1,40}); decision: ([a-z0-9-]{1,40}); error: [A-Za-z0-9.]{1,80}; line: [0-9]{1,8}\.')
        if ($match.Success -and $script:ArcBoxHostReasons.ContainsKey($match.Groups[2].Value)) {
            return "Bootstrap reported stage '$($match.Groups[1].Value)' and diagnostic code '$($match.Groups[2].Value)'. Review the paired event for the cause."
        }
    }
    $path = Join-Path $PrivateRoot "bootstrap-early-$Attempt.log"
    $file = Get-ArcBoxStartupFile $path
    if ($file -and $file.Length -le 256) {
        $text = [IO.File]::ReadAllText($path).Trim()
        if ($text -cmatch '\ABootstrap stopped during (reviewed source and access checks|loading the shared helper|checking and claiming the attempt|preparing protected paths and the transcript) \([A-Za-z0-9]{1,80}, line [0-9]{1,8}\)\.\z') {
            return "$text Review the local startup journal and extension evidence."
        }
    }
    'No allowlisted error detail was recovered. Review the local startup and Bootstrap evidence.'
}

function Write-ArcBoxStartupSummary($Result, [scriptblock]$Local, [scriptblock]$Central) {
    $summary = Format-ArcBoxStartupSummary $Result
    try { & $Local $Result.state $Result.exitCode $summary }
    catch { $summary += ' The final startup receipt could not be written.' }
    try { & $Central $summary $Result.exitCode }
    catch { $summary += ' The workshop summary could not be written.' }
    $summary
}

function Enter-ArcBoxStartupGuard([Threading.Mutex]$Mutex) {
    try { $Mutex.WaitOne(0) }
    catch [Threading.AbandonedMutexException] { $true }
}

function Close-ArcBoxStartupResources($Child, [Threading.Mutex]$Mutex, [bool]$Owned) {
    try {
        if ($Child) { $Child.Dispose() }
    } finally {
        if ($Mutex) {
            try { if ($Owned) { $Mutex.ReleaseMutex() } }
            finally { $Mutex.Dispose() }
        }
    }
}

$result = New-ArcBoxStartupResult not_started 1 'The startup preconditions could not be verified.'
$guard = $child = $null
$held = $journalReady = $dispatchPossible = $false
try {
try {
    $arguments = @{}; foreach ($item in $PSBoundParameters.GetEnumerator()) { $arguments[$item.Key] = $item.Value }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
        throw 'The startup control requires SYSTEM.'
    }
    $options = ConvertFrom-Json ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bootstrapOptionsBase64)))
    if ($options.runId -isnot [string] -or $options.runId -cnotmatch '\A[a-f0-9]{32}\z' -or
        $templateBaseUrl -cnotmatch '\Ahttps://raw\.githubusercontent\.com/folkenne/arc_jumpstart/([a-f0-9]{40})/azure_arc_servers_jumpstart/\z') {
        throw 'Expected an immutable artifact ref and explicit Run 0010 run identity.'
    }
    $release = $Matches[1]
    $run = $options.runId
    $attempt = [guid]::NewGuid().ToString('N')
    . (Join-Path $PSScriptRoot 'ArcBox.Host.ps1')
    $childPath = Join-Path $PSScriptRoot 'Bootstrap.ps1'
    if (-not (Get-ArcBoxStartupFile $childPath)) { throw 'The pinned Bootstrap script was not staged.' }

    $guard = [Threading.Mutex]::new($false, 'Global\ArcBoxBootstrapStartup')
    $held = Enter-ArcBoxStartupGuard $guard
    if (-not $held) {
        $result = New-ArcBoxStartupResult uncertain 1 'Another startup controller is active. Do not relaunch.'
    } else {
        $privateRoot = Split-Path -Parent (Split-Path -Parent (Get-ArcBoxPrivateScriptPath -Attempt $attempt))
        $null = New-Item -Path $privateRoot -ItemType Directory -Force
        Protect-ArcBoxDirectory $privateRoot
        $claim = Join-Path $privateRoot 'bootstrap.started'
        $startupLog = Join-Path $privateRoot 'bootstrap-startup.jsonl'
        $entryPath = Join-Path $privateRoot "bootstrap-entry-$attempt"
        $logs = 'C:\ArcBox\Logs'
        $occupied = { (Get-ArcBoxStartupFile $claim) -or [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine') }
        $priorStartup = Get-ArcBoxStartupFile $startupLog
        $journalReady = $true
        if ((& $occupied) -or $priorStartup) {
            $result = New-ArcBoxStartupResult uncertain 1 'A prior startup journal or Bootstrap claim exists. No new process was created.'
        } else {
            Write-ArcBoxStartupRecord 'StartupOpened' $null 'The CSE startup control opened one diagnostic window.'
            $child = New-ArcBoxBootstrapProcess $childPath $arguments $run $attempt
            $clock = [Diagnostics.Stopwatch]::new()
            $dispatchPossible = $true
            $result = Invoke-ArcBoxStartupGate -Elapsed { $clock.ElapsedMilliseconds } -Wait {
                param($milliseconds) Start-Sleep -Milliseconds $milliseconds
            } -Occupied $occupied -Record {
                param($event, $code) Write-ArcBoxStartupRecord $event $code $null
            } -Launch {
                if (-not $clock.IsRunning) { $clock.Start() }
                try {
                    if ($child.Start()) { @{ kind = 'created'; code = $null } }
                    else { @{ kind = 'unknown'; code = $null } }
                } catch { Get-ArcBoxStartFailure $_ }
            } -Entered {
                (Test-ArcBoxStartupReceipt $entryPath "$run/$attempt") -or (Test-ArcBoxStartupReceipt $claim $attempt)
            } -ChildRunning { -not $child.HasExited } -ChildExit {
                $child.WaitForExit()
                $child.ExitCode
            } -Claimed {
                Test-ArcBoxStartupReceipt $claim $attempt
            } -FailureDetail { Get-ArcBoxBootstrapFailureDetail $logs $privateRoot $attempt }
        }
    }
} catch {
    if ($dispatchPossible) {
        $result = New-ArcBoxStartupResult uncertain 1 'A startup evidence or process read failed. Do not relaunch.'
    }
}

$summary = Format-ArcBoxStartupSummary $result
if ($journalReady) {
    $summary = Write-ArcBoxStartupSummary $result -Local {
        param($state, $code, $text)
        Write-ArcBoxStartupRecord $state $code $text
    } -Central {
        param($text, $code)
        if ((Get-ArcBoxStartupFile (Join-Path $logs 'WorkshopDeployment.log')) -and
            (Test-ArcBoxStartupReceipt $claim $attempt) -and
            [Environment]::GetEnvironmentVariable('ArcBoxRunId', 'Machine') -ceq $run -and
            [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine') -ceq $attempt) {
            Start-ArcBoxJournal -ScriptName 'Invoke-ArcBoxBootstrapStartup.ps1' -Boot (Get-ArcBoxBootTime) -Release $release
            $level = if ($code -eq 0) { 'INFO' } else { 'ERROR' }
            Write-ArcBoxJournal bootstrap $level $text -Milestone -Durable -NextCheck 'Review the local startup journal for process and attempt evidence.'
        }
    }
}
} finally {
    try { Close-ArcBoxStartupResources $child $guard $held }
    catch { $summary = "$(Format-ArcBoxStartupSummary $result) A temporary handle did not close cleanly." }
}
Write-Output $summary
exit $result.exitCode
