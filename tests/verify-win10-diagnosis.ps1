$ErrorActionPreference = 'Stop'
$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
foreach ($name in @('Get-CurrentWindowsBuild','Get-NetworkAccessActionMode','Get-SharedPrinterAccessDiagnosis')) {
    $definition = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name
    }, $true)
    if (-not $definition) { throw "Função ausente: $name" }
    Invoke-Expression $definition.Extent.Text
}

if ((Get-CurrentWindowsBuild) -lt 10240) { throw 'Build do Windows não detectada.' }
if ((Get-NetworkAccessActionMode -BuildNumber 19045) -ne 'Win10PrinterDiagnosis' -or
    (Get-NetworkAccessActionMode -BuildNumber 26200) -ne 'Network24H2Repair') {
    throw 'O botão de rede não escolheu o fluxo correto para Windows 10 e 11.'
}
function Test-TcpPortSafe {
    param($HostOrIp, $Port, $TimeoutMs)
    return ($HostOrIp -eq '10.0.0.24' -and $Port -in @(135,445))
}
$diagnosis = Get-SharedPrinterAccessDiagnosis -UNCPath '\\SERVIDOR\Fila' -AlternateHost '10.0.0.24'
if (-not $diagnosis.Valid -or -not $diagnosis.SMBReachable -or
    $diagnosis.SuggestedHost -ne '10.0.0.24' -or $diagnosis.Message -notlike '*RPC 135 aberta*') {
    throw 'O diagnóstico não reconheceu o acesso pelo IP alternativo.'
}
$invalid = Get-SharedPrinterAccessDiagnosis -UNCPath 'SERVIDOR\Fila'
if ($invalid.Valid) { throw 'Caminho incompleto foi aceito.' }
Write-Output 'OK: diagnóstico identifica SMB/RPC pelo IP e rejeita caminho incompleto.'
