$script:ArcBoxStepCatalog = @'
{
  "stages": {
    "arm-submit": "Submit deployment",
    "arm-observation": "Check deployment state",
    "bootstrap-extension": "Run bootstrap extension",
    "bootstrap": "Prepare ArcBox client",
    "disk": "Prepare lab storage",
    "os-volume": "Prepare system volume",
    "powershell": "Prepare PowerShell",
    "modules": "Load PowerShell modules",
    "artifacts": "Stage lab artifacts",
    "features": "Prepare Windows features",
    "tasks": "Register startup tasks",
    "reboot": "Restart ArcBox client",
    "post-reboot": "Resume after reboot",
    "dsc-common": "Install base software",
    "dsc-itpro": "Configure Hyper-V",
    "performance": "Sample host performance",
    "host-network": "Configure host network",
    "packages": "Install lab software",
    "identity": "Authenticate to Azure",
    "servers": "Configure guest VMs",
    "Nested guest setup": "Configure guest VMs",
    "guest-access": "Check guest access",
    "arc-connect": "Connect to Arc",
    "arc-features": "Configure Arc features",
    "apt-lock-wait": "Wait for package locks",
    "Win2K25 Arc onboarding": "Request Arc setup",
    "Ubuntu-01 Arc onboarding": "Request Arc setup",
    "Win2K25 Arc onboarding registration": "Connect to Arc",
    "Ubuntu-01 Arc onboarding registration": "Connect to Arc",
    "Win2K25 Arc onboarding connection": "Verify Arc connection",
    "Ubuntu-01 Arc onboarding connection": "Verify Arc connection",
    "workbook": "Deploy monitoring workbook",
    "proxy": "Configure lab proxy",
    "winget": "Check Windows Package Manager",
    "vhd-images": "Prepare guest images",
    "vhdx-transfer": "Download guest image",
    "vhdx-prepare": "Prepare guest image",
    "student-access": "Test student access",
    "student-rdp": "Test RDP sign-in",
    "student-windows": "Test Windows tools",
    "student-ubuntu": "Test Ubuntu access",
    "student-sql": "Run SSMS query"
  },
  "operations": {
    "Download installer": "Download installer",
    "Verify installer publisher": "Verify installer publisher",
    "Install MSI": "Install MSI",
    "Verify installed engine": "Verify PowerShell version",
    "Download pinned module": "Download pinned module",
    "Verify and stage module": "Stage verified module",
    "Install verified module files": "Install verified module",
    "Import locked module": "Import locked module",
    "Download artifact": "Download artifact",
    "Receive pinned script": "Stage pinned script",
    "Install Windows feature": "Install Windows feature",
    "Install Windows capability": "Install Windows capability",
    "Register startup task": "Register startup task",
    "Schedule client reboot": "Schedule client reboot",
    "Create the DHCP scope": "Create DHCP scope",
    "Create the lab NAT": "Create lab NAT",
    "Sign in with managed identity": "Use managed identity",
    "Prepare offline Linux disks": "Prepare Linux disks",
    "Create guest VM": "Create guest VM",
    "Request VM startup": "Start guest VM",
    "Verify VM running": "Verify guest VM running",
    "Open PowerShell Direct": "Open PowerShell Direct",
    "Copy the Arc agent installer": "Copy Arc installer",
    "Copy and verify SQL lab files": "Stage SQL lab files",
    "Configure the Ubuntu lab shell": "Configure Ubuntu shell",
    "Copy the shared Hyper-V shortcut": "Copy Hyper-V shortcut",
    "Set DHCP options": "Set DHCP options",
    "Download lab wallpaper": "Download lab wallpaper",
    "Save protected worker inputs": "Save worker inputs",
    "Stage worker helper": "Stage worker helper",
    "Disable automatic logon": "Disable automatic logon",
    "Remove obsolete automatic logon value": "Remove legacy autologon",
    "Create guest storage directory": "Create guest storage",
    "Guard and create partition with drive letter": "Create lab partition",
    "Guard and format volume": "Format lab volume",
    "Guard and initialize disk": "Initialize lab disk",
    "Protect guest storage directory": "Protect guest storage",
    "Create browser policy key": "Create browser policy key",
    "Disable browser sidebar": "Disable browser sidebar",
    "Enable Windows optional feature": "Enable optional feature",
    "Hide browser first-run experience": "Hide browser welcome",
    "Reserve the proxy DHCP lease": "Reserve proxy lease",
    "Restart guest network adapters": "Restart guest networking",
    "Select the deployment subscription": "Select Azure subscription",
    "Import Windows module": "Import Windows module",
    "Read locked module manifest": "Read module manifest",
    "Resolve provisioning dependencies": "Resolve provisioning dependencies",
    "Validate package closure": "Verify package dependencies",
    "Verify command provider": "Verify command provider",
    "Verify required installed module imports": "Verify module imports",
    "Resize and verify OS partition": "Resize system partition",
    "Add Azure CLI extension": "Add Azure CLI extension",
    "Request task start": "Request task start",
    "Install lab profile": "Install lab profile",
    "Retain recovery installer": "Keep recovery installer",
    "Save prepared boot checkpoint": "Save reboot checkpoint",
    "Copy the change tracking file": "Copy change tracking file",
    "Disable scheduled task": "Disable scheduled task",
    "Enable task execution evidence": "Enable task history",
    "Register student presentation task": "Register student task",
    "Stage Ubuntu lab shell enhancement": "Stage Ubuntu shell",
    "Load Windows PowerShell profile": "Load PowerShell profile",
    "Record loaded module provenance": "Record module provenance"
  },
  "operationStageIds": {
    "Transfer lab disk image": "vhdx-transfer",
    "Download and verify lab disk images": "vhdx-prepare"
  }
}
'@ | ConvertFrom-Json

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
    'arc-onboarding' = 'Check the first failed Arc onboarding operation.'
    'apt-lock-timeout' = 'Check the APT wait record and concurrent Ubuntu updates before recovery.'
    'apt-controller' = 'Check the reviewed Linux installer and APT controller prerequisites.'
    'package-install' = 'Check the private package evidence before attempting recovery.'
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
        [switch]$Durable, [switch]$Milestone, [string]$LabImpact, [string]$NextCheck, [string]$StudentHeadline,
        [switch]$WorkshopRecap
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
        $labelProperty = $null
        $stepId = $Stage
        if ($Operation) {
            $alias = $script:ArcBoxStepCatalog.operationStageIds.PSObject.Properties[$Operation]
            if ($alias) { $stepId = $alias.Value }
            $labelProperty = $script:ArcBoxStepCatalog.operations.PSObject.Properties[$Operation]
            if ($labelProperty) { $stepId = $Operation }
        }
        if (-not $labelProperty) { $labelProperty = $script:ArcBoxStepCatalog.stages.PSObject.Properties[$stepId] }
        $label = if ($labelProperty) { $labelProperty.Value }
        if ($label) { $row.stepId = $stepId; $row.label = $label }
        if ($Failure) {
            $exception = $Failure.Exception
            $origin = $exception.Data['ArcBoxIncidentId']
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
            $row.incident = if ($origin -is [string] -and $origin -cmatch '\A[a-f0-9]{32}\z') {
                @{id=$origin; relation='propagated'; effect=$Stage}
            } else {
                @{id=$id; relation='origin'}
            }
        }
        $nl = [Environment]::NewLine
        $t = if ($null -ne $ElapsedMs) { " | ${ElapsedMs} ms" } else { '' }
        $stepText = if ($label) { " [$label]" } else { '' }
        $text = "$(Format-ArcBoxJournalUtc $at) [$Severity] [$Stage]$stepText $Headline$t$nl"
        $text += "  $Owner | Run $($j.run) | Attempt $($j.attempt) | Boot $(Format-ArcBoxJournalUtc $j.boot)$nl"
        $objective = @{
            bootstrap='Prepare ArcBox-Client'; disk='Prepare storage for lab VMs'; 'os-volume'='Prepare the system volume'
            powershell='Prepare PowerShell'; modules='Load required PowerShell modules'; artifacts='Stage lab artifacts'
            features='Prepare Windows features'; tasks='Register scheduled tasks'; reboot='Restart and resume setup'
            packages='Install base software'; 'dsc-common'='Install base software'; 'dsc-itpro'='Prepare Hyper-V'
            'post-reboot'='Run unattended setup'; servers='Prepare nested lab VMs'; 'guest-access'='Verify guest access'
            'host-network'='Prepare the lab network'; identity='Sign in to Azure'
            'vhd-images'='Download and verify lab disk images'; proxy='Prepare the lab proxy'
            'arc-connect'='Connect lab VMs to Azure Arc'; 'arc-features'='Request Azure Arc features'
            'apt-lock-wait'='Wait for Ubuntu package updates'; workbook='Deploy the Azure workbook'
        }[$Stage]
        if (-not $objective) { $objective = $Stage }
        $title = "== $objective | $Owner =="
        if (-not $j.adminTitles) { $j.adminTitles = @{} }
        $adminHeading = if ($j.adminTitles[$Owner] -cne $title) { "$title$nl" } else { '' }
        $technical = $adminHeading + $text + "  $logName | Event $id | Sequence $sequence | Release $($j.release)$nl"
        if ($Operation) { $technical += "  Operation: $Operation$nl" }
        if ($StudentHeadline -and $StudentHeadline -cne $Headline) { $technical += "  Result: $StudentHeadline$nl" }
        if ($LastConfirmed) { $technical += "  Last confirmed: $LastConfirmed$nl" }
        if ($LabImpact) { $technical += "  Lab impact: $LabImpact$nl" }
        if ($NextCheck) { $technical += "  Next check: $NextCheck$nl" }
        # Do not project exception messages, invocation text, arguments or raw command streams.
        if ($row.failure) { $technical += ((Format-ArcBoxJournalDetail $row.failure 'error') -join $nl) + $nl }
        if ($Detail) { $technical += ((Format-ArcBoxJournalDetail $Detail 'evidence') -join $nl) + $nl }
        $records = [ordered]@{}
        $records[$logName] = ($row | ConvertTo-Json -Depth 8 -Compress) + $nl
        $records[$readableName] = $technical + $nl
        $propagated = $row.Contains('incident') -and $row.incident.relation -eq 'propagated'
        $advancedName = 'scripts\WorkshopDeployment.admin.log'
        $advancedPath = Join-Path $j.root $advancedName
        $advancedHeading = ''
        if (-not [IO.File]::Exists($advancedPath)) {
            $advancedHeading = "ArcBox ITPro | Advanced workshop deployment$nl" +
                "All times are UTC. Started or requested does not confirm completion.$nl$nl"
        }
        if ($advancedHeading -or $j.advancedTitle -cne $title) { $advancedHeading += "$title$nl" }
        $state = if ($Severity -ne 'INFO') { $Severity } elseif ($Detail -is [Collections.IDictionary]) {
            $outcome = if ($Detail.outcome) { $Detail.outcome } else { $Detail.structuredState }
            switch ($outcome) {
                { $_ -in 'started','start' } { 'STARTED' }
                'requested' { 'REQUESTED' }
                { $_ -in 'ok','succeeded','verified','downloaded','reused' } { 'OK' }
                default { 'INFO' }
            }
        } else { 'INFO' }
        $advancedText = if ($StudentHeadline -and $Severity -eq 'INFO') { $StudentHeadline } else { $Headline }
        $records[$advancedName] = $advancedHeading +
            ("{0}  {1,-10} {2}{3}  [#{4} | event {5} | attempt {6}]{7}" -f
                (Format-ArcBoxJournalUtc $at), $state, ("$stepText $advancedText".TrimStart()), $t, $sequence, $id, $j.attempt, $nl)
        if ($LastConfirmed) { $records[$advancedName] += "  Last confirmed: $LastConfirmed$nl" }
        if ($LabImpact) { $records[$advancedName] += "  Lab impact: $LabImpact$nl" }
        if ($NextCheck) { $records[$advancedName] += "  Next check: $NextCheck$nl" }
        if ($row.failure -and $null -ne $row.failure.nativeExit) {
            $records[$advancedName] += "  Native exit: $($row.failure.nativeExit)$nl"
        } elseif ($Detail -is [Collections.IDictionary] -and $Detail.nativeExit -is [int]) {
            $records[$advancedName] += "  Native exit: $($Detail.nativeExit)$nl"
        }
        if ($Detail -is [Collections.IDictionary] -and $Detail.messageDisposition -ceq 'Allowlisted' -and $Detail.message) {
            $records[$advancedName] += "  Diagnostic: $($Detail.message)$nl"
        }
        $workshopPath = Join-Path $j.root 'WorkshopDeployment.log'
        if (-not $DetailedOnly -and ($Milestone -or ($Severity -eq 'ERROR' -and -not $propagated))) {
            $followup = if ($Severity -eq 'ERROR' -or ($Severity -eq 'WARNING' -and $Failure -and -not $propagated)) {
                "  Last confirmed: $(if ($LastConfirmed) {$LastConfirmed} else {'This step did not complete.'})$nl" +
                "  Lab impact: $(if ($LabImpact) {$LabImpact} else {'Dependent lab steps are not ready.'})$nl" +
                "  Next check: $(if ($NextCheck) {$NextCheck} else {'See the linked administrator event. Cause not confirmed here.'})$nl"
            } else { '' }
            $workshopHeadline = if ($StudentHeadline) { $StudentHeadline } else { $Headline }
            $heading = ''
            if (-not [IO.File]::Exists($workshopPath)) {
                $heading = "ArcBox ITPro | Workshop deployment$nl" +
                    "Follow the main stages in order. All times are UTC. Event IDs link to the administrator logs.$nl$nl"
            }
            if ($heading -or $j.workshopTitle -cne $title) { $heading += "$title$nl" }
            $records['WorkshopDeployment.log'] = $heading + "[$Severity]$stepText $workshopHeadline$nl" + $followup +
                "  $(Format-ArcBoxJournalUtc $at) | Event $id | $logName | Sequence $sequence | Attempt $($j.attempt)$nl"
            if ($LocalPortalUrl) { $records['WorkshopDeployment.log'] += "  Azure portal: $LocalPortalUrl$nl" }
        }
        if ($WorkshopRecap -and [IO.File]::Exists($workshopPath)) {
            # The central log is already expurgated and append-only; scope prior incidents to this attempt.
            $issues = [Collections.Generic.List[string]]::new()
            $entry = $null
            foreach ($line in [IO.File]::ReadLines($workshopPath)) {
                if ($line -cmatch '^\[(ERROR|WARNING)\] (.+)$') { $entry = $line; continue }
                if ($line.StartsWith('[INFO] ', [StringComparison]::Ordinal)) { $entry = $null; continue }
                if ($line -cmatch '^  \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC \| Event ([a-f0-9]{32}) \| events\\[a-zA-Z0-9.-]+\.admin\.jsonl \| Sequence ([0-9]+) \| Attempt (.*)$') {
                    if ($entry -and $Matches[3] -ceq [string]$j.attempt) {
                        $issues.Add("  - $entry (Event $($Matches[1]), Sequence $($Matches[2]))")
                    }
                    $entry = $null
                }
            }
            $recap = if ($issues.Count) { $issues -join $nl } else { '  No warnings or errors recorded in this attempt.' }
            $records['WorkshopDeployment.log'] += "$nl== Warnings and errors | Attempt $($j.attempt) ==$nl$recap$nl$nl"
        }
        foreach ($sink in $records.Keys) {
            try {
                $path = Join-Path $j.root $sink
                $body = $records[$sink]
                if ($sink -eq $advancedName -and $readableName -notin $failed -and
                    [IO.File]::Exists((Join-Path $j.root $readableName))) {
                    $body += "  Related log: $Owner.admin.log$nl"
                }
                if ($Durable) {
                    $stream = [IO.FileStream]::new($path, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read, 4096, [IO.FileOptions]::WriteThrough)
                    try {
                        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                        $stream.Write($bytes,0,$bytes.Length)
                        $stream.Flush($true)
                    } finally { $stream.Dispose() }
                } else { [IO.File]::AppendAllText($path, $body) }
                if ($sink -eq 'WorkshopDeployment.log') { $j.workshopTitle = if ($WorkshopRecap) { $null } else { $title } }
                if ($sink -eq $readableName) { $j.adminTitles[$Owner] = $title }
                if ($sink -eq $advancedName) { $j.advancedTitle = $title }
                if ($sink -eq $logName -and $row.Contains('incident') -and $row.incident.relation -eq 'origin') {
                    $Failure.Exception.Data['ArcBoxIncidentId'] = $id
                }
            }
            catch { $failed += $sink }
        }
    } catch {
        $failed += $sink
    } finally { if ($lock) { $lock.Dispose() } }
    if ($failed) {
        $summary = if ($Failure) { " Error type: $($Failure.Exception.GetType().FullName)." } else { '' }
        Write-Warning "Workshop journal write failed ($($failed -join ', ')) | Event $id | $Owner [$Stage/$Severity]. $Headline$summary Check task or extension output and surviving local logs." -WarningAction Continue
        if ($Durable -and @($failed | Where-Object { $_ -ne 'scripts\WorkshopDeployment.admin.log' }).Count) {
            throw 'Required Bootstrap operation record could not be persisted.'
        }
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
    param([string]$Stage,[string]$Action,[string]$Target,[string]$Version,[string]$Repository,[switch]$DetailedOnly)
    if (-not $script:ArcBoxJournal -or $Action -cnotmatch '\A[A-Za-z][A-Za-z0-9 .:-]{1,75}\z' -or
        $Target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9 ._:/-]{0,115}\z' -or $Target -match '://' -or
        $Version -cnotmatch '\A[0-9., \[\]()]{0,40}\z' -or
        $Repository -cnotin '', 'PSGallery', 'Configured repository priority', 'Verified local staging', 'Verified machine modules') {
        throw 'Invalid Bootstrap operation metadata.'
    }
    $op = @{operationId=[guid]::NewGuid().ToString('N'); outcome='Started'; action=$Action; target=$Target
        version=$(if ($Version) { $Version }); repository=$(if ($Repository) { $Repository })
        engine=[string]$PSVersionTable.PSEdition; engineVersion=$PSVersionTable.PSVersion.ToString()
        startedAt=[datetime]::UtcNow.ToString('o')}
    $routine = $Action -cin 'Download pinned module','Verify and stage module','Install verified module files','Download artifact',
        'Read locked module manifest','Import locked module','Verify command provider','Record loaded module provenance'
    Write-ArcBoxJournal $Stage INFO "$Action - $Target (started)." -Detail $op -Operation $Action -DetailedOnly:($routine -or $DetailedOnly) -Durable
    $op.clock = [Diagnostics.Stopwatch]::StartNew()
    $op
}

