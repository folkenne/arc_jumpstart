function Read-ArcBoxModuleLock {
    param([string]$Path)
    $lock = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop
    $validName = '\A[A-Za-z][A-Za-z0-9_-]{0,45}(?:\.[A-Za-z][A-Za-z0-9_-]{0,35}){0,4}\z'
    $validVersion = '\A[0-9]+(?:\.[0-9]+){1,3}\z'
    $roots = @('Az','Az.ConnectedMachine','Microsoft.PowerShell.SecretManagement','Azure.Arc.Jumpstart.Common','Pester','Microsoft.PowerShell.PSResourceGet')
    if ($lock.schema -ne 1 -or $lock.repository -cne 'PSGallery' -or $lock.uri -cne 'https://www.powershellgallery.com/api/v2' -or
        @($lock.roots.PSObject.Properties).Count -ne $roots.Count -or
        !$lock.packages -or @($lock.packages).Count -gt 200) { throw 'The module lock is invalid' }
    $names = @{}
    foreach ($pin in $lock.packages) {
        if ($pin.name -cnotmatch $validName -or $pin.version -cnotmatch $validVersion -or
            $pin.sha512 -cnotmatch '\A[a-f0-9]{128}\z' -or $pin.bytes -lt 100 -or $pin.bytes -gt 128MB -or
            $names.ContainsKey($pin.name)) { throw 'The module lock is invalid' }
        $names[$pin.name] = $pin
    }
    foreach ($name in $roots) {
        if (!$names.ContainsKey($name) -or $lock.roots.$name -cne $names[$name].version) {
            throw "Required dependency '$name' is missing"
        }
    }
    foreach ($pin in $lock.packages) {
        foreach ($dep in $pin.dependencies) {
            # ConvertFrom-Json yields a two-element array per dependency.
            if ($dep -isnot [array] -or $dep.Count -ne 2 -or $dep[0] -cnotmatch $validName -or
                $dep[1] -cnotmatch '\A[0-9., \[\]()]{0,45}\z') { throw 'The module lock is invalid' }
        }
    }
    $lock
}

function Get-ArcBoxProvisioningCommands {
    [ordered]@{
        'Az.Accounts' = @('Disable-AzContextAutosave','Connect-AzAccount','Get-AzAccessToken','Invoke-AzRestMethod')
        'Az.ConnectedMachine' = @('Get-AzConnectedMachine')
        'Azure.Arc.Jumpstart.Common' = @('Invoke-JSSudoCommand','Convert-JSImageToBitMap','Set-JSDesktopBackground')
    }
}

function Stop-ArcBoxModuleOperation {
    param([string]$Code,[string]$Message,[hashtable]$Detail = @{},[Exception]$Cause)
    if ($Cause) {
        while ($Cause.InnerException) { $Cause = $Cause.InnerException }
        $Detail.cause = $Cause.GetType().FullName
    }
    $Detail.code = $Code
    $failure = [InvalidOperationException]::new($Message)
    $failure.Data['ArcBoxModuleFailure'] = Get-ArcBoxModuleFailureDetail $Detail
    throw $failure
}

function Test-ArcBoxLockedVersion {
    param([version]$Version,[string]$Constraint)
    if (!$Constraint.Trim()) { return $true }
    if ($Constraint -match '\A\[([0-9.]+)\]\z') { return $Version -eq [version]$Matches[1] }
    if ($Constraint -match '\A[0-9.]+\z') { return $Version -ge [version]$Constraint }
    if ($Constraint -notmatch '\A([\[(])\s*([0-9.]*)\s*,\s*([0-9.]*)\s*([\])])\z') { return $false }
    $lo, $hi = $Matches[2], $Matches[3]
    if (($lo -and ($Version -lt [version]$lo -or ($Version -eq [version]$lo -and $Matches[1] -eq '('))) -or
        ($hi -and ($Version -gt [version]$hi -or ($Version -eq [version]$hi -and $Matches[4] -eq ')')))) { return $false }
    $true
}

