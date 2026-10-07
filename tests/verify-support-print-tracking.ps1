param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'src\scripts\IMPRESSAO-COMUM.ps1')
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$script:case='';$script:polls=0;$script:submits=0;$script:remoteCalls=0
function Submit-PrinterValidationPage {param($QueueName,$DocumentName);$script:submits++;$script:document=$DocumentName;return 42}
function Get-PrintJob {param($PrinterName,$ErrorAction);$script:polls++
 switch($script:case){
  observed {if($script:polls -eq 1){return [pscustomobject]@{ID=42;JobStatus='Printing'}}}
  pending {return [pscustomobject]@{ID=42;JobStatus='Spooling'}}
  error {return [pscustomobject]@{ID=42;JobStatus='Error'}}
  deleted {return [pscustomobject]@{ID=42;JobStatus='Deleted'}}
  unrelated {return [pscustomobject]@{ID=17;JobStatus='Error'}}
  denied {throw (New-Object ComponentModel.Win32Exception(5))}
 }
 return @()
}
function Get-PrinterRemoteJobObservation {param($UNCPath,$DocumentName);$script:remoteCalls++
 Assert ($DocumentName -eq $script:document) 'Consulta remota perdeu o documento único'
 if($script:case -eq 'server-denied'){return @{Status='Unavailable';Code=5;Observed=$false}}
 if($script:case -in @('server-printing','server-error')){return @{Status='Queried';Observed=$true;Jobs=@(@{JobId=99;Status=$(if($script:case -eq 'server-error'){2}else{16});DocumentName=$DocumentName})}}
 return @{Status='Queried';Observed=$false;Jobs=@()}
}
function Start-Sleep {param($Milliseconds)}
foreach($case in @('unobserved','observed','pending','error','deleted','unrelated','denied','server-denied','server-printing','server-error')){
 $script:case=$case;$script:polls=0;$before=$script:submits
 $r=Test-PrinterJobDelivery -QueueName '\\HOST\Fila' -UNCPath '\\HOST\Fila' -Seconds 0
 if($case -eq 'observed'){$script:polls=0;$r=Test-PrinterJobDelivery -QueueName '\\HOST\Fila' -Seconds 1;$before++}
 Assert ($script:submits -eq $before+1) "Documento reenviado em $case"
 Assert ($r.JobId -eq 42 -and $r.JobAccepted -and -not $r.PhysicalPrintConfirmed) 'Retorno perdeu aceitação ou inventou impressão física'
 switch($case){
  unobserved {Assert ($r.JobState -eq 'AcceptedNotObserved' -and -not $r.JobValidated) 'Ausência foi aceita como entrega comprovada'}
  observed {Assert ($r.JobState -eq 'LeftClientQueue' -and $r.JobObserved) 'Documento observado não acompanhado'}
  pending {Assert ($r.Pending -and -not $r.Success) 'Documento pendente virou sucesso'}
  error {Assert (-not $r.Success -and $r.JobState -eq 'Error') 'Erro de job ocultado'}
  deleted {Assert (-not $r.Success) 'Exclusão virou entrega'}
  unrelated {Assert (-not $r.QueueClean -and -not $r.JobValidated -and $r.Success) 'Outro documento alterou a aceitação do teste'}
  denied {Assert ($r.JobState -eq 'ObservationUnavailable' -and $r.JobAccepted) 'Consulta negada perdeu a aceitação registrada'}
  server-denied {Assert ($r.ServerObservation -eq 'Unavailable' -and $r.ServerObservationCode -eq 5 -and -not $r.ServerJobObserved) 'Consulta remota negada virou ausência ou recebimento'}
  server-printing {Assert ($r.Success -and $r.ServerJobObserved -and $r.ServerJobs[0].JobId -eq 99) 'ID remoto confundido com local ou Printing virou erro'}
  server-error {Assert (-not $r.Success -and $r.JobState -eq 'ServerError') 'Erro do servidor ignorado'}
 }
}
$temp=Join-Path $env:TEMP ('SupportJobTest_'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
try{
 $script:case='pending';$script:polls=0;$checkpoint=Join-Path $temp 'accepted.xml'
 $r=Test-PrinterJobDelivery -QueueName 'Local' -Seconds 0 -CheckpointPath $checkpoint
 $saved=Import-Clixml -LiteralPath $checkpoint
 Assert ($saved.JobAccepted -and $saved.JobId -eq 42 -and $saved.DocumentName) 'Checkpoint não preserva o envio antes do acompanhamento'
 # Execute the real RAW implementation with only its operating-system calls replaced.
 $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'src\scripts\IMPRESSAO-COMUM.ps1'),[ref]$t,[ref]$e)
 $literal=$ast.FindAll({param($n)$n -is [Management.Automation.Language.StringConstantExpressionAst] -and $n.Value.Contains('public static class PrinterJobNative')},$true)|Select-Object -First 1
 $code=$literal.Value.Replace('PrinterJobNative','PrinterJobNativeFixture')
 $code=$code.Replace('public static class PrinterJobNativeFixture {','public static class PrinterJobNativeFixture { public static bool Partial;public static int Writes,Aborts;')
 $replacements=@{
  Open=' static bool Open(string name,out IntPtr handle,IntPtr defaults){handle=new IntPtr(1);return true;}'
  Close=' static bool Close(IntPtr handle){return true;}'
  Start=' static uint Start(IntPtr handle,uint level,ref DOC doc){return 73;}'
  StartPagePrinter=' static bool StartPagePrinter(IntPtr handle){return true;}'
  EndPagePrinter=' static bool EndPagePrinter(IntPtr handle){return true;}'
  EndDocPrinter=' static bool EndDocPrinter(IntPtr handle){return true;}'
  AbortPrinter=' static bool AbortPrinter(IntPtr handle){Aborts++;return true;}'
  WritePrinter=' static bool WritePrinter(IntPtr handle,byte[] data,uint count,out uint written){Writes++;written=Partial?count-1:count;return true;}'
 }
 foreach($name in $replacements.Keys){$pattern='(?m)^ \[DllImport[^\r\n]+\] static extern (bool|uint) '+$name+'\([^\r\n]+;';Assert ([regex]::IsMatch($code,$pattern)) ('API não localizada: '+$name);$code=[regex]::Replace($code,$pattern,$replacements[$name])}
 Add-Type -TypeDefinition $code -ErrorAction Stop
 $id=[PrinterJobNativeFixture]::SendRaw('Fixture','Documento único',[byte[]]@(27,64,65,10))
 Assert ($id -eq 73 -and [PrinterJobNativeFixture]::Writes -eq 1 -and -not [PrinterJobNativeFixture]::Aborts) 'RAW não retornou JobId com um envio'
 [PrinterJobNativeFixture]::Partial=$true
 try{[void][PrinterJobNativeFixture]::SendRaw('Fixture','Parcial',[byte[]]@(1,2));throw 'Envio parcial aceito'}catch{Assert ($_.Exception.GetBaseException().NativeErrorCode -eq 29) 'RAW parcial não preservou falha'}
 Assert ([PrinterJobNativeFixture]::Aborts -eq 1) 'Documento RAW incompleto não abortado'
}finally{if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}}
'OK: dez estados, checkpoint, IDs separados, envio único e implementação RAW com APIs substituídas; nenhuma impressão real.'
