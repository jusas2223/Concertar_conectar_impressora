$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$temp=Join-Path $env:TEMP ('CascadeTest_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
$utf8=New-Object Text.UTF8Encoding($true)
try{
    Copy-Item -LiteralPath (Join-Path $root 'src\scripts\CONECTAR-IMPRESSORA.ps1'),(Join-Path $root 'src\scripts\INSTALAR-PORTA-LOCAL.ps1') -Destination $temp
    $common=[IO.File]::ReadAllText((Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1'))
    $mocks=@'
function Set-PrinterCompatibilityPolicies {param($Role,$StateDirectory) $global:policyCalls++;return @{Success=$true;Message='Fixture';StatePath='Fixture-state'}}
function Assert-PrinterAdmin {}
function Test-PrinterSharedQueueExists {param($Server,$ShareName) if($global:scenario -eq 'missing-share'){return 2310};return 0}
function Test-PrinterRemoteQueueAccess {param($UNCPath) if($global:scenario -eq 'port-denied'){return 5};return 0}
function Submit-PrinterValidationPage {param($QueueName) $global:jobCalls++; return 42}
function Get-PrintJob {param($PrinterName,$ErrorAction)
 if($global:scenario -eq 'job-error'){return [pscustomobject]@{ID=42;JobStatus='Error'}}
 if($global:scenario -eq 'unrelated-job'){return [pscustomobject]@{ID=17;JobStatus='Error'}}
 return @()
}
function Get-PrinterDriver {param($Name,$ErrorAction) if($global:driverReady){return [pscustomobject]@{Name='Fabricante modelo';MajorVersion=3;PrinterEnvironment='Windows x64'}}}
function Get-Printer {param($Name,$ErrorAction) return $global:queue}
function Wait-ExactPrinter {param($UNCPath,$QueueName,$DriverName,$Seconds) return $global:queue}
function Get-PrinterPort {param($Name,$ErrorAction) if($global:port){return [pscustomobject]@{Name=$global:port}}}
function Add-PrinterPort {param($Name,$ErrorAction)
 if($global:scenario -eq 'port-denied'){throw (New-Object ComponentModel.Win32Exception(5))}
 $global:port=$Name
}
function Remove-PrinterPort {param($Name,$ErrorAction) $global:port=''}
function Add-Printer {param($ConnectionName,$Name,$DriverName,$PortName,$ErrorAction)
 if($ConnectionName){
  $global:nativeCalls++
  if($global:scenario -eq 'access'){throw (New-Object ComponentModel.Win32Exception(5))}
  if($global:scenario -in @('native','job-error','unrelated-job') -or ($global:scenario -eq 'inject' -and $global:driverReady)){
   $global:queue=[pscustomobject]@{Name=$ConnectionName;DriverName='Fabricante modelo';PortName='Network';ShareName='Fila';ComputerName='SERVIDOR'};return
  }
  throw (New-Object ComponentModel.Win32Exception(1801))
 }
 $global:queue=[pscustomobject]@{Name=$Name;DriverName=$DriverName;PortName=$PortName}
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'IMPRESSAO-COMUM.ps1'),$common+"`r`n"+$mocks,$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'DRIVER-DO-SERVIDOR.ps1'),@'
param($Server,$ShareName,$DriverName,$Action,$ProgressPath)
$global:driverCalls++
if($Server -ne 'SERVIDOR' -or $ShareName -ne 'Fila'){throw 'Parâmetros não preservados.'}
if($global:scenario -in @('missing','credential-hint','missing-share')){return @{Success=$false;Code=2;Stage='Ler pacote remoto';Message='Pacote INF não disponível'}}
if($global:scenario -eq 'driver-denied'){return @{Success=$false;Code=5;NativeCode=5;NeedsAuthentication=$true;FailureScope='Remote';Stage='Ler manifesto remoto';Resource='\\SERVIDOR\print$';Message='Acesso negado ao pacote'}}
$global:driverReady=$true
return @{Success=$true;DriverName='Fabricante modelo';Message='Fixture instalado'}
'@,$utf8)
    [IO.File]::WriteAllText((Join-Path $temp 'wrapper.ps1'),@'
param([string]$Scenario)
$global:scenario=$Scenario;$global:queue=$null;$global:port='';$global:driverReady=$false
$global:nativeCalls=0;$global:driverCalls=0;$global:jobCalls=0;$global:policyCalls=0
$mode=if($Scenario -in @('job-error','unrelated-job','test-page')){'TestPage'}else{'QueueOnly'}
$result=& (Join-Path $PSScriptRoot 'CONECTAR-IMPRESSORA.ps1') -Server SERVIDOR -ShareName Fila -ValidationMode $mode
if($global:policyCalls -ne 0){throw 'Conectar alterou políticas/reiniciou Spooler'}
switch($Scenario){
 native {if(-not $result.Success -or $result.Level -ne 'Native' -or $global:nativeCalls -ne 1 -or $global:driverCalls){throw 'Nível 1 falhou'}}
 inject {if(-not $result.Success -or $result.Level -ne 'InjectedDriver' -or $global:nativeCalls -ne 2 -or $global:driverCalls -ne 1){throw 'Nível 2 falhou'}}
 local {if(-not $result.Success -or $result.Level -ne 'LocalPort' -or $result.PortUNC -ne '\\SERVIDOR\Fila' -or $global:nativeCalls -ne 2 -or $global:driverCalls -ne 1){throw 'Nível 3 falhou'}}
 missing {if($result.Success -or $global:nativeCalls -ne 1 -or $global:driverCalls -ne 1 -or $global:port){throw 'Driver ausente foi aceito/repetido'}}
 credential-hint {if($result.Success -or -not $result.CredentialRetryRecommended -or $result.NativeConnectionCode -ne 1801 -or $result.ConfirmedUNC -ne '\\SERVIDOR\Fila'){throw 'Fila existente recusada com 709 não ofereceu conta alternativa'}}
 missing-share {if($result.CredentialRetryRecommended -or $result.NeedsAuthentication){throw 'Compartilhamento ausente pediu senha'}}
 driver-denied {if($result.Success -or $result.Code -ne 5 -or -not $result.NeedsAuthentication -or $result.Stage -ne 'Ler manifesto remoto' -or $result.Resource -ne '\\SERVIDOR\print$' -or $global:nativeCalls -ne 1 -or $global:port){throw '709 ocultou recusa de acesso do driver'}}
 access {if($result.Success -or -not $result.NeedsAuthentication -or $result.Code -ne 5 -or $global:nativeCalls -ne 1 -or $global:driverCalls){throw 'Acesso negado iniciou instalação ou perdeu a indicação de conta'}}
 port-denied {if($result.Success -or -not $result.NeedsAuthentication -or $result.Stage -ne 'Criar porta local UNC' -or $global:jobCalls){throw 'Porta negada foi aceita ou perdeu a indicação de conta'}}
 job-error {if($result.Success -or -not $result.QueueInstalled -or $global:nativeCalls -ne 1 -or $global:driverCalls -or $global:jobCalls -ne 1){throw 'Job em erro foi aceito/reenviado'}}
 unrelated-job {if(-not $result.Success -or $result.QueueClean -or -not $result.JobValidated){throw 'Outro job alterou a validação do job de teste'}}
}
if($result.Success -and (-not $result.QueueInstalled -or ($mode -eq 'TestPage' -and -not $result.JobValidated) -or $result.PhysicalPrintConfirmed)){throw 'Validação falsa'}
if($mode -eq 'QueueOnly' -and $global:jobCalls){throw 'Conectar enviou teste automático'}
'@,$utf8)
    foreach($case in @('native','inject','local','missing','credential-hint','missing-share','access','driver-denied','port-denied','job-error','unrelated-job')){
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $temp 'wrapper.ps1') -Scenario $case
        if($LASTEXITCODE){throw "Cascata falhou em $case"}
    }
}finally{
    if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}
}
'OK: 11 cenários; conexão sem políticas/teste automático, conta alternativa para fila confirmada e job opcional.'
