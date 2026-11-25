$script:ArcBoxHostReasons = @{
    'disk-contract' = 'Check the configured managed disk ID and its unique IMDS attachment and LUN.'
    'disk-discovery' = 'Check IMDS and the Windows storage presentation for the intended disk.'
    'disk-identity' = 'Compare the Windows location and controller evidence for the intended Azure LUN.'
    'disk-letter' = 'Check which partition owns F:; no disk was initialized.'
    'disk-layout' = 'Inspect the existing partition layout. Do not reformat.'
    'disk-drift' = 'The disk or drive ownership changed. Inspect it before retrying.'
    'disk-write' = 'Inspect partial disk state before any recovery or retry.'
    'ps-existing' = 'Inspect the existing PowerShell executable before replacing it.'
    'ps-download' = 'Check access to the pinned PowerShell release asset.'
    'ps-signature' = 'Check the MSI publisher and the client certificate trust chain.'
    'ps-install' = 'Inspect the local MSI error and Windows Installer events.'
    'ps-restart' = 'An unexpected MSI reboot occurred. Check the client boot state.'
    'ps-probe' = 'Check that the absolute pwsh path starts version 7.6.10.'
    'artifact-download' = 'Verify the approved artifact commits and client HTTPS reachability.'
    'artifact-pin' = 'Check the successor artifact source, output filename and bootstrap inputs.'
    'private-config' = 'Check the protected local provisioning directory and attempt ID.'
    'private-hash' = 'Compare the staged artifact with the approved SHA-256 before retrying.'
    'nested-credential-read' = 'Check the immutable Level Up artifact source and the expected legacy lab credential schema.'
    'performance' = 'Check the local sampler task; guest setup does not depend on it.'
    'module-setup' = 'Inspect local PowerShell Gallery and module import errors.'
    'windows-features' = 'Inspect Windows feature installation and servicing state.'
    'task-register' = 'Check task registration, account and verified pwsh path.'
    'reboot-pending' = 'Wait for the prepared Hyper-V reboot before dispatching lab setup.'
    'winget-setup' = 'Check reviewed machine installer pins, exit codes and installed tools.'
    'machine-reboot-required' = 'Inspect the installer and servicing state before any approved recovery reboot.'
    'dsc-config' = 'Check the required machine configuration and observed Hyper-V state.'
    'checkpoint' = 'Inspect the saved attempt; do not replay an interrupted mutating phase.'
    'workbook' = 'Inspect the named workbook ARM operation and its terminal result.'
    'task-dispatch' = 'Inspect the exact downstream task and its last result.'
    'guest-access' = 'Check the VM switch, distinct IPv4 leases and SSH readiness.'
    'proxy-config' = 'Check the Proxy VM, loaded Squid configuration and baseline allowlist.'
    'arc-inventory' = 'Check the current run inventory, identity permissions and guest agent logs.'
    'arc-feature' = 'Check feature request errors and terminal status for the baseline pair.'
}

function Stop-ArcBoxHostStep {
    param([string]$Code, [string]$Detail)
    $failure = [InvalidOperationException]::new($Detail)
    $failure.Data['ArcBoxReason'] = $Code
    throw $failure
}

function Start-ArcBoxJournal {
    param([string]$ScriptName, [string]$Boot, [string]$Release, [string]$Root = 'C:\ArcBox\Logs')
    if ($ScriptName -cnotmatch '\A[A-Za-z][A-Za-z0-9.-]+\.(?:ps1|sh)\z') { throw 'Invalid log owner.' }
    $script:ArcBoxJournal = @{
        script=$ScriptName; root=$Root; boot=$Boot; release=$Release; clocks=@{}
        run=[Environment]::GetEnvironmentVariable('ArcBoxRunId','Machine')
        attempt=[Environment]::GetEnvironmentVariable('ArcBoxAttemptId','Machine')
    }
}

function Initialize-ArcBoxJournalLayout {
    param([string]$Root)
    foreach ($name in 'scripts','events') {
        $path = Join-Path $Root $name
        New-Item -Path $path -ItemType Directory -Force -ErrorAction Stop | Out-Null
        Protect-ArcBoxDirectory -Path $path
    }
}

function Format-ArcBoxJournalUtc {
    param([string]$Value)
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParseExact($Value, [string[]]@('o','yyyy-MM-ddTHH:mm:ssK','yyyy-MM-ddTHH:mm:ss.FFFFFFFK'),
            [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) {
        return $parsed.UtcDateTime.ToString("yyyy-MM-dd HH:mm:ss 'UTC'", [Globalization.CultureInfo]::InvariantCulture)
    }
    return 'unknown'
}

function Format-ArcBoxJournalDetail {
    param($Value, [string]$Key)
    if ($null -eq $Value) { return }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($name in ($Value.Keys | Sort-Object)) {
            Format-ArcBoxJournalDetail $Value[$name] "$(if ($Key) { "$Key." })$name"
        }
    } elseif ($Value -is [array]) {
        for ($i = 0; $i -lt $Value.Count; $i++) { Format-ArcBoxJournalDetail $Value[$i] "$Key[$i]" }
    } else {
        if ($Value -is [string] -and $Value -cmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})\z') {
            $Value = Format-ArcBoxJournalUtc $Value
        }
        "  ${Key}: $Value"
    }
}

