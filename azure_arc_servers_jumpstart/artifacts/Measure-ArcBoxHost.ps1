param(
    [Parameter(Mandatory)][ValidatePattern('\A[a-f0-9]{32}\z')][string]$Attempt,
    [ValidateSet('sample','assessment-start','assessment-end','lab-start','lab-end')][string]$Action = 'sample'
)

$ErrorActionPreference = 'Stop'
$run = [Environment]::GetEnvironmentVariable('ArcBoxRunId', 'Machine')
if ($run -cnotmatch '\A[a-f0-9]{32}\z' -or
    $Attempt -cne [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine') -or
    $PSScriptRoot -ine "$env:ProgramFiles\ArcBoxPerf\$Attempt") {
    throw 'Performance collection must use the current attempt in its protected installation directory.'
}
$deadline = [datetimeoffset]::ParseExact(
    [IO.File]::ReadAllText("$PSScriptRoot\deadline.txt"), 'o', [Globalization.CultureInfo]::InvariantCulture)
if ([datetimeoffset]::UtcNow -ge $deadline) {
    if ($Action -eq 'sample') { return }
    throw 'This attempt''s sampling window has expired.'
}

if ($Action -ne 'sample') {
    $sample = Get-Item -LiteralPath "$PSScriptRoot\samples.jsonl" -ErrorAction Stop
    if (([datetime]::UtcNow - $sample.LastWriteTimeUtc).TotalSeconds -gt 15) {
        throw 'No recent samples; do not mark this action as measured.'
    }
    $stream = [IO.File]::Open("$PSScriptRoot\$Action.json", 'CreateNew', 'Write', 'None')
    try {
        $row = @{v=1; run=$run; attempt=$Attempt; at=[datetime]::UtcNow.ToString('o'); marker=$Action}
        $bytes = [Text.Encoding]::ASCII.GetBytes(($row | ConvertTo-Json -Compress))
        $stream.Write($bytes, 0, $bytes.Length)
    } finally { $stream.Dispose() }
    return
}

$hostCounters = [ordered]@{
    cpuPct = @('Processor','% Processor Time','_Total')
    hypervPct = @('Hyper-V Hypervisor Logical Processor','% Total Run Time','_Total')
    availableMiB = @('Memory','Available MBytes','')
    committedBytes = @('Memory','Committed Bytes','')
    pageReadsPerSec = @('Memory','Page Reads/sec','')
    pagesInPerSec = @('Memory','Pages Input/sec','')
    pageFilePct = @('Paging File','% Usage','_Total')
}
$diskCounters = [ordered]@{
    fReadsPerSec = @('LogicalDisk','Disk Reads/sec','F:')
    fWritesPerSec = @('LogicalDisk','Disk Writes/sec','F:')
    fReadBytesPerSec = @('LogicalDisk','Disk Read Bytes/sec','F:')
    fWriteBytesPerSec = @('LogicalDisk','Disk Write Bytes/sec','F:')
    fReadMs = @('LogicalDisk','Avg. Disk sec/Read','F:')
    fWriteMs = @('LogicalDisk','Avg. Disk sec/Write','F:')
}

function Read-HostCounter($Key, $Spec, $OpenCounters) {
    try {
        if (-not $OpenCounters.ContainsKey($Key)) {
            # Prime rate counters rather than reporting warm-up values as observations.
            $OpenCounters[$Key] = [Diagnostics.PerformanceCounter]::new($Spec[0], $Spec[1], $Spec[2], $true)
            $null = $OpenCounters[$Key].NextValue()
            return $null
        }
        $value = $OpenCounters[$Key].NextValue()
        if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -lt 0) { return $null }
        if ($Key -in 'fReadMs','fWriteMs') { $value *= 1000 }
        [Math]::Round($value, 3)
    } catch [InvalidOperationException] {
        if ($OpenCounters.ContainsKey($Key)) {
            $OpenCounters[$Key].Dispose()
            $OpenCounters.Remove($Key)
        }
        return $null
    }
}

$boot = (Get-CimInstance -ClassName Win32_OperatingSystem -Property LastBootUpTime).LastBootUpTime.ToUniversalTime().ToString('o')
$output = "$PSScriptRoot\samples.jsonl"
$openCounters = @{}
$clock = [Diagnostics.Stopwatch]::StartNew()
try {
    for ($tick = 0; [datetimeoffset]::UtcNow -lt $deadline; $tick++) {
        if ([IO.File]::Exists($output) -and [IO.FileInfo]::new($output).Length -ge 8MB) { break }
        if ($Attempt -cne [Environment]::GetEnvironmentVariable('ArcBoxAttemptId', 'Machine')) { break }
        $row = [ordered]@{v=1; run=$run; attempt=$Attempt; boot=$boot; at=[datetime]::UtcNow.ToString('o')}
        foreach ($key in $hostCounters.Keys) { $row[$key] = Read-HostCounter $key $hostCounters[$key] $openCounters }
        if ([IO.File]::Exists("$PSScriptRoot\disk-ready.txt")) {
            foreach ($key in $diskCounters.Keys) { $row[$key] = Read-HostCounter $key $diskCounters[$key] $openCounters }
            if ($row.fReadsPerSec -eq 0) { $row.fReadMs = $null }
            if ($row.fWritesPerSec -eq 0) { $row.fWriteMs = $null }
        }
        [IO.File]::AppendAllText($output, (($row | ConvertTo-Json -Compress) + [Environment]::NewLine))
        $tick = [Math]::Max($tick, [Math]::Floor($clock.Elapsed.TotalSeconds / 5))
        $wait = [int]([Math]::Max(1, (5000 * ($tick + 1)) - $clock.ElapsedMilliseconds))
        Start-Sleep -Milliseconds $wait
    }
} finally {
    foreach ($counter in $openCounters.Values) { $counter.Dispose() }
}