function Get-ArcBoxProvisioningPins {
    param($Lock)
    $pins = @{}
    foreach ($pin in $Lock.packages) { $pins[$pin.name] = $pin }
    $state = @{}
    function Visit-ArcBoxDependency($Name,$RequestingModule,$Constraint) {
        if ($state[$Name] -eq 'Complete') { return }
        if ($state[$Name] -eq 'Visiting' -or !$pins.ContainsKey($Name)) {
            Stop-ArcBoxModuleOperation LockDependency 'Locked dependency constraint is not satisfied.' `
                @{requestingModule=$RequestingModule; dependency=$Name; constraint=$Constraint; lockedVersion=$pins[$Name].version
                    dependencyReason=$(if ($state[$Name] -eq 'Visiting') { 'Cycle' } else { 'MissingPin' })}
        }
        $pin = $pins[$Name]
        $state[$Name] = 'Visiting'
        foreach ($dep in $pin.dependencies) {
            $candidate = $pins[$dep[0]]
            if (!$candidate -or !(Test-ArcBoxLockedVersion ([version]$candidate.version) $dep[1])) {
                Stop-ArcBoxModuleOperation LockDependency 'Locked dependency constraint is not satisfied.' `
                    @{requestingModule=$Name; dependency=$dep[0]; constraint=$dep[1]; lockedVersion=$candidate.version
                        dependencyReason=$(if ($candidate) { 'IncompatiblePin' } else { 'MissingPin' })}
            }
            Visit-ArcBoxDependency $dep[0] $Name $dep[1]
        }
        $state[$Name] = 'Complete'
        $pin
    }
    $roots = (Get-ArcBoxProvisioningCommands).Keys
    # Prefer the requesting edge over a bare missing-root error for shared dependencies.
    foreach ($name in $roots) {
        if ($pins.ContainsKey($name)) { Visit-ArcBoxDependency $name }
    }
    foreach ($name in $roots) {
        if (!$pins.ContainsKey($name)) { Visit-ArcBoxDependency $name }
    }
}

function Get-ArcBoxGalleryResponse {
    param([Net.HttpWebRequest]$Request)
    try { $Request.GetResponse() }
    catch {
        $failure = $_.Exception
        while ($failure -and $failure -isnot [Net.WebException]) { $failure = $failure.InnerException }
        if ($failure -isnot [Net.WebException]) { throw }
        $hostName = $Request.RequestUri.DnsSafeHost
        if ($failure.Response -is [Net.HttpWebResponse]) {
            try { throw "PSGallery $hostName HTTP status: $([int]$failure.Response.StatusCode)." }
            finally { $failure.Response.Dispose() }
        }
        throw "PSGallery $hostName transport failure: $($failure.Status)."
    }
}