function Get-ArcBoxWorkshopOperationResult {
    param([hashtable]$Operation)
    $target = $Operation.target
    $version = $Operation.version
    switch -CaseSensitive ($Operation.action) {
        'Download pinned module' { "$target module package downloaded. Expected version $version; archive not yet verified." }
        'Verify and stage module' { "$target module archive verified and staged at version $version; not yet confirmed installed." }
        'Install verified module files' { "$target module version $version confirmed on disk; import is separate." }
        'Read locked module manifest' { "$target installed manifest verified at version $version." }
        'Import locked module' { "$target module imported at verified version $version." }
        'Verify command provider' { "$target resolved to the verified module at version $version." }
        'Verify installed engine' { "PowerShell engine version $version verified by running the installed executable." }
        default {
            $expected = if ($version) { " Expected version $version; this action does not attest the installed version." } else { '' }
            "$($Operation.action) completed for $target.$expected"
        }
    }
}

function Complete-ArcBoxOperation {
    param([string]$Stage,[hashtable]$Operation,[System.Management.Automation.ErrorRecord]$Failure,[switch]$ContinueOnFailure,[switch]$DetailedOnly)
    $detail = $Operation.Clone()
    $elapsed = if ($detail.clock) { $detail.clock.ElapsedMilliseconds }
    $detail.Remove('clock')
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
        $guidance = @(switch ($Stage) {
            'host-network' { 'Guest network setup cannot proceed.', 'Check the DHCP scope and options, NAT, or shortcut named above before changing anything.' }
            'identity' { 'Azure-dependent lab setup cannot proceed.', 'Check the client managed identity, deployment scope and its access before retrying.' }
            'servers' { 'Dependent guest setup cannot proceed.', 'Check the named VM or file operation in Hyper-V before retrying.' }
            'guest-access' { 'Dependent guest configuration cannot proceed.', 'Check the named VM is running and its guest access or network service is ready.' }
            default { 'Dependent lab steps are not ready.', 'Check the named action and the linked administrator event before retrying.' }
        })
        Write-ArcBoxJournal $Stage ERROR "$($detail.action) failed for $($detail.target)." `
            -LastConfirmed 'This action started but did not complete successfully.' -LabImpact $guidance[0] -NextCheck $guidance[1] `
            -Detail $detail -Operation $detail.action -Failure $Failure -ElapsedMs $elapsed -DetailedOnly:($ContinueOnFailure -or $Stage -ceq 'disk') -Durable
        if ($ContinueOnFailure) {
            Write-ArcBoxJournal $Stage WARNING "$($detail.action) failed for $($detail.target); lab provisioning is continuing past this failure." `
                -Detail @{failedOperationId=$detail.operationId; bootstrapContinued=$true} -Milestone -Durable
        }
    } else {
        $detail.outcome = 'Succeeded'
        $routine = $DetailedOnly -or $Stage -cin 'disk','modules','features','tasks','artifacts','powershell','bootstrap','reboot' -or
            $detail.action -cin 'Download artifact','Record loaded module provenance','Add Azure CLI extension','Import Windows module'
        $result = Get-ArcBoxWorkshopOperationResult $detail
        Write-ArcBoxJournal $Stage INFO "$($detail.action) completed for $($detail.target)." `
            -Detail $detail -Operation $detail.action -ElapsedMs $elapsed -DetailedOnly:$routine -Milestone `
            -StudentHeadline $result -Durable
    }
}

function Invoke-ArcBoxOperation {
    param([string]$Stage,[string]$Action,[string]$Target,[scriptblock]$Command,[string]$Version,[string]$Repository,[switch]$DetailedOnly)
    $op = Start-ArcBoxOperation $Stage $Action $Target $Version $Repository -DetailedOnly:$DetailedOnly
    try { & $Command }
    catch {
        $failure = $_
        try { Complete-ArcBoxOperation $Stage $op -Failure $failure }
        catch { Write-Warning 'Operation failed, but its result record could not be persisted. Use the durable start as the last attempted action.' }
        throw $failure
    }
    Complete-ArcBoxOperation $Stage $op -DetailedOnly:$DetailedOnly
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
            if ($text.StartsWith('ArcBoxAptWait:v1:', [StringComparison]::Ordinal)) { continue }
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
        [Parameter(Mandatory)][ValidateSet('0600','0644','0755')][string]$Mode
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
        param($Token, $Group, $Tenant, $Location, $Subscription, $FilterSource, $Target)
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
        $packageMarker = if ($code -ne 0 -and $markers.Count -eq 0) {
            $packageMarkers = @($output | Where-Object {
                $_ -is [string] -and $_.Length -le 180 -and $_.StartsWith('ArcBoxPackageFailure:v1:', [StringComparison]::Ordinal)
            })
            if ($packageMarkers.Count -eq 1) { $packageMarkers[0] }
        }
        $id = "/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.HybridCompute/machines/$Target"
        $safe = if ($observed) { & ([scriptblock]::Create($FilterSource)) $output $id $Tenant }
        $wait = @($output | Where-Object { $_ -is [string] -and $_.Length -le 180 -and $_.StartsWith('ArcBoxAptWait:v1:', [StringComparison]::Ordinal) })
        [pscustomobject]@{Tag='arcbox-installer-v1'; Phase=$(if ($observed) {'agent-connect'} else {'native-command'});
            ExitCode=$code; ConnectObserved=$observed; ErrorCode=$safe.errorCode; PortalUrl=$safe.portalUrl; PackageMarker=$packageMarker
            Target=$Target; WaitMarker=$(if ($wait.Count -eq 1) {$wait[0]})
            ControllerUnavailable=($code -eq 125 -and $output -ccontains 'ArcBoxAptControllerUnavailable')}
    }
}

function ConvertFrom-ArcBoxPackageFailure {
    param([string]$Marker, [int]$ExitCode, [string]$Target)
    if ($ExitCode -le 0 -or $ExitCode -gt 255 -or $Marker.Length -gt 180) { return }
    $appendState = 'captured|truncated|unchanged|missing|unbound|unstable|unavailable'
    $pattern = '\AArcBoxPackageFailure:v1:(?<exit>[0-9]{1,3}):(?<at>unknown|[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z):' +
        '(?<ref>none|package\.[a-zA-Z0-9]{10}):(?<installer>captured|truncated-or-limit|empty|unavailable):' +
        "(?<apt>$appendState):(?<dpkg>$appendState):" + '(?<clue>apt-lock|apt-dependency|apt-download|dpkg-error|unclassified)\z'
    if ($Marker -cnotmatch $pattern -or [int]$Matches.exit -ne $ExitCode) { return }
    $at = $Matches.at
    if ($at -cne 'unknown') {
        $parsed = [datetime]::MinValue
        if (-not [datetime]::TryParseExact($at, 'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return }
    }
    if ($Matches.ref -ceq 'none' -and ($Matches.installer -cne 'unavailable' -or
        $Matches.apt -cne 'unavailable' -or $Matches.dpkg -cne 'unavailable' -or $Matches.clue -cne 'unclassified')) { return }
    $summary = switch -CaseSensitive ($Matches.clue) {
        'apt-lock' { 'APT reported a package-manager lock error.' }
        'apt-dependency' { 'APT reported a dependency resolution error.' }
        'apt-download' { 'APT reported a download error.' }
        'dpkg-error' { 'dpkg reported an error.' }
        default {
            if ($Matches.installer -cin 'captured','truncated-or-limit' -or
                $Matches.apt -cin 'captured','truncated' -or $Matches.dpkg -cin 'captured','truncated') {
                'No known error signature was found in the captured diagnostics.'
            } else {
                'No diagnostic detail was available for classification.'
            }
        }
    }
    [ordered]@{
        schema='arcbox-package-failure-v1'; target=$Target; stage='package-install'; nativeExit=$ExitCode
        failedAt=$(if ($at -cne 'unknown') { $at })
        captureRef=$(if ($Matches.ref -cne 'none') { $Matches.ref })
        installer=$Matches.installer; apt=$Matches.apt; dpkg=$Matches.dpkg; clue=$Matches.clue; summary=$summary
    }
}

function ConvertFrom-ArcBoxAptWait {
    param([string]$Marker, [string]$Target, [int]$ExitCode)
    $stamp = '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
    if ($Marker.Length -gt 180 -or $Target -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,62}\z' -or
        $Marker -cnotmatch ("\AArcBoxAptWait:v1:(?<start>$stamp):(?<end>$stamp):(?<elapsed>[0-9]{1,4}):(?<count>[1-9][0-9]{0,3}):" +
        '(?<state>released|timeout|waiting):(?<native>0|2|100):(?<ref>package\.[a-zA-Z0-9]{10})\z')) { return }
    if ([int]$Matches.elapsed -gt 1800 -or ($Matches.state -ceq 'timeout' -and $ExitCode -ne 124)) { return }
    $start = $end = [datetime]::MinValue
    $format = 'yyyy-MM-ddTHH:mm:ssZ'
    $culture = [Globalization.CultureInfo]::InvariantCulture
    $styles = [Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [datetime]::TryParseExact($Matches.start,$format,$culture,$styles,[ref]$start) -or
        -not [datetime]::TryParseExact($Matches.end,$format,$culture,$styles,[ref]$end)) { return }
    [ordered]@{schema='arcbox-apt-wait-v1'; stage='apt-lock-wait'; target=$Target; state=$Matches.state
        startedAt=$Matches.start; endedAt=$(if ($Matches.state -ne 'waiting') {$Matches.end}); elapsedSeconds=[int]$Matches.elapsed
        intervals=[int]$Matches.count; budgetSeconds=1800; captureRef=$Matches.ref
        aptNativeExit=$(if ($Matches.native -ne '0') {[int]$Matches.native})}
}

function Get-ArcBoxAgentStatusCommand {
    {
        $agent = if ($env:OS -eq 'Windows_NT') { Join-Path $env:ProgramW6432 'AzureConnectedMachineAgent\azcmagent.exe' }
            else { '/opt/azcmagent/bin/azcmagent' }
        $result = [pscustomobject]@{Tag='arcbox-agent-state-v1'; Status='Unverified'; LastHeartbeat=$null;
            ExitCode=$null; Reason='agent unavailable'; ErrorCode=$null; ResourceId=$null; TenantId=$null}
        if (-not (Test-Path -LiteralPath $agent -PathType Leaf)) { return $result }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo.FileName = $agent
        $process.StartInfo.Arguments = 'show --json'
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
            if ($document -is [pscustomobject]) {
                $resourceShape = '\A/subscriptions/[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}/resourceGroups/[a-z0-9._()-]{1,90}/providers/Microsoft\.HybridCompute/machines/[a-z0-9._-]{1,54}\z'
                if ($document.resourceId -is [string] -and $document.resourceId -match $resourceShape) {
                    $result.ResourceId = $document.resourceId
                } elseif ($null -eq $document.resourceId -and $document.subscriptionId -is [string] -and
                    $document.resourceGroup -is [string] -and $document.resourceName -is [string]) {
                    $id = "/subscriptions/$($document.subscriptionId)/resourceGroups/$($document.resourceGroup)/providers/Microsoft.HybridCompute/machines/$($document.resourceName)"
                    if ($id -match $resourceShape) { $result.ResourceId = $id }
                }
                $tenant = [guid]::Empty
                if ($document.tenantId -is [string] -and [guid]::TryParseExact($document.tenantId,'D',[ref]$tenant) -and
                    $tenant -ne [guid]::Empty) { $result.TenantId = $tenant.ToString('D') }
                foreach ($state in 'Connected','Disconnected','Expired','Not registered') {
                    if ($document.status -is [string] -and $document.status.Trim() -ieq $state) {
                        $result.Status = $state
                        $result.Reason = $null
                        break
                    }
                }
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

function Get-ArcBoxResidentIdentityState {
    param($Agent, [string]$ExpectedId, [string]$Tenant)
    if ([string]::IsNullOrWhiteSpace($ExpectedId) -or [string]::IsNullOrWhiteSpace($Tenant) -or
        [string]::IsNullOrWhiteSpace($Agent.ResourceId) -or [string]::IsNullOrWhiteSpace($Agent.TenantId)) {
        return 'Unverified'
    }
    if ($Agent.ResourceId -ieq $ExpectedId -and $Agent.TenantId -ieq $Tenant) { return 'Matched' }
    'Mismatch'
}

function Write-ArcBoxGuestConnection {
    param([string]$Name, [string]$Stage, [string]$Transport, [string]$GuestLog, [scriptblock]$Read,
        [bool]$Registered, [string]$Guest, [string]$Group, [string]$Subscription, [string]$Tenant)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $attempts = if ($Registered) { 3 } else { 1 }
    $detail = [ordered]@{command='azcmagent show --json'; expected='Connected'; target=$Guest;
        status='Unverified'; lastHeartbeat=$null; nativeExit=$null; errorCode=$null; reason=$null; transport=$Transport; guestLog=$GuestLog;
        residentIdentity='Unverified'}
    $expectedId = if ($Group -and $Subscription -and $Guest) {
        "/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.HybridCompute/machines/$Guest"
    }
    for ($i = 1; $i -le $attempts; $i++) {
        $detail.reads = $i
        $detail.status = 'Unverified'
        $detail.nativeExit = $null
        $detail.errorCode = $null
        $detail.reason = $null
        $detail.lastHeartbeat = $null
        $detail.residentIdentity = 'Unverified'
        try { $rows = @(& $Read) }
        catch {
            $detail.reason = "$Transport status read failed or timed out"
            break
        }
        if ($rows.Count -ne 1 -or $rows[0].Tag -cne 'arcbox-agent-state-v1' -or
            $rows[0].Status -cnotin 'Unverified','Connected','Disconnected','Expired','Not registered' -or
            ($null -ne $rows[0].ExitCode -and $rows[0].ExitCode -isnot [int]) -or
            ($rows[0].Status -ne 'Unverified' -and ($null -eq $rows[0].ExitCode -or $rows[0].ExitCode -ne 0))) {
            $detail.reason = 'agent status response could not be parsed'
            break
        }
        $row = $rows[0]
        $detail.status = $row.Status
        $detail.nativeExit = $row.ExitCode
        if ($row.ExitCode -eq 0) { $detail.residentIdentity = Get-ArcBoxResidentIdentityState $row $expectedId $Tenant }
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
        { $_ -in 'Disconnected','Expired','Not registered' } { "The local agent reports $_. Check the guest agent log and network path." }
        default { "Connection Unverified: $($detail.reason). Check the guest agent and remoting path." }
    }
    $when = if ($detail.lastHeartbeat) { " Last known heartbeat: $(Format-ArcBoxJournalUtc $detail.lastHeartbeat)." }
        else { ' No heartbeat timestamp was verified.' }
    $identitySummary = switch ($detail.residentIdentity) {
        'Matched' { ' The resident Azure resource identity matched.' }
        'Mismatch' { ' The resident Azure resource identity did not match.' }
        default { ' The resident Azure resource identity was not verified.' }
    }
    $level = if ($detail.status -eq 'Connected' -and $detail.residentIdentity -eq 'Matched') {'INFO'} else {'WARNING'}
    Write-ArcBoxJournal "$Stage connection" $level "${Stage}: $observation$when$identitySummary" -Owner $Name -Operation 'azcmagent show' -Milestone `
        -LastConfirmed 'Read-only guest evidence; this does not override the registration result.' -Detail $detail -ElapsedMs $clock.ElapsedMilliseconds
}

function Invoke-ArcBoxGuestInstaller {
    param([string]$Name, [string]$Stage, [scriptblock]$Action, [string]$Transport, [string]$GuestLog,
        [scriptblock]$ReadStatus, [switch]$NonBlocking,
        [ValidateSet('ArcBox-Win2K25','ArcBox-Ubuntu-01')][string]$Guest,
        [string]$Group, [string]$Subscription, [string]$Tenant, [hashtable]$RegistrationLinks)
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $detail = [ordered]@{transport=$Transport; guestLog=$GuestLog; protocol='arcbox-installer-v1'; outcome='dispatch'; registration='Not observed'}
    if ($NonBlocking) { $detail.nonBlocking = $true }
    if ($Guest) { $detail.target = $Guest }
    Write-ArcBoxJournal $Stage INFO "Requesting $Name over $Transport. Guest execution is not yet confirmed." -Owner $Name -Detail $detail
    $last = 'Invocation requested. The installer did not return a verified status.'
    $windowsHelper = $Name -ceq 'installArcAgent.ps1'
    $registrationError = $null
    $target = $wait = $package = $portal = $null
    $reason = 'arc-onboarding'
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
        if (-not $windowsHelper -and $results[0].PSObject.Properties['Target'] -and
            $results[0].Target -cmatch '\A[A-Za-z0-9][A-Za-z0-9.-]{0,62}\z') {
            $target = $results[0].Target
            $wait = ConvertFrom-ArcBoxAptWait $results[0].WaitMarker $target $code
            if ($wait) {
                $message = switch ($wait.state) {
                    'released' { "Package manager locks cleared on $target after $($wait.elapsedSeconds) seconds of waiting." }
                    'timeout' { "Package manager locks did not clear on $target before the 30-minute deadline." }
                    default { "Package manager waiting on $target has no confirmed finish." }
                }
                Write-ArcBoxJournal 'apt-lock-wait' INFO $message -Owner $Name -Detail $wait -Milestone
            }
        }
        if (-not $windowsHelper -and $detail.phase -ceq 'native-command' -and $code -gt 0 -and
            $results[0].PSObject.Properties['PackageMarker']) {
            $package = ConvertFrom-ArcBoxPackageFailure $results[0].PackageMarker $code $target
            if ($package) {
                $detail.phase = $package.stage
                $detail.packageFailure = $package
                $reason = 'package-install'
            }
            if ($wait -and $wait.state -ceq 'timeout') {
                $detail.phase = 'apt-lock-wait'
                $detail.nativeExit = $wait.aptNativeExit
                $detail.controllerExit = $code
                if ($package) { $package.nativeExit = $null }
                $reason = 'apt-lock-timeout'
            } elseif ($results[0].PSObject.Properties['ControllerUnavailable'] -and $results[0].ControllerUnavailable) {
                $detail.phase = 'apt-controller'
                $detail.nativeExit = $null
                $detail.controllerExit = $code
                $reason = 'apt-controller'
            }
        }
        if ($results[0].ConnectObserved) {
            $detail.registration = if ($code -eq 0) {'Succeeded'} else {'Failed'}
            if ($results[0].ErrorCode -cmatch '\AAZCM[0-9]{4}\z') { $detail.errorCode = $results[0].ErrorCode }
            if ($Guest -and $Subscription -cmatch '\A[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}\z' -and
                $Group -cmatch '\A[a-zA-Z0-9._()-]{1,90}\z') {
                $expectedPortal = "https://portal.azure.com/#/resource/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.HybridCompute/machines/$Guest"
                if ($results[0].PortalUrl -is [string] -and $results[0].PortalUrl -ieq $expectedPortal) { $portal = $expectedPortal }
            }
            $detail.portalLinkEmitted = [bool]$portal
        }
        $last = "$Transport returned a validated installer result; the connection read is separate."
        if ($null -eq $code) {
            $detail.outcome = 'guest-step-failure'
            $detail.guestErrorType = $results[0].ErrorType
            throw [InvalidOperationException]::new("$Name failed in $($detail.phase) before observing a native exit.")
        }
        if ($code -ne 0) {
            $detail.outcome = if ($reason -eq 'apt-lock-timeout') {'lock-timeout'} else {'native-failure'}
            $errorDetail = [InvalidOperationException]::new("$Name returned native exit $code ($($detail.phase)). Inspect the indicated guest log if that stage reached it.")
            if ($null -ne $detail.nativeExit) { $errorDetail.Data['ArcBoxNativeExit'] = $detail.nativeExit }
            $errorDetail.Data['ArcBoxReason'] = $reason
            throw $errorDetail
        }
        if (-not $results[0].ConnectObserved) {
            $detail.outcome = 'missing-connect-result'
            throw [InvalidOperationException]::new('No azcmagent connect result was confirmed.')
        }
        $detail.outcome = 'exit-zero'
        Write-ArcBoxJournal "$Stage registration" INFO 'Registration succeeded: azcmagent connect returned exit 0. Checking local connection separately.' `
            -Owner $Name -Operation 'azcmagent connect' -Detail $detail -LastConfirmed $last -ElapsedMs $watch.ElapsedMilliseconds `
            -Milestone -Durable -LocalPortalUrl $portal -StudentHeadline "${Stage}: registration succeeded; local connection is a separate check."
        if ($portal -and $null -ne $RegistrationLinks) { $RegistrationLinks[$Guest] = $true }
    } catch {
        $registrationError = $_
        $next = switch ($detail.outcome) {
            'transport' { "$Transport failed before a result arrived. Check guest readiness and session access; no guest log is guaranteed." }
            'native-failure' {
                if ($detail.registration -eq 'Failed') { "Registration failed: azcmagent connect returned exit $($detail.nativeExit). Check the guest agent log." }
                elseif ($detail.phase -eq 'package-install') { "The Linux Arc agent package did not install on $target. Azure Arc registration did not start." }
                elseif ($detail.phase -eq 'apt-controller') { "Package setup on $target stopped at the installer safety check or lock controller. Registration did not start." }
                else { "$Stage failed. Registration was not observed." }
            }
            'lock-timeout' { "The 30-minute package lock deadline expired on $target. Azure Arc registration did not start." }
            'guest-step-failure' { "$Name failed in $($detail.phase) before observing a native exit. Check the stage and indicated guest logs." }
            'missing-connect-result' { "$Name did not confirm an azcmagent connect result. Check the staged helper and guest logs." }
            'missing-result' { "$Name returned no installer result. Check the remote session and guest log before any retry." }
            'malformed-result' { "$Name returned an invalid installer result. Check the helper version and guest log before any retry." }
            'duplicate-result' { "$Name returned more than one result. Check the helper version and guest log before any retry." }
            default { 'The guest response did not establish an installer outcome. Check the remote session and guest log before any retry.' }
        }
        $severity = if ($NonBlocking) { 'WARNING' } else { 'ERROR' }
        Write-ArcBoxJournal "$Stage registration" $severity $next -Milestone:$NonBlocking -LocalPortalUrl $portal `
            -Owner $Name -Operation $(if ($detail.registration -eq 'Failed') {'azcmagent connect'} else {$Name}) `
            -Detail $detail -LastConfirmed $last -ElapsedMs $watch.ElapsedMilliseconds -Failure $_ `
            -LabImpact $(if ($NonBlocking) { 'Arc-dependent exercises for this guest are not ready; other lab setup can continue.' }
                else { 'Arc-dependent exercises for this guest are not ready.' }) -StudentHeadline "$Stage did not complete. $(
                if ($reason -eq 'apt-lock-timeout') { 'The package manager lock did not clear and registration did not start.' }
                elseif ($detail.phase -eq 'package-install') { 'The agent package did not install and registration did not start.' }
                elseif ($detail.registration -eq 'Failed') { "Registration returned exit $($detail.nativeExit); check the guest agent log." }
                else { 'Check the referenced administrator event for the verified result.' })" `
            -NextCheck $(if ($reason -eq 'apt-lock-timeout') { $script:ArcBoxHostReasons[$reason] }
                elseif ($package) { $package.summary + ' Check the private package evidence before retrying.' }
                else { 'Check the linked administrator event and guest evidence. Cause not confirmed here.' })
    }
    if ($ReadStatus) {
        try { Write-ArcBoxGuestConnection $Name $Stage $Transport $GuestLog $ReadStatus ($detail.registration -eq 'Succeeded') $Guest $Group $Subscription $Tenant }
        catch { Write-ArcBoxJournal "$Stage connection" WARNING 'Connection Unverified: the client could not record the guest status. Check the guest agent log.' -Owner $Name -Failure $_ }
    }
    if ($registrationError) { throw $registrationError }
}

