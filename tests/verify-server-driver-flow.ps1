$ErrorActionPreference='Stop'
$path=Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile($path,[ref]$t,[ref]$e)
if($e.Count){throw $e[0].Message}
$fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Connect-UNCPrinterSafe'},$true)|Select-Object -First 1
. ([scriptblock]::Create($fn.Extent.Text))
function Write-AppLog {param([Parameter(Mandatory=$true)][string]$Message,$Level)}
function Test-TcpPortSafe {param($HostOrIp,$Port,$TimeoutMs) return $true}
function Get-InstalledPrintersWmi {return @()}
function Test-PrinterShareInstalled {param($UNCPath,$InstalledPrinters) return $script:registered}
function Invoke-BoundedPrinterAttempt {
 param($UNCPath,$Method,$TimeoutSeconds,$NetworkCredential,$CredentialServer)
 if($NetworkCredential -ne $script:authenticatedPrinterCredential -or $CredentialServer -ne '192.0.2.5'){throw 'Credencial não preservada.'}
 if($Method -ne 'Cascade'){throw 'Múltiplas cascatas externas não permitidas.'}
 $script:calls++
 switch($script:scenario){
  success {return @{Success=$true;QueueInstalled=$true;ConnectedUNC=$UNCPath;Message='Fixture'}}
  missing {return @{Success=$false;DriverName='Modelo';Code=1797;Message='Pacote ausente';Cascaded=$true}}
  cancel {return @{Success=$false;Cancelled=$true;Message='Cancelado'}}
  timeout {return @{Success=$false;TimedOut=$true;Message='Prazo'}}
 }
}
$global:SimulationMode=$false
$script:authenticatedPrinterServer='192.0.2.5'
$script:authenticatedPrinterCredential=New-Object Management.Automation.PSCredential('SERVIDOR\teste',(ConvertTo-SecureString 'Fixture-only' -AsPlainText -Force))
foreach($script:scenario in @('success','missing','cancel','timeout')){
 $script:calls=0;$script:registered=($script:scenario -eq 'success')
 $result=Connect-UNCPrinterSafe -UNCPath '\\192.0.2.5\FilaRenomeada'
 if($script:calls -ne 1){throw 'Cascata repetida externamente.'}
 switch($script:scenario){
  success {if(-not $result.Success){throw 'Fila não confirmada'}}
  missing {if($result.Success -or $result.Code -ne 1797 -or $result.DriverName -ne 'Modelo'){throw 'Falha/driver perdida'}}
  cancel {if($result.Success -or $result.Code -ne 1223){throw 'Cancelamento perdido'}}
  timeout {if($result.Success -or $result.Code -ne 1460){throw 'Timeout perdido'}}
 }
}
'OK: uma cascata com credenciais preservadas e erros/prazos sem repetição externa.'
