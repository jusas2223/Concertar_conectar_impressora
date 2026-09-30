$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mainPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\AssistenteImpressoras.ps1'
$tokens = $null
$errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainPath, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw $errors[0].Message }
$definition = $ast.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq 'Wait-PrinterRepairProcess'
}, $true)
if (-not $definition) { throw 'Janela de progresso ausente.' }
Invoke-Expression $definition.Extent.Text

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Teste de progresso'
try {
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile -Command "Start-Sleep -Seconds 2; exit 7"' -WindowStyle Hidden -PassThru
    $code = Wait-PrinterRepairProcess -Process $process -ErrorCode '709'
    if ($code -ne 7) { throw "Codigo de saida incorreto: $code" }
} finally {
    $form.Dispose()
}

Write-Output 'OK: janela de carregamento fecha apos o processo e devolve seu codigo de saida.'
