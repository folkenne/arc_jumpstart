$script:ArcBoxHostReasons = @{
    'disk-contract' = 'Check the managed disk ID, LUN 0 attachment and no-temp-disk VM size.'
    'disk-discovery' = 'Check IMDS and Windows SCSI visibility before retrying.'
    'disk-identity' = 'Check that Windows maps each Azure LUN to one healthy device.'
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
    'artifact-download' = 'Verify the approved artifact ref and client reachability.'
    'private-config' = 'Set the approved versioned Blob URI without SAS and its SHA-256.'
    'private-read' = 'Check client managed identity Blob Reader access, DNS and reachability.'
    'private-hash' = 'Compare the private payload with the approved SHA-256 before retrying.'
    'nested-credential-config' = 'Supply the approved versioned Key Vault reference for the nested Windows login.'
    'nested-credential-read' = 'Check the private vault route, secret version and the client identity secret access.'
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
        [string]$Reason
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
    Add-Content -LiteralPath 'C:\ArcBox\Logs\workshop-host-events.jsonl' -Encoding ASCII -Value (
        ConvertTo-Json -InputObject $record -Compress) -ErrorAction Stop
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

function Get-ArcBoxPrivateBlobUri {
    param([string]$VersionUri, [string]$Sha256,
        [ValidateSet('ArcServersLogonScript.ps1','testDefenderForSQL.ps1')][string]$Name = 'ArcServersLogonScript.ps1')
    $uri = $null
    $leaf = [regex]::Escape($Name)
    if ($Sha256 -notmatch '\A[0-9a-f]{64}\z' -or
        $VersionUri -cnotmatch ('\Ahttps://[a-z0-9]{3,24}\.blob\.core\.windows\.net/[a-z0-9][a-z0-9-]{1,61}[a-z0-9]/(?:[A-Za-z0-9_-]+/)*' + $leaf + '\?versionid=\d{4}-\d\d-\d\dT\d\d(?::|%3[Aa])\d\d(?::|%3[Aa])\d\d\.\d{7}Z\z') -or
        -not [uri]::TryCreate($VersionUri, [UriKind]::Absolute, [ref]$uri) -or
        [uri]::UnescapeDataString($uri.Query) -cnotmatch '\A\?versionid=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}Z\z') {
        Stop-ArcBoxHostStep private-config 'Expected the reviewed versioned Azure Blob URI without SAS and a separately approved digest.'
    }
    $uri
}

function Get-ArcBoxNestedCredentialUri {
    param([string]$SecretUri)
    if ($SecretUri -cnotmatch '\Ahttps://[a-z][a-z0-9-]{1,22}[a-z0-9]\.vault\.azure\.net/secrets/arcbox-nested-windows/[a-f0-9]{32}\z') {
        Stop-ArcBoxHostStep nested-credential-config 'Expected the reviewed version of the nested Windows secret.'
    }
    [uri]$SecretUri
}

function Get-ArcBoxNestedCredential {
    param([string]$SecretUri)
    $uri = Get-ArcBoxNestedCredentialUri $SecretUri
    try {
        $identity = Read-ArcBoxMetadataJson '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net'
        if ([string]::IsNullOrWhiteSpace($identity.access_token)) { throw 'No vault access token.' }
        $secret = Invoke-RestMethod -Uri "$($uri.AbsoluteUri)?api-version=7.4" -Method Get `
            -Headers @{ Authorization = "Bearer $($identity.access_token)" } -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop
        if ($secret.id -cne $uri.AbsoluteUri -or $secret.value -isnot [string] -or
            [string]::IsNullOrWhiteSpace($secret.value)) { throw 'No matching credential version.' }
        [pscredential]::new('Administrator', (ConvertTo-SecureString -String $secret.value -AsPlainText -Force))
    } catch {
        # Do not log the request, bearer token, response body or transport error payload.
        Stop-ArcBoxHostStep nested-credential-read 'Could not load the approved nested Windows credential.'
    }
}

function Assert-ArcBoxPrivateScript {
    param([string]$Path, [string]$Sha256)
    if ($Sha256 -notmatch '\A[0-9a-f]{64}\z' -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $Sha256) {
        Stop-ArcBoxHostStep private-hash 'Private script does not match the reviewed bytes.'
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
    if (Test-Path -LiteralPath $done) { return }
    # CreateNew also prevents a manually started duplicate outside Task Scheduler.
    try { $marker = [IO.File]::Open($started, 'CreateNew', 'Write', 'None') }
    catch [IO.IOException] { Stop-ArcBoxHostStep checkpoint "Inspect the interrupted or active $Stage phase before recovery." }
    $marker.Dispose()
    try {
        Write-ArcBoxHostEvent $Stage start
        & $Action
        Write-ArcBoxHostEvent $Stage ok
        [IO.File]::Move($started, $done)
    } catch {
        Write-ArcBoxHostEvent $Stage failed (Get-ArcBoxHostFailureCode $_ $Reason)
        throw
    }
}

function Receive-ArcBoxPrivateScript {
    param([string]$VersionUri, [string]$Sha256, [string]$Destination,
        [ValidateSet('ArcServersLogonScript.ps1','testDefenderForSQL.ps1')][string]$Name = 'ArcServersLogonScript.ps1')
    if ([IO.Path]::GetFileName($Destination) -cne $Name) {
        Stop-ArcBoxHostStep private-config 'Private artifact destination has an unexpected filename.'
    }
    $uri = Get-ArcBoxPrivateBlobUri -VersionUri $VersionUri -Sha256 $Sha256 -Name $Name
    $pending = "$Destination.$([guid]::NewGuid().ToString('N')).download"
    try {
        try {
            # Use the VM identity directly; no Az login, SAS, proxy or redirect for the IMDS token request.
            $token = (Read-ArcBoxMetadataJson '/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fstorage.azure.com%2F').access_token
            if (-not $token) { throw 'The VM identity did not return a storage token.' }
            $headers = @{ Authorization = "Bearer $token"; 'x-ms-version' = '2021-12-02'; 'x-ms-date' = [datetime]::UtcNow.ToString('R') }
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $headers -MaximumRedirection 0 `
                -OutFile $pending -TimeoutSec 60 -ErrorAction Stop
        } catch {
            # Do not log request/response data or attach the original exception with an authorization header.
            Stop-ArcBoxHostStep private-read 'Private artifact request failed. Check identity, version and supported storage connectivity.'
        } finally {
            if ($headers) { $headers.Clear() }
            $token = $null
        }
        Assert-ArcBoxPrivateScript -Path $pending -Sha256 $Sha256
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
    }
    $scriptPath = Join-Path $dir 'Measure-ArcBoxHost.ps1'
    Invoke-WebRequest -UseBasicParsing -Uri ($TemplateBaseUrl + 'artifacts/Measure-ArcBoxHost.ps1') `
        -OutFile $scriptPath -MaximumRedirection 0 -TimeoutSec 30 -ErrorAction Stop
    [IO.File]::WriteAllText("$dir\deadline.txt", [datetimeoffset]::UtcNow.AddHours(12).ToString('o'))
    $action = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -Attempt $Attempt"
    $principal = New-ScheduledTaskPrincipal -UserId SYSTEM -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([timespan]::FromHours(12))
    Register-ScheduledTask -TaskName 'ArcBox-HostBaseline' -TaskPath '\' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) `
        -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
    Start-ScheduledTask -TaskName 'ArcBox-HostBaseline' -TaskPath '\' -ErrorAction Stop
    $dir
}