function Receive-ArcBoxGalleryPackage {
    param($Pin,[string]$Path)
    $first = [uri]("https://www.powershellgallery.com/api/v2/package/$($Pin.name)/$($Pin.version)")
    $expected = "/packages/$($Pin.name).$($Pin.version).nupkg"
    $request = [Net.HttpWebRequest]::Create($first)
    $request.AllowAutoRedirect = $false
    $request.Timeout = $request.ReadWriteTimeout = 20000
    $response = Get-ArcBoxGalleryResponse $request
    try {
        if ([int]$response.StatusCode -ne 302) { throw "Gallery package '$($Pin.name)' could not be downloaded" }
        $location = [uri]$response.Headers['Location']
        if (!$location.IsAbsoluteUri -or $location.Scheme -cne 'https' -or $location.DnsSafeHost -cne 'cdn.powershellgallery.com' -or
            !$location.IsDefaultPort -or $location.UserInfo -or $location.AbsolutePath -ine $expected -or $location.Query -or $location.Fragment) {
            throw "Gallery package '$($Pin.name)' could not be downloaded"
        }
    } finally { $response.Dispose() }
    $request = [Net.HttpWebRequest]::Create($location)
    $request.AllowAutoRedirect = $false
    $request.Timeout = $request.ReadWriteTimeout = 20000
    $response = Get-ArcBoxGalleryResponse $request
    try {
        if ([int]$response.StatusCode -ne 200) { throw "PSGallery cdn.powershellgallery.com HTTP status: $([int]$response.StatusCode)." }
        if ($response.ContentLength -ge 0 -and $response.ContentLength -ne $Pin.bytes) {
            Stop-ArcBoxModuleOperation PackageLength 'Package byte count does not match the lock.' `
                @{expectedBytes=$Pin.bytes; observedBytes=$response.ContentLength}
        }
        $src = $response.GetResponseStream()
        $dst = [IO.File]::Open($Path,'CreateNew')
        try {
            $buffer = [byte[]]::new(65536)
            $total = 0L
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (($n = $src.Read($buffer,0,$buffer.Length)) -gt 0) {
                $total += $n
                if ($total -gt $Pin.bytes) {
                    Stop-ArcBoxModuleOperation PackageLength 'Package byte count does not match the lock.' `
                        @{expectedBytes=$Pin.bytes; observedBytes=$total}
                }
                if ($clock.Elapsed.TotalSeconds -gt 90) {
                    throw "Gallery package '$($Pin.name)' could not be downloaded"
                }
                $dst.Write($buffer,0,$n)
            }
        } finally { $dst.Dispose(); $src.Dispose() }
    } finally { $response.Dispose() }
}

