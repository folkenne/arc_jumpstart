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
            if (!$names.ContainsKey($dep[0])) { throw "Required dependency '$($dep[0])' is missing" }
        }
    }
    $lock
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
        if ([int]$response.StatusCode -ne 200 -or ($response.ContentLength -ge 0 -and $response.ContentLength -ne $Pin.bytes)) {
            throw "Gallery package '$($Pin.name)' has an invalid digest"
        }
        $src = $response.GetResponseStream()
        $dst = [IO.File]::Open($Path,'CreateNew')
        try {
            $buffer = [byte[]]::new(65536)
            $total = 0L
            $clock = [Diagnostics.Stopwatch]::StartNew()
            while (($n = $src.Read($buffer,0,$buffer.Length)) -gt 0) {
                $total += $n
                if ($total -gt $Pin.bytes -or $clock.Elapsed.TotalSeconds -gt 90) {
                    throw "Gallery package '$($Pin.name)' could not be downloaded"
                }
                $dst.Write($buffer,0,$n)
            }
        } finally { $dst.Dispose(); $src.Dispose() }
    } finally { $response.Dispose() }
}

function Expand-ArcBoxVerifiedModule {
    param($Pin,[string]$Package,[string]$Destination)
    if (!(Test-Path -LiteralPath $Package -PathType Leaf) -or (Get-Item -LiteralPath $Package).Length -ne $Pin.bytes) {
        throw "Gallery package '$($Pin.name)' has an invalid digest"
    }
    $actual = (Get-FileHash -LiteralPath $Package -Algorithm SHA512).Hash.ToLowerInvariant()
    if ($actual -cne $Pin.sha512) {
        throw "Gallery package '$($Pin.name)' has an invalid digest"
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
            $versions[0].InnerText -cne $Pin.version) { throw $identityError }
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/') -or $name -in '[Content_Types].xml', '.signature.p7s', $nuspec[0].FullName -or
                $name.StartsWith('_rels/') -or $name.StartsWith('package/')) { continue }
            $parts = $name.Split('/')
            if ($name -match '[\\:%]' -or @($parts | Where-Object { $_ -in '', '.', '..' -or $_.EndsWith('.') -or $_.EndsWith(' ') }).Count) {
                throw "Staged module '$($Pin.name)' has an invalid manifest"
            }
            $path = $Destination
            foreach ($part in $parts) { $path = Join-Path $path $part }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$path,$false)
        }
    } finally { $zip.Dispose() }
    if (!(Test-Path -LiteralPath (Join-Path $Destination "$($Pin.name).psd1") -PathType Leaf)) {
        throw "Staged module '$($Pin.name)' has an invalid manifest"
    }
    Write-ArcBoxJournal modules INFO "Verified archive identity, version and SHA-512 for $($Pin.name)." -DetailedOnly -Durable `
        -Detail @{module=$Pin.name; version=$Pin.version; repository='PSGallery'; bytes=$Pin.bytes; sha512=$actual}
}

function Test-ArcBoxStagedImports {
    param([string]$Pwsh,[string]$ModuleRoot,[string]$LockPath,[string]$Repository = 'Verified local staging')
    $j = $script:ArcBoxJournal
    $helper = (Get-Command Start-ArcBoxOperation -CommandType Function -ErrorAction Stop).ScriptBlock.File
    if (!$j -or !$helper) { throw 'Module import verification failed before any lab data disk write' }
        $probe = {
            $ErrorActionPreference = 'Stop'
            try {
                if ($PSVersionTable.PSVersion.ToString() -cne '7.6.10') { throw 'Unexpected smoke-test engine' }
                $root = [IO.Path]::GetFullPath($env:ARCBOX_SMOKE_MODULES).TrimEnd('\')
                $env:PSModulePath = $root + ';' + (Join-Path $PSHOME 'Modules')
                . $env:ARCBOX_SMOKE_HELPER
                $j = $env:ARCBOX_SMOKE_JOURNAL | ConvertFrom-Json -DateKind String
                Start-ArcBoxJournal -ScriptName 'Bootstrap.ps1' -Boot $j.boot -Release $j.release -Root $j.root
                $script:ArcBoxJournal.run = $j.run
                $script:ArcBoxJournal.attempt = $j.attempt
                $repository = $env:ARCBOX_SMOKE_SOURCE
                $lock = Get-Content -LiteralPath $env:ARCBOX_SMOKE_LOCK -Raw | ConvertFrom-Json
                function Assert-LockedModulePath($Module,$Pin) {
                    $expectedPath = Join-Path (Join-Path $root $Pin.name) $Pin.version
                    if (!$Module -or $Module.Version.ToString() -cne $Pin.version -or !$Module.Path -or
                        !$Module.Path.StartsWith($expectedPath + '\',[StringComparison]::OrdinalIgnoreCase)) {
                        throw "Staged module '$($Pin.name)' has an invalid manifest"
                    }
                }
                foreach ($name in 'Microsoft.PowerShell.PSResourceGet','Az.Accounts','Az.ConnectedMachine','Azure.Arc.Jumpstart.Common',
                    'Microsoft.PowerShell.SecretManagement','Pester','Az') {
                    $pin = $lock.packages | Where-Object name -CEQ $name | Select-Object -First 1
                    Invoke-ArcBoxOperation modules 'Import locked module' $name {
                        if (!$pin) { throw "Required dependency '$name' is missing" }
                        $manifest = Join-Path (Join-Path (Join-Path $root $name) $pin.version) "$name.psd1"
                        if (!(Test-Path -LiteralPath $manifest -PathType Leaf)) { throw "Required dependency '$name' is missing" }
                        $loaded = @(Import-Module -Name $manifest -Global -PassThru -ErrorAction Stop | Where-Object Name -EQ $name)
                        if ($loaded.Count -ne 1) { throw "Staged module '$name' has an invalid manifest" }
                        Assert-LockedModulePath $loaded[0] $pin
                    } -Version $pin.version -Repository $repository
                }
                $expected = [ordered]@{ 'Install-PSResource'='Microsoft.PowerShell.PSResourceGet'; 'Connect-AzAccount'='Az.Accounts'
                    'Disable-AzContextAutosave'='Az.Accounts'
                    'Get-AzAccessToken'='Az.Accounts'; 'Invoke-AzRestMethod'='Az.Accounts'; 'Get-AzConnectedMachine'='Az.ConnectedMachine'
                    'Set-JSDesktopBackground'='Azure.Arc.Jumpstart.Common'; 'Invoke-JSSudoCommand'='Azure.Arc.Jumpstart.Common'
                    'Convert-JSImageToBitMap'='Azure.Arc.Jumpstart.Common' }
                foreach ($cmd in $expected.Keys) {
                    $pin = $lock.packages | Where-Object name -EQ $expected[$cmd] | Select-Object -First 1
                    Invoke-ArcBoxOperation modules 'Verify command provider' "$($pin.name): $cmd" {
                        $resolved = Get-Command -Name $cmd -ErrorAction Stop
                        if ($resolved.ModuleName -ne $pin.name) { throw 'Module command did not resolve from the verified version.' }
                        Assert-LockedModulePath $resolved.Module $pin
                    } -Version $pin.version -Repository $repository
                }
                foreach ($module in Get-Module -All) {
                    $pin = $lock.packages | Where-Object name -EQ $module.Name | Select-Object -First 1
                    if (!$pin) { continue }
                    Invoke-ArcBoxOperation modules 'Record loaded module provenance' $pin.name {
                        Assert-LockedModulePath $module $pin
                        Write-ArcBoxJournal modules INFO "Verified loaded module $($pin.name)." -DetailedOnly -Durable `
                            -Detail @{module=$pin.name; version=$module.Version.ToString(); modulePath=$module.Path; repository=$repository; engine='7.6.10'}
                    } -Version $pin.version -Repository $repository
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
        $info.EnvironmentVariables['ARCBOX_SMOKE_SOURCE'] = $Repository
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