function Write-ArcBoxJournal {
    param(
        [string]$Stage, [ValidateSet('INFO','WARNING','ERROR')][string]$Severity, [string]$Headline,
        [object]$Detail, [string]$Operation, [string]$LastConfirmed, [System.Management.Automation.ErrorRecord]$Failure,
        [Nullable[long]]$ElapsedMs, [switch]$DetailedOnly, [string]$Owner, [string]$LocalPortalUrl,
        [switch]$Durable
    )
    $j = $script:ArcBoxJournal
    if (-not $j) { return }
    if (-not $Owner) { $Owner = $j.script }
    if ($Owner -cnotmatch '\A[A-Za-z][A-Za-z0-9.-]+\.(?:ps1|sh)\z') { throw 'Invalid log owner.' }
    $logName = "events\$Owner.admin.jsonl"
    $readableName = "scripts\$Owner.admin.log"
    $id = [guid]::NewGuid().ToString('N')
    $failed = @()
    $sink = 'preparing records or taking the journal lock'
    $lock = $null
    try {
        for ($i = 0; $i -lt 40 -and -not $lock; $i++) {
            try { $lock = [IO.File]::Open((Join-Path $j.root 'workshop-journal.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
            catch [IO.IOException] { if ($i -eq 39) { throw }; Start-Sleep -Milliseconds 100 }
        }
        # The same lock serializes sequence allocation and every append, even across boots.
        $sequence = [long]1
        if ($lock.Length -ne 0) {
            $bytes = [byte[]]::new(8)
            if ($lock.Length -ne 8 -or $lock.Read($bytes,0,8) -ne 8) { throw 'Invalid journal sequence file.' }
            $sequence = [BitConverter]::ToInt64($bytes,0) + 1L
        }
        $lock.Position = 0
        $lock.Write([BitConverter]::GetBytes($sequence),0,8)
        $lock.Flush($true)
        $at = [datetime]::UtcNow.ToString('o')
        $row = [ordered]@{v=1; id=$id; at=$at; sequence=$sequence; level=$Severity; script=$Owner; release=$j.release
            stage=$Stage; run=$j.run; attempt=$j.attempt; boot=$j.boot; elapsedMs=$ElapsedMs
            headline=$Headline; operation=$Operation; lastConfirmed=$LastConfirmed; detail=$Detail}
        if ($Failure) {
            $exception = $Failure.Exception
            $info = $Failure.InvocationInfo
            $native = if ($exception.Data.Contains('ArcBoxNativeExit')) { $exception.Data['ArcBoxNativeExit'] }
                elseif ($exception.PSObject.Properties['ExitCode']) { $exception.ExitCode }
                elseif ($exception.PSObject.Properties['NativeErrorCode']) { $exception.NativeErrorCode }
            $row.failure = [ordered]@{
                exception=$exception.GetType().FullName; hresult=$exception.HResult
                nativeExit=$null; command=$null; source=$null
                line=$info.ScriptLineNumber; column=$info.OffsetInLine
                category=$Failure.CategoryInfo.Category.ToString()
            }
            if ($native -is [int]) { $row.failure.nativeExit = $native }
            if ($info.MyCommand.Name -match '\A[A-Za-z0-9_.-]{1,80}\z') { $row.failure.command = $info.MyCommand.Name }
            if ($info.ScriptName) { $row.failure.source = [IO.Path]::GetFileName($info.ScriptName) }
        }
        $nl = [Environment]::NewLine
        $t = if ($null -ne $ElapsedMs) { " | ${ElapsedMs} ms" } else { '' }
        $text = "$(Format-ArcBoxJournalUtc $at) [$Severity] [$Stage] $Headline$t$nl"
        $text += "  $Owner | Run $($j.run) | Attempt $($j.attempt) | Boot $(Format-ArcBoxJournalUtc $j.boot)$nl"
        $technical = $text + "  $logName | Event $id | Sequence $sequence | Release $($j.release)$nl"
        if ($Operation) { $technical += "  Operation: $Operation$nl" }
        if ($LastConfirmed) { $technical += "  Last confirmed: $LastConfirmed$nl" }
        # Do not project exception messages, invocation text, arguments or raw command streams.
        if ($row.failure) { $technical += ((Format-ArcBoxJournalDetail $row.failure 'error') -join $nl) + $nl }
        if ($Detail) { $technical += ((Format-ArcBoxJournalDetail $Detail 'evidence') -join $nl) + $nl }
        $records = [ordered]@{}
        $records[$logName] = ($row | ConvertTo-Json -Depth 8 -Compress) + $nl
        $records[$readableName] = $technical + $nl
        if (-not $DetailedOnly) {
            $records['WorkshopDeployment.log'] = $text + "  $logName | Event $id | Sequence $sequence$nl  Administrator: $readableName$nl"
            if ($LocalPortalUrl) { $records['WorkshopDeployment.log'] += "  Azure portal: $LocalPortalUrl$nl" }
        }
        foreach ($sink in $records.Keys) {
            try {
                $path = Join-Path $j.root $sink
                if ($Durable) {
                    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
                    try {
                        $bytes = [Text.Encoding]::UTF8.GetBytes($records[$sink])
                        $stream.Write($bytes,0,$bytes.Length)
                        $stream.Flush($true)
                    } finally { $stream.Dispose() }
                } else { [IO.File]::AppendAllText($path, $records[$sink]) }
            }
            catch { $failed += $sink }
        }
    } catch {
        $failed += $sink
    } finally { if ($lock) { $lock.Dispose() } }
    if ($failed) {
        $summary = if ($Failure) { " Error type: $($Failure.Exception.GetType().FullName)." } else { '' }
        Write-Warning "Workshop journal write failed ($($failed -join ', ')) | Event $id | $Owner [$Stage/$Severity]. $Headline$summary Check task or extension output and surviving local logs." -WarningAction Continue
        if ($Durable) { throw 'Required Bootstrap operation record could not be persisted.' }
    }
}

function ConvertTo-ArcBoxOperationError {
    param([string]$Original)
    $package = '(?:Az(?:\.[A-Za-z][A-Za-z0-9]{0,30})?|Microsoft\.PowerShell\.(?:PSResourceGet|SecretManagement)|Azure\.Arc\.Jumpstart\.Common|Pester)'
    $patterns = @(
        ('(?ix)\A(?:Package|Resource)\s+[''"](?<package>{0})[''"]\s+(?:was|could)\s+not\s+(?:be\s+)?found(?:\s+in\s+repository\s+[''"]PSGallery[''"])?(?:;\s+missing\s+dependency\s+[''"](?<dependency>{0})[''"])?\.?\z' -f $package),
        ('(?ix)\AThe\s+specified\s+module\s+[''"](?<dependency>{0})[''"]\s+was\s+not\s+loaded\s+because\s+no\s+valid\s+module\s+file\s+was\s+found\s+in\s+any\s+module\s+directory\.\z' -f $package),
        ('(?i)\A(?:Required|Missing) dependency [''"](?<dependency>{0})[''"](?: was not found| is missing)?\.?\z' -f $package),
        ('(?i)\A(?:Gallery package|Staged module) [''"](?<package>{0})[''"] (?:has an invalid digest|has an invalid manifest|has an unexpected archive identity or version|is missing|could not be downloaded)\.?\z' -f $package),
        '\APSGallery (?:www|cdn)\.powershellgallery\.com (?:transport failure: [A-Za-z]{3,32}|HTTP status: [1-5][0-9]{2})\.\z',
        '\APackage (?:byte count|SHA-512) does not match the lock\.\z',
        '\A(?:Archive contains an unsafe file entry|Archive extraction failed|Manifest read failed|Manifest version mismatch|Loaded module version mismatch|Loaded module path mismatch|Locked dependency constraint is not satisfied|Manifest dependency constraint is not satisfied|Verified module files do not match the existing installation|Module origin includes a reparse point|Required module import failed|Required command provider check failed|Alternate required module is visible to the worker|Package archive identity or version mismatch)\.\z',
        '\A(?:Module command did not resolve from the verified version|Module operation failed; native error text withheld|Module package staging exceeded its time budget)\.\z',
        '(?i)\AThe remote server returned an error: \((?:400|401|403|404|429|500|502|503|504)\) [A-Za-z ]{1,45}\.\z',
        '(?i)\A(?:The request timed out|Unable to connect to the remote server|Module import verification (?:failed|timed out) before any lab data disk write|The module lock is invalid|The module destination already exists and was not replaced)\.?\z'
    )
    foreach ($pattern in $patterns) {
        if ($original.Length -le 360 -and $original -match $pattern) {
            $missing = if ($Matches.ContainsKey('dependency')) { $Matches['dependency'] }
            return @{message=$original; missingDependency=$missing; messageDisposition='Allowlisted'}
        }
    }
    @{message=$null; missingDependency=$null; messageDisposition='Withheld: unrecognized text; see restricted native log'}
}

function Get-ArcBoxModuleFailureDetail {
    param($Detail)
    if (!$Detail) { return }
    $safe = @{}
    $rules = @{
        code = '\A(?:UnsafeEntry|ExtractionFailed|ManifestRead|ManifestVersion|ModuleVersion|ModulePath|LockDependency|ManifestDependency|ExistingFiles|ReparsePoint|ImportFailed|CommandProvider|AlternateModule|ArchiveIdentity|PackageLength|PackageDigest)\z'
        observedVersion = '\A[0-9]+(?:\.[0-9]+){1,3}\z'
        lockedVersion = '\A[0-9]+(?:\.[0-9]+){1,3}\z'
        requestingModule = '\A[A-Za-z][A-Za-z0-9._-]{0,115}\z'
        dependency = '\A[A-Za-z][A-Za-z0-9._-]{0,115}\z'
        dependencyReason = '\A(?:MissingPin|IncompatiblePin|NotInClosure|Cycle)\z'
        constraint = '\A[0-9., *\[\]()=<>]{1,60}\z'
        expectedOrigin = '\Amachine-modules\\[A-Za-z0-9_.\\ -]{1,200}\z'
        observedOrigin = '\A(?:machine-modules\\[A-Za-z0-9_.\\ -]{1,200}|<outside verified version>|<not available>)\z'
        zipEntry = '\A[A-Za-z0-9_.()\[\]+ /-]{1,512}\z'
        cause = '\A[A-Za-z][A-Za-z0-9.]{1,120}Exception\z'
    }
    foreach ($key in $rules.Keys) {
        $value = $Detail.$key
        if ($value -is [string] -and $value -cmatch $rules[$key] -and $value -notmatch '(?:^|[\\/])\.\.(?:[\\/]|$)|//') {
            $safe[$key] = $value
        }
    }
    if (($Detail.destinationLength -is [int] -or $Detail.destinationLength -is [long]) -and
        $Detail.destinationLength -gt 0 -and $Detail.destinationLength -le 32767) {
        $safe.destinationLength = [int]$Detail.destinationLength
    }
    foreach ($key in 'expectedBytes','observedBytes') {
        $value = $Detail.$key
        if (($value -is [int] -or $value -is [long]) -and $value -ge 0) { $safe[$key] = [long]$value }
    }
    $safe
}

function Set-ArcBoxProvisioningModulePath {
    param([string]$MachineModules)
    $env:PSModulePath = $MachineModules + ';' + (Join-Path $PSHOME 'Modules')
}

function Start-ArcBoxOperation {
    param([string]$Stage,[string]$Action,[string]$Target,[string]$Version,[string]$Repository)
    if (-not $script:ArcBoxJournal -or $Action -cnotmatch '\A[A-Za-z][A-Za-z0-9 .:-]{1,75}\z' -or
        $Target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,115}\z' -or $Target -match '://' -or
        $Version -cnotmatch '\A[0-9., \[\]()]{0,40}\z' -or
        $Repository -cnotin '', 'PSGallery', 'Configured repository priority', 'Verified local staging', 'Verified machine modules') {
        throw 'Invalid Bootstrap operation metadata.'
    }
    $op = @{operationId=[guid]::NewGuid().ToString('N'); outcome='Started'; action=$Action; target=$Target
        version=$(if ($Version) { $Version }); repository=$(if ($Repository) { $Repository })
        engine=[string]$PSVersionTable.PSEdition; engineVersion=$PSVersionTable.PSVersion.ToString()}
    $routine = $Action -cin 'Download pinned module','Verify and stage module','Install verified module files','Download artifact',
        'Read locked module manifest','Import locked module','Verify command provider','Record loaded module provenance'
    Write-ArcBoxJournal $Stage INFO "$Action - $Target (started)." -Detail $op -Operation $Action -DetailedOnly:$routine -Durable
    $op
}

function Complete-ArcBoxOperation {
    param([string]$Stage,[hashtable]$Operation,[System.Management.Automation.ErrorRecord]$Failure,[switch]$ContinueOnFailure)
    $detail = $Operation.Clone()
    if ($Failure) {
        $detail.outcome = 'Failed'
        $safe = ConvertTo-ArcBoxOperationError $Failure.Exception.Message
        if ($Stage -ceq 'modules' -and !$safe.message) {
            $safe.message = 'Module operation failed; native error text withheld.'
        }
        foreach ($key in $safe.Keys) { $detail[$key] = $safe[$key] }
        foreach ($key in 'ArcBoxChildException','ArcBoxChildCategory') {
            if ($Failure.Exception.Data.Contains($key)) { $detail[$key] = $Failure.Exception.Data[$key] }
        }
        if ($Stage -ceq 'modules') {
            $detail.bootstrapContinued = [bool]$ContinueOnFailure
            $detail.moduleFailure = Get-ArcBoxModuleFailureDetail $Failure.Exception.Data['ArcBoxModuleFailure']
        }
        Write-ArcBoxJournal $Stage ERROR "$($detail.action) failed for $($detail.target). See the administrator log before retrying." `
            -Detail $detail -Operation $detail.action -Failure $Failure -DetailedOnly:$ContinueOnFailure -Durable
        if ($ContinueOnFailure) {
            Write-ArcBoxJournal $Stage WARNING "$($detail.action) failed for $($detail.target); lab provisioning is continuing past this failure." `
                -Detail @{failedOperationId=$detail.operationId; bootstrapContinued=$true} -Durable
        }
    } else {
        $detail.outcome = 'Succeeded'
        Write-ArcBoxJournal $Stage INFO "$($detail.action) completed for $($detail.target)." `
            -Detail $detail -Operation $detail.action -DetailedOnly -Durable
    }
}

function Invoke-ArcBoxOperation {
    param([string]$Stage,[string]$Action,[string]$Target,[scriptblock]$Command,[string]$Version,[string]$Repository)
    $op = Start-ArcBoxOperation $Stage $Action $Target $Version $Repository
    try { & $Command }
    catch {
        $failure = $_
        try { Complete-ArcBoxOperation $Stage $op -Failure $failure }
        catch { Write-Warning 'Operation failed, but its result record could not be persisted. Use the durable start as the last attempted action.' }
        throw $failure
    }
    Complete-ArcBoxOperation $Stage $op
}

function Invoke-ArcBoxLoggedScript {
    param([string]$Name, [string]$Stage, [scriptblock]$Action, [switch]$DispatchOnly)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Write-ArcBoxJournal $Stage INFO "$Name started." -Owner $Name
    try {
        & $Action
        $text = if ($DispatchOnly) { 'returned after dispatch; verify the downstream operation separately.' }
            else { 'returned without a terminating error; verify its required downstream results separately.' }
        Write-ArcBoxJournal $Stage INFO "$Name $text" -ElapsedMs $watch.ElapsedMilliseconds -Owner $Name
    } catch {
        Write-ArcBoxJournal $Stage ERROR "$Name stopped at a terminating error. Dependent work cannot be treated as ready; inspect the administrator record and existing transcript." `
            -ElapsedMs $watch.ElapsedMilliseconds -Failure $_ -Owner $Name -Operation $Name -LastConfirmed 'Script invoked; no completion verified.'
        throw
    }
}

function Get-ArcBoxConnectOutputFilter {
    {
        param([object[]]$Output, [string]$ExpectedId, [string]$ExpectedTenant)
        # Keep only documented error identifiers and the exact expected Azure portal route.
        $safe = [pscustomobject]@{errorCode=$null; portalUrl=$null}
        foreach ($line in $Output) {
            $text = [string]$line
            if (-not $safe.errorCode -and $text -match '(?i)\bAZCM[0-9]{4}\b') { $safe.errorCode = $Matches[0].ToUpperInvariant() }
            if ($ExpectedId -and $text -match '(?i)(?:^|\s)(https://portal\.azure\.com/#(?:@([a-f0-9-]{36}))?/resource(/subscriptions/[a-f0-9-]{36}/resourceGroups/[a-z0-9._()-]{1,90}/providers/Microsoft\.HybridCompute/machines/[a-z0-9._-]{1,64})(?:/overview)?)(?:\s|$)' -and
                $Matches[3] -ieq $ExpectedId -and (-not $Matches[2] -or $Matches[2] -ieq $ExpectedTenant)) {
                $safe.portalUrl = 'https://portal.azure.com/#/resource' + $ExpectedId
            }
        }
        $safe
    }
}

function Send-ArcBoxLinuxFile {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Runspaces.PSSession]$Session,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][ValidateSet('0600','0644')][string]$Mode
    )

    $bytes = [IO.File]::ReadAllBytes($Path)
    $encoded = [Convert]::ToBase64String($bytes)
    $expectedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    Invoke-Command -Session $Session -ErrorAction Stop -ArgumentList $encoded,$expectedHash,$Destination,$Mode -ScriptBlock {
        param($Encoded, $ExpectedHash, $Destination, $Mode)
        $ErrorActionPreference = 'Stop'
        $PSNativeCommandUseErrorActionPreference = $true

        $stage = mktemp -d
        try {
            $source = Join-Path $stage 'payload'
            [IO.File]::WriteAllBytes($source, [Convert]::FromBase64String($Encoded))
            if ((Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ine $ExpectedHash) {
                throw 'Linux staging payload failed its SHA-256 check.'
            }

            # Keep executable scripts and pending configuration in a root-owned directory.
            if ($Destination.StartsWith('/var/lib/arcbox-provisioning/', [StringComparison]::Ordinal)) {
                sudo -n install -d -o root -g root -m 0700 '/var/lib/arcbox-provisioning'
            }
            sudo -n install -o root -g root -m $Mode -- $source $Destination
            $installed = sudo -n sha256sum -- $Destination
            if (($installed -split '\s+', 2)[0] -ine $ExpectedHash) {
                throw 'Installed Linux payload failed its SHA-256 check.'
            }
        } finally {
            Remove-Item -LiteralPath (Join-Path $stage 'payload') -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $stage -Force -ErrorAction Stop
        }
    }
}

