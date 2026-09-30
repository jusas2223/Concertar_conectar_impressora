param(
    [string]$OutputPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'Arrumar_impressoraVG.exe')
)

$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw "Compilador .NET Framework nao encontrado: $compiler" }
$source = Join-Path $PSScriptRoot 'Program.cs'
$scriptFile = Join-Path $PSScriptRoot 'AssistenteImpressoras.ps1'
$outputDirectory = Split-Path -Parent $OutputPath
[IO.Directory]::CreateDirectory($outputDirectory) | Out-Null

$tokens = $null
$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref]$tokens, [ref]$parseErrors) | Out-Null
if ($parseErrors.Count -gt 0) {
    $parseErrors | ForEach-Object { Write-Error ("Linha {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) }
    throw 'O script PowerShell nao passou na analise sintatica.'
}

$resourceArgument = '/resource:' + $scriptFile + ',AssistenteImpressoras.AssistenteImpressoras.ps1'
$printerFix = Join-Path $PSScriptRoot 'scripts\CORRIGIR-ERRO-IMPRESSORA.ps1'
$printerRestore = Join-Path $PSScriptRoot 'scripts\RESTAURAR-ERRO-IMPRESSORA.ps1'
$networkFix = Join-Path $PSScriptRoot 'scripts\CORRIGIR-ACESSO-REDE-24H2.ps1'
$networkRestore = Join-Path $PSScriptRoot 'scripts\RESTAURAR-ACESSO-REDE.ps1'
$localPortInstall = Join-Path $PSScriptRoot 'scripts\INSTALAR-PORTA-LOCAL.ps1'
$connectionInstall = Join-Path $PSScriptRoot 'scripts\CONECTAR-IMPRESSORA.ps1'
$serverDriver = Join-Path $PSScriptRoot 'scripts\DRIVER-DO-SERVIDOR.ps1'
$interface = Join-Path $PSScriptRoot 'scripts\INTERFACE.ps1'
$compatibilityDiagnosis = Join-Path (Split-Path -Parent $PSScriptRoot) 'Diagnostico_Compartilhamento.ps1'
foreach ($required in @($printerFix, $printerRestore, $networkFix, $networkRestore, $localPortInstall, $connectionInstall, $serverDriver, $interface, $compatibilityDiagnosis)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Recurso ausente: $required" }
}
$parseInputs = @($scriptFile, $printerFix, $printerRestore, $networkFix, $networkRestore, $localPortInstall, $connectionInstall, $serverDriver, $interface, $compatibilityDiagnosis)
foreach ($inputPath in $parseInputs) {
    $parseErrors = $null
    $tokens = $null
    [System.Management.Automation.Language.Parser]::ParseFile($inputPath, [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count -gt 0) { throw "Erro de sintaxe em $inputPath`: $($parseErrors[0].Message)" }
}
$printerResource = '/resource:' + $printerFix + ',AssistenteImpressoras.CORRIGIR-ERRO-IMPRESSORA.ps1'
$printerRestoreResource = '/resource:' + $printerRestore + ',AssistenteImpressoras.RESTAURAR-ERRO-IMPRESSORA.ps1'
$networkResource = '/resource:' + $networkFix + ',AssistenteImpressoras.CORRIGIR-ACESSO-REDE-24H2.ps1'
$restoreResource = '/resource:' + $networkRestore + ',AssistenteImpressoras.RESTAURAR-ACESSO-REDE.ps1'
$localPortResource = '/resource:' + $localPortInstall + ',AssistenteImpressoras.INSTALAR-PORTA-LOCAL.ps1'
$connectionResource = '/resource:' + $connectionInstall + ',AssistenteImpressoras.CONECTAR-IMPRESSORA.ps1'
$serverDriverResource = '/resource:' + $serverDriver + ',AssistenteImpressoras.DRIVER-DO-SERVIDOR.ps1'
$interfaceResource = '/resource:' + $interface + ',AssistenteImpressoras.INTERFACE.ps1'
$compatibilityResource = '/resource:' + $compatibilityDiagnosis + ',AssistenteImpressoras.Diagnostico_Compartilhamento.ps1'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /codepage:65001 /reference:System.Windows.Forms.dll $resourceArgument $printerResource $printerRestoreResource $networkResource $restoreResource $localPortResource $connectionResource $serverDriverResource $interfaceResource $compatibilityResource ('/out:' + $OutputPath) $source
if ($LASTEXITCODE -ne 0) { throw "Falha na compilacao: $LASTEXITCODE" }
Write-Output $OutputPath
