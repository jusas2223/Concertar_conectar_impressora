param(
    [Parameter(Mandatory=$true)][string]$UNCPath,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [ValidateSet('AddPrinter','WScript')][string]$Method = 'AddPrinter'
)

$ErrorActionPreference = 'Stop'
$result = @{ Success=$false; Message='A conexão não foi concluída.' }
try {
    if ($UNCPath -notmatch '^\\\\[^\\]+\\[^\\]+$') {
        throw 'O caminho da impressora precisa estar no formato \\SERVIDOR\Fila.'
    }
    if ($Method -eq 'AddPrinter') {
        if (-not (Get-Command Add-Printer -ErrorAction SilentlyContinue)) {
            throw 'O comando Add-Printer não está disponível neste Windows.'
        }
        Add-Printer -ConnectionName $UNCPath -ErrorAction Stop
    } else {
        $network = New-Object -ComObject WScript.Network -ErrorAction Stop
        $network.AddWindowsPrinterConnection($UNCPath)
    }
    $result = @{ Success=$true; Message="O Windows concluiu $Method." }
} catch {
    $result = @{ Success=$false; Message=$_.Exception.Message; HResult=$_.Exception.HResult }
}

try { $result | Export-Clixml -LiteralPath $ResultPath -Force -ErrorAction Stop }
catch { exit 2 }
if ($result.Success) { exit 0 }
exit 1
