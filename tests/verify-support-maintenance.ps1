param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'src\scripts\IMPRESSAO-COMUM.ps1')
. (Join-Path $SourceRoot 'src\scripts\ATENDIMENTO-COMUM.ps1')
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$script:queues=@([pscustomobject]@{Name='Escolhida'},[pscustomobject]@{Name='Outra'})
$script:jobs=@{Escolhida=@();Outra=@()};$script:removed=@();$script:swap=$false
function Get-Printer {param($ErrorAction);return $script:queues}
function Get-PrintJob {param($PrinterName,$ErrorAction)
 if($script:swap -and $PrinterName -eq 'Escolhida'){$script:swap=$false;return [pscustomobject]@{ID=1;DocumentName='Reutilizado';SubmittedTime='Novo'}}
 return $script:jobs[$PrinterName]
}
function Remove-PrintJob {param($PrinterName,$ID,$ErrorAction);$script:removed+=($PrinterName+':'+$ID);$script:jobs[$PrinterName]=@($script:jobs[$PrinterName]|Where-Object ID -ne $ID)}
$script:jobs.Escolhida=@([pscustomobject]@{ID=1;DocumentName='Teste';SubmittedTime='Antes'},[pscustomobject]@{ID=2;DocumentName='Outro';SubmittedTime='Antes'})
$script:jobs.Outra=@([pscustomobject]@{ID=1;DocumentName='Preservado';SubmittedTime='Antes'})
$r=Remove-SupportPrintJobs -QueueName Escolhida -JobIds @(1) -DocumentName Teste
Assert ($r.Success -and $r.Removed -eq 1 -and $script:jobs.Escolhida.Count -eq 1 -and $script:jobs.Outra.Count -eq 1) 'Cancelar um documento atingiu outro'
$r=Remove-SupportPrintJobs -QueueName Escolhida -All
Assert ($r.Success -and $script:jobs.Escolhida.Count -eq 0 -and $script:jobs.Outra.Count -eq 1) 'Limpeza de fila atingiu outra impressora'
$script:jobs.Escolhida=@([pscustomobject]@{ID=1;DocumentName='Teste';SubmittedTime='Antes'});$script:swap=$true;$before=$script:removed.Count
try{Remove-SupportPrintJobs -QueueName Escolhida -JobIds @(1) -DocumentName Teste|Out-Null;throw 'ID reutilizado aceito'}catch{Assert ($_.Exception.Message -match 'outro documento') 'Erro de identidade do documento não preservado'}
Assert ($script:removed.Count -eq $before) 'Cancelou um documento que reutilizou ID'
$script:printers=@()
function Get-WmiObject {param($Class,$ErrorAction);return $script:printers}
function New-FixturePrinter([string]$Name){
 $p=[pscustomobject]@{Name=$Name;Paused=$true;PrinterState=1;WorkOffline=$true;Puts=0;Resumes=0}
 $p|Add-Member ScriptMethod Resume {$this.Paused=$false;$this.PrinterState=0;$this.Resumes++;return @{ReturnValue=0}}
 $p|Add-Member ScriptMethod Put {$this.Puts++;return $null}
 return $p
}
$first=New-FixturePrinter 'Escolhida';$second=New-FixturePrinter 'Outra';$script:printers=@($first,$second)
$r=Reset-SupportPrinterState -QueueName Escolhida -Unpause $true -ClearOffline $false
Assert ($r.Success -and -not $first.Paused -and $first.WorkOffline -and $first.Puts -eq 0 -and $second.Paused) 'Despausar alterou offline ou outra impressora'
$r=Reset-SupportPrinterState -QueueName Outra -Unpause $false -ClearOffline $true
Assert ($r.Success -and $second.Paused -and -not $second.WorkOffline -and $second.Resumes -eq 0) 'Online também despausou'
$script:service=[pscustomobject]@{Status='Running'};$script:startup='Manual';$script:starts=0;$script:stops=0;$script:configs=0
$script:service|Add-Member ScriptMethod WaitForStatus {param($Status,$Timeout);if($this.Status -ne $Status){throw 'Status não confirmado'}}
function Get-Service {param($Name,$ErrorAction);return $script:service}
function Start-Service {param($Name,$ErrorAction);$script:service.Status='Running';$script:starts++}
function Stop-Service {param($Name,[switch]$Force,$ErrorAction);$script:service.Status='Stopped';$script:stops++}
function Set-Service {param($Name,$StartupType,$ErrorAction);$script:startup='Auto';$script:configs++}
function Get-CimInstance {param($ClassName,$Filter,$OperationTimeoutSec,$ErrorAction);return [pscustomobject]@{StartMode=$script:startup}}
$r=Invoke-SupportSpoolerAction Restart
Assert ($r.Success -and $script:starts -eq 1 -and $script:stops -eq 1 -and $script:configs -eq 0 -and $script:startup -eq 'Manual') 'Reinício alterou inicialização ou não confirmou serviço'
$r=Invoke-SupportSpoolerAction AutoStart
Assert ($r.Success -and $script:configs -eq 1 -and $script:starts -eq 1) 'Mudar inicialização reiniciou serviço'
$temp=Join-Path $env:TEMP ('SupportPurgeTest_'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
try{
 $script:spoolDirectory=$temp
 function Get-ItemProperty {param($Path,$Name,$ErrorAction);return @{DefaultSpoolDirectory=$script:spoolDirectory}}
 [IO.File]::WriteAllText((Join-Path $temp 'fixture.SPL'),'fixture');[IO.File]::WriteAllText((Join-Path $temp 'fixture.SHD'),'fixture');[IO.File]::WriteAllText((Join-Path $temp 'preservado.txt'),'fixture')
 $r=Invoke-SupportSpoolerAction Purge
 Assert ($r.Success -and $r.FilesRemoved -eq 2 -and (Test-Path -LiteralPath (Join-Path $temp 'preservado.txt')) -and $script:service.Status -eq 'Running') 'Purga passou dos tipos autorizados ou deixou serviço parado'
 $script:spoolDirectory=[IO.Path]::GetPathRoot($temp)
 try{Invoke-SupportSpoolerAction Purge|Out-Null;throw 'Raiz aceita como spool'}catch{Assert ($_.Exception.Message -match 'Pasta de spool inválida') 'Pasta perigosa não recusada'}
 Assert ($script:service.Status -eq 'Running') 'Falha na purga deixou serviço parado'
 function Invoke-SupportSpoolerAction {param($Action);if($Action -eq 'AutoStart'){throw 'Fixture: negado'};return @{Success=$true;Action=$Action;Message='Confirmado'}}
 $r=Invoke-SupportWorkerOperation @{Action='Maintenance';Actions=@('Restart','AutoStart')}
 Assert (-not $r.Success -and $r.Actions.Count -eq 2 -and $r.Actions[0].Success -and -not $r.Actions[1].Success) 'Falha parcial virou sucesso geral'
}finally{if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}}
'OK: cancelamento individual, isolamento de filas, ID reutilizado, estados independentes, serviço verificado e falha parcial; sem alterações em impressoras/serviços reais.'
