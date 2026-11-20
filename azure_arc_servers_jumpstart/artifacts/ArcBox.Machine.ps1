$script:ArcBoxPackageSpecs = [ordered]@{
    'Git.Git' = @('exe', 'ProgramFiles\Git\cmd\git.exe')
    'Microsoft.VisualStudioCode' = @('exe', 'ProgramFiles\Microsoft VS Code\Code.exe')
    'Microsoft.AzureCLI' = @('msi', 'ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd')
    'Microsoft.Edge' = @('msi', 'ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe')
    'Microsoft.Azure.AZCopy.10' = @('zip', 'ProgramFiles\ArcBoxTools\azcopy.exe')
    'Microsoft.DotNet.SDK.8' = @('exe', 'ProgramFiles\dotnet\sdk\8.*\dotnet.dll')
    'Microsoft.Sysinternals.BGInfo' = @('zip', 'ProgramFiles\ArcBoxTools\Bginfo64.exe')
    'FireDaemon.OpenSSL' = @('msi', 'ProgramFiles\FireDaemon OpenSSL 3\bin\openssl.exe')
    '7zip.7zip' = @('msi', 'ProgramFiles\7-Zip\7z.exe')
}

# Keep the package IDs declared in common/ITPro DSC; use reviewed machine installers,
# not App Installer's per-user alias or configuration engine on Server 2022.
function Assert-ArcBoxMachinePackages {
    param($Packages)
    if ($null -eq $Packages -or @($Packages.PSObject.Properties).Count -ne $script:ArcBoxPackageSpecs.Count) {
        Stop-ArcBoxHostStep winget-setup 'Supply the full reviewed machine installer set.'
    }
    foreach ($id in $script:ArcBoxPackageSpecs.Keys) {
        $pin = $Packages.PSObject.Properties[$id].Value
        $kind = $script:ArcBoxPackageSpecs[$id][0]
        if ($pin.uri -cnotmatch ('\Ahttps://[a-zA-Z0-9][a-zA-Z0-9.-]*/[a-zA-Z0-9_./%+~-]+\.' + $kind + '\z') -or
            $pin.sha256 -cnotmatch '\A[a-f0-9]{64}\z' -or
            $pin.installedSha256 -cnotmatch '\A[a-f0-9]{64}\z') {
            Stop-ArcBoxHostStep winget-setup "Missing or invalid installer pin for $id."
        }
    }
}

