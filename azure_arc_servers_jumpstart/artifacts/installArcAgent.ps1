param (
    [string]$AccessToken,
    [string]$SpnTenantId,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$AzureLocation,
    [string]$FilterSource
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$ProgressPreference = 'SilentlyContinue'
$phase = 'download'
$code = $null
$failureType = $null
$safe = $null
function Protect-GuestAgentDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Agent working path is not a regular directory.'
    }
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in 'S-1-5-18','S-1-5-32-544') {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
}
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $work = Join-Path $env:ProgramFiles 'ArcBoxGuestAgent'
    $null = New-Item -ItemType Directory -Path $work -Force
    Protect-GuestAgentDirectory $work
    $msi = Join-Path $work 'AzureConnectedMachineAgent.msi'
    $msiLog = Join-Path $work 'installationlog.txt'
    Invoke-WebRequest -Uri https://aka.ms/AzureConnectedMachineAgent -OutFile $msi -UseBasicParsing
    $phase = 'msi'
    $code = [int](Start-Process -FilePath msiexec.exe -ArgumentList ('/i "{0}" /l*v+ "{1}" /qn /norestart' -f $msi, $msiLog) -Wait -PassThru).ExitCode
    if ($code -eq 0) {
        $phase = 'agent-connect'
        $code = $null
        $agent = "$env:ProgramW6432\AzureConnectedMachineAgent\azcmagent.exe"
        if (-not (Test-Path -LiteralPath $agent -PathType Leaf)) { throw [IO.FileNotFoundException]::new('Guest agent executable was not found.') }
        $priorCode = $global:LASTEXITCODE
        try {
            $global:LASTEXITCODE = $null
            $ErrorActionPreference = 'Continue'
            $output = @(& $agent connect --access-token $AccessToken `
                --resource-group $ResourceGroup --tenant-id $SpnTenantId --location $AzureLocation `
                --subscription-id $SubscriptionId --cloud AzureCloud --tags 'Project=jumpstart_arcbox' `
                --correlation-id 'd009f5dd-dba8-4ac7-bac9-b54ef3a6671a' 2>&1)
            $code = $global:LASTEXITCODE
        } finally {
            $global:LASTEXITCODE = $priorCode
            $ErrorActionPreference = 'Stop'
        }
        if ($code -isnot [int]) { throw [InvalidOperationException]::new('No exit was returned by the guest agent.') }
        $id = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.HybridCompute/machines/ArcBox-Win2K25"
        $safe = & ([scriptblock]::Create($FilterSource)) $output $id $SpnTenantId
    }
} catch {
    $failureType = $_.Exception.GetType().Name
} finally {
    $AccessToken = $null
    $output = $null
}
[pscustomobject]@{Tag='arcbox-installer-v1'; Phase=$phase; ExitCode=$code; ErrorType=$failureType;
    ConnectObserved=($phase -ceq 'agent-connect' -and $code -is [int]); ErrorCode=$safe.errorCode; PortalUrl=$safe.portalUrl}
