$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$t=$null;$e=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\AssistenteImpressoras.ps1'),[ref]$t,[ref]$e)
if($e.Count){throw $e[0].Message}
foreach($name in @('Connect-PrinterUsingAvailableSession','Invoke-PrinterOperationUsingAvailableSession','Use-PrinterCredentialForEndpoint')){
 $fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)|Select-Object -First 1
 . ([scriptblock]::Create($fn.Extent.Text))
}
function Write-AppLog {param($Message,$Level) if($Message.Contains('Fixture-password')){throw 'Senha no log'}}
function Connect-UNCPrinterSafe {
 param($UNCPath,$AlternateHost)
 if($UNCPath -ne '\\SERVIDOR\Fila' -or $AlternateHost -ne '192.0.2.10'){throw 'Endereço alterado'}
 $script:calls++
 if($script:calls -eq 2){
  if(-not $script:authenticatedPrinterCredential){throw 'Nova tentativa sem credencial'}
  return $script:second
 }
 return $script:first
}
function Invoke-BoundedPrinterAttempt {
 param($UNCPath,$Method,$TimeoutSeconds,$NetworkCredential,$CredentialServer)
 $script:authCalls++
 if($Method -ne 'Authenticate' -or $CredentialServer -ne 'SERVIDOR' -or
    $NetworkCredential.UserName -ne 'SERVIDOR\conta' -or $NetworkCredential.GetNetworkCredential().Password -ne 'Fixture-password'){throw 'Credencial alterada'}
 if($script:authDenied){return @{Success=$false;Code=1326;Message='Recusada'}}
 return @{Success=$true}
}
$cases=@('session-success','709','driver','port87','offline','conflict','cancel-worker','timeout','job-error','access','logon','existing','decline','cancel-dialog','auth-denied','retry-denied','second-server','local-denied','driver-denied','local-logon-code')
foreach($case in $cases){
 $script:calls=0;$script:prompts=0;$script:authCalls=0;$script:authDenied=$false
 $script:authenticatedPrinterServer='';$script:authenticatedPrinterCredential=$null
 $script:first=@{Success=$false;Code=5;NeedsAuthentication=$true}
 $script:second=@{Success=$true;QueueInstalled=$true}
 $script:choice=@{User='SERVIDOR\conta';Password='Fixture-password'}
 switch($case){
  session-success {$script:first=@{Success=$true;QueueInstalled=$true}}
  709 {$script:first=@{Success=$false;Code=1801}}
  driver {$script:first=@{Success=$false;Code=1797}}
  port87 {$script:first=@{Success=$false;Code=87}}
  offline {$script:first=@{Success=$false;Code=53}}
  conflict {$script:first=@{Success=$false;Code=1219}}
  cancel-worker {$script:first=@{Success=$false;Code=1223}}
  timeout {$script:first=@{Success=$false;Code=1460}}
  job-error {$script:first=@{Success=$false;Code=5;NeedsAuthentication=$true;QueueInstalled=$true}}
  logon {$script:first=@{Success=$false;Code=1326}}
  local-denied {$script:first=@{Success=$false;Code=5;FailureScope='Local';NeedsAuthentication=$false}}
  local-logon-code {$script:first=@{Success=$false;Code=1326;FailureScope='Local';NeedsAuthentication=$false}}
  driver-denied {$script:first=@{Success=$false;Code=5;Stage='Ler manifesto remoto';Resource='\\SERVIDOR\print$';FailureScope='Remote';NeedsAuthentication=$true}}
  existing {
   $script:authenticatedPrinterServer='SERVIDOR'
   $script:authenticatedPrinterCredential=New-Object Management.Automation.PSCredential('SERVIDOR\conta',(ConvertTo-SecureString 'Fixture-only' -AsPlainText -Force))
  }
  decline {$script:choice=@{WithoutCredential=$true}}
  cancel-dialog {$script:choice=@{Cancelled=$true}}
  auth-denied {$script:authDenied=$true}
  retry-denied {$script:second=@{Success=$false;Code=1326;NeedsAuthentication=$true}}
  second-server {
   $script:authenticatedPrinterServer='OUTRO'
   $script:authenticatedPrinterCredential=New-Object Management.Automation.PSCredential('OUTRO\conta',(ConvertTo-SecureString 'Fixture-only' -AsPlainText -Force))
  }
 }
 $prompt={param($Server)
  if($script:calls -ne 1){throw 'Conta solicitada antes de tentar a sessão atual'}
  $script:prompts++;return $script:choice
 }
 $result=Connect-PrinterUsingAvailableSession -UNCPath '\\SERVIDOR\Fila' -AlternateHost '192.0.2.10' -RequestCredential $prompt
 $expectedPrompt=$case -in @('access','logon','existing','decline','cancel-dialog','auth-denied','retry-denied','second-server','driver-denied')
 $expectedRetry=$case -in @('access','logon','existing','retry-denied','second-server','driver-denied')
 if($script:prompts -ne [int]$expectedPrompt -or $script:calls -ne (1+[int]$expectedRetry)){throw "Prompt/repetição indevida em $case"}
 if($expectedRetry -and $script:authCalls -ne 1){throw 'Autenticação não executada'}
 if($case -in @('access','logon','second-server') -and -not $result.Success){throw 'Nova conta não conectou'}
 if($case -eq 'cancel-dialog' -and $result.Code -ne 1223){throw 'Cancelamento perdido'}
 if($case -in @('auth-denied','retry-denied') -and ($result.Success -or $result.Code -ne 1326)){throw 'Erro de conta perdido'}
 if($expectedPrompt -and $case -notin @('decline','cancel-dialog') -and $script:choice.Password){throw 'Senha em texto mantida no retorno'}
}
'OK: 20 cenários; sessão atual primeiro, substituição de conta recusada, erro remoto/local e uma repetição.'