function Get-ArcBoxUbuntuInstallerCommand {
    {
        param($Token, $Group, $Tenant, $Location, $Subscription, $FilterSource)
        $PSNativeCommandUseErrorActionPreference = $false
        $ErrorActionPreference = 'Continue'
        $previousExit = $global:LASTEXITCODE
        try {
            $global:LASTEXITCODE = $null
            $output = @($Token | sudo -n sh /var/lib/arcbox-provisioning/arcbox-install-agent.sh $Group $Tenant $Location $Subscription 2>&1)
            $code = $global:LASTEXITCODE
        } finally { $global:LASTEXITCODE = $previousExit }
        if ($code -isnot [int]) { return }
        $markers = @($output | Where-Object { $_ -is [string] -and $_ -cmatch '\AArcBoxConnectExit:[0-9]{1,3}\z' })
        $observed = $markers.Count -eq 1 -and [int]($markers[0].Split(':')[1]) -eq $code
        $id = "/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.HybridCompute/machines/ArcBox-Ubuntu-01"
        $safe = if ($observed) { & ([scriptblock]::Create($FilterSource)) $output $id $Tenant }
        [pscustomobject]@{Tag='arcbox-installer-v1'; Phase=$(if ($observed) {'agent-connect'} else {'native-command'});
            ExitCode=$code; ConnectObserved=$observed; ErrorCode=$safe.errorCode; PortalUrl=$safe.portalUrl}
    }
}

function Get-ArcBoxAgentStatusCommand {
    {
        $agent = if ($env:OS -eq 'Windows_NT') { Join-Path $env:ProgramW6432 'AzureConnectedMachineAgent\azcmagent.exe' }
            else { '/opt/azcmagent/bin/azcmagent' }
        $result = [pscustomobject]@{Tag='arcbox-agent-state-v1'; Status='Unverified'; LastHeartbeat=$null;
            ExitCode=$null; Reason='agent unavailable'; ErrorCode=$null}
        if (-not (Test-Path -LiteralPath $agent -PathType Leaf)) { return $result }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo.FileName = $agent
        $process.StartInfo.Arguments = 'show status lastHeartbeat --json'
        $process.StartInfo.UseShellExecute = $false
        $process.StartInfo.RedirectStandardOutput = $true
        $process.StartInfo.RedirectStandardError = $true
        $result.Reason = 'agent status command could not run'
        try {
            if (-not $process.Start()) { return $result }
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(5000)) {
                try { Stop-Process -Id $process.Id -ErrorAction Stop } catch { if (-not $process.HasExited) { $result.Reason = 'agent status timed out; process stop failed'; return $result } }
                $result.Reason = 'agent status command timed out'
                return $result
            }
            $result.ExitCode = $process.ExitCode
            if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdout,$stderr),1000)) {
                $result.Reason = 'agent status output did not complete'
                return $result
            }
            if ($result.ExitCode -ne 0) {
                $result.Reason = 'agent status command returned a nonzero exit'
                if (($stdout.Result + "`n" + $stderr.Result) -match '(?i)\bAZCM[0-9]{4}\b') { $result.ErrorCode = $Matches[0].ToUpperInvariant() }
                return $result
            }
            $result.Reason = 'agent status response could not be parsed'
            $document = ConvertFrom-Json -InputObject $stdout.Result -ErrorAction Stop
            if ($document -is [pscustomobject] -and $document.status -is [string] -and $document.status -iin 'Connected','Disconnected') {
                $result.Status = if ($document.status -ieq 'Connected') {'Connected'} else {'Disconnected'}
                $result.Reason = $null
                $raw = $document.lastHeartbeat
                if ($raw -is [datetime] -and $raw.Kind -ne 'Unspecified') { $raw = $raw.ToString('o') }
                $heartbeat = [datetimeoffset]::MinValue
                if ($raw -is [string] -and $raw -match '\A\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d{1,7})?(?:Z|[+-]\d{2}:\d{2})\z' -and
                    [datetimeoffset]::TryParse($raw,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::None,[ref]$heartbeat) -and
                    $heartbeat -gt [datetimeoffset]::MinValue) {
                    $result.LastHeartbeat = $heartbeat.UtcDateTime.ToString('o')
                }
            }
        } catch {
            if ($result.Reason -ne 'agent status response could not be parsed') { $result.Reason = 'agent status command could not run' }
        } finally { $process.Dispose() }
        $result
    }
}

function Receive-ArcBoxAgentStatusJob {
    param([scriptblock]$Start)
    $job = & $Start
    try {
        if (-not (Wait-Job -Job $job -Timeout 10)) { throw 'Agent status remoting timed out.' }
        Receive-Job -Job $job -ErrorAction Stop -WarningAction SilentlyContinue -InformationAction SilentlyContinue
    } finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
}

