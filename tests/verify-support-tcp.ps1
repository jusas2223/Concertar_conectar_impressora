param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
. (Join-Path $SourceRoot 'src\scripts\ATENDIMENTO-COMUM.ps1')
function Assert($Condition,$Message){if(-not $Condition){throw $Message}}
$script:ports=@();$script:creates=0;$script:hidePort=$false;$script:queues=@();$script:adds=0;$script:fakeAdd=$false
function Get-WmiObject {param($Class,$ErrorAction);if(-not $script:hidePort){return $script:ports}}
function New-SupportTcpPortInstance {
 $script:creates++;$p=[pscustomobject]@{Name='';HostAddress='';Protocol=0;PortNumber=0;SNMPEnabled=$true;Queue=''}
 $p|Add-Member ScriptMethod Put {$script:ports+=,$this;return $null};return $p
}
function Get-Printer {param($ErrorAction);return $script:queues}
function Get-PrinterDriver {param($ErrorAction);return @([pscustomobject]@{Name='Modelo Exato';PrinterEnvironment='Windows x64'},[pscustomobject]@{Name='Outro';PrinterEnvironment='Windows x64'})}
function Add-Printer {param($Name,$PortName,$DriverName,$ErrorAction);$script:adds++;if(-not $script:fakeAdd){$script:queues+=,[pscustomobject]@{Name=$Name;PortName=$PortName;DriverName=$DriverName}}}
foreach($bad in @('','192.168.1','256.0.0.1','1.2.3.4.5','hostname','1.2.-3.4')){Assert (-not(Test-PrinterIPv4 $bad)) ('IPv4 inválido aceito: '+$bad)}
Assert (Test-PrinterIPv4 '192.0.2.10') 'IPv4 válido recusado'
foreach($port in @(0,65536)){try{New-SupportTcpPort '192.0.2.10' $port|Out-Null;throw 'Porta inválida aceita'}catch{Assert ($_.Exception.Message -match 'inválidos') 'Erro de porta inválida não preservado'}}
$r=New-SupportTcpPort '192.0.2.10' 9100 RAW
Assert ($r.Success -and $script:creates -eq 1 -and $script:ports[0].PortNumber -eq 9100) 'RAW não confirmou a porta'
$r=New-SupportTcpPort '192.0.2.10' 9100 RAW
Assert ($r.Existing -and $script:creates -eq 1) 'Porta equivalente duplicada'
$original=$script:ports[0];$r=New-SupportTcpPort '192.0.2.10' 9200 RAW
Assert ($r.PortName -ne $original.Name -and $original.PortNumber -eq 9100) 'Porta existente foi alterada para outro endpoint'
$r=New-SupportTcpPort '192.0.2.10' 515 LPR 'FilaA';$lpr=$script:ports|Where-Object Name -eq $r.PortName
Assert ($lpr.Protocol -eq 2 -and $lpr.PortNumber -eq 515 -and $lpr.Queue -eq 'FilaA') 'LPR incorreto'
$r=New-SupportTcpPort '192.0.2.10' 515 LPR 'FilaB'
Assert ($r.PortName -ne $lpr.Name -and $lpr.Queue -eq 'FilaA') 'Fila LPR reutilizada incorretamente'
$script:hidePort=$true
try{New-SupportTcpPort '192.0.2.11'|Out-Null;throw 'Porta invisível aceita'}catch{Assert ($_.Exception.Message -match 'não foram confirmadas') 'Retorno WMI virou sucesso sem consulta'}
$script:hidePort=$false
$r=Install-SupportLocalPrinter 'Nova' 'Porta Exata' 'Modelo Exato' -Seconds 0
Assert ($r.Success -and $r.QueueInstalled -and $script:adds -eq 1) 'Fila/driver/porta exatos não validados'
$r=Install-SupportLocalPrinter 'Nova' 'Porta Exata' 'Modelo Exato' -Seconds 0
Assert ($script:adds -eq 1) 'Fila equivalente reinstalada'
try{Install-SupportLocalPrinter 'Nova' 'Outra Porta' 'Modelo Exato' -Seconds 0|Out-Null;throw 'Fila existente sobrescrita'}catch{Assert ($_.Exception.Message -match 'outra porta ou driver') 'Conflito de fila não preservado'}
try{Install-SupportLocalPrinter 'Ausente' 'Porta' 'Modelo' -Seconds 0|Out-Null;throw 'Driver aproximado aceito'}catch{Assert ($_.Exception.Message -match 'não está instalado') 'Driver aproximado não recusado'}
$script:fakeAdd=$true
try{Install-SupportLocalPrinter 'Invisível' 'Porta' 'Modelo Exato' -Seconds 0|Out-Null;throw 'Exit code aceito como fila instalada'}catch{Assert ($_.Exception.Message -match 'não confirmou') 'Registro inexistente virou sucesso'}
'OK: IPv4/portas, RAW/LPR, colisões preservadas, driver exato e confirmação da fila; WMI/Spooler substituídos.'