function Expand-ArcBoxVerifiedModule {
    param($Pin,[string]$Package,[string]$Destination)
    $item = Get-Item -LiteralPath $Package -ErrorAction Stop
    if ($item.PSIsContainer -or $item.Length -ne $Pin.bytes) {
        Stop-ArcBoxModuleOperation PackageLength 'Package byte count does not match the lock.' `
            @{expectedBytes=$Pin.bytes; observedBytes=$item.Length}
    }
    $actual = (Get-FileHash -LiteralPath $Package -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($actual -cne $Pin.sha512) {
        Stop-ArcBoxModuleOperation PackageDigest 'Package SHA-512 does not match the lock.'
    }
    $zip = [IO.Compression.ZipFile]::OpenRead($Package)
    try {
        $nuspec = @($zip.Entries | Where-Object FullName -Match '\A[^/\\]+\.nuspec\z')
        $identityError = "Gallery package '$($Pin.name)' has an unexpected archive identity or version."
        if ($nuspec.Count -ne 1 -or $nuspec[0].Length -gt 1MB) { throw $identityError }
        $settings = [Xml.XmlReaderSettings]::new()
        $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $settings.MaxCharactersInDocument = 1MB
        $stream = $nuspec[0].Open()
        try {
            $reader = [Xml.XmlReader]::Create($stream,$settings)
            try {
                $document = [Xml.XmlDocument]::new()
                $document.XmlResolver = $null
                $document.Load($reader)
            } catch [Xml.XmlException] { throw $identityError }
            finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
        $metadata = "/*[local-name()='package']/*[local-name()='metadata']"
        $ids = $document.SelectNodes("$metadata/*[local-name()='id']")
        $versions = $document.SelectNodes("$metadata/*[local-name()='version']")
        if ($ids.Count -ne 1 -or $versions.Count -ne 1 -or $ids[0].InnerText -ine $Pin.name -or
            $versions[0].InnerText -cne $Pin.version) {
            Stop-ArcBoxModuleOperation ArchiveIdentity 'Package archive identity or version mismatch.' `
                @{observedVersion=$(if ($versions.Count -eq 1) { $versions[0].InnerText })}
        }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/') -or $name -in '[Content_Types].xml', '.signature.p7s', $nuspec[0].FullName -or
                $name.StartsWith('_rels/') -or $name.StartsWith('package/')) { continue }
            $parts = $name.Split('/')
            if ($name -match '[\\:%]' -or @($parts | Where-Object { $_ -in '', '.', '..' -or $_.EndsWith('.') -or $_.EndsWith(' ') }).Count) {
                Stop-ArcBoxModuleOperation UnsafeEntry 'Archive contains an unsafe file entry.' @{zipEntry=$name}
            }
            $path = $Destination.TrimEnd('\') + '\' + ($parts -join '\')
            try {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
            } catch {
                Stop-ArcBoxModuleOperation ExtractionFailed 'Archive extraction failed.' `
                    @{zipEntry=$name; destinationLength=$path.Length} $_.Exception
            }
        }
    } finally { $zip.Dispose() }
    if (!(Test-Path -LiteralPath (Join-Path $Destination "$($Pin.name).psd1") -PathType Leaf)) {
        Stop-ArcBoxModuleOperation ManifestRead 'Manifest read failed.' `
            @{expectedOrigin="machine-modules\$($Pin.name)\$($Pin.version)\$($Pin.name).psd1"; observedOrigin='<not available>'}
    }
    Write-ArcBoxJournal modules INFO "Verified archive identity, version and SHA-512 for $($Pin.name)." -DetailedOnly -Durable `
        -Detail @{module=$Pin.name; version=$Pin.version; repository='PSGallery'; bytes=$Pin.bytes; sha512=$actual}
}

function Assert-ArcBoxModuleDirectory {
    param([string]$Path)
    for ($dir = [IO.DirectoryInfo]::new($Path); $dir; $dir = $dir.Parent) {
        if ($dir.Exists -and ($dir.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Stop-ArcBoxModuleOperation ReparsePoint 'Module origin includes a reparse point.'
        }
    }
}

function Get-ArcBoxModuleFileSet {
    param([string]$Root)
    $set = @{}
    $dirs = [Collections.Generic.Stack[string]]::new()
    $dirs.Push($Root)
    while ($dirs.Count) {
        $dir = $dirs.Pop()
        $item = Get-Item -LiteralPath $dir -Force -ErrorAction Stop
        $acl = Get-Acl -LiteralPath $dir -ErrorAction Stop
        $relative = $dir.Substring($Root.Length)
        $set[$relative] = $acl.Owner + '|' + $acl.GetSecurityDescriptorSddlForm('Access')
        foreach ($child in $item.EnumerateFileSystemInfos()) {
            if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                Stop-ArcBoxModuleOperation ReparsePoint 'Module origin includes a reparse point.'
            }
            if ($child.Attributes -band [IO.FileAttributes]::Directory) { $dirs.Push($child.FullName); continue }
            $acl = Get-Acl -LiteralPath $child.FullName -ErrorAction Stop
            $hash = (Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256 -ErrorAction Stop).Hash
            $set[$child.FullName.Substring($Root.Length)] = "$hash|$($acl.Owner)|$($acl.GetSecurityDescriptorSddlForm('Access'))"
        }
    }
    $set
}

function Install-ArcBoxVerifiedModuleFiles {
    param($Pin,[string]$Staged,[string]$ModuleRoot)
    $folder = Join-Path (Join-Path $ModuleRoot $Pin.name) $Pin.version
    Assert-ArcBoxModuleDirectory $folder
    if (Test-Path -LiteralPath $folder) {
        $expected = Get-ArcBoxModuleFileSet $Staged
        $observed = if (Test-Path -LiteralPath $folder -PathType Container) { Get-ArcBoxModuleFileSet $folder }
        if (!$observed -or $observed.Count -ne $expected.Count -or
            @($expected.Keys | Where-Object { !$observed.ContainsKey($_) -or $observed[$_] -cne $expected[$_] }).Count) {
            Stop-ArcBoxModuleOperation ExistingFiles 'Verified module files do not match the existing installation.' `
                @{expectedOrigin="machine-modules\$($Pin.name)\$($Pin.version)"; observedOrigin="machine-modules\$($Pin.name)\$($Pin.version)"}
        }
        Write-ArcBoxJournal modules INFO "Reused exact verified files for $($Pin.name)." -Detail @{module=$Pin.name; version=$Pin.version} -DetailedOnly -Durable
        return
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $folder))
    # A same-volume directory move publishes the complete verified version or nothing.
    [IO.Directory]::Move($Staged, $folder)
}