function Test-ArcBoxInstalledTool {
    param([string]$Path, [string]$Hash)
    foreach ($file in Get-Item -Path $Path -ErrorAction SilentlyContinue) {
        if (-not $file.PSIsContainer -and -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -and
            (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $Hash) {
            return $true
        }
    }
    $false
}

function Install-ArcBoxMachinePackages {
    param($Packages, [string]$Work, [switch]$ItPro)
    Assert-ArcBoxMachinePackages $Packages
    foreach ($id in $script:ArcBoxPackageSpecs.Keys) {
        if (($id -eq '7zip.7zip') -ne $ItPro.IsPresent) { continue }
        $kind, $relative = $script:ArcBoxPackageSpecs[$id]
        $base, $leaf = $relative -split '\\', 2
        $expected = Join-Path ([Environment]::GetEnvironmentVariable($base)) $leaf
        $pin = $Packages.PSObject.Properties[$id].Value
        if (Test-ArcBoxInstalledTool $expected $pin.installedSha256) { continue }
        $asset = Join-Path $Work "$id.$kind"
        try {
            Invoke-WebRequest -Uri $pin.uri -OutFile $asset -MaximumRedirection 0 -TimeoutSec 300 -ErrorAction Stop
        } catch { Stop-ArcBoxHostStep winget-setup "Could not retrieve the reviewed installer for $id." }
        if ((Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash -ine $pin.sha256) {
            Stop-ArcBoxHostStep winget-setup "Installer digest mismatch for $id."
        }
        if ($kind -eq 'zip') {
            $expanded = Join-Path $Work "$id-expanded"
            Expand-Archive -LiteralPath $asset -DestinationPath $expanded -Force
            $binary = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter (Split-Path -Leaf $expected))
            if ($binary.Count -ne 1 -or (Get-AuthenticodeSignature -FilePath $binary[0].FullName).Status -ne 'Valid' -or
                -not (Test-ArcBoxInstalledTool $binary[0].FullName $pin.installedSha256)) {
                Stop-ArcBoxHostStep winget-setup "The signed tool in $id did not match the reviewed installed digest."
            }
            New-Item -ItemType Directory -Path (Split-Path -Parent $expected) -Force | Out-Null
            Copy-Item -LiteralPath $binary[0].FullName -Destination $expected
        } else {
            if ((Get-AuthenticodeSignature -FilePath $asset).Status -ne 'Valid') {
                Stop-ArcBoxHostStep winget-setup "Installer signature invalid for $id."
            }
            if ($kind -eq 'msi') {
                $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList ('/i "{0}" /qn /norestart ALLUSERS=1' -f $asset) -Wait -PassThru
            } else {
                $flags = switch ($id) {
                    'Git.Git' { '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /ALLUSERS' }
                    'Microsoft.VisualStudioCode' { '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /ALLUSERS' }
                    'Microsoft.DotNet.SDK.8' { '/install /quiet /norestart' }
                }
                $proc = Start-Process -FilePath $asset -ArgumentList $flags -Wait -PassThru
            }
            if ($proc.ExitCode -in 1641,3010) {
                Stop-ArcBoxHostStep machine-reboot-required "Installer for $id requested or started a reboot; do not dispatch downstream work."
            }
            if ($proc.ExitCode -ne 0) { Stop-ArcBoxHostStep winget-setup "Installer for $id returned $($proc.ExitCode)." }
        }
        if (-not (Test-ArcBoxInstalledTool $expected $pin.installedSha256)) {
            Stop-ArcBoxHostStep winget-setup "Installed machine tool for $id did not match the reviewed bytes."
        }
        Remove-Item -LiteralPath $asset -Force
    }
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ";$env:ProgramFiles\ArcBoxTools"
}

function Set-ArcBoxHyperVHost {
    if ((Get-Service -Name vmms).Status -ne 'Running') { Stop-ArcBoxHostStep dsc-config 'Hyper-V service is not running.' }
    if (-not (Get-VMHost).EnableEnhancedSessionMode) { Set-VMHost -EnableEnhancedSessionMode $true }
    $switch = Get-VMSwitch -Name 'InternalNATSwitch' -ErrorAction SilentlyContinue
    if (-not $switch) { $switch = New-VMSwitch -Name 'InternalNATSwitch' -SwitchType Internal }
    if ($switch.SwitchType -ne 'Internal') { Stop-ArcBoxHostStep dsc-config 'Existing switch is not internal.' }
    $alias = 'vEthernet (InternalNATSwitch)'
    $ips = @(Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object IPAddress -NotLike '169.254.*')
    if ($ips.Count -eq 0) { New-NetIPAddress -InterfaceAlias $alias -IPAddress '10.10.1.1' -PrefixLength 24 | Out-Null }
    elseif ($ips.Count -ne 1 -or $ips[0].IPAddress -ne '10.10.1.1' -or $ips[0].PrefixLength -ne 24) {
        Stop-ArcBoxHostStep dsc-config 'Existing switch IPv4 configuration differs from the workshop.'
    }
    if (-not (Get-VMHost).EnableEnhancedSessionMode -or
        -not (Get-NetIPAddress -InterfaceAlias $alias -IPAddress '10.10.1.1' -PrefixLength 24 -ErrorAction Stop)) {
        Stop-ArcBoxHostStep dsc-config 'Hyper-V host configuration did not converge.'
    }
}

function Initialize-ArcBoxGuests {
    param([string]$Root)
    # Keep the six image, memory, CPU and secure-boot settings of the nested-VM DSC.
    $layout = [ordered]@{
        'ArcBox-Win2K25' = @(4, 8GB, $true)
        'ArcBox-Win2K22' = @(1, 8GB, $true)
        'ArcBox-SQL' = @(2, 8GB, $true)
        'ArcBox-Ubuntu-01' = @(1, 4GB, $false)
        'ArcBox-Ubuntu-02' = @(1, 2GB, $false)
        'ArcBox-Proxy' = @(1, 2GB, $false)
    }
    if (@(Get-VM | Where-Object { $_.Name -notin $layout.Keys }).Count) {
        Stop-ArcBoxHostStep dsc-config 'An unrelated VM exists on the workshop host.'
    }
    foreach ($name in $layout.Keys) {
        $cpu, $memory, $secureBoot = $layout[$name]
        $path = Join-Path $Root "VBD-$name.vhdx"
        $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
        if (-not $vm) {
            $vm = New-VM -Name $name -Path $Root -VHDPath $path -Generation 2 `
                -MemoryStartupBytes $memory -SwitchName 'InternalNATSwitch'
            Set-VM -VM $vm -ProcessorCount $cpu -StaticMemory `
                -AutomaticStartAction Start -AutomaticStopAction ShutDown
            Set-VMFirmware -VM $vm -EnableSecureBoot $(if ($secureBoot) { 'On' } else { 'Off' })
            Get-VMIntegrationService -VM $vm -Name 'Guest Service Interface' | Enable-VMIntegrationService
        }
        $vm = Get-VM -Name $name
        $drives = @($vm | Get-VMHardDiskDrive)
        $adapters = @($vm | Get-VMNetworkAdapter)
        if ($vm.Generation -ne 2 -or $drives.Count -ne 1 -or $drives[0].Path -ine $path -or
            $adapters.Count -ne 1 -or $adapters[0].SwitchName -ne 'InternalNATSwitch' -or
            $vm.ProcessorCount -ne $cpu -or $vm.MemoryStartup -ne $memory -or $vm.DynamicMemoryEnabled -or
            $vm.AutomaticStartAction -ne 'Start' -or $vm.AutomaticStopAction -ne 'ShutDown' -or
            [string](Get-VMFirmware -VM $vm).SecureBoot -ne $(if ($secureBoot) { 'On' } else { 'Off' }) -or
            -not (Get-VMIntegrationService -VM $vm -Name 'Guest Service Interface').Enabled) {
            Stop-ArcBoxHostStep dsc-config "Unexpected configuration for $name; preserve its state."
        }
    }
}