function Invoke-ArcBoxGuestRegistration {
    param([string]$Guest, [scriptblock]$Action)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    try { & $Action | Out-Null; return $null }
    catch {
        if (-not $_.Exception.Data['ArcBoxIncidentId']) {
            Write-ArcBoxJournal arc-connect WARNING "${Guest}: Arc registration could not be completed." `
                -Failure $_ -ElapsedMs $clock.ElapsedMilliseconds -Milestone -Durable `
                -Detail @{target=$Guest; outcome='registration-unverified'; nonBlocking=$true} `
                -LastConfirmed 'Guest preparation completed; Arc registration was not verified.' `
                -LabImpact 'Arc exercises for this guest are not ready; other lab setup can continue.' `
                -NextCheck 'Check the referenced administrator event and verify the guest and Azure Arc status before retrying.'
        }
        return $_
    }
}

function Write-ArcBoxArcFeaturesNotReached {
    param([string]$Guest, [System.Management.Automation.ErrorRecord]$Failure)
    Write-ArcBoxJournal arc-features WARNING "${Guest}: monitoring associations, extensions and patch assessment were not requested because this guest was not verified Connected. Check Arc registration before attempting these exercises." `
        -Failure $Failure -Milestone -Durable -Detail @{target=$Guest; outcome='not-reached'; nonBlocking=$true}
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
        [string]$Reason, [switch]$LegacyOnly, [System.Management.Automation.ErrorRecord]$Failure
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
            performance='Host sampler'; 'post-reboot'='SYSTEM provisioning'; 'dsc-common'='Pinned machine packages'
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
        $milestone = ($State -eq 'ok' -and $Stage -in 'bootstrap','reboot','powershell','modules','features','tasks','dsc-common','dsc-itpro','servers','guest-access','arc-connect','arc-features','workbook','post-reboot') -or
            ($State -eq 'failed' -and $Stage -in 'bootstrap','post-reboot','performance') -or
            ($State -eq 'requested' -and $Stage -eq 'arc-features') -or
            ($State -eq 'start' -and $Stage -in 'bootstrap','dsc-common','servers','arc-connect')
        $student = switch ("$Stage/$State") {
            'post-reboot/ok' { 'The SYSTEM worker reached the end of provisioning. Resolve any Arc warnings before the affected exercises; verify RDP and SSMS in the student account.' }
            'post-reboot/failed' { 'Automated ITPro provisioning stopped. The lab is not ready for handoff.' }
            'reboot/ok' { 'ArcBox-Client restarted and Hyper-V is running. Automated guest setup is resuming.' }
            'bootstrap/start' { 'ArcBox-Client preparation started. Its outcome is not yet verified.' }
            'bootstrap/ok' { 'ArcBox-Client preparation finished and requested a restart. Wait for automated setup to resume.' }
            'bootstrap/failed' { 'ArcBox-Client preparation stopped. The lab is not ready for handoff.' }
            'guest-access/ok' { 'Hyper-V guest access checks passed. Arc registration is a separate step.' }
            'dsc-common/ok' { 'The required machine tools were installed or verified on ArcBox-Client. Hyper-V setup is next.' }
            'dsc-itpro/ok' { 'Hyper-V configuration checks passed on ArcBox-Client. Guest setup is next.' }
            'arc-connect/ok' { 'Azure Arc registration was confirmed for the expected lab guests. Arc features are checked separately.' }
            'arc-features/ok' { 'Arc feature setup returned. Check the requested extensions and assessments before using those exercises.' }
            'workbook/ok' { 'Workbook setup returned. Open the workbook to verify it displays lab data.' }
            default { $headline }
        }
        Write-ArcBoxJournal $Stage $level $headline -Detail @{structuredState=$State; reason=$Reason} -ElapsedMs $ms `
            -Milestone:$milestone -StudentHeadline $student -Failure $Failure -NextCheck $(if ($State -eq 'failed') { $script:ArcBoxHostReasons[$Reason] })
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
            Sha256 = 'ee5a486e210d111fae59f96a9e426128f9e37d7fcd1bca63e2e9d56ccb2937bc'
        }
        'installArcAgentUbuntu.sh' = @{
            Uri = "${TemplateBaseUrl}artifacts/installArcAgentUbuntu.sh"
            Sha256 = '7c85ec52d554abecd685a664862b679a141d1178d090fb5787cdd4a6a7a98227'
        }
        'arcbox_apt.py' = @{
            Uri = "${TemplateBaseUrl}artifacts/arcbox_apt.py"
            Sha256 = '33cfb095795c2ac3180320c7d78389222be2e472dbb298082bbb2d79d53ab5ff'
        }
        'ArcBox.LinuxShell.sh' = @{
            Uri = "${TemplateBaseUrl}artifacts/ArcBox.LinuxShell.sh"
            Sha256 = '95f97685dcf3993f3847357b7e449218090b5baf78a4802c379a6122ca268036'
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
    '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f (Join-Path $Work 'ArcBoxPostReboot.ps1')
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
        Write-ArcBoxHostEvent $Stage failed (Get-ArcBoxHostFailureCode $_ $Reason) -Failure $_
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
    $taskAction = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Attempt $Attempt"
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::FromHours(12))
    Invoke-ArcBoxOperation performance 'Register startup task' 'ArcBox-HostBaseline' {
        Register-ScheduledTask -TaskName 'ArcBox-HostBaseline' -TaskPath '\' -Action $taskAction -Trigger (New-ScheduledTaskTrigger -AtStartup) `
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
                -ElapsedMs $clock.ElapsedMilliseconds -Milestone:(!$VerifyOnly)
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
            -ElapsedMs $clock.ElapsedMilliseconds -Milestone
    } catch {
        if (-not $_.Exception.Data['ArcBoxReason']) { $_.Exception.Data['ArcBoxReason'] = 'disk-write' }
        $detail = if ($_.Exception.Data['ArcBoxReason'] -in 'disk-contract','disk-discovery','disk-identity','disk-letter','disk-layout','disk-drift') {
            $_.Exception.Message
        } else { "$operation did not complete or verify." }
        Write-ArcBoxJournal disk ERROR "$detail $last $($script:ArcBoxHostReasons[$_.Exception.Data['ArcBoxReason']])" `
            -ElapsedMs $clock.ElapsedMilliseconds -Failure $_ -LastConfirmed $last -Detail @{operation=$operation} `
            -Milestone -LabImpact 'Nested VM storage is not verified; VM provisioning cannot proceed.' `
            -NextCheck $script:ArcBoxHostReasons[$_.Exception.Data['ArcBoxReason']]
        throw
    }
}

function Test-ArcBoxPowerShell {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $version = & $Path -NoLogo -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' 2>$null
    $LASTEXITCODE -eq 0 -and "$version" -ceq '7.6.10'
}

function Get-ArcBoxVersionToken {
    param([string]$Value)
    if ($Value -cmatch '\A[0-9]+(?:\.[0-9]+){1,5}(?:p[0-9]+|\.windows\.[0-9]+)?(?:[+-][A-Za-z0-9][A-Za-z0-9.+~-]*)?\z' -and $Value.Length -le 80) {
        $Value
    }
}

function Get-ArcBoxToolVersion {
    param([string]$Path, [string]$Arguments, [string]$Pattern)
    $start = [Diagnostics.ProcessStartInfo]::new($Path, $Arguments)
    $start.WorkingDirectory = Split-Path -Parent $Path
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $proc = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        if (-not $proc.WaitForExit(5000)) { $proc.Kill(); throw 'Version probe timed out.' }
        if (-not $stdout.Wait(500) -or -not $stderr.Wait(500) -or $proc.ExitCode -ne 0) { throw 'Version probe did not complete successfully.' }
        foreach ($text in $stdout.Result, $stderr.Result) {
            if ($text.Length -le 512 -and $text.Trim() -cmatch $Pattern) {
                return (Get-ArcBoxVersionToken $Matches['version'])
            }
        }
    } finally { $proc.Dispose() }
}

function Write-ArcBoxWindowsInventory {
    param([ValidateSet('DHCP','Hyper-V','Containers','VirtualMachinePlatform','OpenSSH')][string[]]$Group,
        [switch]$AfterReboot, [string]$RestartHint)
    $moment = if ($AfterReboot) { 'post-reboot readback' } else { 'pre-reboot readback' }
    foreach ($item in $Group) {
        try {
            switch ($item) {
                { $_ -in 'Containers','VirtualMachinePlatform' } {
                    $state = [string](Get-WindowsOptionalFeature -Online -FeatureName $item -ErrorAction Stop).State
                    Write-ArcBoxWindowsFeatureState $item $state $moment $RestartHint
                }
                'OpenSSH' {
                    $state = [string](Get-WindowsCapability -Online -Name 'OpenSSH.Client~~~~0.0.1.0' -ErrorAction Stop).State
                    Write-ArcBoxWindowsFeatureState 'OpenSSH.Client' $state $moment $RestartHint
                }
                default {
                    $names = if ($item -eq 'DHCP') { @('DHCP','RSAT-DHCP') } else { @('Hyper-V','RSAT-Hyper-V-Tools') }
                    $seen = @{}
                    for ($i = 0; $i -lt $names.Count; $i++) {
                        $name = $names[$i]
                        if ($seen.ContainsKey($name)) { continue }
                        $seen[$name] = $true
                        try {
                            $feature = Get-WindowsFeature -Name $name -ErrorAction Stop
                            Write-ArcBoxWindowsFeatureState $name ([string]$feature.InstallState) $moment $RestartHint
                            if ($feature.SubFeatures) { $names += @($feature.SubFeatures) }
                        } catch { Write-ArcBoxWindowsFeatureState $name '' $moment $RestartHint }
                    }
                }
            }
        } catch {
            $name = if ($item -eq 'OpenSSH') { 'OpenSSH.Client' } else { $item }
            Write-ArcBoxWindowsFeatureState $name '' $moment $RestartHint
        }
    }
}

function Write-ArcBoxWindowsFeatureState {
    param([string]$Name, [string]$State, [string]$Moment, [string]$RestartHint)
    if ($Name -cnotmatch '\A[A-Za-z0-9.-]{1,80}\z') { throw 'Invalid Windows feature inventory name.' }
    $known = $State -cin 'Installed','Available','Removed','Enabled','Disabled','DisabledWithPayloadRemoved',
        'EnablePending','DisablePending','InstallPending','UninstallPending','NotPresent','Staged'
    $status = if ($known) { $State } else { 'state not observed' }
    $restart = if ($State -cmatch 'Pending\z') { ' Restart pending; verify the state after reboot.' }
        elseif ($RestartHint -in 'Yes','True') { ' The servicing request reported a restart requirement; confirm after reboot.' }
        else { '' }
    $level = if ($known) { 'INFO' } else { 'WARNING' }
    Write-ArcBoxJournal features $level "$Name Windows component: $status ($Moment).$restart" -DetailedOnly:($level -eq 'INFO') -Milestone -Durable
}

function Install-ArcBoxPowerShell {
    param([string]$Executable, [string]$RecoveryMsi)
    $installed = Test-ArcBoxPowerShell $Executable
    if (-not $installed -and (Test-Path -LiteralPath $Executable)) {
        Stop-ArcBoxHostStep ps-existing 'Existing PowerShell is not the expected version; no downgrade attempted.'
    }
    if ($installed) {
        Write-ArcBoxJournal powershell INFO 'Existing PowerShell engine version 7.6.10 verified and reused.' -Milestone -Durable
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

function Get-ArcBoxGuestArcResource {
    param([string]$Id, [datetimeoffset]$NotBefore)
    $result = Invoke-AzRestMethod -Path "${Id}?api-version=2024-07-10" -Method GET -ErrorAction Stop
    if ([int]$result.StatusCode -eq 404) { return }
    if ([int]$result.StatusCode -ne 200) { Stop-ArcBoxHostStep arc-inventory 'The expected Arc resource could not be read.' }
    $item = $result.Content | ConvertFrom-Json -ErrorAction Stop
    $rawCreated = $item.systemData.createdAt
    if ($rawCreated -is [datetime]) { $rawCreated = $rawCreated.ToString('o') }
    $created = [datetimeoffset]::MinValue
    if ($item.id -ine $Id -or $rawCreated -notmatch '(?:Z|[+-]\d\d:\d\d)\z' -or
        -not [datetimeoffset]::TryParse([string]$rawCreated, [ref]$created) -or
        $created -lt $NotBefore -or $created -gt [datetimeoffset]::UtcNow) {
        Stop-ArcBoxHostStep arc-inventory 'An Arc resource is stale or mismatched.'
    }
    $item
}

function Wait-ArcBoxBaselineRegistration {
    param([string]$Group, [string]$Subscription, [datetimeoffset]$NotBefore, [hashtable]$Attempts,
        [ValidateRange(1,600)][int]$TimeoutSeconds = 600, [hashtable]$RegistrationLinks)
    $pending = @{}
    $connected = @{}
    $failures = @{}
    foreach ($guest in 'ArcBox-Win2K25','ArcBox-Ubuntu-01') {
        if (-not $Attempts.ContainsKey($guest)) { throw "Missing Arc attempt result for $guest." }
        if ($Attempts[$guest]) { $failures[$guest] = $Attempts[$guest]; continue }
        $pending[$guest] = "/subscriptions/$Subscription/resourceGroups/$Group/providers/Microsoft.HybridCompute/machines/$guest"
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($pending.Count) {
        foreach ($guest in @($pending.Keys | Sort-Object)) {
            $id = $pending[$guest]
            $reportedStatus = 'Not observed'
            try {
                $item = Get-ArcBoxGuestArcResource $id $NotBefore
                if ($item -and $item.properties.status -cin 'Connected','Disconnected','Expired','Error') {
                    $reportedStatus = $item.properties.status
                }
                if ($reportedStatus -cne 'Connected') {
                    if ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) { continue }
                    Stop-ArcBoxHostStep arc-inventory 'The expected Arc resource was not verified Connected before the inventory deadline.'
                }
                $version = Get-ArcBoxVersionToken $item.properties.agentVersion
                $evidence = if ($version) { "Azure-reported installed version: $version." } else { 'Installed version not observed.' }
                Write-ArcBoxJournal arc-connect INFO "$guest Azure Connected Machine agent: Azure resource verified Connected. $evidence" `
                    -Milestone -LocalPortalUrl $(if ($null -eq $RegistrationLinks -or -not $RegistrationLinks[$guest]) {
                        "https://portal.azure.com/#/resource$($item.id)"
                    })
                $connected[$guest] = $id
            } catch {
                $failures[$guest] = $_
                Write-ArcBoxJournal arc-connect WARNING "${guest}: Azure Arc connection was not verified." -Failure $_ -Milestone -Durable `
                    -ElapsedMs $clock.ElapsedMilliseconds `
                    -Detail @{target=$guest; outcome='connection-unverified'; observedStatus=$reportedStatus; nonBlocking=$true} `
                    -LastConfirmed 'The registration command returned successfully; Azure connection was not verified.' `
                    -LabImpact 'Arc exercises for this guest are not ready; other lab setup can continue.' `
                    -NextCheck 'Check the referenced administrator event and compare the local agent state with Azure inventory.'
            }
            $pending.Remove($guest)
        }
        if ($pending.Count) {
            $remaining = $TimeoutSeconds - $clock.Elapsed.TotalSeconds
            if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int](1000 * [Math]::Min(10, $remaining))) }
        }
    }
    @{Connected=$connected; Failures=$failures}
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
        [Parameter(Mandatory)][ValidatePattern('\AVBD-ArcBox-[A-Za-z0-9-]+\.vhdx\z')][string]$ImageName,
        [ValidatePattern('\A[0-9a-f]{64}\z')][string]$ExpectedSha256)
    $PSNativeCommandUseErrorActionPreference = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $operation = 'Download and verify lab disk images'
    $detail = @{image=$ImageName; operationId=[guid]::NewGuid().ToString('N'); startedAt=[datetime]::UtcNow.ToString('o'); outcome='started'
        hashRequired=[bool]$ExpectedSha256; sha256Verified=$false}
    Write-ArcBoxJournal vhd-images INFO "${ImageName}: checking for a local image before transfer. Not yet verified." `
        -DetailedOnly -Operation $operation -Detail $detail
    $pending = $null
    $phase = 'existing-image-check'
    try {
        $reuse = Test-Path -LiteralPath $Path
        $candidate = $Path
        if (-not $reuse) {
            $phase = 'transfer'
            $pending = "$Path.$([guid]::NewGuid().ToString('N')).pending.vhdx"
            $candidate = $pending
            $transfer = @{ image=$ImageName; operationId=[guid]::NewGuid().ToString('N')
                parentOperationId=$detail.operationId; startedAt=[datetime]::UtcNow.ToString('o'); outcome='started' }
            Write-ArcBoxJournal vhd-images INFO "${ImageName}: AzCopy transfer started." `
                -Operation 'Transfer lab disk image' -Detail $transfer -DetailedOnly
            $transfer.transferStartedAt = [datetime]::UtcNow.ToString('o')
            $transferClock = [Diagnostics.Stopwatch]::StartNew()
            $nativeExit = $null
            try {
                $nativeExit = & {
                    # Windows PowerShell treats redirected native stderr as a nonterminating error.
                    $ErrorActionPreference = 'Continue'
                    $previousExit = $global:LASTEXITCODE
                    try {
                        $global:LASTEXITCODE = $null
                        & $AzCopy copy $SourceUri $pending --overwrite=false --check-length=true --log-level=ERROR 2>&1 | Out-Null
                        $global:LASTEXITCODE
                    } finally { $global:LASTEXITCODE = $previousExit }
                }
            } finally {
                $transferClock.Stop()
                $transfer.endedAt = [datetime]::UtcNow.ToString('o')
                $transfer.outcome = if ($null -ne $nativeExit -and $nativeExit -eq 0) { 'succeeded' } else { 'failed' }
                $transfer.nativeExitCode = $nativeExit
                $level = if ($transfer.outcome -eq 'succeeded') { 'INFO' } else { 'WARNING' }
                Write-ArcBoxJournal vhd-images $level "${ImageName}: AzCopy transfer $($transfer.outcome)." `
                    -Operation 'Transfer lab disk image' -Detail $transfer -ElapsedMs $transferClock.ElapsedMilliseconds `
                    -DetailedOnly
            }
            if ($null -eq $nativeExit) { throw 'AzCopy did not return a process exit code.' }
            if ($nativeExit -ne 0) {
                $failure = [InvalidOperationException]::new('VHDX download failed. Check the restricted AzCopy job log.')
                $failure.Data['ArcBoxNativeExit'] = [int]$nativeExit
                throw $failure
            }
        }
        $phase = if ($reuse) { 'existing-image-validation' } else { 'staged-image-validation' }
        $detail.validationCheck = 'hyper-v'
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
            -not (Test-VHD -Path $candidate -ErrorAction Stop)) {
            throw 'The workshop VHDX did not pass Hyper-V validation.'
        }
        if ($ExpectedSha256) {
            $detail.validationCheck = 'sha256'
            if ((Get-FileHash -LiteralPath $candidate -Algorithm SHA256 -ErrorAction Stop).Hash -ine $ExpectedSha256) {
                throw 'The workshop VHDX does not match the reviewed SHA-256.'
            }
            $detail.sha256Verified = $true
        }
        $detail.Remove('validationCheck')
        if (-not $reuse) {
            $phase = 'local-publication'
            # File.Move refuses an existing destination, including one created during staging.
            [IO.File]::Move($pending, $Path)
        }
    } catch {
        $detail.outcome = 'failed'
        $detail.phase = $phase
        $elapsed = $clock.ElapsedMilliseconds
        $last, $next = switch ($phase) {
            'transfer' { 'No local image was available; transfer did not complete successfully.', 'Check storage reachability and the restricted AzCopy job log.' }
            'existing-image-validation' { 'An existing local image was found but was not verified or overwritten.', 'Check the existing image with Hyper-V and compare its required SHA-256, if configured.' }
            'staged-image-validation' { 'AzCopy returned success, but the staged image was not verified or published.', 'Check the Hyper-V validation result and the required SHA-256, if configured.' }
            'local-publication' { 'The staged image passed validation but was not moved into place.', 'Check the destination, permissions, and any competing file. Do not overwrite an existing image.' }
            default { 'The local image state could not be confirmed.', 'Check access to the intended image directory.' }
        }
        $label = $phase.Replace('-', ' ')
        Write-ArcBoxJournal vhd-images ERROR "${ImageName}: $label failed after $elapsed ms." `
            -Operation $operation -Detail $detail -ElapsedMs $elapsed -Failure $_ -LastConfirmed $last `
            -LabImpact 'Dependent VM setup cannot proceed.' -NextCheck $next
        throw
    } finally {
        if ($pending -and (Test-Path -LiteralPath $pending)) {
            Remove-Item -LiteralPath $pending -Force -ErrorAction Continue
        }
    }
    $detail.outcome = if ($reuse) { 'reused' } else { 'downloaded' }
    $action = if ($reuse) { 'reused the verified local image' } else { 'downloaded, verified, and moved the image into place' }
    $elapsed = $clock.ElapsedMilliseconds
    $checks = if ($ExpectedSha256) { 'Hyper-V validation and SHA-256 matched.' } else { 'Hyper-V validation passed; no SHA-256 is configured.' }
    Write-ArcBoxJournal vhd-images INFO "${ImageName}: $action in $elapsed ms. $checks" `
        -Operation $operation -Detail $detail -ElapsedMs $elapsed -DetailedOnly
}

function Receive-ArcBoxVhdBatch {
    param([Collections.IDictionary]$Images,[string]$SourceFolder,[string]$AzCopy,[hashtable]$ImageHashes)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($image in $Images.GetEnumerator()) {
        $verification = @{}
        if ($ImageHashes.ContainsKey($image.Value)) { $verification.ExpectedSha256 = $ImageHashes[$image.Value] }
        Receive-ArcBoxVhd -Path $image.Key -ImageName $image.Value -SourceUri ($SourceFolder + $image.Value) -AzCopy $AzCopy @verification
    }
    $seconds = $clock.Elapsed.TotalSeconds.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    Write-ArcBoxJournal vhd-images INFO "$($Images.Count) lab disk images verified and available locally ($seconds s). VM preparation can continue." `
        -Milestone -Operation 'Download and verify lab disk images' -ElapsedMs $clock.ElapsedMilliseconds `
        -Detail @{outcome='verified'; imageCount=$Images.Count}
}
