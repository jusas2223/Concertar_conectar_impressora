$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fixPath = Join-Path $root 'src\scripts\CORRIGIR-ERRO-IMPRESSORA.ps1'
$restorePath = Join-Path $root 'src\scripts\RESTAURAR-ERRO-IMPRESSORA.ps1'

foreach ($path in @($fixPath, $restorePath)) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw "Erro de sintaxe em $path`: $($errors[0].Message)" }
}

$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($fixPath, [ref]$tokens, [ref]$errors)
foreach ($name in @('Get-PrinterRepairPlan','Get-PrinterRepairBuild','Get-PrinterRepairRegistryState')) {
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    if (-not $definition) { throw "Funcao ausente: $name" }
    Invoke-Expression $definition.Extent.Text
}

$win11 = @(Get-PrinterRepairPlan -Code 709 -BuildNumber 22621)
$oldWin10 = @(Get-PrinterRepairPlan -Code 709 -BuildNumber 19044)
$newWin10 = @(Get-PrinterRepairPlan -Code 709 -BuildNumber 19045)
$rpc11b = @(Get-PrinterRepairPlan -Code 11b -BuildNumber 22621)
if (($win11.Name -join ',') -ne 'RpcUseNamedPipeProtocol,RpcProtocols') { throw 'Plano 709 Windows 11 incorreto.' }
if ($oldWin10.Count -ne 1 -or $oldWin10[0].Name -ne '713073804') { throw 'Override legado da build 19044 incorreto.' }
if ($newWin10.Count -ne 0) { throw 'Aplicou override legado na build 19045.' }
if ($rpc11b.Count -ne 1 -or $rpc11b[0].Name -ne 'RpcAuthnLevelPrivacyEnabled') { throw 'Plano 11b incorreto.' }

$build = Get-PrinterRepairBuild
if ($build -lt 10240) { throw 'Build atual nao identificada.' }
$before = @(
    Get-PrinterRepairRegistryState -KeyPath 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' -ValueName 'RpcUseNamedPipeProtocol'
    Get-PrinterRepairRegistryState -KeyPath 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' -ValueName 'RpcProtocols'
    Get-PrinterRepairRegistryState -KeyPath 'SYSTEM\CurrentControlSet\Control\Print' -ValueName 'RpcAuthnLevelPrivacyEnabled'
) | ConvertTo-Json -Compress
$spoolerBefore = (Get-Service -Name Spooler).Status
$testRoot = Join-Path $env:TEMP ('PrinterRepairTest_' + [Guid]::NewGuid().ToString('N'))
$paths = @((Join-Path $testRoot '709'), (Join-Path $testRoot '11b'))
try {
    foreach ($i in 0,1) {
        $code = @('709','11b')[$i]
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $fixPath -ErrorCode $code -OutputDirectory $paths[$i] -DiagnosticOnly | Out-Null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath (Join-Path $paths[$i] 'Relatorio.txt'))) {
            throw "Diagnostico do erro $code falhou."
        }
    }
    $after = @(
        Get-PrinterRepairRegistryState -KeyPath 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' -ValueName 'RpcUseNamedPipeProtocol'
        Get-PrinterRepairRegistryState -KeyPath 'SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC' -ValueName 'RpcProtocols'
        Get-PrinterRepairRegistryState -KeyPath 'SYSTEM\CurrentControlSet\Control\Print' -ValueName 'RpcAuthnLevelPrivacyEnabled'
    ) | ConvertTo-Json -Compress
    if ($before -cne $after -or $spoolerBefore -ne (Get-Service -Name Spooler).Status) {
        throw 'O diagnostico alterou Registro ou Spooler.'
    }
} finally {
    foreach ($directory in $paths) {
        if ([IO.Directory]::Exists($directory)) {
            Get-ChildItem -LiteralPath $directory -File | ForEach-Object { [IO.File]::Delete($_.FullName) }
            [IO.Directory]::Delete($directory)
        }
    }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot) }
}

Write-Output 'OK: planos 709/11b por build; diagnosticos reais sem mudar Registro ou Spooler.'
