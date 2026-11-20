$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ArcBox.Host.ps1')
$root = 'C:\ArcBox'
$env:AZURE_CONFIG_DIR = (New-Item -ItemType Directory -Path (Join-Path $PSScriptRoot 'workbook-cli') -Force).FullName
Start-Transcript -Path "$root\Logs\MonitorWorkbookLogonScript.log" -Append | Out-Null
try {
    Invoke-ArcBoxAz @('login','--identity','--output','none')
    $workspaceId = Invoke-ArcBoxAz @('monitor','log-analytics','workspace','show','--subscription',$env:subscriptionId,
        '--resource-group',$env:resourceGroup,'--workspace-name',$env:workspaceName,'--query','id','-o','tsv','--only-show-errors')
    if (-not $workspaceId) { Stop-ArcBoxHostStep workbook 'The intended workspace could not be resolved.' }
    $template = (Get-Content -LiteralPath "$root\mgmtMonitorWorkbook.json" -Raw).
        Replace('<subscriptionId>',$env:subscriptionId).Replace('<resourceGroup>',$env:resourceGroup).Replace('<workspaceName>',$env:workspaceName)
    $parameters = (Get-Content -LiteralPath "$root\mgmtMonitorWorkbook.parameters.json" -Raw).Replace('workbookResourceId-stage',$workspaceId)
    $templateFile = Join-Path $PSScriptRoot 'workbook.json'
    $parametersFile = Join-Path $PSScriptRoot 'workbook.parameters.json'
    [IO.File]::WriteAllText($templateFile, $template)
    [IO.File]::WriteAllText($parametersFile, $parameters)
    $name = "arcbox-workbook-$([Environment]::GetEnvironmentVariable('ArcBoxAttemptId','Machine'))"
    $result = Invoke-ArcBoxAz @('deployment','group','create','--name',$name,'--subscription',$env:subscriptionId,
        '--resource-group',$env:resourceGroup,'--template-file',$templateFile,'--parameters',$parametersFile,
        '--query','properties.provisioningState','-o','tsv','--only-show-errors')
    if ($result -cne 'Succeeded') { Stop-ArcBoxHostStep workbook 'The workbook deployment did not report Succeeded.' }
} finally {
    Stop-Transcript | Out-Null
}
