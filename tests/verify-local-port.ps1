$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $root 'src\scripts\INSTALAR-PORTA-LOCAL.ps1'
$tempDirectory = Join-Path $env:TEMP ('PrinterLocalPortTest_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null

$wrapper = Join-Path $tempDirectory 'mock installer.ps1'
@'
param([string]$Installer, [string]$RequestPath, [string]$ResultPath)
$global:mockPort = ''
$global:mockQueue = $null
$global:denyPort = ((Import-Clixml -LiteralPath $RequestPath).QueueName -eq 'MP Negada')
$global:invalidPort = [bool](Import-Clixml -LiteralPath $RequestPath).FixtureInvalidPort
Add-Type -TypeDefinition 'public static class LocalPortMonitorBridge { public static string Port=""; public static string Add(string name) { Port=name; return "Local Port (Fixture)"; } }'
function Get-PrinterDriver {
    param($Name, $ErrorAction)
    if ($Name -eq 'Driver de Teste') { return [pscustomobject]@{ Name=$Name } }
}
function Get-PrinterPort {
    param($Name, $ErrorAction)
    if ([LocalPortMonitorBridge]::Port) { return [pscustomobject]@{ Name=[LocalPortMonitorBridge]::Port } }
    if ($global:mockPort -eq $Name) { return [pscustomobject]@{ Name=$Name } }
}
function Add-PrinterPort {
    param($Name, $ErrorAction)
    if ($global:denyPort) { throw 'O acesso foi negado para o recurso especificado.' }
    if ($global:invalidPort) { throw (New-Object ArgumentException('Invalid parameter fixture')) }
    if ($Name -ne '\\SERVIDOR\MP') { throw 'Porta inesperada.' }
    $global:mockPort = $Name
}
function Get-Printer {
    param($Name, $ErrorAction)
    if ($global:mockQueue -and (-not $Name -or $Name -eq $global:mockQueue.Name)) { return $global:mockQueue }
}
function Add-Printer {
    param($Name, $DriverName, $PortName, $ErrorAction)
    if ($Name -ne 'MP em SERVIDOR' -or $DriverName -ne 'Driver de Teste' -or $PortName -ne '\\SERVIDOR\MP') {
        throw 'Os parametros da fila nao foram preservados.'
    }
    $global:mockQueue = [pscustomobject]@{ Name=$Name; DriverName=$DriverName; PortName=$PortName }
}
function Remove-PrinterPort { throw 'Nao deveria remover uma porta em teste bem-sucedido.' }
. $Installer -RequestPath $RequestPath -ResultPath $ResultPath
'@ | Set-Content -LiteralPath $wrapper -Encoding UTF8

try {
    foreach ($driverName in @('Driver de Teste','Driver Ausente')) {
        $request = Join-Path $tempDirectory ($driverName.Replace(' ','_') + '.request.xml')
        $resultPath = Join-Path $tempDirectory ($driverName.Replace(' ','_') + '.result.xml')
        @{ UNCPath='\\SERVIDOR\MP'; DriverName=$driverName; QueueName='MP em SERVIDOR'; InfPath='' } |
            Export-Clixml -LiteralPath $request
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Installer $installer -RequestPath $request -ResultPath $resultPath
        $result = Import-Clixml -LiteralPath $resultPath
        if ($driverName -eq 'Driver de Teste') {
            if (-not $result.Success -or $result.PortName -ne '\\SERVIDOR\MP') { throw "Fila local nao foi criada e confirmada: $($result.Message)" }
        } elseif ($result.Success -or $result.Message -notlike '*não está instalado*' -or
            $result.Stage -ne 'Verificar driver instalado no cliente') {
            throw 'Driver ausente foi tratado como sucesso ou perdeu a etapa da falha.'
        }
    }
    $deniedRequest = Join-Path $tempDirectory 'porta_negada.request.xml'
    $deniedResult = Join-Path $tempDirectory 'porta_negada.result.xml'
    @{ UNCPath='\\SERVIDOR\MP'; DriverName='Driver de Teste'; QueueName='MP Negada'; InfPath='' } |
        Export-Clixml -LiteralPath $deniedRequest
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Installer $installer -RequestPath $deniedRequest -ResultPath $deniedResult
    $denied = Import-Clixml -LiteralPath $deniedResult
    if ($denied.Success -or $denied.Stage -ne 'Criar porta local UNC' -or
        $denied.Message -notlike '*acesso foi negado*' -or -not $denied.HResult) {
        throw 'A falha de acesso ao criar porta não informou etapa e código.'
    }
    $invalidRequest = Join-Path $tempDirectory 'invalid.request.xml'
    $invalidResult = Join-Path $tempDirectory 'invalid.result.xml'
    @{ UNCPath='\\SERVIDOR\MP'; DriverName='Driver de Teste'; QueueName='MP em SERVIDOR'; InfPath=''; FixtureInvalidPort=$true } | Export-Clixml -LiteralPath $invalidRequest
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $wrapper -Installer $installer -RequestPath $invalidRequest -ResultPath $invalidResult
    $native = Import-Clixml -LiteralPath $invalidResult
    if (-not $native.Success -or $native.PortMethod -ne 'XcvData/LocalMon') { throw "Erro 87 não acionou o monitor com fila confirmada: $($native.Message)" }
} finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'OK: instalacao local usa UNC/driver exatos e identifica driver ausente ou acesso negado na porta.'
