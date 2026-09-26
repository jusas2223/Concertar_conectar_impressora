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

$script:logs = New-Object System.Collections.ArrayList
function Write-AppLog { param($Message, $Level) [void]$script:logs.Add("$Level $Message") }
function Test-TcpPortSafe { param($HostOrIp, $Port, $TimeoutMs) return $true }
function Start-Sleep { param($Milliseconds) }
function Invoke-BoundedPrinterAttempt {
    param($UNCPath, $Method, $TimeoutSeconds)
    $script:attempts++
    if ($script:timeoutFirst) { return @{ Success=$false; TimedOut=$true; Message='Prazo esgotado no teste.' } }
    if ($script:invalidName) { return @{ Success=$false; Message='O nome da impressora é inválido. (HRESULT: 0x80070709)' } }
    if ($script:allowIp -and $UNCPath -eq '\\10.0.0.4\Fila' -and $Method -eq 'AddPrinter') {
        $script:installedIp = $true
    }
    if ($script:allowWScript -and $UNCPath -eq '\\SERVIDOR\Fila' -and $Method -eq 'WScript') {
        $script:installedWScript = $true
    }
    return @{ Success=($Method -eq 'PrintUI'); Message='Método terminou no teste.' }
}
function Test-PrinterConnectionInstalled {
    param($UNCPath)
    return (($script:installedIp -and $UNCPath -eq '\\10.0.0.4\Fila') -or
        ($script:installedWScript -and $UNCPath -eq '\\SERVIDOR\Fila'))
}

$global:SimulationMode = $false
$script:allowIp = $false
$script:installedIp = $false
$script:installedWScript = $false
$script:allowWScript = $false
$script:attempts = 0
$script:timeoutFirst = $false
$script:invalidName = $false
$falseSuccess = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila' -AlternateHost '10.0.0.4'
if ($falseSuccess.Success) { throw 'PrintUI codigo 0 foi aceito sem impressora instalada.' }

$script:allowIp = $true
$script:installedIp = $false
$script:attempts = 0
$ipSuccess = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila' -AlternateHost '10.0.0.4'
if (-not $ipSuccess.Success -or $ipSuccess.ConnectedUNC -cne '\\10.0.0.4\Fila') {
    throw 'A segunda tentativa pelo IP nao foi confirmada.'
}

$script:allowIp = $false
$script:installedIp = $false
$script:attempts = 0
$script:timeoutFirst = $true
$timeout = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila' -AlternateHost '10.0.0.4'
if ($timeout.Success -or $timeout.Code -ne 1460 -or $script:attempts -ne 1) {
    throw 'A tentativa com prazo esgotado foi repetida ou reportada como sucesso.'
}
$script:timeoutFirst = $false

$script:invalidName = $true
$script:attempts = 0
$invalidName = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila'
if ($invalidName.Success -or $invalidName.Code -ne 1801 -or $script:attempts -ne 2) {
    throw 'O erro 0x80070709 não interrompeu a tentativa PrintUI redundante.'
}
$script:attempts = 0
$invalidByNameAndIp = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila' -AlternateHost '10.0.0.4'
if ($invalidByNameAndIp.Success -or $invalidByNameAndIp.Code -ne 1801 -or $script:attempts -ne 4) {
    throw 'A falha 0x80070709 não foi conferida pelo nome e IP sem abrir PrintUI.'
}
$script:invalidName = $false

$script:allowWScript = $true
$script:installedWScript = $false
$script:attempts = 0
$wscriptSuccess = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila'
if (-not $wscriptSuccess.Success -or $wscriptSuccess.ConnectedUNC -cne '\\SERVIDOR\Fila' -or $script:attempts -ne 2) {
    throw 'A conexão por WScript não foi preservada como segundo método.'
}
$script:allowWScript = $false
$script:installedWScript = $false

$script:existingLocal = $true
$script:allowIp = $false
$localSuccess = Connect-UNCPrinterSafe -UNCPath '\\SERVIDOR\Fila'
if (-not $localSuccess.Success -or -not $localSuccess.LocalPort -or $localSuccess.ConnectedUNC -ne 'Fila em SERVIDOR') {
    throw 'Uma fila local existente na porta UNC nao foi reconhecida.'
}

Write-Output 'OK: caminho por IP, WScript preservado, 0x80070709 encerra PrintUI redundante, sucesso falso rejeitado, prazo esgotado sem repeticao e fila local reconhecida.'
