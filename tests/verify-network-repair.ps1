$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sourcePath = Join-Path $root 'src\scripts\CORRIGIR-ACESSO-REDE-24H2.ps1'
$restorePath = Join-Path $root 'src\scripts\RESTAURAR-ACESSO-REDE.ps1'

foreach ($path in @($sourcePath, $restorePath)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -ne 0) { throw "Erro de sintaxe em $path`: $($errors[0].Message)" }
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
foreach ($functionName in @('Get-NetworkRepairPlan','Get-NetworkRepairBuild','Get-NetworkRepairRegistryState')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName }, $true)
    if (-not $definition) { throw "Funcao de diagnostico ausente: $functionName" }
    Invoke-Expression $definition.Extent.Text
}

$detectedBuild = Get-NetworkRepairBuild
if ($detectedBuild -lt 10240) { throw "Build do Windows nao detectada: $detectedBuild" }
$registryRead = Get-NetworkRepairRegistryState -KeyPath 'SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ValueName 'ProductName'
if (-not $registryRead.Exists -or -not $registryRead.Value) { throw 'Leitura do Registro falhou.' }

$client = @(Get-NetworkRepairPlan -TargetRole Cliente -BuildNumber 26100)
$host24 = @(Get-NetworkRepairPlan -TargetRole Host -BuildNumber 26100)
$hostOld = @(Get-NetworkRepairPlan -TargetRole Host -BuildNumber 19045)
if ($client.Count -ne 3 -or ($client -join ' ') -notmatch 'convidado|assinatura|AllowInsecureGuestAuth') {
    throw 'Plano de cliente incompleto.'
}
if ($host24.Count -ne 2 -or ($host24 -join ' ') -notmatch 'RpcProtocols=7') {
    throw 'Plano de host 24H2 incompleto.'
}
if ($hostOld.Count -ne 1 -or ($hostOld -join ' ') -match 'RpcProtocols') {
    throw 'Politica RPC foi oferecida para build antiga.'
}
if (($client -join ' ') -match 'servidor|RpcProtocols' -or ($host24 -join ' ') -match 'convidado|AllowInsecureGuestAuth') {
    throw 'Os papeis cliente e host foram misturados.'
}

Write-Output 'OK: scripts sem erro de sintaxe; ajustes de cliente e host separados por papel e build.'