function Read-ArcBoxProvisioningManifest {
    param($Pin,[string]$Manifest,[hashtable]$Required,[hashtable]$Locked)
    $expected = "machine-modules\$($Pin.name)\$($Pin.version)\$($Pin.name).psd1"
    try { $data = Import-PowerShellDataFile -LiteralPath $Manifest -ErrorAction Stop }
    catch {
        Stop-ArcBoxModuleOperation ManifestRead 'Manifest read failed.' @{expectedOrigin=$expected; observedOrigin='<not available>'} $_.Exception
    }
    if ([string]$data.ModuleVersion -cne $Pin.version) {
        Stop-ArcBoxModuleOperation ManifestVersion 'Manifest version mismatch.' `
            @{expectedOrigin=$expected; observedOrigin=$expected; observedVersion=[string]$data.ModuleVersion}
    }
    foreach ($spec in $data.RequiredModules) {
        $name = if ($spec -is [string]) { $spec } else { $spec.ModuleName }
        $selected = if ($name) { $Required[$name] }
        $lockedPin = if ($name) { $Locked[$name] }
        $constraint = if ($spec -isnot [string] -and $spec.RequiredVersion) { "[$($spec.RequiredVersion)]" }
            elseif ($spec -isnot [string] -and ($spec.ModuleVersion -or $spec.MaximumVersion)) {
                "[$($spec.ModuleVersion), $($spec.MaximumVersion)]"
            } else { '' }
        $compatible = $selected -and $(if ($constraint -match '\*\]\z') {
            # PowerShell also checks the actual ModuleSpecification (including GUID) on import.
            $prefix = ([string]$spec.MaximumVersion).TrimEnd('*')
            $candidate = [version]$selected.version
            ($candidate.ToString().StartsWith($prefix, [StringComparison]::Ordinal) -or
                $candidate -lt [version]($prefix + '0')) -and
                (!$spec.ModuleVersion -or $candidate -ge [version]$spec.ModuleVersion)
        } else { Test-ArcBoxLockedVersion ([version]$selected.version) $constraint })
        if (!$compatible) {
            Stop-ArcBoxModuleOperation ManifestDependency 'Manifest dependency constraint is not satisfied.' `
                @{requestingModule=$Pin.name; dependency=$name; constraint=$constraint; lockedVersion=$lockedPin.version
                    dependencyReason=$(if (!$lockedPin) { 'MissingPin' } elseif (!$selected) { 'NotInClosure' } else { 'IncompatiblePin' })
                    expectedOrigin=$expected; observedOrigin=$expected}
        }
    }
}

