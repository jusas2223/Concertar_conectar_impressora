param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'src\scripts\ATENDIMENTO-COMUM.ps1')
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$hostReport=@{Kind='AssistenteImpressoras.Diagnostico';Schema=1;Computer='HOST';CapturedAt=(Get-Date).AddHours(-72).ToString('o');OSBuild='26100';IPv4=@('192.0.2.10');PrintersQuerySucceeded=$true;DriversQuerySucceeded=$true;Printers=@(@{Name='Fila';ShareName='Compartilhada';Shared=$true;DriverName='Modelo'});Drivers=@(@{Name='Modelo';PrinterEnvironment='Windows x64'});Policies=@();Issues=@()}
$clientReport=@{Computer='CLIENTE';OSBuild='19045';CapturedAt=(Get-Date).ToString('o');PrintersQuerySucceeded=$true;DriversQuerySucceeded=$true;Printers=@(@{Name='Local (Rede)';PortName='\\192.0.2.10\Compartilhada'});Drivers=@(@{Name='Modelo';PrinterEnvironment='Windows NT x86'});Policies=@();Issues=@()}
$r=Compare-SupportDiagnosticSnapshots $hostReport $clientReport
Assert ($r.Message -match 'fila correspondente=True' -and $r.Message -match 'Arquiteturas' -and $r.Message -match '48 horas') 'Comparativo perdeu UNC por IP, arquitetura ou validade temporal'
$clientReport.PrintersQuerySucceeded=$false;$clientReport.DriversQuerySucceeded=$false
$r=Compare-SupportDiagnosticSnapshots $hostReport $clientReport
Assert ($r.Message -match 'consulta indisponível' -and $r.Message -notmatch 'no cliente=False') 'Consulta negada virou driver ausente'
$credential=New-Object Management.Automation.PSCredential('HOST\teste',(ConvertTo-SecureString 'segredo-da-fixture' -AsPlainText -Force))
$safe=ConvertTo-SupportSafeData @{Password='secreto';Credential=$credential;Nested=@{RawBase64='comando';Message='senha=secreto';JobId=42};Server='HOST'}
$json=$safe|ConvertTo-Json -Depth 8
Assert ($json -notmatch 'secreto|segredo-da-fixture|RawBase64|Password|Credential' -and $json -match '42') 'Redação perdeu dados úteis ou expôs segredo'
$safe=ConvertTo-SupportSafeData @{Status=[DayOfWeek]::Monday;SubmittedTime=(Get-Date)}
$roundtrip=($safe|ConvertTo-Json -Depth 8)|ConvertFrom-Json
Assert ($roundtrip.Status -eq 'Monday' -and $roundtrip.SubmittedTime -match '^\d{4}-') 'Enum/data não normalizados para JSON portátil'
$temp=Join-Path $env:TEMP ('SupportBundleTest_'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($temp)
try{
 $log=Join-Path $temp 'Atendimento.log';$records=Join-Path $temp 'Dados';[void][IO.Directory]::CreateDirectory($records)
 [IO.File]::WriteAllText($log,"antes`r`n",[Text.UTF8Encoding]::new($true))
 [IO.File]::AppendAllText($log,"linha adicionada agora`r`nsenha=secreto",[Text.UTF8Encoding]::new($true))
 [IO.File]::WriteAllText((Join-Path $records '001.json'),'{"Password":"secreto","JobId":42,"RawBase64":"comando"}')
 function Get-SupportDiagnosticSnapshot {param($Server,$ShareName);return @{Kind='AssistenteImpressoras.Diagnostico';Schema=1;Computer='FIXTURE';Printers=@();Issues=@()}}
 $zip=Join-Path $temp 'Atendimento.zip';$r=Export-SupportBundle -OutputPath $zip -LogPath $log -RecordsDirectory $records -Since (Get-Date).AddYears(1).ToString('o')
 Assert ($r.Success -and (Test-Path -LiteralPath $zip)) 'ZIP não foi criado'
 $extracted=Join-Path $temp 'Extract';[IO.Compression.ZipFile]::ExtractToDirectory($zip,$extracted)
 $text=[IO.File]::ReadAllText((Join-Path $extracted 'Atendimento.log'));$record=[IO.File]::ReadAllText((Join-Path $extracted 'Tentativas\001.json'))
 Assert ($text -match 'linha adicionada agora' -and $text -notmatch 'secreto') 'ZIP usou log desatualizado ou expôs senha'
 Assert ($record -match '42' -and $record -notmatch 'secreto|RawBase64') 'JSON do atendimento não sanitizado'
 $r=Export-SupportBundle -OutputPath (Join-Path $temp 'SemTentativas.zip') -LogPath $log -Since (Get-Date).AddYears(1).ToString('o')
 Assert $r.Success 'Exportação antes da primeira operação falhou'
 Assert (@(Get-ChildItem -LiteralPath $temp -Recurse -File|Where-Object Extension -eq '.ps1').Count -eq 0) 'ZIP contém script executável'
}finally{if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}}
'OK: comparativo host/cliente, consultas inconclusivas, segredos excluídos e ZIP com log atual; nenhuma alteração no sistema.'
