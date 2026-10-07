param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
$t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $SourceRoot 'src\AssistenteImpressoras.ps1'),[ref]$t,[ref]$e)
foreach($name in @('Stop-PrinterWorkerTree','Invoke-BoundedPrinterAttempt')){
 $fn=$ast.FindAll({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name},$true)|Select-Object -First 1
 if(-not $fn){throw ('Função ausente: '+$name)};. ([scriptblock]::Create($fn.Extent.Text))
}
$temp=Join-Path $env:TEMP ('SupportInterruption_'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
$PrinterConnectionPath=Join-Path $temp 'worker de teste.ps1';$request=Join-Path $temp 'request.xml';$ready=Join-Path $temp 'ready.txt';$script:cancelPrinterConnection=$false
try{
 @{Ready=$ready}|Export-Clixml -LiteralPath $request
 [IO.File]::WriteAllText($PrinterConnectionPath,@'
param([string]$UNCPath,[string]$Method,[string]$ResultPath,[string]$RequestPath)
$r=Import-Clixml -LiteralPath $RequestPath
@{Success=$true;QueueInstalled=$true;QueueName='Fila';JobAccepted=$true;JobId=42;DocumentName='Único';PhysicalPrintConfirmed=$false;Message='Aceito'}|Export-Clixml -LiteralPath $ResultPath
[IO.File]::WriteAllText($r.Ready,[string]$PID)
Start-Sleep -Seconds 15
'@,[Text.UTF8Encoding]::new($true))
 $r=Invoke-BoundedPrinterAttempt -UNCPath '' -Method Operation -LocalPortRequestPath $request -TimeoutSeconds 2
 if(-not $r.TimedOut -or -not $r.JobAccepted -or $r.JobId -ne 42 -or $r.Success -or -not $r.QueueInstalled){throw 'Prazo perdeu o job aceito ou virou sucesso'}
 $workerId=[int][IO.File]::ReadAllText($ready)
 if(Get-Process -Id $workerId -ErrorAction SilentlyContinue){throw 'Worker continuou ativo depois do prazo'}
 Remove-Item -LiteralPath $ready
 $timer=New-Object Windows.Forms.Timer;$timer.Interval=100
 $timer.Add_Tick({if(Test-Path -LiteralPath $ready){$script:cancelPrinterConnection=$true;$timer.Stop()}})
 try{$timer.Start();$r=Invoke-BoundedPrinterAttempt -UNCPath '' -Method Operation -LocalPortRequestPath $request -TimeoutSeconds 8}finally{$timer.Stop();$timer.Dispose();$script:cancelPrinterConnection=$false}
 if(-not $r.Cancelled -or -not $r.JobAccepted -or $r.JobId -ne 42 -or $r.Success){throw 'Cancelamento perdeu o job aceito'}
 $workerId=[int][IO.File]::ReadAllText($ready)
 if(Get-Process -Id $workerId -ErrorAction SilentlyContinue){throw 'Worker continuou ativo depois do cancelamento'}
}finally{if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}}
'OK: prazo/cancelamento preservam checkpoint e encerram o processo; sem reenvio ou impressão real.'