function Assert-ArcBoxLoadedModule {
    param($Module,$Pin,[string]$Root)
    $versionPath = "machine-modules\$($Pin.name)\$($Pin.version)"
    $expected = Join-Path (Join-Path $Root $Pin.name) $Pin.version
    $origin = '<not available>'
    $inside = $false
    if ($Module.Path) {
        $full = [IO.Path]::GetFullPath($Module.Path)
        $inside = $full.StartsWith($expected + '\',[StringComparison]::OrdinalIgnoreCase)
        $origin = if ($inside) { "$versionPath\$($full.Substring($expected.Length + 1))" } else { '<outside verified version>' }
    }
    $detail = @{expectedOrigin=$versionPath; observedOrigin=$origin; observedVersion=[string]$Module.Version}
    if (!$Module -or [string]$Module.Version -cne $Pin.version) {
        Stop-ArcBoxModuleOperation ModuleVersion 'Loaded module version mismatch.' $detail
    }
    if (!$inside) { Stop-ArcBoxModuleOperation ModulePath 'Loaded module path mismatch.' $detail }
    Assert-ArcBoxModuleDirectory (Split-Path -Parent $full)
    if ((Get-Item -LiteralPath $full -Force -ErrorAction Stop).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Stop-ArcBoxModuleOperation ReparsePoint 'Module origin includes a reparse point.' $detail
    }
}

function Import-ArcBoxProvisioningModule {
    param($Pin,[string]$Manifest,[string]$Root)
    try {
        $loaded = @(Import-Module -Name $Manifest -Global -PassThru -ErrorAction Stop | Where-Object Name -EQ $Pin.name)
    } catch { Stop-ArcBoxModuleOperation ImportFailed 'Required module import failed.' @{} $_.Exception }
    if ($loaded.Count -ne 1) { Stop-ArcBoxModuleOperation ImportFailed 'Required module import failed.' }
    Assert-ArcBoxLoadedModule $loaded[0] $Pin $Root
}

function Test-ArcBoxInstalledImports {
    param([string]$Pwsh,[string]$ModuleRoot,[string]$LockPath)
    $j = $script:ArcBoxJournal
    $helper = (Get-Command Start-ArcBoxOperation -CommandType Function -ErrorAction Stop).ScriptBlock.File
    $modules = (Get-Command Read-ArcBoxModuleLock -CommandType Function -ErrorAction Stop).ScriptBlock.File
    if (!$j -or !$helper -or !$modules) { throw 'Module import verification failed before any lab data disk write' }
        $probe = {
            $ErrorActionPreference = 'Stop'
            try {
                if ($PSVersionTable.PSVersion.ToString() -cne '7.6.10') { throw 'Unexpected smoke-test engine' }
                $root = [IO.Path]::GetFullPath($env:ARCBOX_SMOKE_MODULES).TrimEnd('\')
                . $env:ARCBOX_SMOKE_HELPER
                . $env:ARCBOX_SMOKE_MODULE_HELPER
                Set-ArcBoxProvisioningModulePath $root
                $j = $env:ARCBOX_SMOKE_JOURNAL | ConvertFrom-Json -DateKind String
                Start-ArcBoxJournal -ScriptName 'Bootstrap.ps1' -Boot $j.boot -Release $j.release -Root $j.root
                $script:ArcBoxJournal.run = $j.run
                $script:ArcBoxJournal.attempt = $j.attempt
                $repository = 'Verified machine modules'
                $lock = Read-ArcBoxModuleLock $env:ARCBOX_SMOKE_LOCK
                $pins = @(Get-ArcBoxProvisioningPins $lock)
                $locked = @{}
                foreach ($pin in $lock.packages) { $locked[$pin.name] = $pin }
                $required = @{}
                foreach ($pin in $pins) { $required[$pin.name] = $pin }
                $commands = Get-ArcBoxProvisioningCommands
                foreach ($pin in $pins) {
                    $manifest = Join-Path (Join-Path (Join-Path $root $pin.name) $pin.version) "$($pin.name).psd1"
                    Invoke-ArcBoxOperation modules 'Read locked module manifest' $pin.name {
                        Read-ArcBoxProvisioningManifest $pin $manifest $required $locked
                    } -Version $pin.version -Repository $repository
                    Invoke-ArcBoxOperation modules 'Import locked module' $pin.name {
                        Import-ArcBoxProvisioningModule $pin $manifest $root
                        $visibleModules = @(Get-Module -Name $pin.name -ListAvailable)
                        if (!$visibleModules.Count) {
                            Stop-ArcBoxModuleOperation ModulePath 'Loaded module path mismatch.' `
                                @{expectedOrigin="machine-modules\$($pin.name)\$($pin.version)\$($pin.name).psd1"; observedOrigin='<not available>'}
                        }
                        foreach ($visible in $visibleModules) {
                            if ($visible.Path -ine $manifest -or [string]$visible.Version -cne $pin.version) {
                                Stop-ArcBoxModuleOperation AlternateModule 'Alternate required module is visible to the worker.' `
                                    @{expectedOrigin="machine-modules\$($pin.name)\$($pin.version)\$($pin.name).psd1"
                                        observedOrigin='<outside verified version>'; observedVersion=[string]$visible.Version}
                            }
                        }
                    } -Version $pin.version -Repository $repository
                }
                foreach ($pin in $pins) {
                    foreach ($cmd in $commands[$pin.name]) {
                        Invoke-ArcBoxOperation modules 'Verify command provider' "$($pin.name): $cmd" {
                            try { $resolved = Get-Command -Name $cmd -ErrorAction Stop }
                            catch { Stop-ArcBoxModuleOperation CommandProvider 'Required command provider check failed.' @{} $_.Exception }
                            if ($resolved.ModuleName -ne $pin.name) {
                                Stop-ArcBoxModuleOperation CommandProvider 'Required command provider check failed.' `
                                    @{observedVersion=[string]$resolved.Module.Version; observedOrigin='<outside verified version>'}
                            }
                            Assert-ArcBoxLoadedModule $resolved.Module $pin $root
                        } -Version $pin.version -Repository $repository
                    }
                }
                'ARCBOX_IMPORT_OK'
            } catch {
                'ARCBOX_IMPORT_ERROR=' + (ConvertTo-Json -Compress -InputObject @{
                    message=$_.Exception.Message; exception=$_.Exception.GetType().FullName; category=$_.CategoryInfo.Category.ToString()
                })
                exit 1
            }
        }
        $info = [Diagnostics.ProcessStartInfo]::new($Pwsh)
        $info.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' +
            [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probe.ToString()))
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $info.RedirectStandardError = $true
        $info.EnvironmentVariables['ARCBOX_SMOKE_MODULES'] = $ModuleRoot
        $info.EnvironmentVariables['ARCBOX_SMOKE_LOCK'] = $LockPath
        $info.EnvironmentVariables['ARCBOX_SMOKE_HELPER'] = $helper
        $info.EnvironmentVariables['ARCBOX_SMOKE_MODULE_HELPER'] = $modules
        $info.EnvironmentVariables['ARCBOX_SMOKE_JOURNAL'] = @{
            root=$j.root; run=$j.run; attempt=$j.attempt; boot=$j.boot; release=$j.release
        } | ConvertTo-Json -Compress
        $process = [Diagnostics.Process]::Start($info)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (!$process.WaitForExit(300000)) {
                $process.Kill()
                throw 'Module import verification timed out before any lab data disk write'
            }
            if (!$stdout.Wait(5000) -or !$stderr.Wait(5000)) { throw 'Module import verification output did not close' }
            $output = $stdout.Result -split '\r?\n'
            $code = $process.ExitCode
        } finally { $process.Dispose() }
        if ($code -ne 0 -or @($output -ceq 'ARCBOX_IMPORT_OK').Count -ne 1) {
            $message = 'Module import verification failed before any lab data disk write'
            $prefix = 'ARCBOX_IMPORT_ERROR='
            $marker = @($output | Where-Object { $_ -is [string] -and $_.Length -lt 1200 -and $_.StartsWith($prefix) })
            $row = $null
            if ($marker.Count -eq 1) {
                try { $row = $marker[0].Substring($prefix.Length) | ConvertFrom-Json -ErrorAction Stop }
                catch { $row = $null } # Native output is not a trusted diagnostic record.
            }
            if ($row) {
                $safe = ConvertTo-ArcBoxOperationError $row.message
                if ($safe.message) { $message = $safe.message }
            }
            $failure = [InvalidOperationException]::new($message)
            $failure.Data['ArcBoxNativeExit'] = $code
            if ($row.exception -cmatch '\A[A-Za-z][A-Za-z0-9.]{1,120}Exception\z') { $failure.Data['ArcBoxChildException'] = $row.exception }
            if ($row.category -cmatch '\A[A-Za-z]{3,35}\z') { $failure.Data['ArcBoxChildCategory'] = $row.category }
            throw $failure
        }
}

function Invoke-ArcBoxPackageAction {
    param($Pin,[string]$Action,[string]$Repository,[bool]$Required,[scriptblock]$Command)
    $op = Start-ArcBoxOperation modules $Action $Pin.name $Pin.version $Repository
    try { & $Command }
    catch {
        Complete-ArcBoxOperation modules $op -Failure $_ -ContinueOnFailure:(!$Required)
        if ($Required) { throw }
        return $false
    }
    Complete-ArcBoxOperation modules $op
    $true
}

function Install-ArcBoxLockedModules {
    param([string]$LockPath,[string]$ScratchRoot,[string]$Pwsh)
    $lock = Invoke-ArcBoxOperation modules 'Validate package closure' 'ArcBox.Modules.lock.json' {
        Read-ArcBoxModuleLock $LockPath
    } -Repository 'PSGallery'
    $requiredPins = @(Invoke-ArcBoxOperation modules 'Resolve provisioning dependencies' 'ArcBox.Modules.lock.json' {
        Get-ArcBoxProvisioningPins $lock
    } -Repository 'PSGallery')
    $required = @{}
    foreach ($pin in $requiredPins) { $required[$pin.name] = $true }
    $dest = Join-Path $env:ProgramFiles 'PowerShell\Modules'
    Assert-ArcBoxModuleDirectory $dest
    Assert-ArcBoxModuleDirectory $ScratchRoot
    if ([IO.Path]::GetPathRoot($dest) -ine [IO.Path]::GetPathRoot($ScratchRoot)) {
        throw 'Verified module extraction and installation must use the same OS volume.'
    }
    $stageDir = Join-Path $ScratchRoot ([guid]::NewGuid().ToString('N').Substring(0,8))
    if (Test-Path -LiteralPath $stageDir) { throw 'Short module scratch directory already exists.' }
    [void][IO.Directory]::CreateDirectory($stageDir)
    Protect-ArcBoxDirectory $stageDir
    $budget = [Diagnostics.Stopwatch]::StartNew()
    $warnings = 0
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        # Required packages get the time budget first. Still attempt every optional pin.
        $order = $requiredPins + @($lock.packages | Where-Object { !$required.ContainsKey($_.name) })
        for ($i = 0; $i -lt $order.Count; $i++) {
            $pin = $order[$i]
            $blocking = $required.ContainsKey($pin.name)
            $package = Join-Path $stageDir "$i.zip"
            $folder = Join-Path $stageDir "$i"
            if (!(Invoke-ArcBoxPackageAction $pin 'Download pinned module' PSGallery $blocking {
                if ($budget.Elapsed.TotalMinutes -ge 15) { throw 'Module package staging exceeded its time budget.' }
                Receive-ArcBoxGalleryPackage $pin $package
            })) { $warnings++; continue }
            if (!(Invoke-ArcBoxPackageAction $pin 'Verify and stage module' PSGallery $blocking {
                [void][IO.Directory]::CreateDirectory($folder)
                Protect-ArcBoxDirectory -Path $folder -LabRead
                Expand-ArcBoxVerifiedModule $pin $package $folder
            })) { $warnings++; continue }
            if (!(Invoke-ArcBoxPackageAction $pin 'Install verified module files' 'Verified machine modules' $blocking {
                Install-ArcBoxVerifiedModuleFiles $pin $folder $dest
            })) { $warnings++; continue }
        }
    } finally {
        try {
            Assert-ArcBoxModuleDirectory $stageDir
            Remove-Item -LiteralPath $stageDir -Recurse -Force -ErrorAction Stop
        }
        catch { Write-ArcBoxJournal modules WARNING 'Protected OS module scratch could not be removed.' -DetailedOnly -Failure $_ }
    }
    if ($warnings) {
        Write-ArcBoxJournal modules WARNING "$warnings optional locked packages could not be installed. See the administrator log for affected packages." `
            -Detail @{optionalPackageWarnings=$warnings} -Durable
    }
    Invoke-ArcBoxOperation modules 'Verify required installed module imports' 'Provisioning module closure' {
        Test-ArcBoxInstalledImports $Pwsh $dest $LockPath
    } -Version '7.6.10' -Repository 'Verified machine modules'
}
