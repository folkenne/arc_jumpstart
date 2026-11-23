$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArcBox.Host.ps1')
$root = 'C:\ArcBox'
$env:AZURE_CONFIG_DIR = (New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'workbook-cli') -Force).FullName
Start-Transcript -Path "$root\Logs\MonitorWorkbookLogonScript.log" -Append | Out-Null
$step = 'Azure CLI managed identity sign-in'
$last = 'Workbook transcript started; Azure identity is not verified.'
try {
    Invoke-ArcBoxAz @('login','--identity','--output','none')
    $last = 'Managed identity sign-in returned successfully.'
    $step = 'Resolve the configured Log Analytics workspace'
    $workspaceId = Invoke-ArcBoxAz @('monitor','log-analytics','workspace','show','--subscription',$env:subscriptionId,
        '--resource-group',$env:resourceGroup,'--workspace-name',$env:workspaceName,'--query','id','-o','tsv','--only-show-errors')
    if (-not $workspaceId) { Stop-ArcBoxHostStep workbook 'The intended workspace could not be resolved.' }
    $last = 'The configured Log Analytics workspace resolved.'
    $step = 'Prepare the workbook files'
    $template = (Get-Content -LiteralPath "$root\mgmtMonitorWorkbook.json" -Raw).
        Replace('<subscriptionId>',$env:subscriptionId).Replace('<resourceGroup>',$env:resourceGroup).Replace('<workspaceName>',$env:workspaceName)
    $parameters = (Get-Content -LiteralPath "$root\mgmtMonitorWorkbook.parameters.json" -Raw).Replace('workbookResourceId-stage',$workspaceId)
    $templateFile = Join-Path $PSScriptRoot 'workbook.json'
    $parametersFile = Join-Path $PSScriptRoot 'workbook.parameters.json'
    [IO.File]::WriteAllText($templateFile, $template)
    [IO.File]::WriteAllText($parametersFile, $parameters)
    $name = "arcbox-workbook-$([Environment]::GetEnvironmentVariable('ArcBoxAttemptId','Machine'))"
    $step = 'Submit the named workbook ARM deployment'
    Write-ArcBoxJournal workbook INFO 'Submitting the workbook; the ARM request is not a completion result.' `
        -Owner 'MonitorWorkbookLogonScript.ps1' -Detail @{deployment=$name; expected='Succeeded'} -LastConfirmed $last
    $result = Invoke-ArcBoxAz @('deployment','group','create','--name',$name,'--subscription',$env:subscriptionId,
        '--resource-group',$env:resourceGroup,'--template-file',$templateFile,'--parameters',$parametersFile,
        '--query','properties.provisioningState','-o','tsv','--only-show-errors')
    if ($result -cne 'Succeeded') { Stop-ArcBoxHostStep workbook 'The workbook deployment did not report Succeeded.' }
    Write-ArcBoxJournal workbook INFO 'Azure reported the workbook deployment Succeeded.' `
        -Owner 'MonitorWorkbookLogonScript.ps1' -Detail @{deployment=$name; observed='Succeeded'} -LastConfirmed 'ARM terminal state observed; workbook display not tested.'
} catch {
    Write-ArcBoxJournal workbook ERROR 'Workbook setup stopped. Check the named operation and verify the workbook before handoff.' `
        -Owner 'MonitorWorkbookLogonScript.ps1' -Operation $step -Failure $_ -LastConfirmed $last `
        -Detail @{deployment=$name; transcript='MonitorWorkbookLogonScript.log'}
    throw
} finally {
    try { Stop-Transcript | Out-Null }
    catch { Write-Warning 'Workbook setup could not close its transcript; check the administrator journals.' -WarningAction Continue }
}
