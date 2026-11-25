#requires -Version 5.1
param(
    [Parameter(Mandatory)][string]$VMRoot,
    [Parameter(Mandatory)][ValidatePattern('(?i)\AC:\\ProgramData\\ArcBoxLinux-[0-9a-f]{32}\z')][string]$SshDir
)

$ErrorActionPreference = 'Stop'
if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18' -or
    $VMRoot -ine 'F:\Virtual Machines' -or @(Get-VM).Count) {
    throw 'Offline Linux preparation requires the untouched workshop host under SYSTEM.'
}

function New-ArcBoxRescueDvd {
    param([string]$Source, [string]$BootImage, [string]$Destination)
    if (!('ArcBoxRescueIsoStream' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class ArcBoxRescueIsoStream {
    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int SHCreateStreamOnFileEx(
        string path, uint mode, uint attributes, bool create, IStream template, out IStream stream);

    public static IStream Open(string path) {
        IStream stream;
        Marshal.ThrowExceptionForHR(SHCreateStreamOnFileEx(path, 0x20, 0, false, null, out stream));
        return stream;
    }

    public static void Write(object source, string path) {
        var stream = (IStream)source;
        var count = Marshal.AllocHGlobal(sizeof(int));
        try {
            using (var output = new FileStream(path, FileMode.CreateNew)) {
                var buffer = new byte[65536];
                while (true) {
                    stream.Read(buffer, buffer.Length, count);
                    var read = Marshal.ReadInt32(count);
                    if (read == 0) break;
                    output.Write(buffer, 0, read);
                }
            }
        } finally {
            Marshal.FreeHGlobal(count);
        }
    }
}
'@
    }
    $boot = New-Object -ComObject IMAPI2FS.BootOptions
    $boot.AssignBootImage([ArcBoxRescueIsoStream]::Open($BootImage))
    $boot.PlatformId = 0xef
    $boot.Emulation = 0
    $image = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
    $image.VolumeName = 'RESCUE1303'
    $image.FileSystemsToCreate = 3
    $image.FreeMediaBlocks = 2295104
    $image.StageFiles = $false
    $image.BootImageOptions = $boot
    $image.Root.AddTree($Source, $false)
    [ArcBoxRescueIsoStream]::Write($image.CreateResultImage().ImageStream, $Destination)
}

function Receive-ArcBoxOfflineHostKey {
    param([string]$Id)
    $deadline = [datetime]::UtcNow.AddMinutes(3)
    $pipe = New-Object IO.Pipes.NamedPipeClientStream('.', $Id, [IO.Pipes.PipeDirection]::In, [IO.Pipes.PipeOptions]::Asynchronous)
    try {
        $pipe.Connect(60000)
        $reader = New-Object IO.StreamReader($pipe)
        try {
            $prefix = "ARCBOX-SEED:${Id}:"
            while ([datetime]::UtcNow -lt $deadline) {
                $remaining = [int]($deadline - [datetime]::UtcNow).TotalMilliseconds
                if ($remaining -le 0) { break }
                $read = $reader.ReadLineAsync()
                if (!$read.Wait($remaining)) { break }
                $line = $read.GetAwaiter().GetResult()
                if ($null -eq $line) { break }
                if ($line -cmatch ('^' + [regex]::Escape($prefix) + 'Failed ([0-9]{1,3})$')) {
                    throw "Offline Linux preparation exited $($Matches[1])."
                }
                if ($line -cmatch ('^' + [regex]::Escape($prefix) + 'Ready (ssh-ed25519 [A-Za-z0-9+/]{60,100}={0,2})$')) {
                    return $Matches[1]
                }
            }
        } finally { $reader.Dispose() }
    } finally { $pipe.Dispose() }
    throw 'Offline helper did not return its bound SSH host key.'
}

$worker = ((Get-Content -LiteralPath (Join-Path $sshDir 'id_ed25519.pub') -Raw).Trim() -split '\s+')[0..1] -join ' '
if ($worker -cnotmatch '^ssh-ed25519 [A-Za-z0-9+/]{60,100}={0,2}$') { throw 'Invalid worker public key.' }
$seed = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'ArcBox.LinuxSeed.sh') -Raw
$media = Join-Path $PSScriptRoot 'linux-rescue'
$tree = Join-Path $media 'content'
$stock = Join-Path $media 'systemrescue-13.03-amd64.iso'
$parents = Join-Path $VMRoot 'ArcBoxLinuxImages'
$roles = [ordered]@{
    'ArcBox-Ubuntu-01' = 'VBD-ArcBox-Ubuntu-01.vhdx'
    'ArcBox-Ubuntu-02' = 'VBD-ArcBox-Ubuntu-02.vhdx'
    'ArcBox-Proxy' = 'VBD-ArcBox-Ubuntu-02.vhdx'
}
if ((Test-Path -LiteralPath $media) -or @($roles.Keys | Where-Object {
    (Test-Path -LiteralPath (Join-Path $VMRoot "VBD-$_.vhdx")) -or
    (Test-Path -LiteralPath (Join-Path $sshDir "$_.offline.json"))
}).Count) { throw 'Existing Linux setup data requires reconciliation, not an overwrite.' }
$null = New-Item -ItemType Directory -Path $media, $tree
$curl = Join-Path $env:SystemRoot 'System32\curl.exe'
& $curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 600 `
    --output $stock 'https://downloads.sourceforge.net/project/systemrescuecd/sysresccd-x86/13.03/systemrescue-13.03-amd64.iso'
if ($LASTEXITCODE -or (Get-FileHash -LiteralPath $stock -Algorithm SHA256).Hash -ine
    'b71b98ba6b92145524cb1a72206b9888a59861ad6fb05d127faf618ca0136891') {
    throw 'SystemRescue download did not match the pinned release.'
}
$tar = Join-Path $env:SystemRoot 'System32\tar.exe'
$source = @(& $tar -tf $stock)
if ($LASTEXITCODE -or 'boot/grub/x86_64-efi/acpi.mod' -cnotin $source -or
    @($source | Where-Object { $_ -match '(^[/\\]|\\|:|(?:^|/)\.\.(?:/|$))' }).Count) {
    throw 'Verified media lacks the expected safe Rock Ridge paths.'
}
# Mounting through Windows CDFS changes the names GRUB needs.
& $tar -xf $stock -C $tree
if ($LASTEXITCODE -ne 0) { throw 'Rescue media extraction failed.' }
$bootImage = Join-Path $tree 'efi\archiso\efiboot.img'
$autorun = Join-Path $tree 'autorun'
if (!(Test-Path -LiteralPath $autorun)) { $null = New-Item -ItemType Directory -Path $autorun }
if (@(Get-ChildItem -LiteralPath $autorun -File | Where-Object Name -Match '^autorun[0-9a-f]?$').Count) {
    throw 'Verified source unexpectedly contains executable autorun files.'
}
$bootPaths = '(?i)^boot/grub/|^EFI/|airootfs\.sfs$'
$keyHashes = @('05ccb100bdfb734934e0df5cb4992398815bac396c22522eea51168547e619c0')
foreach ($entry in $roles.GetEnumerator()) {
    $name = $entry.Key
    $parent = Join-Path $parents $entry.Value
    $disk = Join-Path $VMRoot "VBD-$name.vhdx"
    $id = 'arcbox-' + [guid]::NewGuid().ToString('N')
    $iso = Join-Path $media "$name.iso"
    $script = ($seed.Replace('__INSTANCE__', $id).Replace('__WORKER_PUBLIC__', $worker) -replace "`r`n", "`n") + "`n"
    [IO.File]::WriteAllText((Join-Path $autorun 'autorun'), $script, [Text.UTF8Encoding]::new($false))
    New-ArcBoxRescueDvd -Source $tree -BootImage $bootImage -Destination $iso
    $entries = @(& $tar -tf $iso)
    if ($LASTEXITCODE -or 'autorun/autorun' -cnotin $entries -or @(Compare-Object -CaseSensitive `
        -ReferenceObject @($source | Where-Object { $_ -match $bootPaths }) `
        -DifferenceObject @($entries | Where-Object { $_ -match $bootPaths })).Count) {
        throw 'The derived DVD differs from the verified boot paths.'
    }
    $base = Get-VHD -Path $parent
    if ($base.Attached -or $base.ParentPath) { throw 'Expected a detached Linux image parent.' }
    $null = New-VHD -Path $disk -ParentPath $parent -Differencing
    if ((Get-VHD -Path $disk).ParentPath -ine $parent) { throw 'Unexpected Linux disk parent.' }
    $helper = New-VM -Name $id -Generation 2 -NoVHD -Path $media -MemoryStartupBytes 2GB
    Get-VMNetworkAdapter -VM $helper | Remove-VMNetworkAdapter
    Set-VM -VM $helper -AutomaticStartAction Nothing -AutomaticStopAction ShutDown
    $dvd = Add-VMDvdDrive -VM $helper -Path $iso -Passthru
    Add-VMHardDiskDrive -VM $helper -Path $disk
    Set-VMFirmware -VM $helper -EnableSecureBoot Off -BootOrder $dvd
    $drives = @(Get-VMHardDiskDrive -VM $helper)
    if ($drives.Count -ne 1 -or $drives[0].Path -ine $disk -or @(Get-VMNetworkAdapter -VM $helper).Count -or
        @( (Get-VMFirmware -VM $helper).BootOrder ).Count -ne 1 -or (Get-VMDvdDrive -VM $helper).Path -ine $iso) {
        throw 'Offline helper has an unexpected boot order, disk or NIC.'
    }
    Set-VMComPort -VMName $id -Number 1 -Path "\\.\pipe\$id"
    Start-VM -VM $helper
    $key = Receive-ArcBoxOfflineHostKey -Id $id
    $deadline = [datetime]::UtcNow.AddSeconds(45)
    while ((Get-VM -Id $helper.Id).State -ne 'Off' -and [datetime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 2 }
    if ((Get-VM -Id $helper.Id).State -ne 'Off') { throw 'Offline helper did not shut down after writing its receipt.' }
    Get-VMHardDiskDrive -VM $helper | Remove-VMHardDiskDrive
    if ((Get-VHD -Path $disk).Attached) { throw 'Linux disk did not detach from the offline helper.' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try { $fingerprint = [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::ASCII.GetBytes($key))).Replace('-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
    if ($fingerprint -in $keyHashes) { throw 'Duplicate or cloned Linux host key.' }
    $keyHashes += $fingerprint
    $proof = [ordered]@{ Disk = $disk; Parent = $parent; Instance = $id; HostKey = $key } | ConvertTo-Json -Compress
    $pending = Join-Path $sshDir "$name.$id.tmp"
    [IO.File]::WriteAllText($pending, $proof, [Text.Encoding]::ASCII)
    [IO.File]::Move($pending, (Join-Path $sshDir "$name.offline.json"))
    Remove-VM -VM $helper -Force
    Write-Output "$name offline disk preparation verified."
}
Remove-Item -LiteralPath $media -Recurse -Force