function Get-ArcBoxDataDisk {
    param([string]$ExpectedId)
    $storage = Get-ArcBoxStorageMetadata
    $attached = @($storage.dataDisks | Where-Object { $_.managedDisk.id -ieq $ExpectedId })
    if ($attached.Count -eq 0) { Stop-ArcBoxHostStep disk-discovery 'The expected disk is not visible in IMDS.' }
    if ($attached.Count -ne 1 -or "$($attached[0].lun)" -ne '0' -or
        $attached[0].createOption -ne 'Attach' -or "$($storage.resourceDisk.size)" -ne '0' -or
        @($storage.dataDisks | Where-Object { "$($_.lun)" -eq '0' }).Count -ne 1) {
        Stop-ArcBoxHostStep disk-contract 'A unique LUN 0 attachment and no local temp disk are required.'
    }
    $os = @(Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop)
    $disks = @(Get-Disk -ErrorAction Stop)
    if ($os.Count -ne 1 -or @($disks | Where-Object Number -eq $os[0].DiskNumber).Count -ne 1) {
        Stop-ArcBoxHostStep disk-discovery 'Windows OS disk inventory is not ready.'
    }
    # Disk numbers can change; require a one-to-one mapping between Azure LUNs and Windows SCSI locations.
    $byLun = @{}
    foreach ($device in $disks) {
        if ($device.Number -ne $os[0].DiskNumber -and $device.BusType -eq 'SCSI') {
            if ($device.Location -notmatch '\bBus Number\s+\d+\s*:\s*Target Id\s+\d+\s*:\s*LUN\s+(\d+)\s*$') {
                Stop-ArcBoxHostStep disk-discovery 'Not all SCSI device locations have resolved.'
            }
            $lun = [int]$Matches[1]
            if ($byLun.ContainsKey($lun)) { Stop-ArcBoxHostStep disk-identity 'Multiple devices claim the same attachment LUN.' }
            $byLun[$lun] = $device
        }
    }
    foreach ($attachment in $storage.dataDisks) {
        if ("$($attachment.lun)" -notmatch '\A\d{1,2}\z' -or -not $byLun.ContainsKey([int]$attachment.lun)) {
            Stop-ArcBoxHostStep disk-discovery 'A declared SCSI LUN is not visible in Windows.'
        }
    }
    if ($byLun.Count -ne @($storage.dataDisks).Count) {
        Stop-ArcBoxHostStep disk-identity 'Unmatched SCSI devices; no disk was selected.'
    }
    $disk = $byLun[0]
    if ($disk.IsOffline -eq $true) { Stop-ArcBoxHostStep disk-discovery 'The expected disk is offline.' }
    if ($disk.IsBoot -ne $false -or $disk.IsSystem -ne $false -or
        $disk.IsOffline -ne $false -or $disk.IsReadOnly -ne $false -or
        $disk.HealthStatus -ne 'Healthy' -or $disk.Size -ne 1TB -or [string]::IsNullOrWhiteSpace($disk.UniqueId) -or
        @($disks | Where-Object UniqueId -eq $disk.UniqueId).Count -ne 1 -or
        @($disks | Where-Object Number -eq $disk.Number).Count -ne 1) {
        Stop-ArcBoxHostStep disk-identity 'The workshop data disk could not be verified.'
    }
    $disk
}

