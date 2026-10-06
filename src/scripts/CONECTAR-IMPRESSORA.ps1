param(
 [string]$UNCPath='', [string]$ResultPath='',
 [ValidateSet('Cascade','AddPrinter','WScript','PublishDriver','InstallDriver','PrepareHost','PrepareClient','Authenticate','RestoreClientPolicies','RestoreHostPolicies')][string]$Method='Cascade',
 [string]$Server='', [string]$ShareName='', [string]$DriverName='',
 [ValidateSet('TestPage','QueueOnly')][string]$ValidationMode='QueueOnly',
 [switch]$SkipPolicyPreparation, [string]$StateDirectory='', [string]$AccessResource='', [switch]$HasNetworkCredential
)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'IMPRESSAO-COMUM.ps1')
$result=@{Success=$false;QueueInstalled=$false;Message='A conexão não foi concluída.'}
$injected=$null
$history=New-Object Collections.ArrayList
$currentStage='Validar endereço'; $lastNativeError=0; $authenticationRequired=$false
function Write-ConnectionStage {
 param([string]$Text)
 [void]$history.Add($Text)
 if($ResultPath){[IO.File]::WriteAllText($ResultPath+'.progress',$Text,[Text.Encoding]::UTF8)}
}
function Try-NativePrinterConnection {
 param([string]$Path)
 try{
  Add-Printer -ConnectionName $Path -ErrorAction Stop
  $printer=Wait-ExactPrinter -UNCPath $Path -Seconds 10
  if(-not $printer){throw 'A chamada terminou, mas a fila não foi confirmada em 10 segundos.'}
  return @{Success=$true;Printer=$printer}
 }catch{
  return (Get-PrinterOperationFailure -Record $_ -Stage 'Conectar fila remota' -Resource $Path -Scope Remote)
 }
}
function Complete-PrinterConnection {
 param($Printer,[string]$Level,[bool]$LocalPort)
 $completed=@{Success=$true;QueueInstalled=$true;QueueName=[string]$Printer.Name;ConnectedUNC=[string]$Printer.Name;
 DriverName=[string]$Printer.DriverName;Level=$Level;LocalPort=$LocalPort;PortUNC=$UNCPath;
 JobValidated=$false;JobValidationAttempted=$false;PhysicalPrintConfirmed=$false;Message='Fila registrada e confirmada no Windows.'}
 if($ValidationMode -eq 'TestPage'){
  $completed.JobValidationAttempted=$true
  Write-ConnectionStage 'Validar job de teste identificado pelo JobId'
  try{
   $delivery=Test-PrinterJobDelivery -QueueName $Printer.Name -Seconds 10
   foreach($key in $delivery.Keys){$completed[$key]=$delivery[$key]}
  }catch{$completed.Success=$false;$completed.Message='Fila instalada, mas a validação do job falhou: '+$_.Exception.Message}
  if(-not $completed.Success){$completed.Code=if($completed.Pending){1460}else{31}}
 }
 return $completed
}
try{
 if($Method -in @('RestoreClientPolicies','RestoreHostPolicies')){
  $result=Restore-PrinterCompatibilityPolicies -Role $(if($Method -eq 'RestoreClientPolicies'){'Client'}else{'Host'}) -StateDirectory $StateDirectory
 }elseif($Method -eq 'PrepareClient'){
  $result=& (Join-Path $PSScriptRoot 'DRIVER-DO-SERVIDOR.ps1') -Action PrepareClient -StateDirectory $StateDirectory
 }else{
  $address=Resolve-PrinterUNC -UNCPath $UNCPath -Server $Server -ShareName $ShareName
  $Server=$address.Server;$ShareName=$address.ShareName;$UNCPath=$address.UNCPath
  if($Method -eq 'Authenticate'){
   $result=Test-PrinterNetworkSession -Server $Server
   if($result.Success -and $AccessResource){
    $driverRoot='\\'+$Server+'\print$'
    if($AccessResource -ine $driverRoot -and -not $AccessResource.StartsWith($driverRoot+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Recurso de autenticação não corresponde ao print$ do servidor.'}
    $result=Test-PrinterDriverResourceAccess -Resource $AccessResource
   }
  }elseif($Method -in @('PublishDriver','InstallDriver','PrepareHost')){
   $result=& (Join-Path $PSScriptRoot 'DRIVER-DO-SERVIDOR.ps1') -UNCPath $UNCPath -Action $Method -DriverName $DriverName -StateDirectory $StateDirectory -ProgressPath $(if($ResultPath){$ResultPath+'.progress'}else{''})
  }elseif($Method -in @('AddPrinter','WScript')){
   if($Method -eq 'WScript'){
    $network=New-Object -ComObject WScript.Network -ErrorAction Stop
    $network.AddWindowsPrinterConnection($UNCPath)
    $printer=Wait-ExactPrinter -UNCPath $UNCPath -Seconds 10
    if(-not $printer){throw 'WScript terminou sem registrar a fila.'}
    $result=@{Success=$true;QueueInstalled=$true;QueueName=$printer.Name;ConnectedUNC=$printer.Name;Message='Fila nativa confirmada.'}
   }else{
    $attempt=Try-NativePrinterConnection -Path $UNCPath
    if($attempt.Success){$result=@{Success=$true;QueueInstalled=$true;QueueName=$attempt.Printer.Name;ConnectedUNC=$attempt.Printer.Name;Message='Fila nativa confirmada.'}}
    else{$result=$attempt}
   }
  }else{
   # Connecting must not restart a Spooler that may also serve other PCs.
   # Compatibility changes remain explicit in PrepareClient/PrepareHost.
   $currentStage='Nível 1: conexão nativa';Write-ConnectionStage $currentStage
   $native=Try-NativePrinterConnection -Path $UNCPath
   if($native.Success){$result=Complete-PrinterConnection -Printer $native.Printer -Level Native -LocalPort $false}
   else{
    $lastNativeError=$native.Code;Write-ConnectionStage ("Nível 1 recusado ($($native.Code)): $($native.Message)")
    $authenticationRequired=[bool]$native.NeedsAuthentication
    if($native.NeedsAuthentication -or $native.Code -in @(53,64,67,1219)){$result=$native;throw "Acesso/rede recusado antes de instalar o driver: $($native.Message)"}
    $currentStage='Nível 2: receber e injetar driver';Write-ConnectionStage $currentStage
    $injected=& (Join-Path $PSScriptRoot 'DRIVER-DO-SERVIDOR.ps1') -Server $Server -ShareName $ShareName -DriverName $DriverName -Action InstallDriver -ProgressPath $(if($ResultPath){$ResultPath+'.progress'}else{''})
    if(-not $injected.Success){$result=$injected;if(-not $result.Stage){$result.Stage=$currentStage};throw "Transferência de driver falhou: $($injected.Message)"}
    $DriverName=[string]$injected.DriverName
    if(-not $DriverName -or -not(Get-PrinterDriver -Name $DriverName -ErrorAction Stop)){throw 'Driver recebido não foi confirmado por nome no cliente.'}
    Write-ConnectionStage $injected.Message
    if($injected.RebootRequired){Write-ConnectionStage 'PnPUtil indicou reinicialização necessária; o PC não foi reiniciado automaticamente.'}
    $currentStage='Nível 2: repetir conexão nativa uma vez';Write-ConnectionStage $currentStage
    $retry=Try-NativePrinterConnection -Path $UNCPath
    if($retry.Success){$result=Complete-PrinterConnection -Printer $retry.Printer -Level InjectedDriver -LocalPort $false}
    else{
     $lastNativeError=$retry.Code;Write-ConnectionStage ("Nível 2 recusado ($($retry.Code)): $($retry.Message)")
     $authenticationRequired=[bool]$retry.NeedsAuthentication
     if($authenticationRequired){$result=$retry;throw "Acesso recusado após instalar o driver: $($retry.Message)"}
     $currentStage='Nível 3: criar fila local em porta UNC';Write-ConnectionStage $currentStage
     $queueName=$ShareName+' em '+$Server
     $local=& (Join-Path $PSScriptRoot 'INSTALAR-PORTA-LOCAL.ps1') -Server $Server -ShareName $ShareName -DriverName $DriverName -QueueName $queueName
     if(-not $local.Success){
      $result=$local;$result.DriverName=$DriverName
      Write-ConnectionStage ('Nível 3 recusado: '+$local.Stage+'; '+$local.Message)
     }else{
      $printer=Wait-ExactPrinter -UNCPath $UNCPath -QueueName $queueName -DriverName $DriverName -Seconds 10
      if(-not $printer){throw 'Porta local terminou sem fila correspondente ao driver/UNC.'}
      $result=Complete-PrinterConnection -Printer $printer -Level LocalPort -LocalPort $true
     }
    }
   }
  }
 }
}catch{
 if(-not $result.Stage){
  $result=Get-PrinterOperationFailure -Record $_ -Stage $currentStage -Resource $UNCPath -Scope Local
 }
 $result.QueueInstalled=$false
 $result.DriverName=$DriverName
}
if($injected -and $injected.RebootRequired){$result.RebootRequired=$true}
if($Method -eq 'Cascade' -and -not $result.Success -and -not $result.QueueInstalled -and
   -not $HasNetworkCredential -and -not $result.NeedsAuthentication -and $lastNativeError -in @(1801,283,3019) -and
   -not($result.FailureScope -eq 'Local' -and $result.Code -eq 5)){
 try{
  $shareCode=Test-PrinterSharedQueueExists -Server $Server -ShareName $ShareName
  $result.ShareLookupCode=$shareCode
  if($shareCode -eq 0){$result.CredentialRetryRecommended=$true;$result.NativeConnectionCode=$lastNativeError;$result.ConfirmedUNC=$UNCPath}
  elseif($shareCode -in @(5,86,1244,1326,1385,1909)){
   $result.PreviousFailureCode=$result.Code;$result.NeedsAuthentication=$true;$result.Resource=$UNCPath;$result.FailureScope='Remote'
   $result.Code=$shareCode;$result.NativeCode=$shareCode;$result.Stage='Confirmar fila compartilhada'
   $result.Message='O servidor recusou a consulta ao compartilhamento. Erro anterior da instalação: '+$result.Message
  }
 }catch{Write-ConnectionStage ('Não foi possível confirmar o compartilhamento para oferecer outra conta: '+$_.Exception.Message)}
}
$result.History=@($history.ToArray());$result.Cascaded=($Method -eq 'Cascade')
if(-not $ResultPath){return $result}
try{$result | Export-Clixml -LiteralPath $ResultPath -Force -ErrorAction Stop}catch{exit 2}
if($result.Success){exit 0}else{exit 1}
