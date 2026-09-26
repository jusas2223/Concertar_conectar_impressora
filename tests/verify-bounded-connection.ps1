$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms

$sourcePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($sourcePath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-BoundedPrinterAttempt'
}, $true)
if (-not $definition) { throw 'Rotina de conexão com prazo ausente.' }
Invoke-Expression $definition.Extent.Text

$tempDirectory = Join-Path $env:TEMP ('PrinterConnectionTest_' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($tempDirectory) | Out-Null
$PrinterConnectionPath = Join-Path $tempDirectory 'conexao de teste.ps1'
try {
    [IO.File]::WriteAllText($PrinterConnectionPath, @'
param([string]$UNCPath, [string]$ResultPath)
if ($UNCPath -like '*lenta') { Start-Sleep -Seconds 8 }
@{ Success=$true; Message=$UNCPath } | Export-Clixml -LiteralPath $ResultPath -Force
'@, [Text.Encoding]::UTF8)

    $script:cancelPrinterConnection = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $timeout = Invoke-BoundedPrinterAttempt -UNCPath '\\TESTE\lenta' -Method AddPrinter -TimeoutSeconds 1
    $watch.Stop()
    if (-not $timeout.TimedOut -or $watch.Elapsed.TotalSeconds -gt 6) {
        throw "A tentativa lenta não foi interrompida no prazo: $($watch.Elapsed.TotalSeconds)s"
    }

    $cancelTimer = New-Object System.Windows.Forms.Timer
    $cancelTimer.Interval = 400
    $cancelTimer.Add_Tick({
        $script:cancelPrinterConnection = $true
        $cancelTimer.Stop()
    })
    try {
        $script:cancelPrinterConnection = $false
        $cancelTimer.Start()
        $watch.Restart()
        $cancelled = Invoke-BoundedPrinterAttempt -UNCPath '\\TESTE\lenta' -Method AddPrinter -TimeoutSeconds 10
        $watch.Stop()
        if (-not $cancelled.Cancelled -or $watch.Elapsed.TotalSeconds -gt 6) {
            throw "A tentativa não reagiu ao cancelamento: $($watch.Elapsed.TotalSeconds)s"
        }
    } finally {
        $cancelTimer.Stop()
        $cancelTimer.Dispose()
        $script:cancelPrinterConnection = $false
    }

    $success = Invoke-BoundedPrinterAttempt -UNCPath '\\TESTE\rapida' -Method AddPrinter -TimeoutSeconds 5
    if (-not $success.Success -or $success.Message -cne '\\TESTE\rapida') {
        throw 'A rotina com prazo não retornou o resultado de uma tentativa rápida.'
    }
    $wscript = Invoke-BoundedPrinterAttempt -UNCPath '\\TESTE\rapida' -Method WScript -TimeoutSeconds 5
    if (-not $wscript.Success -or $wscript.Message -cne '\\TESTE\rapida') {
        throw 'O método WScript não foi executado na rotina com prazo.'
    }
} finally {
    Remove-Item -LiteralPath $tempDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'OK: processo demorado interrompido por prazo e cancelamento; Add-Printer e WScript retornaram resultado.'
