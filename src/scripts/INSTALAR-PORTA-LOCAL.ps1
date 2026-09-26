param(
    [Parameter(Mandatory=$true)][string]$RequestPath,
    [Parameter(Mandatory=$true)][string]$ResultPath
)

$ErrorActionPreference = 'Stop'
$result = @{ Success = $false; Message = 'A instalação não foi concluída.' }
$stage = 'Ler dados da instalação'

try {
    $request = Import-Clixml -LiteralPath $RequestPath -ErrorAction Stop
    $unc = [string]$request.UNCPath
    $driver = ([string]$request.DriverName).Trim()
    $queue = ([string]$request.QueueName).Trim()
    $inf = [string]$request.InfPath

    if ($unc -notmatch '^\\\\[^\\]+\\[^\\]+$') { throw 'Caminho da impressora inválido. Use \\SERVIDOR\Fila.' }
    if (-not $driver) { throw 'Informe o nome exato do driver para o Windows 10.' }
    if (-not $queue -or $queue.Length -gt 200 -or $queue -match '[\\/]') {
        throw 'Nome da fila local inválido.'
    }
    if ($inf) {
        $inf = [IO.Path]::GetFullPath($inf)
        if ([IO.Path]::GetExtension($inf) -ine '.inf' -or -not (Test-Path -LiteralPath $inf -PathType Leaf)) {
            throw 'Selecione um arquivo INF existente do driver para Windows 10.'
        }
    }

    $stage = 'Verificar fila local existente'
    $existing = Get-Printer -Name $queue -ErrorAction SilentlyContinue
    if ($existing) {
        if ([string]$existing.PortName -ieq $unc -and [string]$existing.DriverName -ieq $driver) {
            $result = @{ Success = $true; QueueName = $queue; PortName = $unc; Message = 'Fila local já instalada e confirmada.' }
        } else {
            throw "Já existe uma impressora chamada '$queue' com outra porta ou outro driver. Escolha outro nome."
        }
    } else {
        $stage = 'Verificar driver instalado no cliente'
        $installedDriver = Get-PrinterDriver -Name $driver -ErrorAction SilentlyContinue
        if (-not $installedDriver -and $inf) {
            $stage = 'Instalar pacote INF do driver'
            $pnpOutput = & pnputil.exe /add-driver $inf 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "O Windows recusou o pacote INF (código $LASTEXITCODE): $($pnpOutput -join ' ')"
            }
            Add-PrinterDriver -Name $driver -ErrorAction Stop
            $installedDriver = Get-PrinterDriver -Name $driver -ErrorAction SilentlyContinue
        }
        if (-not $installedDriver) {
            throw "O driver '$driver' não está instalado neste PC. Selecione o INF oficial para Windows 10 ou instale o driver e tente novamente."
        }

        $createdPort = $false
        $stage = 'Criar porta local UNC'
        if (-not (Get-PrinterPort -Name $unc -ErrorAction SilentlyContinue)) {
            Add-PrinterPort -Name $unc -ErrorAction Stop
            $createdPort = $true
        }
        try {
            $stage = 'Criar fila com driver e porta local'
            Add-Printer -Name $queue -DriverName $driver -PortName $unc -ErrorAction Stop
            $createdQueue = $null
            $stage = 'Confirmar fila criada no Windows'
            for ($attempt = 0; $attempt -lt 6; $attempt++) {
                $createdQueue = Get-Printer -Name $queue -ErrorAction SilentlyContinue
                if ($createdQueue) { break }
                if ($attempt -lt 5) { Start-Sleep -Milliseconds 500 }
            }
            if ([string]$createdQueue.PortName -ine $unc -or [string]$createdQueue.DriverName -ine $driver) {
                throw "O Windows criou a fila com porta ou driver diferente do solicitado (porta='$($createdQueue.PortName)', driver='$($createdQueue.DriverName)')."
            }
            $result = @{ Success = $true; Stage = $stage; QueueName = $queue; PortName = $unc; Message = 'Fila local criada e confirmada no Windows.' }
        } catch {
            if ($createdPort -and -not (Get-Printer -ErrorAction SilentlyContinue | Where-Object { [string]$_.PortName -ieq $unc })) {
                Remove-PrinterPort -Name $unc -ErrorAction SilentlyContinue
            }
            throw
        }
    }
} catch {
    $result = @{
        Success = $false
        Stage = $stage
        Message = $_.Exception.Message
        HResult = ('0x{0:X8}' -f ([long]$_.Exception.HResult -band 4294967295))
        ErrorId = [string]$_.FullyQualifiedErrorId
    }
}

try {
    $result | Export-Clixml -LiteralPath $ResultPath -Force -ErrorAction Stop
} catch {
    exit 2
}
if ($result.Success) { exit 0 }
exit 1
