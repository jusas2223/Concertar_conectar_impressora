param(
    [Parameter(Mandatory=$true)][string]$Servidor,
    [Parameter(Mandatory=$true)][string]$Compartilhamento,
    [string]$Driver = '',
    [string]$OutputDirectory = ''
)

# Diagnostico de leitura para executar no cliente e no computador que compartilha.
# Nao altera Registro, firewall, Spooler, filas ou credenciais.
$ErrorActionPreference = 'Continue'
if ($Servidor -notmatch '^[A-Za-z0-9._-]+$' -or
    $Compartilhamento -notmatch '^[^\\/,:*?"<>|]+$') {
    throw 'Informe nome ou IP do servidor e o nome exato do compartilhamento.'
}
$unc = '\\' + $Servidor + '\' + $Compartilhamento
$lines = New-Object System.Collections.ArrayList
function Add-Line([string]$value) { [void]$lines.Add($value) }
function Test-Port([string]$hostName, [int]$port) {
    $client = New-Object Net.Sockets.TcpClient
    try {
        $pending = $client.BeginConnect($hostName, $port, $null, $null)
        if (-not $pending.AsyncWaitHandle.WaitOne(1500, $false)) { return $false }
        $client.EndConnect($pending)
        return $true
    } catch { return $false }
    finally { $client.Close() }
}
function Read-Value([string]$path, [string]$name) {
    try {
        $entry = Get-ItemProperty -Path $path -Name $name -ErrorAction Stop
        return [string]$entry.$name
    } catch { return '(não definido)' }
}

$stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$logDirectory = $null
$logCandidates = @()
if ($OutputDirectory) { $logCandidates += $OutputDirectory }
else { $logCandidates += (Join-Path $PSScriptRoot 'Logs') }
$logCandidates += (Join-Path $env:LOCALAPPDATA 'AssistenteImpressoras\Logs')
$logCandidates += (Join-Path $env:TEMP 'AssistenteImpressoras_Logs')
foreach ($candidate in $logCandidates) {
    $probe = $null
    try {
        [IO.Directory]::CreateDirectory($candidate) | Out-Null
        $probe = Join-Path $candidate ('.write-test-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        $logDirectory = $candidate
        break
    } catch {
        # O relatório deve funcionar mesmo se o EXE vier de um compartilhamento somente leitura.
    } finally {
        if ($probe -and [IO.File]::Exists($probe)) {
            try { [IO.File]::Delete($probe) } catch {}
        }
    }
}
if (-not $logDirectory) { throw 'Não foi encontrada uma pasta gravável para o relatório.' }
$outputPath = Join-Path $logDirectory "Compatibilidade_Impressora_$stamp.txt"
$build = [Environment]::OSVersion.Version.Build
$localAddresses = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress)
$isHost = $Servidor -ieq $env:COMPUTERNAME -or $Servidor -eq 'localhost' -or
    $Servidor -eq '127.0.0.1' -or $Servidor -in $localAddresses
$spooler = Get-Service -Name Spooler -ErrorAction SilentlyContinue
$smb = Test-Port $Servidor 445
$rpc = Test-Port $Servidor 135