function Install-ArcBoxLockedModules {
    param([string]$LockPath,[string]$Work,[string]$Pwsh)
    $lock = Invoke-ArcBoxOperation modules 'Validate package closure' 'ArcBox.Modules.lock.json' {
        Read-ArcBoxModuleLock $LockPath
    } -Repository 'PSGallery'
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $stageDir = Join-Path $Work 'ModuleStage'
    [void][IO.Directory]::CreateDirectory($stageDir)
    $modules = Join-Path $stageDir 'Modules'
    $dest = Join-Path $env:ProgramFiles 'PowerShell\Modules'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($pin in $lock.packages) {
        $package = Join-Path $stageDir "$($pin.name).$($pin.version).nupkg"
        $folder = Join-Path (Join-Path $modules $pin.name) $pin.version
        Invoke-ArcBoxOperation modules 'Download pinned module' $pin.name {
            if ($clock.Elapsed.TotalMinutes -ge 15) { throw 'Module package staging exceeded its time budget.' }
            Receive-ArcBoxGalleryPackage $pin $package
        } -Version $pin.version -Repository 'PSGallery'
        Invoke-ArcBoxOperation modules 'Verify and stage module' $pin.name {
            Expand-ArcBoxVerifiedModule $pin $package $folder
        } -Version $pin.version -Repository 'PSGallery'
    }
    $smokeTargets = 'PSResourceGet Az.Accounts Az.ConnectedMachine Jumpstart.Common SecretManagement Pester Az'
    Invoke-ArcBoxOperation modules 'Verify isolated module imports' $smokeTargets {
        Test-ArcBoxStagedImports $Pwsh $modules $LockPath
    } -Version '7.6.10' -Repository 'Verified local staging'
    foreach ($pin in $lock.packages) {
        if (Test-Path -LiteralPath (Join-Path (Join-Path $dest $pin.name) $pin.version)) {
            throw 'The module destination already exists and was not replaced'
        }
    }
    foreach ($pin in $lock.packages) {
        Invoke-ArcBoxOperation modules 'Install verified module files' $pin.name {
            $moduleDir = Join-Path $dest $pin.name
            $source = Join-Path (Join-Path $modules $pin.name) $pin.version
            [void][IO.Directory]::CreateDirectory($moduleDir)
            Protect-ArcBoxDirectory -Path $source -LabRead
            [IO.Directory]::Move($source, (Join-Path $moduleDir $pin.version))
        } -Version $pin.version -Repository 'Verified local staging'
    }
    Invoke-ArcBoxOperation modules 'Verify installed module imports' $smokeTargets {
        Test-ArcBoxStagedImports $Pwsh $dest $LockPath 'Verified machine modules'
    } -Version '7.6.10' -Repository 'Verified machine modules'
}