function Initialize-ArcBoxDataDrive {
    param([string]$ExpectedId, [ValidateRange(1,12)][int]$DiscoveryAttempts = 12, [switch]$VerifyOnly)
    if ($ExpectedId -notmatch '\A/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft\.Compute/disks/[^/]+\z') {
        Stop-ArcBoxHostStep disk-contract 'The deployment did not supply a managed disk resource ID.'
    }
    for ($i = 1; $i -le $DiscoveryAttempts; $i++) {
        try { $disk = Get-ArcBoxDataDisk $ExpectedId; break }
        catch {
            if ((Get-ArcBoxHostFailureCode $_ disk-discovery) -ne 'disk-discovery' -or $i -eq $DiscoveryAttempts) { throw }
            Start-Sleep -Seconds 5
        }
    }
    $volumes = @(Get-Volume -ErrorAction Stop | Where-Object DriveLetter -eq 'F')
    if ($volumes.Count -or (Get-PSDrive -Name F -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath 'F:\')) {
        if ($volumes.Count -ne 1) { Stop-ArcBoxHostStep disk-letter 'F: does not identify a unique local volume.' }
        $partitions = @(Get-Partition -DriveLetter F -ErrorAction Stop)
        # A healthy rerun is a no-op only when F: still belongs to the verified attachment.
        if ($partitions.Count -eq 1 -and $partitions[0].DiskNumber -eq $disk.Number -and
            $volumes[0].FileSystem -eq 'NTFS' -and $volumes[0].FileSystemLabel -eq 'VMsDisk' -and
            $volumes[0].HealthStatus -eq 'Healthy') { return }
        Stop-ArcBoxHostStep disk-letter 'F: belongs to a different or unhealthy volume.'
    }
    if ($VerifyOnly -or $disk.PartitionStyle -ne 'RAW' -or $disk.NumberOfPartitions -ne 0) {
        Stop-ArcBoxHostStep disk-layout 'The intended disk is not empty.'
    }
    try { $current = Get-ArcBoxDataDisk $ExpectedId }
    catch { $_.Exception.Data['ArcBoxReason'] = 'disk-drift'; throw }
    if ($current.UniqueId -ne $disk.UniqueId -or $current.Number -ne $disk.Number -or
        $current.Location -ne $disk.Location -or $current.PartitionStyle -ne 'RAW' -or $current.NumberOfPartitions -ne 0 -or
        (Get-Volume -ErrorAction Stop | Where-Object DriveLetter -eq 'F') -or
        (Get-PSDrive -Name F -ErrorAction SilentlyContinue) -or (Test-Path -LiteralPath 'F:\')) {
        Stop-ArcBoxHostStep disk-drift 'Disk state changed before the first write.'
    }
    try {
        $current | Initialize-Disk -PartitionStyle MBR -PassThru -ErrorAction Stop |
            New-Partition -UseMaximumSize -DriveLetter F -ErrorAction Stop |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel VMsDisk -Confirm:$false -Force -ErrorAction Stop | Out-Null
    } catch { $_.Exception.Data['ArcBoxReason'] = 'disk-write'; throw }
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
        Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.msi' -OutFile $msi -TimeoutSec 300 -ErrorAction Stop
        # Verify the publisher before execution and the actual binary before task registration.
        $phase = 'ps-signature'
        $signature = Get-AuthenticodeSignature -FilePath $msi -ErrorAction Stop
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
            throw 'PowerShell MSI does not have a valid Microsoft publisher signature.'
        }
        if (-not $installed) {
            $phase = 'ps-install'
            $result = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -Wait -PassThru -ErrorAction Stop -ArgumentList (
                '/I "{0}" /quiet /norestart ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=1 ADD_FILE_CONTEXT_MENU_RUNPOWERSHELL=1 ENABLE_PSREMOTING=1 REGISTER_MANIFEST=1 USE_MU=1 ENABLE_MU=1 ADD_PATH=1' -f $msi)
            if ($result.ExitCode -eq 1641) { $phase = 'ps-restart' }
            if ($result.ExitCode -notin 0,3010) { throw "PowerShell MSI returned $($result.ExitCode); expected 0 or 3010." }
            $phase = 'ps-probe'
            if (-not (Test-ArcBoxPowerShell $Executable)) { throw 'Installed PowerShell failed the 7.6.10 probe.' }
        }
        $phase = 'ps-download'
        Move-Item -LiteralPath $msi -Destination $RecoveryMsi -Force -ErrorAction Stop
    } catch { $_.Exception.Data['ArcBoxReason'] = $phase; throw }
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
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $addresses = @(Get-VMNetworkAdapter -VMName $Name -ErrorAction Stop |
            Where-Object SwitchName -eq 'InternalNATSwitch' |
            ForEach-Object IPAddresses | Where-Object {
                $_ -match '\A10\.10\.1\.(\d{1,3})\z' -and [int]$Matches[1] -in (2..254)
            } | Sort-Object -Unique)
        if ($addresses.Count -eq 1 -and (Test-ArcBoxSshListener $addresses[0])) { return $addresses[0] }
        if ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds) { Start-Sleep -Seconds 3 }
    } while ($clock.Elapsed.TotalSeconds -lt $TimeoutSeconds)
    Stop-ArcBoxHostStep guest-access "$Name did not have a unique reachable IPv4 address on the workshop switch."
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
        Stop-ArcBoxHostStep arc-feature "Azure CLI request failed ($LASTEXITCODE): $($Arguments[0..2] -join ' ')."
    }
}