function Write-ArcBoxGuestConnection {
    param([string]$Name, [string]$Stage, [string]$Transport, [string]$GuestLog, [scriptblock]$Read,
        [bool]$Registered)
    $attempts = if ($Registered) { 3 } else { 1 }
    $detail = [ordered]@{command='azcmagent show status lastHeartbeat --json'; expected='Connected';
        status='Unverified'; lastHeartbeat=$null; nativeExit=$null; errorCode=$null; reason=$null; transport=$Transport; guestLog=$GuestLog}
    for ($i = 1; $i -le $attempts; $i++) {
        $detail.reads = $i
        $detail.status = 'Unverified'
        $detail.nativeExit = $null
        $detail.errorCode = $null
        $detail.reason = $null
        try { $rows = @(& $Read) }
        catch {
            $detail.reason = "$Transport status read failed or timed out"
            break
        }
        if ($rows.Count -ne 1 -or $rows[0].Tag -cne 'arcbox-agent-state-v1' -or $rows[0].Status -cnotin 'Unverified','Connected','Disconnected' -or
            ($null -ne $rows[0].ExitCode -and $rows[0].ExitCode -isnot [int]) -or
            ($rows[0].Status -ne 'Unverified' -and ($null -eq $rows[0].ExitCode -or $rows[0].ExitCode -ne 0))) {
            $detail.reason = 'agent status response could not be parsed'
            break
        }
        $row = $rows[0]
        $detail.status = $row.Status
        $detail.nativeExit = $row.ExitCode
        if ($row.ErrorCode -cmatch '\AAZCM[0-9]{4}\z') { $detail.errorCode = $row.ErrorCode }
        if ($row.LastHeartbeat -is [string] -and $row.LastHeartbeat -cmatch '\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z\z') {
            $detail.lastHeartbeat = $row.LastHeartbeat
        }
        if ($row.Status -eq 'Connected') { break }
        if ($row.Status -eq 'Unverified') {
            $detail.reason = if ($row.Reason -cin 'agent unavailable','agent status command could not run','agent status command timed out',
                'agent status timed out; process stop failed','agent status output did not complete',
                'agent status command returned a nonzero exit','agent status response could not be parsed') { $row.Reason } else { 'agent status evidence was unavailable' }
        }
        if ($i -lt $attempts) {
            Write-ArcBoxJournal "$Stage connection" INFO "The guest did not confirm Connected on read $i of $attempts; will read again." `
                -Owner $Name -Detail $detail -DetailedOnly
        }
        if ($i -lt $attempts) { Start-Sleep -Seconds 3 }
    }
    $observation = switch ($detail.status) {
        'Connected' { 'The local agent reports Connected; the Azure inventory check is separate.' }
        'Disconnected' { 'The local agent reports Disconnected. Check the guest agent log and network path.' }
        default { "Connection Unverified: $($detail.reason). Check the guest agent and remoting path." }
    }
    $when = if ($detail.lastHeartbeat) { " Last known heartbeat: $(Format-ArcBoxJournalUtc $detail.lastHeartbeat)." }
        else { ' No heartbeat timestamp was verified.' }
    $level = if ($detail.status -eq 'Connected') {'INFO'} else {'WARNING'}
    Write-ArcBoxJournal "$Stage connection" $level "$observation$when" -Owner $Name -Operation 'Read local agent connection' `
        -LastConfirmed 'Read-only guest evidence; this does not override the registration result.' -Detail $detail
}

function Invoke-ArcBoxGuestInstaller {
    param([string]$Name, [string]$Stage, [scriptblock]$Action, [string]$Transport, [string]$GuestLog,
        [string]$ExpectedId, [scriptblock]$ReadStatus)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $detail = [ordered]@{transport=$Transport; guestLog=$GuestLog; protocol='arcbox-installer-v1'; outcome='dispatch'; registration='Not observed'}
    Write-ArcBoxJournal $Stage INFO "Requesting $Name over $Transport. Guest execution is not yet confirmed." -Owner $Name -Detail $detail
    $last = 'Invocation requested. The installer did not return a verified status.'
    $windowsHelper = $Name -ceq 'installArcAgent.ps1'
    $registrationError = $null
    $portalUrl = $null
    try {
        try { $results = @(& $Action) }
        catch {
            $detail.outcome = 'transport'
            $detail.remoteErrorType = $_.Exception.GetType().FullName
            $detail.remoteErrorCategory = $_.CategoryInfo.Category.ToString()
            throw [InvalidOperationException]::new("$Transport invocation failed before a result was received. Check guest readiness and the transport; no guest log is guaranteed.")
        }
        if ($results.Count -eq 0) { $detail.outcome = 'missing-result' }
        elseif ($results.Count -gt 1) { $detail.outcome = 'duplicate-result' }
        elseif ($results[0] -isnot [pscustomobject] -or $results[0].Tag -isnot [string] -or
            $results[0].Tag -cne 'arcbox-installer-v1' -or $results[0].Phase -isnot [string] -or
            $results[0].ConnectObserved -isnot [bool] -or
            ($results[0].ConnectObserved -ne ($results[0].Phase -ceq 'agent-connect' -and $results[0].ExitCode -is [int])) -or
            (-not $windowsHelper -and ($results[0].ExitCode -isnot [int] -or $results[0].Phase -cnotin 'native-command','agent-connect')) -or
            ($windowsHelper -and ($results[0].Phase -cnotmatch '\A(download|msi|agent-connect)\z' -or
                ($results[0].ExitCode -isnot [int] -and -not ($null -eq $results[0].ExitCode -and
                    $results[0].ErrorType -is [string] -and $results[0].ErrorType -cmatch '\A[A-Za-z0-9]{1,80}Exception\z'))))) {
            $detail.outcome = 'malformed-result'
        }
        if ($detail.outcome -ne 'dispatch') {
            $detail.resultCount = $results.Count
            throw [InvalidOperationException]::new("The guest returned $($detail.outcome). Do not infer an installer outcome; check the remoting session and guest diagnostics.")
        }
        $code = $results[0].ExitCode
        $detail.nativeExit = $code
        $detail.phase = $results[0].Phase
        if ($results[0].ConnectObserved) {
            $detail.registration = if ($code -eq 0) {'Succeeded'} else {'Failed'}
            if ($results[0].ErrorCode -cmatch '\AAZCM[0-9]{4}\z') { $detail.errorCode = $results[0].ErrorCode }
        }
        $portalUrl = if ($ExpectedId -and $results[0].PortalUrl -is [string] -and
            $results[0].PortalUrl -ceq ('https://portal.azure.com/#/resource' + $ExpectedId)) { $results[0].PortalUrl }
        $last = "$Transport returned a validated installer result; the connection read is separate."
        if ($null -eq $code) {
            $detail.outcome = 'guest-step-failure'
            $detail.guestErrorType = $results[0].ErrorType
            throw [InvalidOperationException]::new("$Name failed in $($detail.phase) before observing a native exit.")
        }
        if ($code -ne 0) {
            $detail.outcome = 'native-failure'
            $errorDetail = [InvalidOperationException]::new("$Name returned native exit $code ($($detail.phase)). Inspect the indicated guest log if that stage reached it.")
            $errorDetail.Data['ArcBoxNativeExit'] = $code
            throw $errorDetail
        }
        if (-not $results[0].ConnectObserved) {
            $detail.outcome = 'missing-connect-result'
            throw [InvalidOperationException]::new('No azcmagent connect result was confirmed.')
        }
        $detail.outcome = 'exit-zero'
        Write-ArcBoxJournal "$Stage registration" INFO 'Registration succeeded: azcmagent connect returned exit 0. Checking local connection separately.' `
            -Owner $Name -Operation 'azcmagent connect' -Detail $detail -LastConfirmed $last -ElapsedMs $watch.ElapsedMilliseconds -LocalPortalUrl $portalUrl
    } catch {
        $registrationError = $_
        $next = switch ($detail.outcome) {
            'transport' { "$Transport failed before a result arrived. Check guest readiness and session access; no guest log is guaranteed." }
            'native-failure' {
                if ($detail.registration -eq 'Failed') { "Registration failed: azcmagent connect returned exit $($detail.nativeExit). Check the guest agent log." }
                else { "$Name returned native exit $($detail.nativeExit) ($($detail.phase)); registration was not observed. Check the guest installer log if it was reached." }
            }
            'guest-step-failure' { "$Name failed in $($detail.phase) before observing a native exit. Check the stage and indicated guest logs." }
            'missing-connect-result' { "$Name did not confirm an azcmagent connect result. Check the staged helper and guest logs." }
            'missing-result' { "$Name returned no installer result. Check the remote session and guest log before any retry." }
            'malformed-result' { "$Name returned an invalid installer result. Check the helper version and guest log before any retry." }
            'duplicate-result' { "$Name returned more than one result. Check the helper version and guest log before any retry." }
            default { 'The guest response did not establish an installer outcome. Check the remote session and guest log before any retry.' }
        }
        Write-ArcBoxJournal "$Stage registration" ERROR $next `
            -Owner $Name -Operation $Name -Detail $detail -LastConfirmed $last -ElapsedMs $watch.ElapsedMilliseconds -Failure $_ -LocalPortalUrl $portalUrl
    }
    if ($ReadStatus -and $detail.outcome -ne 'transport') {
        try { Write-ArcBoxGuestConnection $Name $Stage $Transport $GuestLog $ReadStatus ($detail.registration -eq 'Succeeded') }
        catch { Write-ArcBoxJournal "$Stage connection" WARNING 'Connection Unverified: the client could not record the guest status. Check the guest agent log.' -Owner $Name -Failure $_ }
    } elseif ($ReadStatus) {
        Write-ArcBoxJournal "$Stage connection" WARNING "Connection Unverified: $Transport did not return an installer result; no guest read was established." `
            -Owner $Name -Detail @{status='Unverified'; reason='installer transport failed'; transport=$Transport}
    }
    if ($registrationError) { throw $registrationError }
}

function Get-ArcBoxHostFailureCode {
    param([System.Management.Automation.ErrorRecord]$Record, [string]$Fallback)
    $code = $Record.Exception.Data['ArcBoxReason']
    if ($code -and $script:ArcBoxHostReasons.ContainsKey($code)) { return $code }
    return $Fallback
}

function Write-ArcBoxHostEvent {
    param(
        [ValidateSet('bootstrap','disk','powershell','modules','artifacts','features',
            'reboot','winget','dsc-common','dsc-itpro','tasks','performance',
            'guest-access','proxy','arc-connect','arc-features','post-reboot','servers','workbook')][string]$Stage,
        [ValidateSet('start','ok','failed','requested')][string]$State,
        [string]$Reason, [switch]$LegacyOnly
    )
    $record = [ordered]@{
        v = 1; stage = $Stage; state = $State; at = [datetime]::UtcNow.ToString('o')
        run = [Environment]::GetEnvironmentVariable('ArcBoxRunId', 'Machine')
        attempt = [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine')
    }
    if ($State -eq 'failed' -and $Reason -and $script:ArcBoxHostReasons.ContainsKey($Reason)) {
        $record.reason = $Reason
        $record.message = $script:ArcBoxHostReasons[$Reason]
    }
    try {
        Add-Content -LiteralPath 'C:\ArcBox\Logs\workshop-host-events.jsonl' -Encoding ASCII -Value (
            ConvertTo-Json -InputObject $record -Compress) -ErrorAction Stop
    } catch {
        if ($State -ne 'failed') { throw }
        Write-Warning "Could not write legacy failed-stage evidence ($Stage/$Reason). See the surviving journal or task output." -WarningAction Continue
    }
    if ($script:ArcBoxJournal -and -not $LegacyOnly) {
        $clocks = $script:ArcBoxJournal.clocks
        if ($State -eq 'start') { $clocks[$Stage] = [Diagnostics.Stopwatch]::StartNew() }
        $ms = if ($clocks.ContainsKey($Stage)) { $clocks[$Stage].ElapsedMilliseconds }
        $level = if ($State -eq 'failed' -and $Stage -eq 'performance') { 'WARNING' }
            elseif ($State -eq 'failed') { 'ERROR' } else { 'INFO' }
        $area = @{
            bootstrap='Client Bootstrap'; disk='Lab data drive'; powershell='PowerShell 7'
            modules='PowerShell dependencies'; artifacts='Lab artifact staging'; features='Windows and Hyper-V features'
            tasks='SYSTEM and presentation task registration'; reboot='Hyper-V host reboot'
            performance='Host sampler'; 'post-reboot'='SYSTEM provisioning'; 'dsc-common'='Eight pinned packages'
            'dsc-itpro'='Hyper-V configuration'; servers='Nested guest setup'; workbook='Workbook setup'
            'guest-access'='Nested guest access'; proxy='Proxy setup'; 'arc-connect'='Baseline Arc connections'; 'arc-features'='Baseline Arc features'
        }[$Stage]
        if (-not $area) { $area = $Stage }
        $headline = switch ($State) {
            'start' { "$area started." }
            'ok' {
                if ($Stage -eq 'bootstrap') { 'Bootstrap completed and scheduled the reboot; SYSTEM provisioning and technical handoff are not yet verified.' }
                elseif ($Stage -eq 'post-reboot') { 'SYSTEM provisioning returned; verify its completion marker and technical handoff separately.' }
                elseif ($Stage -eq 'reboot') { 'New boot and running Hyper-V service verified; SYSTEM provisioning is resuming.' }
                else { "$area completed." }
            }
            'requested' { "$area requested; this records dispatch, not completion." }
            'failed' {
                if ($Stage -eq 'performance') { 'Host sampler did not complete; provisioning can continue without verified performance data.' }
                else { "$area stopped ($Reason). Dependent stages are not verified. $($script:ArcBoxHostReasons[$Reason])" }
            }
        }
        Write-ArcBoxJournal $Stage $level $headline -Detail @{structuredState=$State; reason=$Reason} -ElapsedMs $ms
    }
}

function Get-ArcBoxStorageMetadata {
    Read-ArcBoxMetadataJson '/metadata/instance/compute/storageProfile?api-version=2021-11-01'
}

function Wait-ArcBoxWindowsSession {
    param([string]$Name, [pscredential]$Credential, [ValidateRange(1,24)][int]$Attempts = 24)
    for ($i = 1; $i -le $Attempts; $i++) {
        try { return New-PSSession -VMName $Name -Credential $Credential -ErrorAction Stop }
        catch {
            if ($i -eq $Attempts) {
                $_.Exception.Data['ArcBoxReason'] = 'guest-access'
                throw
            }
            Start-Sleep -Seconds 5
        }
    }
}

function Read-ArcBoxMetadataJson {
    param([string]$Path)
    $request = [Net.HttpWebRequest]::Create("http://169.254.169.254$Path")
    $request.Headers.Add('Metadata', 'true')
    $request.Proxy = $null
    $request.AllowAutoRedirect = $false
    $request.Timeout = 5000
    $request.ReadWriteTimeout = 5000
    $response = $request.GetResponse()
    try {
        if ($response.StatusCode -ne [Net.HttpStatusCode]::OK) { throw 'Unexpected Azure instance metadata response.' }
        $reader = [IO.StreamReader]::new($response.GetResponseStream())
        try { $reader.ReadToEnd() | ConvertFrom-Json -ErrorAction Stop }
        finally { $reader.Dispose() }
    } finally { $response.Dispose() }
}

function Assert-ArcBoxSuccessorOptions {
    param([pscustomobject]$Options)
    if ($null -eq $Options -or @($Options.PSObject.Properties | Where-Object {
            $_.Name -cnotin 'machinePackages','performance','runId'
        }).Count) {
        Stop-ArcBoxHostStep artifact-pin 'Unexpected bootstrap option; use only the reviewed machine-package and run settings.'
    }
}

function Get-ArcBoxScriptPins {
    param([string]$TemplateBaseUrl)
    if ($TemplateBaseUrl -cnotmatch '\Ahttps://raw\.githubusercontent\.com/folkenne/arc_jumpstart/[a-f0-9]{40}/azure_arc_servers_jumpstart/\z') {
        Stop-ArcBoxHostStep artifact-pin 'Expected the reviewed fork artifact base with a full commit SHA.'
    }
    $upstream = 'https://raw.githubusercontent.com/Azure/arc_jumpstart_levelup/24ef125f81b2cf0a8ea8d81d0dcf8ee47323befd/azure_arc_servers_jumpstart/artifacts/'
    [ordered]@{
        'ArcServersLogonScript.ps1' = @{
            Uri = "${TemplateBaseUrl}artifacts/ArcServersLogonScript.ps1"
            Sha256 = '4f52a8e52a27f521d6feb6ff58e489dd176e3eccd24b767e69d6c0fd745707cf'
        }
        'ArcBox.Linux.ps1' = @{
            Uri = "${TemplateBaseUrl}artifacts/ArcBox.Linux.ps1"
            Sha256 = '88148f8bc9f520fe89b96df8f11492fbdaf8ad48ea64e9640ad3c526dcc726e0'
        }
        'ArcBox.LinuxSeed.sh' = @{
            Uri = "${TemplateBaseUrl}artifacts/ArcBox.LinuxSeed.sh"
            Sha256 = 'cddfc5e8ef619910179fe14b3ef5b4e91af2b7aff4f3f5c58fd2967904617ee2'
        }
        'testDefenderForSQL.ps1' = @{
            Uri = "${upstream}testDefenderForSQL.ps1"
            Sha256 = '8bdef6a7eb91410532443044492d7011ab1acd90ef0728a5adaa3a2cc903de05'
        }
        'SqlAdvancedThreatProtectionShell.psm1' = @{
            Uri = "${upstream}SqlAdvancedThreatProtectionShell.psm1"
            Sha256 = 'ebf51226fee00a15c27f3b77f90058f6e9684bc515a783dcb7321a38308b9237'
        }
    }
}

function Assert-ArcBoxPrivateScript {
    param([string]$Path, [string]$Sha256)
    if ($Sha256 -notmatch '\A[0-9a-f]{64}\z' -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $Sha256) {
        Stop-ArcBoxHostStep private-hash 'Staged artifact does not match the reviewed bytes.'
    }
}

function Get-ArcBoxPrivateScriptPath {
    param([ValidatePattern('\A[a-f0-9]{32}\z')][string]$Attempt)
    if (-not $Attempt) { Stop-ArcBoxHostStep private-config 'Missing provisioning attempt ID.' }
    Join-Path $env:ProgramFiles "ArcBoxPrivate\$Attempt\ArcServersLogonScript.ps1"
}

function New-ArcBoxPrivateScriptDirectory {
    param([string]$Path)
    $parent = Split-Path -Parent $Path
    foreach ($directory in $parent, $Path) {
        $item = New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            Stop-ArcBoxHostStep private-config 'The private artifact directory must not be a reparse point.'
        }
        Protect-ArcBoxDirectory $directory
    }
}

function Protect-ArcBoxDirectory {
    param([string]$Path, [switch]$LabRead)
    if ((Get-Item -LiteralPath $Path -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Stop-ArcBoxHostStep private-config 'A provisioning directory is a reparse point.'
    }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $access = @{ 'S-1-5-18' = 'FullControl'; 'S-1-5-32-544' = 'FullControl' }
    if ($LabRead) { $access['S-1-5-32-545'] = 'ReadAndExecute' }
    foreach ($sid in $access.Keys) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), $access[$sid],
            'ContainerInherit,ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}

function Get-ArcBoxStartupArguments {
    param([string]$Work)
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Work 'WinGet.ps1')
}

function Invoke-ArcBoxCheckpoint {
    param([string]$Work, [string]$Stage, [string]$Reason, [scriptblock]$Action)
    $started = Join-Path $Work "$Stage.started"
    $done = Join-Path $Work "$Stage.ok"
    if (Test-Path -LiteralPath $done) {
        Write-ArcBoxJournal $Stage INFO 'Skipped: this attempt already has a completion checkpoint.'
        return
    }
    # CreateNew also prevents a manually started duplicate outside Task Scheduler.
    try { $marker = [IO.File]::Open($started, 'CreateNew', 'Write', 'None') }
    catch [IO.IOException] { Stop-ArcBoxHostStep checkpoint "Inspect the interrupted or active $Stage phase before recovery." }
    $marker.Dispose()
    try {
        Write-ArcBoxHostEvent $Stage start
        & $Action
        [IO.File]::Move($started, $done)
        Write-ArcBoxHostEvent $Stage ok
    } catch {
        Write-ArcBoxJournal $Stage ERROR "Checkpoint $Stage stopped. Inspect the failed operation before resuming." `
            -Failure $_ -Operation $Stage -LastConfirmed 'Completion is not inferred from dispatch.'
        Write-ArcBoxHostEvent $Stage failed (Get-ArcBoxHostFailureCode $_ $Reason)
        throw
    }
}

function Receive-ArcBoxPinnedScript {
    param([string]$TemplateBaseUrl, [string]$Name, [string]$Destination)
    $pins = Get-ArcBoxScriptPins -TemplateBaseUrl $TemplateBaseUrl
    if ([IO.Path]::GetFileName($Destination) -cne $Name -or $Name -cnotin $pins.Keys) {
        Stop-ArcBoxHostStep artifact-pin 'Unexpected pinned artifact name or destination.'
    }
    $pin = $pins[$Name]
    $pending = "$Destination.$([guid]::NewGuid().ToString('N')).download"
    try {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $pin.Uri -MaximumRedirection 0 `
                -OutFile $pending -TimeoutSec 60 -ErrorAction Stop
        } catch {
            Stop-ArcBoxHostStep artifact-download "Pinned HTTPS download failed for $Name."
        }
        Assert-ArcBoxPrivateScript -Path $pending -Sha256 $pin.Sha256
        if ([IO.File]::Exists($Destination)) { [IO.File]::Replace($pending, $Destination, [NullString]::Value) }
        else { [IO.File]::Move($pending, $Destination) }
    } finally {
        if ([IO.File]::Exists($pending)) { Remove-Item -LiteralPath $pending -Force -ErrorAction Continue }
    }
}

function Start-ArcBoxHostBaseline {
    param([string]$TemplateBaseUrl, [string]$Attempt)
    if ($Attempt -cnotmatch '\A[a-f0-9]{32}\z' -or $env:ProgramFiles -notmatch '\AC:\\') {
        throw 'Performance sampling requires the current attempt and Program Files on C:.'
    }
    $root = Join-Path $env:ProgramFiles 'ArcBoxPerf'
    $dir = Join-Path $root $Attempt
    # SYSTEM must not execute a sampler from the interactive lab tree.
    foreach ($path in $root, $dir) {
        $item = New-Item -Path $path -ItemType Directory -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Unsafe performance directory.' }
        Protect-ArcBoxDirectory -Path $path
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ArcBox.Host.ps1') -Destination (Join-Path $dir 'ArcBox.Host.ps1') -ErrorAction Stop
    $scriptPath = Join-Path $dir 'Measure-ArcBoxHost.ps1'
    Invoke-ArcBoxOperation performance 'Download artifact' 'Measure-ArcBoxHost.ps1' {
        Invoke-WebRequest -UseBasicParsing -Uri ($TemplateBaseUrl + 'artifacts/Measure-ArcBoxHost.ps1') `
            -OutFile $scriptPath -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop
    }
    [IO.File]::WriteAllText("$dir\deadline.txt", [datetimeoffset]::UtcNow.AddHours(12).ToString('o'))
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Attempt $Attempt"
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::FromHours(12))
    Invoke-ArcBoxOperation performance 'Register startup task' 'ArcBox-HostBaseline' {
        Register-ScheduledTask -TaskName 'ArcBox-HostBaseline' -TaskPath '\' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
            -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    }
    Invoke-ArcBoxOperation performance 'Request task start' 'ArcBox-HostBaseline' {
        Start-ScheduledTask -TaskName 'ArcBox-HostBaseline' -TaskPath '\' -ErrorAction Stop
    }
    $dir
}

function Get-ArcBoxDiskLun($Value) {
    if ("$Value" -cmatch '\A[0-9]{1,3}\z' -and [int]$Value -le 63) { [int]$Value }
}

function Get-ArcBoxDiskPresentation($Disk, $Win32, $TempSize) {
    $result = [ordered]@{number=$Disk.Number; bus=[string]$Disk.BusType; lun=$null; adapter=$null; port=$null
        target=$null; scsiBus=$null; win32Join='Not applicable'; namespace=$null; proof='Unresolved'
        sizeBytes=$Disk.Size; layout=[string]$Disk.PartitionStyle
        partitions=$Disk.NumberOfPartitions; offline=$Disk.IsOffline; readOnly=$Disk.IsReadOnly; health=[string]$Disk.HealthStatus}
    switch ($result.bus) {
        'SAS' {
            if ($Disk.Location -match '\AIntegrated\s*:\s*(?:Bus\s+[0-9]+\s*:\s*Device\s+[0-9]+\s*:\s*Function\s+[0-9]+\s*:\s*)?Adapter\s+([0-9]{1,3})\s*:\s*Port\s+([0-9]{1,3})\s*:\s*Target\s+([0-9]{1,3})\s*:\s*LUN\s+([0-9]{1,3})\s*\z') {
                $result.adapter = [int]$Matches[1]; $result.port = [int]$Matches[2]
                $result.target = [int]$Matches[3]; $result.lun = Get-ArcBoxDiskLun $Matches[4]
                if ($result.adapter -eq 0) { $result.proof = 'OS/temporary controller' }
                elseif ($result.adapter -eq 1 -and $null -ne $result.lun) { $result.proof = 'Azure SAS data controller location' }
            }
        }
        'SCSI' {
            if ($Disk.Location -match '\ABus Number\s+([0-9]{1,3})\s*:\s*Target Id\s+([0-9]{1,3})\s*:\s*LUN\s+([0-9]{1,3})\s*\z') {
                $result.scsiBus = [int]$Matches[1]; $result.target = [int]$Matches[2]
                $result.lun = Get-ArcBoxDiskLun $Matches[3]
                if ("$TempSize" -ceq '0' -and $null -ne $result.lun) { $result.proof = 'Azure SCSI location; no IMDS resource disk' }
            }
        }
        'NVMe' {
            # This join reads the documented property of this physical device; its index is not the Azure LUN.
            $physical = '\\.\PHYSICALDRIVE{0}' -f $Disk.Number
            $rows = @($Win32 | Where-Object { $_.Index -eq $Disk.Number -or $_.DeviceID -ieq $physical })
            $result.win32Join = "$($rows.Count) possible physical rows; requires one consistent Index and DeviceID"
            if ($rows.Count -eq 1 -and $rows[0].Index -eq $Disk.Number -and $rows[0].DeviceID -ieq $physical) {
                $row = $rows[0]
                $result.win32Join = 'Unique Index and DeviceID match'
                if ("$($row.SCSILogicalUnit)" -cmatch '\A[0-9]{1,3}\z' -and [int]$row.SCSILogicalUnit -in 1..64) {
                    $result.namespace = [int]$row.SCSILogicalUnit
                    if ($row.Model -imatch '\AVirtual_Disk NVMe Premium\s*\z') {
                        $result.lun = $result.namespace - 1
                        $result.proof = 'Azure remote NVMe role and Windows logical unit minus one'
                    }
                }
            }
        }
        { $_ -in 'ATA','SATA','USB','SD','MMC','1394','Virtual','File Backed Virtual','Storage Spaces' } {
            $result.proof = 'Not an Azure managed controller presentation'
        }
    }
    $result
}

function Get-ArcBoxDataDisk {
    param([string]$ExpectedId)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $storage = Get-ArcBoxStorageMetadata
    $attached = @($storage.dataDisks | Where-Object { $_.managedDisk.id -ieq $ExpectedId })
    $attachmentEvidence = @(foreach ($a in $storage.dataDisks) {
        [ordered]@{managedId=$a.managedDisk.id; lun=(Get-ArcBoxDiskLun $a.lun); option=$a.createOption
            sizeGiB=$a.diskSizeGB; tier=$a.managedDisk.storageAccountType; target=($a.managedDisk.id -ieq $ExpectedId)}
    })
    Write-ArcBoxJournal disk INFO 'Azure attachment inventory checked.' -Detail @{
        expectedId=$ExpectedId; resourceDiskSize=$storage.resourceDisk.size; attachments=$attachmentEvidence
    } -DetailedOnly
    if ($attached.Count -eq 0) { Stop-ArcBoxHostStep disk-discovery 'The configured managed disk is not attached in IMDS; no data disk was selected.' }
    if ($attached.Count -ne 1) { Stop-ArcBoxHostStep disk-contract 'IMDS returned more than one attachment for the configured managed disk.' }
    $lun = Get-ArcBoxDiskLun $attached[0].lun
    if ($null -eq $lun -or $attached[0].createOption -notin 'Attach','Empty','FromImage','Copy','Restore' -or
        @($storage.dataDisks | Where-Object { (Get-ArcBoxDiskLun $_.lun) -eq $lun }).Count -ne 1) {
        Stop-ArcBoxHostStep disk-contract 'The configured managed disk has missing, unsupported or duplicate attachment metadata.'
    }
    $os = @(Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop)
    $disks = @(Get-Disk -ErrorAction Stop)
    if ($os.Count -ne 1 -or @($disks | Where-Object Number -eq $os[0].DiskNumber).Count -ne 1) {
        Stop-ArcBoxHostStep disk-discovery 'Windows OS disk inventory is not ready; no data disk was selected.'
    }
    $win32 = @()
    if (@($disks | Where-Object { $_.BusType -eq 'NVMe' -and $_.Number -ne $os[0].DiskNumber -and -not $_.IsBoot -and -not $_.IsSystem }).Count) {
        try { $win32 = @(Get-CimInstance -ClassName Win32_DiskDrive -OperationTimeoutSec 8 -ErrorAction Stop) }
        catch {
            Write-ArcBoxJournal disk WARNING 'Windows NVMe physical inventory could not be read; potentially matching rows cannot be excluded.' `
                -Failure $_ -Operation 'Read Win32_DiskDrive'
        }
    }
    $osDevice = @($disks | Where-Object Number -eq $os[0].DiskNumber)[0]
    $sasTopology = (Get-ArcBoxDiskPresentation $osDevice $win32 $storage.resourceDisk.size).proof -eq 'OS/temporary controller'
    $candidates = @()
    $unresolved = @()
    foreach ($device in $disks) {
        $row = Get-ArcBoxDiskPresentation $device $win32 $storage.resourceDisk.size
        if ($row.bus -eq 'SAS' -and -not $sasTopology) { $row.proof = 'Unresolved' }
        if ($device.Number -eq $os[0].DiskNumber -or $device.IsBoot -eq $true -or $device.IsSystem -eq $true) {
            $row.decision = 'Excluded: Windows OS, boot or system disk'
        } elseif ($row.proof -in 'OS/temporary controller','Not an Azure managed controller presentation') {
            $row.decision = "Excluded: $($row.proof)"
        } elseif ($null -ne $row.lun -and $row.lun -ne $lun) {
            $row.decision = 'Excluded: different LUN'
        } elseif ($row.proof -eq 'Unresolved') {
            $row.decision = 'Possible target: missing managed role or LUN evidence'
            $unresolved += $row
        } else {
            $row.decision = 'Candidate: managed presentation and matching LUN'
            $candidates += [pscustomobject]@{device=$device; row=$row; lun=$lun; id=$ExpectedId}
        }
        Write-ArcBoxJournal disk INFO "Windows disk $($row.number): $($row.decision)." -Detail $row -DetailedOnly
    }
    $diskName = ($ExpectedId -split '/')[-1]
    if ($candidates.Count -gt 1 -or ($candidates.Count -and $unresolved.Count)) {
        $matchesText = (@(foreach ($c in $candidates) {"Disk $($c.row.number) ($($c.row.bus), LUN $lun)"}) -join ', ')
        $unknownText = (@(foreach ($u in $unresolved) {
            $location = if ($null -ne $u.adapter) { "adapter $($u.adapter)" } else { 'controller unverified' }
            $reported = if ($null -ne $u.lun) { "LUN $($u.lun)" } else { 'LUN unverified' }
            "Disk $($u.number) ($($u.bus), $location, $reported)"
        }) -join ', ')
        Stop-ArcBoxHostStep disk-identity "$diskName at Azure LUN $lun is ambiguous: matching Windows devices: $matchesText; unclassified devices: $($unknownText.Trim() -replace '^$','none'). No unique controller/device link proves the target."
    }
    if ($candidates.Count -ne 1) {
        $unknownText = (@(foreach ($u in $unresolved) {"Disk $($u.number) ($($u.bus))"}) -join ', ')
        Stop-ArcBoxHostStep disk-discovery "$diskName at Azure LUN $lun has no proven Windows match. Unclassified devices: $($unknownText -replace '^$','none')."
    }
    $selected = $candidates[0]
    $disk = $selected.device
    if ($disk.IsOffline -eq $true) { Stop-ArcBoxHostStep disk-discovery "Windows disk $($disk.Number) at Azure LUN $lun is offline." }
    if ($disk.IsBoot -ne $false -or $disk.IsSystem -ne $false -or
        $disk.IsOffline -ne $false -or $disk.IsReadOnly -ne $false -or $disk.HealthStatus -ne 'Healthy' -or
        $disk.Size -le 0 -or [string]::IsNullOrWhiteSpace($disk.UniqueId) -or
        @($disks | Where-Object UniqueId -eq $disk.UniqueId).Count -ne 1 -or
        @($disks | Where-Object Number -eq $disk.Number).Count -ne 1) {
        Stop-ArcBoxHostStep disk-identity "Windows disk $($disk.Number) matched LUN $lun but did not meet identity or health requirements."
    }
    Write-ArcBoxJournal disk INFO "$diskName at Azure LUN $lun maps to Windows disk $($disk.Number) ($($disk.BusType)): $($selected.row.proof)." `
        -ElapsedMs $clock.ElapsedMilliseconds -Detail $selected.row
    $selected
}

function Get-ArcBoxDriveState {
    $volumes = @(Get-Volume -ErrorAction Stop | Where-Object DriveLetter -eq 'F')
    $partitions = @(Get-Partition -ErrorAction Stop | Where-Object DriveLetter -eq 'F')
    [pscustomobject]@{volumes=$volumes; partitions=$partitions; occupied=($volumes.Count -gt 0 -or $partitions.Count -gt 0 -or
        $null -ne (Get-PSDrive -Name F -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath 'F:\'))}
}

function Test-ArcBoxLabVolume($State, $Disk) {
    $State.partitions.Count -eq 1 -and $State.partitions[0].DiskNumber -eq $Disk.Number -and
        $State.volumes.Count -eq 1 -and $State.volumes[0].FileSystem -eq 'NTFS' -and
        $State.volumes[0].FileSystemLabel -eq 'VMsDisk' -and $State.volumes[0].HealthStatus -eq 'Healthy' -and
        $Disk.PartitionStyle -in 'GPT','MBR'
}

function Test-ArcBoxLabVolumeLayout($State, $Disk) {
    $parts = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop)
    if ($parts.Count -ne $Disk.NumberOfPartitions -or
        @($parts | Where-Object { $_.DiskNumber -ne $Disk.Number }).Count) { return $false }
    $other = @($parts | Where-Object { $_.PartitionNumber -ne $State.partitions[0].PartitionNumber })
    $other.Count -eq 0 -or ($Disk.PartitionStyle -eq 'GPT' -and $other.Count -eq 1 -and
        $other[0].GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')
}

function Assert-ArcBoxSameDisk($Before, $After) {
    if ($Before.id -ine $After.id -or $Before.lun -ne $After.lun -or
        $Before.device.UniqueId -ine $After.device.UniqueId -or $Before.device.Number -ne $After.device.Number -or
        $Before.device.BusType -ine $After.device.BusType -or $Before.device.Location -ine $After.device.Location -or
        $Before.device.Size -ne $After.device.Size -or
        $Before.row.namespace -ne $After.row.namespace) {
        Stop-ArcBoxHostStep disk-drift 'The Azure attachment or Windows device identity changed before a disk write.'
    }
}

function Initialize-ArcBoxDataDrive {
    param([string]$ExpectedId, [ValidateRange(1,12)][int]$DiscoveryAttempts = 12, [switch]$VerifyOnly)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $last = 'No data disk write was attempted.'
    $operation = 'Discover verified disk and check F:'
    try {
        if ($ExpectedId -notmatch '\A/subscriptions/[0-9a-f-]{36}/resourceGroups/[A-Za-z0-9_.()-]+/providers/Microsoft\.Compute/disks/[A-Za-z0-9_.-]+\z') {
            Stop-ArcBoxHostStep disk-contract 'The deployment did not supply a managed disk resource ID.'
        }
        for ($i = 1; $i -le $DiscoveryAttempts; $i++) {
            try { $match = Get-ArcBoxDataDisk $ExpectedId; break }
            catch {
                if ((Get-ArcBoxHostFailureCode $_ '') -ne 'disk-discovery' -or $i -eq $DiscoveryAttempts) { throw }
                Write-ArcBoxJournal disk WARNING "Disk discovery read $i of $DiscoveryAttempts did not find a ready target. Rechecking IMDS and Windows in 5 seconds." `
                    -ElapsedMs $clock.ElapsedMilliseconds -Failure $_ -LastConfirmed $last
                Start-Sleep -Seconds 5
            }
        }
        $drive = Get-ArcBoxDriveState
        if ($drive.occupied) {
            if (-not (Test-ArcBoxLabVolume $drive $match.device)) {
                $owners = ($drive.partitions.DiskNumber -join ', ') -replace '^$','not established'
                Stop-ArcBoxHostStep disk-letter "F: is occupied (partition owner: $owners) and is not a healthy NTFS VMsDisk volume on verified disk $($match.device.Number)."
            }
            if (-not (Test-ArcBoxLabVolumeLayout $drive $match.device)) {
                Stop-ArcBoxHostStep disk-layout "Verified disk $($match.device.Number) owns F: but has an unexpected additional partition layout."
            }
            Write-ArcBoxJournal disk INFO "Reused healthy NTFS VMsDisk (F:) on verified Windows disk $($match.device.Number); no disk write needed." `
                -ElapsedMs $clock.ElapsedMilliseconds
            return
        }
        if ($VerifyOnly -or $match.device.PartitionStyle -ne 'RAW' -or "$($match.device.NumberOfPartitions)" -cne '0') {
            Stop-ArcBoxHostStep disk-layout "Disk $($match.device.Number) has layout $($match.device.PartitionStyle), $($match.device.NumberOfPartitions) partitions and no verified F:. Initialization is not permitted."
        }
        $style = if ($match.device.Size -ge 2TB) { 'GPT' } else { 'MBR' }
        $operation = 'Initialize-Disk'
        Write-ArcBoxJournal disk INFO "Write gate: recheck managed disk identity, blank layout and free F: before initializing Windows disk $($match.device.Number) ($style)." `
            -Detail @{operation=$operation; disk=$match.device.Number; expectedLayout='RAW/0 partitions'; partitionStyle=$style} -LastConfirmed $last
        Invoke-ArcBoxOperation disk 'Guard and initialize disk' "Windows disk $($match.device.Number)" {
            $current = Get-ArcBoxDataDisk $ExpectedId
            Assert-ArcBoxSameDisk $match $current
            if ($current.device.PartitionStyle -ne 'RAW' -or "$($current.device.NumberOfPartitions)" -cne '0' -or (Get-ArcBoxDriveState).occupied) {
                Stop-ArcBoxHostStep disk-drift 'Disk layout or F: changed before initialization.'
            }
            Initialize-Disk -InputObject $current.device -PartitionStyle $style -ErrorAction Stop | Out-Null
        }
        $last = "Initialize-Disk returned for disk $($match.device.Number); partitioning and formatting have not been requested."
        $operation = 'New-Partition'
        $created = Invoke-ArcBoxOperation disk 'Guard and create partition with drive letter' "Windows disk $($match.device.Number) F:" {
            $current = Get-ArcBoxDataDisk $ExpectedId
            Assert-ArcBoxSameDisk $match $current
            if ($current.device.PartitionStyle -ne $style -or (Get-ArcBoxDriveState).occupied -or
                # Windows may create the reserved GPT partition itself.
                ("$($current.device.NumberOfPartitions)" -cne '0' -and ($style -ne 'GPT' -or
                    "$($current.device.NumberOfPartitions)" -cne '1' -or
                    @(Get-Partition -DiskNumber $current.device.Number -ErrorAction Stop | Where-Object {
                        $_.DiskNumber -eq $current.device.Number -and $_.GptType -eq '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
                    }).Count -ne 1))) {
                Stop-ArcBoxHostStep disk-drift 'Initialized layout or F: changed before partitioning.'
            }
            $before = [int]$current.device.NumberOfPartitions
            $newPartition = New-Partition -InputObject $current.device -UseMaximumSize -DriveLetter F -ErrorAction Stop
            @{before=$before; partition=$newPartition}
        }
        $partition = $created.partition
        $beforePartitions = $created.before
        $last = 'F: partition creation returned; formatting has not been requested.'
        $operation = 'Format-Volume'
        Invoke-ArcBoxOperation disk 'Guard and format volume' 'F: NTFS VMsDisk' {
            $current = Get-ArcBoxDataDisk $ExpectedId
            Assert-ArcBoxSameDisk $match $current
            $drive = Get-ArcBoxDriveState
            if ($current.device.PartitionStyle -ne $style -or $current.device.NumberOfPartitions -ne ($beforePartitions + 1) -or
                $drive.partitions.Count -ne 1 -or $drive.partitions[0].DiskNumber -ne $current.device.Number -or
                $drive.partitions[0].PartitionNumber -ne $partition.PartitionNumber -or $drive.partitions[0].Offset -ne $partition.Offset -or
                $drive.partitions[0].Size -ne $partition.Size -or $drive.volumes.Count -ne 1 -or $drive.volumes[0].FileSystem -notin '',$null,'RAW') {
                Stop-ArcBoxHostStep disk-drift 'The new F: partition identity or filesystem changed before formatting.'
            }
            Format-Volume -Partition $drive.partitions[0] -FileSystem NTFS -NewFileSystemLabel VMsDisk -Confirm:$false -Force -ErrorAction Stop | Out-Null
        }
        $last = 'Formatting returned; verify the resulting volume before recovery.'
        $operation = 'Verify formatted F:'
        $current = Get-ArcBoxDataDisk $ExpectedId
        Assert-ArcBoxSameDisk $match $current
        $drive = Get-ArcBoxDriveState
        if (-not (Test-ArcBoxLabVolume $drive $current.device) -or -not (Test-ArcBoxLabVolumeLayout $drive $current.device)) {
            Stop-ArcBoxHostStep disk-write 'Formatting returned, but F: ownership, label, filesystem or health did not verify.'
        }
        Write-ArcBoxJournal disk INFO "Verified healthy NTFS VMsDisk (F:) on Windows disk $($current.device.Number) after initialization." `
            -ElapsedMs $clock.ElapsedMilliseconds
    } catch {
        if (-not $_.Exception.Data['ArcBoxReason']) { $_.Exception.Data['ArcBoxReason'] = 'disk-write' }
        $detail = if ($_.Exception.Data['ArcBoxReason'] -in 'disk-contract','disk-discovery','disk-identity','disk-letter','disk-layout','disk-drift') {
            $_.Exception.Message
        } else { "$operation did not complete or verify." }
        Write-ArcBoxJournal disk ERROR "$detail $last $($script:ArcBoxHostReasons[$_.Exception.Data['ArcBoxReason']])" `
            -ElapsedMs $clock.ElapsedMilliseconds -Failure $_ -LastConfirmed $last -Detail @{operation=$operation}
        throw
    }
}

function Test-ArcBoxPowerShell {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $version = & $Path -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
    $LASTEXITCODE -eq 0 -and "$version" -ceq '7.6.10'
}

function Install-ArcBoxPowerShell {
    param([string]$Executable, [string]$RecoveryMsi)
    $installed = Test-ArcBoxPowerShell $Executable
    if (-not $installed -and (Test-Path -LiteralPath $Executable)) {
        Stop-ArcBoxHostStep ps-existing 'Existing PowerShell is not the expected version; no downgrade attempted.'
    }
    $msi = "$RecoveryMsi.$([guid]::NewGuid().ToString('N')).msi"
    $phase = 'ps-download'
    try {
        Invoke-ArcBoxOperation powershell 'Download installer' 'PowerShell MSI' {
            Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.msi' -OutFile $msi -TimeoutSec 300 -ErrorAction Stop
        } -Version '7.6.10'
        # Verify the publisher before execution and the actual binary before task registration.
        $phase = 'ps-signature'
        Invoke-ArcBoxOperation powershell 'Verify installer publisher' 'PowerShell MSI' {
            $signature = Get-AuthenticodeSignature -FilePath $msi -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
                throw 'PowerShell MSI does not have a valid Microsoft publisher signature.'
            }
        } -Version '7.6.10'
        if (-not $installed) {
            $phase = 'ps-install'
            Invoke-ArcBoxOperation powershell 'Install MSI' 'PowerShell MSI' {
                $result = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Wait -PassThru -ErrorAction Stop -ArgumentList (
                    '/I "{0}" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1' -f $msi)
                if ($result.ExitCode -notin 0,3010) {
                    $failure = [InvalidOperationException]::new('PowerShell MSI failed.')
                    $failure.Data['ArcBoxNativeExit'] = $result.ExitCode
                    if ($result.ExitCode -eq 1641) { $failure.Data['ArcBoxReason'] = 'ps-restart' }
                    throw $failure
                }
            } -Version '7.6.10'
            $phase = 'ps-probe'
            Invoke-ArcBoxOperation powershell 'Verify installed engine' 'PowerShell 7' {
                if (-not (Test-ArcBoxPowerShell $Executable)) { throw 'Installed PowerShell failed the 7.6.10 probe.' }
            } -Version '7.6.10'
        }
        $phase = 'ps-download'
        Invoke-ArcBoxOperation powershell 'Retain recovery installer' 'PowerShell MSI' {
            Move-Item -LiteralPath $msi -Destination $RecoveryMsi -Force -ErrorAction Stop
        } -Version '7.6.10'
    } catch { if (-not $_.Exception.Data['ArcBoxReason']) { $_.Exception.Data['ArcBoxReason'] = $phase }; throw }
    finally {
        if (Test-Path -LiteralPath $msi -PathType Leaf) { Remove-Item -LiteralPath $msi -Force -ErrorAction Continue }
    }
}

function Get-ArcBoxBootTime {
    (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToUniversalTime().ToString('o')
}

function Assert-ArcBoxPostReboot {
    param([string]$PreparedOnBoot, [string]$CurrentBoot, [bool]$HyperVRunning)
    if (-not $PreparedOnBoot -or -not $CurrentBoot -or
        [string]::CompareOrdinal($CurrentBoot, $PreparedOnBoot) -le 0 -or -not $HyperVRunning) {
        Stop-ArcBoxHostStep reboot-pending 'The prepared client has not completed a Hyper-V reboot.'
    }
}

function Test-ArcBoxSshListener {
    param([string]$Address)
    $socket = [Net.Sockets.TcpClient]::new()
    try { $socket.ConnectAsync($Address, 22).Wait(1000) -and $socket.Connected }
    catch [AggregateException] {
        if ($_.Exception.InnerException -isnot [Net.Sockets.SocketException]) { throw }
        $false
    } finally { $socket.Dispose() }
}

function Get-ArcBoxLinuxAddress {
    param([string]$Name, [ValidateRange(1,300)][int]$TimeoutSeconds = 180)
    $lan = Get-NetIPAddress -InterfaceAlias 'vEthernet (InternalNATSwitch)' -AddressFamily IPv4 -IPAddress '10.10.1.1' -ErrorAction Stop
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $signal = 'unique guest KVP address missing'
    do {
        $adapter = @(Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop)
        if ($adapter.Count -ne 1 -or $adapter[0].SwitchName -cne 'InternalNATSwitch') {
            Stop-ArcBoxHostStep guest-access "$Name is not on the expected workshop switch."
        }
        $addresses = @($adapter[0].IPAddresses | Where-Object { $_ -match '\A10\.10\.1\.(1[0-9]{2}|200)\z' })
        if ($addresses.Count -eq 1) {
            $ip = $addresses[0]
            $lease = @(Get-DhcpServerv4Lease -IPAddress $ip -ErrorAction SilentlyContinue)
            $signal = 'active DHCP lease missing'
            if ($lease.Count -eq 1 -and $lease[0].AddressState -eq 'Active') {
                $signal = 'TCP/22 not ready'
                if (Test-ArcBoxSshListener $ip) {
                    $signal = 'vSwitch neighbor MAC not matched'
                    # A Linux DHCP client ID can contain a DUID rather than the NIC MAC.
                    $neighbor = @(Get-NetNeighbor -InterfaceIndex $lan.InterfaceIndex -IPAddress $ip -AddressFamily IPv4 -ErrorAction SilentlyContinue)
                    if ($neighbor.Count -eq 1 -and $neighbor[0].State -in 'Reachable','Stale','Delay','Probe' -and
                        ($neighbor[0].LinkLayerAddress -replace '[:-]','') -ieq $adapter[0].MacAddress) { return $ip }
                }
            }
        }
        if ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Seconds 3 }
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    Stop-ArcBoxHostStep guest-access "$Name is not SSH-ready: $signal."
}

function New-ArcBoxLinuxSshOptions {
    param([string]$Name, [string]$Address, [string]$PrivateKey)
    $dir = Split-Path -Parent $PrivateKey
    $proof = Get-Content -LiteralPath (Join-Path $dir "$Name.offline.json") -Raw | ConvertFrom-Json
    $disk = @(Get-VMHardDiskDrive -VMName $Name)
    if ($disk.Count -ne 1 -or $disk[0].Path -ine $proof.Disk -or (Get-VHD -Path $disk[0].Path).ParentPath -ine $proof.Parent -or
        $proof.Instance -cnotmatch '\Aarcbox-[a-f0-9]{32}\z' -or $proof.HostKey -cnotmatch '\Assh-ed25519 [A-Za-z0-9+/]{60,100}={0,2}\z') {
        Stop-ArcBoxHostStep guest-access "No exact offline disk and SSH key binding for $Name."
    }
    $pin = Join-Path $dir "$Name-known_hosts"
    $empty = Join-Path $dir 'empty-ssh-config'
    [IO.File]::WriteAllText($pin, "$Address $($proof.HostKey)`n", [Text.Encoding]::ASCII)
    $options = @{
        StrictHostKeyChecking = 'yes'; UserKnownHostsFile = $pin; GlobalKnownHostsFile = $empty
        HostKeyAlgorithms = 'ssh-ed25519'; IdentitiesOnly = 'yes'; BatchMode = 'yes'
        UpdateHostKeys = 'no'; ConnectTimeout = '10'; PasswordAuthentication = 'no'
    }
    $argsList = @('-F', $empty, '-i', $PrivateKey) + @(foreach ($option in $options.GetEnumerator()) {
        '-o'; "$($option.Key)=$($option.Value)"
    })
    $ssh = Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe'
    $verify = 'set -e; d=/var/lib/arcbox-provisioning; n=$(sudo -n stat -c %s $d/authorized_keys.before); if test $n -gt 0; then sudo -n cmp -n "$n" ~/.ssh/authorized_keys $d/authorized_keys.before; fi; sudo -n cat $d/instance-id'
    $observed = & $ssh @argsList "jumpstart@$Address" $verify
    if ($LASTEXITCODE -ne 0 -or $observed -cne $proof.Instance) {
        Stop-ArcBoxHostStep guest-access "First strict SSH did not confirm the installed key and host identity for $Name."
    }
    $imds = 'curl --noproxy ''*'' -sS --connect-timeout 3 --max-time 5 -H Metadata:true http://169.254.169.254/metadata/instance?api-version=2021-02-01 -o /dev/null 2>/dev/null; code=$?; test $code -eq 7 || test $code -eq 28'
    & $ssh @argsList "jumpstart@$Address" $imds
    if ($LASTEXITCODE -ne 0) { Stop-ArcBoxHostStep guest-access "IMDS isolation was not proved for $Name." }
    $options
}

function Wait-ArcBoxBaselineRegistration {
    param([string]$Group, [string]$Subscription, [datetimeoffset]$NotBefore,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 600)
    $expected = @{}
    foreach ($name in 'ArcBox-Win2K25', 'ArcBox-Ubuntu-01') {
        $expected["/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.HybridCompute/machines/$name"] = $name
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $machines = @(Get-AzConnectedMachine -ResourceGroupName $Group -SubscriptionId $Subscription -ErrorAction Stop)
        $seen = @{}
        foreach ($machine in $machines) {
            if (-not $machine.Id -or -not $expected.ContainsKey($machine.Id) -or $seen.ContainsKey($machine.Id)) {
                Stop-ArcBoxHostStep arc-inventory 'Unexpected or duplicate Arc machine in the workshop resource group.'
            }
            $seen[$machine.Id] = $true
        }
        if ($machines.Count -eq 2 -and @($machines | Where-Object Status -eq 'Connected').Count -eq 2) {
            foreach ($machine in $machines) {
                # The Az listing does not reliably supply systemData for a fresh-run check.
                $result = Invoke-AzRestMethod -Path "$($machine.Id)?api-version=2024-07-10" -Method GET -ErrorAction Stop
                if ([int]$result.StatusCode -ne 200) { throw 'Could not verify the Arc resource creation time.' }
                $item = $result.Content | ConvertFrom-Json -ErrorAction Stop
                $rawCreated = $item.systemData.createdAt
                if ($rawCreated -is [datetime]) { $rawCreated = $rawCreated.ToString('o') }
                $created = [datetimeoffset]::MinValue
                if ($item.id -ine $machine.Id -or $item.properties.status -ne 'Connected' -or
                    $rawCreated -notmatch '(?:Z|[+-]\d\d:\d\d)\z' -or
                    -not [datetimeoffset]::TryParse([string]$rawCreated, [ref]$created) -or
                    $created -lt $NotBefore -or $created -gt [datetimeoffset]::UtcNow) {
                    Stop-ArcBoxHostStep arc-inventory 'An Arc resource is stale, mismatched, or not Connected.'
                }
            }
            return $expected
        }
        if ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Seconds 10 }
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    Stop-ArcBoxHostStep arc-inventory 'The two expected Arc resources did not reach Connected before timeout.'
}

function Invoke-ArcBoxAz {
    param([string[]]$Arguments)
    $PSNativeCommandUseErrorActionPreference = $false
    $az = Join-Path $env:ProgramFiles 'Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
    & $az @Arguments
    if ($LASTEXITCODE -ne 0) {
        $failure = [InvalidOperationException]::new('Azure CLI request failed. See the recorded operation and native exit.')
        $failure.Data['ArcBoxReason'] = 'arc-feature'
        $failure.Data['ArcBoxNativeExit'] = [int]$LASTEXITCODE
        throw $failure
    }
}

function Receive-ArcBoxVhd {
    param([string]$Path, [string]$SourceUri, [string]$AzCopy,
        [ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedSha256)
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-VHD -Path $Path -ErrorAction Stop)) { throw 'Existing workshop VHDX failed validation; it was not overwritten.' }
        if ($ExpectedSha256 -and (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedSha256) {
            throw "Existing workshop image does not match the tested SHA-256: $(Split-Path -Leaf $Path)."
        }
        return
    }

    $pending = "$Path.$([guid]::NewGuid().ToString('N')).pending.vhdx"
    try {
        & $AzCopy copy $SourceUri $pending --overwrite=false --check-length=true --log-level=ERROR
        if ($LASTEXITCODE -ne 0) { throw "VHDX download returned $LASTEXITCODE." }
        if (-not (Test-Path -LiteralPath $pending -PathType Leaf) -or
            -not (Test-VHD -Path $pending -ErrorAction Stop)) {
            throw 'The staged VHDX did not pass Hyper-V validation.'
        }
        if ($ExpectedSha256 -and (Get-FileHash -LiteralPath $pending -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedSha256) {
            throw "Staged workshop image does not match the tested SHA-256: $(Split-Path -Leaf $Path)."
        }
        # File.Move refuses an existing destination, including one created during staging.
        [IO.File]::Move($pending, $Path)
    } finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction Continue }
    }
}
