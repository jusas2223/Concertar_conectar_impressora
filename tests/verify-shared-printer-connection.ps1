$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
foreach ($name in @('Format-PrinterAsNamedUNC','Test-PrinterConnectionInstalled','Test-PrinterShareInstalled','Wait-PrinterConnectionInstalled','Connect-UNCPrinterSafe')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Funcao ausente: $name" }
    Invoke-Expression $definition.Extent.Text
}

$script:printerMapCache = @{}
$byIp = '\\10.0.0.4\Fila'
if ((Format-PrinterAsNamedUNC -PrinterInput $byIp) -cne $byIp) {
    throw 'O caminho por IP foi convertido para nome.'
}

$unrelated = @([pscustomobject]@{ Name='Impressora MP 4200 local'; Network=$false; PortName='USB001'; ShareName='' })
if (Test-PrinterShareInstalled -UNCPath '\\SERVIDOR\MP' -InstalledPrinters $unrelated) {
    throw 'Uma impressora com nome parecido foi marcada como o compartilhamento instalado.'
}
$localPort = @([pscustomobject]@{ Name='MP em SERVIDOR'; Network=$false; PortName='\\SERVIDOR\MP'; ShareName='' })
if (-not (Test-PrinterShareInstalled -UNCPath '\\SERVIDOR\MP' -InstalledPrinters $localPort)) {
    throw 'A fila na porta UNC exata nao foi reconhecida.'
}

function Get-WmiObject {
    param($Class, $ErrorAction)
    if ($script:existingLocal) {
        return [pscustomobject]@{ Network=$false; Name='Fila em SERVIDOR'; PortName='\\SERVIDOR\Fila' }
    }
    return [pscustomobject]@{
        Network=$true; Name='Fila em SERVIDOR'; ServerName='\\SERVIDOR'; ShareName='Fila'
    }
}
function Get-InstalledPrintersWmi { return @(Get-WmiObject -Class Win32_Printer) }
if (-not (Test-PrinterConnectionInstalled -UNCPath '\\SERVIDOR\Fila')) {
    throw 'A verificacao nao reconheceu ServerName e ShareName.'
}


$script:logs=New-Object Collections.ArrayList
function Write-AppLog {param($Message,$Level) [void]$script:logs.Add($Message)}
function Test-TcpPortSafe {param($HostOrIp,$Port,$TimeoutMs) return $true}
$script:fixturePrinters=@()
function Get-InstalledPrintersWmi {return $script:fixturePrinters}
function Invoke-BoundedPrinterAttempt {
 param($UNCPath,$Method,$TimeoutSeconds,$NetworkCredential,$CredentialServer)
 $script:attempts++
 if($Method -ne 'Cascade'){throw 'Interface não invocou a cascata.'}
 switch($script:scenario){
  timeout {return @{Success=$false;TimedOut=$true;Message='Prazo atingido'}}
  cancel {return @{Success=$false;Cancelled=$true;Message='Cancelado'}}
  default {return @{Success=$true;QueueInstalled=$true;ConnectedUNC=$UNCPath;Cascaded=$true;Message='Fixture'}}
 }
}
$global:SimulationMode=$false
$script:attempts=0;$script:scenario='false-success'
$result=Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila'
if($result.Success -or $script:attempts -ne 1){throw 'Sucesso do worker sem fila foi aceito.'}
$script:fixturePrinters=@([pscustomobject]@{Name='Fila local';Network=$false;PortName='\\SERVIDOR\Fila'})
$script:attempts=0;$script:scenario='success'
$result=Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila'
if(-not $result.Success -or $script:attempts -ne 1){throw 'Fila UNC exata não foi confirmada.'}
foreach($script:scenario in @('timeout','cancel')){
 $script:attempts=0
 $result=Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila'
 $code=if($script:scenario -eq 'timeout'){1460}else{1223}
 if($result.Success -or $result.Code -ne $code -or $script:attempts -ne 1){throw 'Worker foi repetido após timeout/cancelamento.'}
}
'OK: UNC exato, nome parecido rejeitado, confirmação independente e cascata sem repetição após timeout/cancelamento.'
