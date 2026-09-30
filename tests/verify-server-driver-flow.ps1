$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
if($e.Count){throw $e[0].Message}
$fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Connect-UNCPrinterSafe'},$true)|Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
function Write-AppLog {param($Message,$Level)}
function Test-TcpPortSafe {param($HostOrIp,$Port,$TimeoutMs) return $true}
function Test-PrinterConnectionInstalled {param($UNCPath) return $false}
function Get-InstalledPrintersWmi {return @()}
function Wait-PrinterConnectionInstalled {param($UNCPath,$Attempts) return $script:registered}
function Invoke-BoundedPrinterAttempt {
 param($UNCPath,$Method,$TimeoutSeconds,$NetworkCredential,$CredentialServer)
 if($NetworkCredential -ne $script:authenticatedPrinterCredential){throw 'Credencial não foi preservada.'}
 [void]$script:calls.Add($Method)
 if($Method -eq 'InstallDriver'){
  switch($script:scenario){
   missing {return @{Success=$false;Message='Pacote não preparado.'}}
   cancel {return @{Success=$false;Cancelled=$true;Message='Cancelado.'}}
   timeout {return @{Success=$false;TimedOut=$true;Message='Prazo esgotado.'}}
   default {return @{Success=$true;DriverName='Modelo de teste';Message='Instalado.'}}
  }
 }
 if($script:calls.Count -eq 3 -and $script:scenario -eq 'success'){$script:registered=$true;return @{Success=$true;Message='Conectado.'}}
 return @{Success=$false;Message='O driver necessário não pode ser recuperado.'}
}
$global:SimulationMode=$false
$script:cancelPrinterConnection=$false
$script:authenticatedPrinterServer='192.0.2.5'
$script:authenticatedPrinterCredential=New-Object Management.Automation.PSCredential('SERVIDOR\teste',(ConvertTo-SecureString 'Fixture-only' -AsPlainText -Force))
foreach($script:scenario in @('success','missing','retry-failure','cancel','timeout')){
 $script:calls=New-Object Collections.ArrayList
 $script:registered=$false
 $result=Connect-UNCPrinterSafe -UNCPath '\\192.0.2.5\FilaRenomeada'
 switch($script:scenario){
  success {if(-not $result.Success -or ($script:calls -join ',') -ne 'AddPrinter,InstallDriver,AddPrinter'){throw 'Transferência não levou a conexão verificada.'}}
  missing {if($result.Success -or $result.Code -ne 1797 -or $script:calls.Count -ne 2){throw 'Pacote ausente foi repetido ou aceito.'}}
  retry-failure {if($result.Success -or $result.DriverName -ne 'Modelo de teste' -or $script:calls.Count -ne 3){throw 'Driver instalado não chegou à alternativa local ou repetiu indefinidamente.'}}
  cancel {if($result.Code -ne 1223 -or $script:calls.Count -ne 2){throw 'Cancelamento não interrompeu o fluxo.'}}
  timeout {if($result.Code -ne 1460 -or $script:calls.Count -ne 2){throw 'Tempo esgotado não interrompeu o fluxo.'}}
 }
}
'OK: transferência preserva autenticação, confirma a fila e encerra por erro, cancelamento ou prazo.'