Add-Line 'DIAGNOSTICO DE IMPRESSORA COMPARTILHADA - SOMENTE LEITURA'
Add-Line ("Data: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
Add-Line ("Computador deste teste: {0}; Windows build {1}; usuário {2}" -f $env:COMPUTERNAME,$build,[Security.Principal.WindowsIdentity]::GetCurrent().Name)
Add-Line ("Servidor informado: {0}; fila: {1}; caminho: {2}" -f $Servidor,$Compartilhamento,$unc)
Add-Line ("Este PC é o servidor informado: {0}" -f $isHost)
Add-Line ("Spooler local: {0}" -f $(if ($spooler) { $spooler.Status } else { 'indisponível' }))
Add-Line ("SMB 445 no servidor: {0}" -f $(if ($smb) { 'responde' } else { 'não responde' }))
Add-Line ("RPC 135 no servidor: {0}" -f $(if ($rpc) { 'responde' } else { 'não responde' }))

if ($smb) {
    $viewProcess = $null
    try {
        $viewStart = New-Object Diagnostics.ProcessStartInfo
        $viewStart.FileName = 'net.exe'
        $viewStart.Arguments = 'view "\\' + $Servidor + '"'
        $viewStart.CreateNoWindow = $true
        $viewStart.UseShellExecute = $false
        $viewStart.RedirectStandardOutput = $true
        $viewStart.RedirectStandardError = $true
        $viewProcess = [Diagnostics.Process]::Start($viewStart)
        if (-not $viewProcess.WaitForExit(5000)) {
            $viewProcess.Kill()
            Add-Line 'Enumeração SMB: prazo de 5 segundos excedido.'
        } else {
            Add-Line ("Enumeração SMB (net view): código {0}" -f $viewProcess.ExitCode)
            if ($viewProcess.ExitCode -eq 5 -or $viewProcess.ExitCode -eq 1326) {
                Add-Line 'A enumeração SMB indicou acesso negado ou credenciais inválidas.'
            }
        }
    } catch { Add-Line ("Enumeração SMB: {0}" -f $_.Exception.Message) }
    finally { if ($viewProcess) { $viewProcess.Dispose() } }
}

try {
    $resolved = @([Net.Dns]::GetHostAddresses($Servidor) | Where-Object AddressFamily -eq InterNetwork |
        ForEach-Object IPAddressToString)
    Add-Line ("IPv4 resolvido: {0}" -f ($resolved -join ', '))
} catch { Add-Line ("Falha ao resolver o nome: {0}" -f $_.Exception.Message) }

try {
    $activeSmb = @(Get-SmbConnection -ErrorAction Stop | Where-Object {
        $_.ServerName -ieq $Servidor -or $_.ServerName -in $resolved
    })
    if ($activeSmb.Count) {
        foreach ($connection in $activeSmb) {
            Add-Line ("Sessão SMB: servidor={0}; compartilhamento={1}; usuário={2}; dialeto={3}" -f
                $connection.ServerName,$connection.ShareName,$connection.UserName,$connection.Dialect)
        }
    } else { Add-Line 'Sessão SMB ativa para esse servidor: não encontrada neste momento.' }
} catch { Add-Line ("Sessão SMB: consulta indisponível ({0})" -f $_.Exception.Message) }

try {
    $driverMatches = @(if ($Driver) { Get-PrinterDriver -Name $Driver -ErrorAction SilentlyContinue })
    Add-Line ("Driver solicitado: {0}" -f $(if ($Driver) { $Driver } else { '(não informado)' }))
    if ($Driver) {
        Add-Line ("Driver instalado neste PC: {0}" -f $(if (@($driverMatches).Count) { 'sim' } else { 'não' }))
    }
    $localDrivers = @(Get-PrinterDriver -ErrorAction Stop | Sort-Object Name | Select-Object -ExpandProperty Name)
    Add-Line ("Drivers de impressão locais ({0}): {1}" -f $localDrivers.Count,
        (($localDrivers | Select-Object -First 50) -join '; '))
} catch { Add-Line ("Consulta de driver falhou: {0}" -f $_.Exception.Message) }

try {
    $localPort = Get-PrinterPort -Name $unc -ErrorAction SilentlyContinue
    Add-Line ("Porta local UNC já existe: {0}" -f [bool]$localPort)
} catch { Add-Line ("Consulta de porta local falhou: {0}" -f $_.Exception.Message) }

try {
    $printers = @(Get-Printer -ErrorAction Stop)
    foreach ($printer in $printers) {
        if ($printer.Name -ieq $unc -or $printer.PortName -ieq $unc -or
            ($isHost -and $printer.Shared -and $printer.ShareName -ieq $Compartilhamento)) {
            Add-Line ("Fila relevante: nome={0}; share={1}; driver={2}; porta={3}; compartilhada={4}" -f
                $printer.Name,$printer.ShareName,$printer.DriverName,$printer.PortName,$printer.Shared)
            if ($isHost) {
                $hostDriver = Get-PrinterDriver -Name $printer.DriverName -ErrorAction SilentlyContinue
                if ($hostDriver) {
                    Add-Line ("Driver do servidor: tipo={0}; pacote={1}; arquitetura={2}" -f
                        $hostDriver.MajorVersion,$hostDriver.IsPackageAware,$hostDriver.PrinterEnvironment)
                }
            }
        }
    }
} catch { Add-Line ("Consulta de filas locais falhou: {0}" -f $_.Exception.Message) }

$printReg = 'HKLM:\SYSTEM\CurrentControlSet\Control\Print'
$rpcReg = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC'
$papReg = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint'
Add-Line ("RpcAuthnLevelPrivacyEnabled: {0}" -f (Read-Value $printReg 'RpcAuthnLevelPrivacyEnabled'))
Add-Line ("RpcProtocols: {0}; RpcUseNamedPipeProtocol: {1}" -f
    (Read-Value $rpcReg 'RpcProtocols'),(Read-Value $rpcReg 'RpcUseNamedPipeProtocol'))
Add-Line ("RestrictDriverInstallationToAdministrators: {0}" -f
    (Read-Value $papReg 'RestrictDriverInstallationToAdministrators'))
try {
    $smbConfig = if ($isHost) { Get-SmbServerConfiguration -ErrorAction Stop } else { Get-SmbClientConfiguration -ErrorAction Stop }
    Add-Line ("SMB requer assinatura: {0}" -f $smbConfig.RequireSecuritySignature)
} catch { Add-Line ("Configuração SMB indisponível: {0}" -f $_.Exception.Message) }

try {
    $events = @(Get-WinEvent -FilterHashtable @{
        LogName='Microsoft-Windows-PrintService/Admin'
        StartTime=(Get-Date).AddDays(-2)
    } -MaxEvents 8 -ErrorAction Stop)
    foreach ($event in $events) {
        Add-Line ("Evento PrintService/Admin: {0} ID={1} {2}" -f
            $event.TimeCreated,$event.Id,($event.Message -replace '\s+',' ').Trim())
    }
} catch { Add-Line 'PrintService/Admin: sem eventos recentes ou log indisponível.' }

Add-Line ''
Add-Line 'INTERPRETAÇÃO'
if (-not $smb) {
    Add-Line 'SMB 445 falhou: confira nome/IP, perfil de rede, compartilhamento e firewall no servidor.'
} elseif (-not $rpc) {
    Add-Line 'SMB funciona, RPC 135 falhou: verifique o serviço de impressão e as regras RPC no servidor.'
} else {
    Add-Line '445 e 135 respondem. Isso não comprova autenticação SMB, portas RPC dinâmicas, permissão da fila ou driver.'
}
if ($Driver -and -not @($driverMatches).Count) {
    Add-Line 'Instale no cliente, como administrador, o driver oficial compatível antes da porta local.'
}
Add-Line 'Se a conexão normal der 0x80070709, tente porta local UNC com driver instalado e registre a etapa exata de qualquer falha.'
Add-Line 'Se a porta local der acesso negado, confira primeiro se o processo foi elevado e se a conta autentica no servidor.'
Add-Line 'Não desative assinatura SMB, autenticação RPC ou restrições de driver sem evidência específica.'

$lines | Set-Content -LiteralPath $outputPath -Encoding UTF8
Write-Output "REPORT_PATH=$outputPath"
Write-Output "Relatório salvo em: $outputPath"
Write-Output ($lines -join [Environment]::NewLine)
