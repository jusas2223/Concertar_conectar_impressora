$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
foreach ($name in @('Get-SubnetAddressCandidates','Test-OpenPrinterPorts')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Funcao ausente: $name" }
    Invoke-Expression $definition.Extent.Text
}

$addresses = @(Get-SubnetAddressCandidates -IPAddress '192.168.1.36' -SubnetMask '255.255.255.0')
if ($addresses.Count -ne 253 -or $addresses -notcontains '192.168.1.100' -or
    $addresses -contains '192.168.1.36' -or $addresses -contains '192.168.1.255') {
    throw 'A varredura da sub-rede nao inclui os vizinhos esperados.'
}

$listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
$listener.Start()
try {
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $found = Test-OpenPrinterPorts -Addresses @('127.0.0.1') -Ports @($port) -TimeoutMs 500
    $stopwatch.Stop()
    if (-not $found.ContainsKey('127.0.0.1') -or -not $found['127.0.0.1'].ContainsKey($port)) {
        throw 'A sondagem nao encontrou uma porta TCP de teste aberta.'
    }
    if ($stopwatch.Elapsed.TotalSeconds -gt 4) {
        throw 'A sondagem de uma porta demorou mais de quatro segundos.'
    }
} finally {
    $listener.Stop()
}

Write-Output 'OK: sub-rede 192.168.1/24 completa e sondagem TCP limitada por tempo.'
