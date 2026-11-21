$script:ArcBoxPackageSpecs = [ordered]@{
    'Git.Git' = @('exe', 'ProgramFiles\Git\cmd\git.exe')
    'Microsoft.VisualStudioCode' = @('exe', 'ProgramFiles\Microsoft VS Code\Code.exe')
    'Microsoft.AzureCLI' = @('msi', 'ProgramFiles\Microsoft SDKs\Azure\CLI2\wbin\az.cmd')
    'Microsoft.Edge' = @('msi', 'ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe')
    'Microsoft.Azure.AZCopy.10' = @('zip', 'ProgramFiles\ArcBoxTools\azcopy.exe')
    'Microsoft.DotNet.SDK.8' = @('exe', 'ProgramFiles\dotnet\sdk\8.0.428\dotnet.dll')
    'Microsoft.Sysinternals.BGInfo' = @('zip', 'ProgramFiles\ArcBoxTools\Bginfo64.exe')
    'FireDaemon.OpenSSL' = @('exe', 'ProgramFiles\FireDaemon OpenSSL 3.5\bin\openssl.exe')
}

# The engineering pilot requires the eight common packages; ITPro 7-Zip is omitted.
# not App Installer's per-user alias or configuration engine on Server 2022.
function Assert-ArcBoxMachinePackages {
    param($Packages)
    $names = @($Packages.PSObject.Properties.Name)
    if ($null -eq $Packages -or $names.Count -ne $script:ArcBoxPackageSpecs.Count -or
        @($names | Where-Object { $_ -cnotin $script:ArcBoxPackageSpecs.Keys }).Count) {
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

function Get-ArcBoxMatchedTool {
    param([string]$Path, [string]$Hash)
    $file = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($file -and -not $file.PSIsContainer -and -not ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        $actual = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
        if ($actual -ieq $Hash) {
            return @{ path = $file.FullName; sha256 = $actual.ToLowerInvariant() }
        }
    }
}

function Write-ArcBoxMachinePackageEvent {
    param([string]$Id, [string]$Event, [hashtable]$Measured)
    Write-Host ('ArcBoxMachinePackage ' + ([ordered]@{
        utc = [DateTime]::UtcNow.ToString('o')
        id = $Id
        event = $Event
        measured = $Measured
    } | ConvertTo-Json -Compress))
}

function Get-ArcBoxReviewedAssetRedirect {
    param([string]$Location, [string]$AssetPath)
    if (-not $AssetPath -or $Location -cnotmatch ('\Ahttps://release-assets\.githubusercontent\.com' + [regex]::Escape($AssetPath) + '\?[^\s#\\]+\z')) {
        throw 'Unexpected installer redirect destination.'
    }
    $target = [uri]$Location
    if (-not $target.IsAbsoluteUri -or $target.Scheme -cne 'https' -or
        $target.IdnHost -cne 'release-assets.githubusercontent.com' -or -not $target.IsDefaultPort -or $target.UserInfo -or $target.Fragment) {
        throw 'Unexpected installer redirect destination.'
    }
    $target
}

function Save-ArcBoxMachineAsset {
    param([string]$Id, [string]$Uri, [string]$Path)
    $reviewed, $assetPath = switch -CaseSensitive ($Id) {
        'Git.Git' {
            'https://github.com/git-for-windows/git/releases/download/v2.56.1.windows.1/Git-2.56.1-64-bit.exe'
            '/github-production-release-asset/23216272/5b3798ad-0b47-4c8d-9b26-e00bfc8b850e'
        }
        'Microsoft.Azure.AZCopy.10' {
            'https://github.com/Azure/azure-storage-azcopy/releases/download/v10.34.2/azcopy_windows_amd64_10.34.2.zip'
            '/github-production-release-asset/114798676/2dbcf361-0df2-4da1-a1bb-142005d0ed82'
        }
    }
    if (-not $reviewed -or $Uri -cne $reviewed) {
        Invoke-WebRequest -Uri $Uri -OutFile $Path -MaximumRedirection 0 -TimeoutSec 300 -ErrorAction Stop
        return
    }

    Add-Type -AssemblyName System.Net.Http
    $handler = [Net.Http.HttpClientHandler]::new()
    $handler.AllowAutoRedirect = $false
    $handler.UseCookies = $false
    $handler.UseDefaultCredentials = $false
    $client = [Net.Http.HttpClient]::new($handler)
    $client.Timeout = [TimeSpan]::FromSeconds(300)
    $client.MaxResponseContentBufferSize = 70MB
    $response = $null
    try {
        $response = $client.GetAsync([uri]$Uri).GetAwaiter().GetResult()
        if ([int]$response.StatusCode -eq 302) {
            $target = Get-ArcBoxReviewedAssetRedirect ($response.Headers.Location.OriginalString) $assetPath
            $response.Dispose()
            $response = $null
            $response = $client.GetAsync($target).GetAwaiter().GetResult()
        }
        if ([int]$response.StatusCode -ne 200) { throw 'Unexpected installer response status.' }
        $file = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $null = $response.Content.CopyToAsync($file).GetAwaiter().GetResult() } finally { $file.Dispose() }
    } finally {
        if ($response) { $response.Dispose() }
        $client.Dispose()
    }
}

function Install-ArcBoxMachinePackages {
    param($Packages, [string]$Work)
    Assert-ArcBoxMachinePackages $Packages
    foreach ($id in $script:ArcBoxPackageSpecs.Keys) {
        $kind, $relative = $script:ArcBoxPackageSpecs[$id]
        $base, $leaf = $relative -split '\\', 2
        $expected = Join-Path ([Environment]::GetEnvironmentVariable($base)) $leaf
        $pin = $Packages.PSObject.Properties[$id].Value
        $installed = Get-ArcBoxMatchedTool $expected $pin.installedSha256
        if ($installed) {
            Write-ArcBoxMachinePackageEvent $id skipped-existing $installed
            continue
        }
        $asset = Join-Path $Work "$id.$kind"
        try {
            Save-ArcBoxMachineAsset -Id $id -Uri $pin.uri -Path $asset
        } catch { Stop-ArcBoxHostStep winget-setup "Could not retrieve the reviewed installer for $id." }
        $assetHash = (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($assetHash -cne $pin.sha256) {
            Stop-ArcBoxHostStep winget-setup "Installer digest mismatch for $id."
        }
        if ($kind -eq 'zip') {
            $expanded = Join-Path $Work "$id-expanded"
            Expand-Archive -LiteralPath $asset -DestinationPath $expanded -Force
            $binary = @(Get-ChildItem -LiteralPath $expanded -Recurse -File -Filter (Split-Path -Leaf $expected))
            if ($binary.Count -ne 1 -or (Get-AuthenticodeSignature -FilePath $binary[0].FullName).Status -ne 'Valid' -or
                -not (Get-ArcBoxMatchedTool $binary[0].FullName $pin.installedSha256)) {
                Stop-ArcBoxHostStep winget-setup "The signed tool in $id did not match the reviewed installed digest."
            }
            Write-ArcBoxMachinePackageEvent $id copy-start @{ assetSha256 = $assetHash }
            New-Item -ItemType Directory -Path (Split-Path -Parent $expected) -Force | Out-Null
            Copy-Item -LiteralPath $binary[0].FullName -Destination $expected
        } else {
            if ((Get-AuthenticodeSignature -FilePath $asset).Status -ne 'Valid') {
                Stop-ArcBoxHostStep winget-setup "Installer signature invalid for $id."
            }
            Write-ArcBoxMachinePackageEvent $id installer-start @{ assetSha256 = $assetHash }
            if ($kind -eq 'msi') {
                $proc = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList ('/i "{0}" /qn /norestart ALLUSERS=1' -f $asset) -Wait -PassThru
            } else {
                $flags = switch ($id) {
                    'Git.Git' { '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /ALLUSERS' }
                    'Microsoft.VisualStudioCode' { '/VERYSILENT /NORESTART /SUPPRESSMSGBOXES /SP- /ALLUSERS /MERGETASKS=desktopicon,!runcode' }
                    'Microsoft.DotNet.SDK.8' { '/install /quiet /norestart' }
                    'FireDaemon.OpenSSL' { '/exenoui /qn /norestart REBOOT=ReallySuppress ADJUSTSYSTEMPATHENV=yes' }
                }
                $proc = Start-Process -FilePath $asset -ArgumentList $flags -Wait -PassThru
            }
            Write-ArcBoxMachinePackageEvent $id installer-exit @{ code = $proc.ExitCode }
            if ($proc.ExitCode -in 1641,3010) {
                Stop-ArcBoxHostStep machine-reboot-required "Installer for $id requested or started a reboot; do not dispatch downstream work."
            }
            if ($proc.ExitCode -ne 0) { Stop-ArcBoxHostStep winget-setup "Installer for $id returned $($proc.ExitCode)." }
        }
        $installed = Get-ArcBoxMatchedTool $expected $pin.installedSha256
        if (-not $installed) {
            Stop-ArcBoxHostStep winget-setup "Installed machine tool for $id did not match the reviewed bytes."
        }
        Write-ArcBoxMachinePackageEvent $id destination-verified $installed
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