function Receive-ArcBoxVhd {
    param([string]$Path, [string]$SourceUri, [string]$CopyFrom, [string]$AzCopy)
    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-VHD -Path $Path -ErrorAction Stop)) { throw 'Existing workshop VHDX failed validation; it was not overwritten.' }
        return
    }

    $pending = "$Path.$([guid]::NewGuid().ToString('N')).pending.vhdx"
    try {
        if ($CopyFrom) {
            # Never use an attached, potentially already personalized Ubuntu disk as a new proxy image.
            if ((Get-VHD -Path $CopyFrom -ErrorAction Stop).Attached -ne $false -or
                (Get-VM -Name 'ArcBox-Ubuntu-02' -ErrorAction SilentlyContinue)) {
                throw 'No pristine Ubuntu-02 disk is available for the missing Proxy disk.'
            }
            Copy-Item -LiteralPath $CopyFrom -Destination $pending -ErrorAction Stop
        } else {
            & $AzCopy copy $SourceUri $pending --overwrite=false --check-length=true --log-level=ERROR
            if ($LASTEXITCODE -ne 0) { throw "VHDX download returned $LASTEXITCODE." }
        }
        if (-not (Test-Path -LiteralPath $pending -PathType Leaf) -or
            -not (Test-VHD -Path $pending -ErrorAction Stop)) {
            throw 'The staged VHDX did not pass Hyper-V validation.'
        }
        # File.Move refuses an existing destination, including one created during staging.
        [IO.File]::Move($pending, $Path)
    } finally {
        if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction Continue }
    }
}
