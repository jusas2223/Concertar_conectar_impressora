<#
================================================================================
 Arrumar Impressora VG
 Ferramenta Portátil para Diagnóstico, Conexão e Manutenção de Impressoras
 Compatibilidade: Windows 7 SP1, Windows 10, Windows 11 (32 e 64 bits)
 Tecnologias: Windows Forms, WMI, PrintUIEntry, WScript.Network, sc.exe
 Sem dependências externas, internet ou módulos adicionais.
================================================================================
#>

param(
    [string]$AppDirectory = "",
    [string]$LauncherPath = "",
    [string]$PrinterFixPath = "",
    [string]$NetworkFixPath = "",
    [string]$LocalPortInstallPath = "",
    [string]$PrinterConnectionPath = "",
    [string]$CompatibilityDiagnosisPath = ""
)

# ------------------------------------------------------------------------------
# 1. INICIALIZAÇÃO DE AMBIENTE E WINFORMS
# ------------------------------------------------------------------------------
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# Obter diretório do script de forma compatível com PS 2.0 / 3.0 / 5.1+ e executável
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($AppDirectory -and (Test-Path -Path $AppDirectory)) {
    $ScriptDir = $AppDirectory
} elseif (-not $ScriptDir -or ($ScriptDir -like "$env:TEMP*")) {
    $curDir = [System.IO.Directory]::GetCurrentDirectory()
    if ($curDir -and (Test-Path -Path $curDir)) {
        $ScriptDir = $curDir
    } elseif ($PSScriptRoot) {
        $ScriptDir = $PSScriptRoot
    }
}

# Verificar escrita de fato: uma pasta existente em um compartilhamento pode ser somente leitura.
$LogsDir = $null
$logCandidates = @(
    (Join-Path -Path $ScriptDir -ChildPath 'Logs'),
    (Join-Path -Path $env:LOCALAPPDATA -ChildPath 'AssistenteImpressoras\Logs'),
    (Join-Path -Path $env:TEMP -ChildPath 'AssistenteImpressoras_Logs')
)
foreach ($candidate in $logCandidates) {
    $probe = $null
    try {
        [IO.Directory]::CreateDirectory($candidate) | Out-Null
        $probe = Join-Path -Path $candidate -ChildPath ('.write-test-' + [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($probe, '')
        $LogsDir = $candidate
        break
    } catch {
        # Tentar o próximo destino gravável no computador local.
    } finally {
        if ($probe -and [IO.File]::Exists($probe)) {
            try { [IO.File]::Delete($probe) } catch {}
        }
    }
}
if (-not $LogsDir) { throw 'Não foi encontrada uma pasta gravável para os logs do assistente.' }

# Variáveis Globais de Estado
$global:SessionStartTime = Get-Date
$global:LogFileName = "Atendimento_" + ($global:SessionStartTime.ToString("yyyyMMdd_HHmmss")) + ".log"
$global:LogFilePath = Join-Path -Path $LogsDir -ChildPath $global:LogFileName
$global:SimulationMode = $false
$global:TempFilesCreated = New-Object System.Collections.ArrayList
$global:InitialPrinterState = @()

# ------------------------------------------------------------------------------
# 2. SISTEMA DE LOGS E AUDITORIA
# ------------------------------------------------------------------------------
function Write-AppLog {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [string]$Level = "INFO" # INFO, SUCESSO, AVISO, ERRO, SIMULACAO
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")

    # Sanitização: Garantir que senhas ou padrões sensíveis não sejam registrados
    $cleanMessage = $Message -replace '(?i)(senha|password|pwd)\s*=\s*[^\s;,]+', '$1=******'
    $cleanMessage = $cleanMessage -replace '(?i)(\/user:[^\s]+)\s+[^\s]+', '$1 ******'

    $logEntry = "[$timestamp] [$Level] $cleanMessage"

    # Gravar em arquivo físico
    try {
        $streamWriter = [System.IO.File]::AppendText($global:LogFilePath)
        $streamWriter.WriteLine($logEntry)
        $streamWriter.Dispose()
    } catch {}

    # Atualizar caixa de logs na interface se disponível
    if ($script:txtLogViewer -and -not $script:txtLogViewer.IsDisposed) {
        try {
            $script:txtLogViewer.AppendText($logEntry + [Environment]::NewLine)
            $script:txtLogViewer.SelectionStart = $script:txtLogViewer.TextLength
            $script:txtLogViewer.ScrollToCaret()
        } catch {}
    }
}

# Inicializar cabeçalho do arquivo de log
Write-AppLog -Message "================================================================================" -Level "INFO"
Write-AppLog -Message "Início de Atendimento - Arrumar Impressora VG" -Level "INFO"
Write-AppLog -Message "Computador: $env:COMPUTERNAME | Usuário: $env:USERNAME | Data: $((Get-Date).ToString())" -Level "INFO"
Write-AppLog -Message "Arquivo de Log: $global:LogFilePath" -Level "INFO"
Write-AppLog -Message "================================================================================" -Level "INFO"

# ------------------------------------------------------------------------------
# 3. FUNÇÕES NATIVAS DE REDE, WMI E SPOOLER COM TIMEOUT
# ------------------------------------------------------------------------------

# Testar se processo está elevado como Administrador
function Test-IsAdmin {
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Connect-PrinterServerAuthenticated {
    param([string]$Server, [string]$User, [string]$Password)

    if ($Server -notmatch '^[A-Za-z0-9._-]+$' -or -not $User -or -not $Password) {
        return @{ Success=$false; Code=-1; Message='Informe servidor, usuário e senha válidos.' }
    }
    if (-not (Test-TcpPortSafe -HostOrIp $Server -Port 445 -TimeoutMs 1500)) {
        return @{ Success=$false; Code=53; Message="A porta SMB 445 de $Server não respondeu." }
    }
    try {
        if (-not ('PrinterNetworkAuth' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PrinterNetworkAuth {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct NETRESOURCE {
        public int dwScope;
        public int dwType;
        public int dwDisplayType;
        public int dwUsage;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpLocalName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpRemoteName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpComment;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpProvider;
    }
    [DllImport("mpr.dll", EntryPoint="WNetAddConnection2W", CharSet=CharSet.Unicode)]
    public static extern int WNetAddConnection2(ref NETRESOURCE resource, string password, string userName, int flags);
}
'@ -ErrorAction Stop
        }
        $resource = New-Object PrinterNetworkAuth+NETRESOURCE
        $resource.dwType = 0
        $resource.lpRemoteName = '\\' + $Server + '\IPC$'
        $code = [PrinterNetworkAuth]::WNetAddConnection2([ref]$resource, $Password, $User, 0)
        if ($code -eq 0) { return @{ Success=$true; Code=0; Message="Sessão autenticada em $Server para este usuário do Windows." } }
        $message = switch ($code) {
            1219 { "Já existe conexão com $Server usando outra conta. Feche as pastas abertas e, no Prompt de Comando, execute 'net use' para listar as conexões. Remova somente as entradas de $Server com 'net use \\$Server\NOME_DO_COMPARTILHAMENTO /delete' e tente novamente." }
            1326 { 'Usuário ou senha recusados pelo servidor. Use a senha da conta do Windows, não o PIN.' }
            5    { 'O servidor recusou o acesso com esta conta.' }
            default { "Falha ao autenticar em $Server (código $code)." }
        }
        return @{ Success=$false; Code=$code; Message=$message }
    } catch {
        return @{ Success=$false; Code=-1; Message=$_.Exception.Message }
    }
}

function Request-PrinterServerCredential {
    param([string]$Server, [string]$InitialUser = '', [System.Windows.Forms.IWin32Window]$Parent)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Conta para impressora em $Server"
    $dialog.Size = New-Object System.Drawing.Size(455, 235)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $instruction = New-Object System.Windows.Forms.Label
    $instruction.Text = 'Use uma conta do PC que compartilha a impressora. Digite a senha da conta, não o PIN.'
    $instruction.Location = New-Object System.Drawing.Point(15, 12)
    $instruction.Size = New-Object System.Drawing.Size(410, 35)
    $dialog.Controls.Add($instruction)

    $userLabel = New-Object System.Windows.Forms.Label
    $userLabel.Text = 'Usuário:'
    $userLabel.Location = New-Object System.Drawing.Point(15, 57)
    $userLabel.AutoSize = $true
    $dialog.Controls.Add($userLabel)
    $userBox = New-Object System.Windows.Forms.TextBox
    $userBox.Location = New-Object System.Drawing.Point(95, 53)
    $userBox.Size = New-Object System.Drawing.Size(328, 23)
    $userBox.Text = if ($InitialUser) { $InitialUser } else { "$Server\" }
    $dialog.Controls.Add($userBox)

    $passLabel = New-Object System.Windows.Forms.Label
    $passLabel.Text = 'Senha:'
    $passLabel.Location = New-Object System.Drawing.Point(15, 92)
    $passLabel.AutoSize = $true
    $dialog.Controls.Add($passLabel)
    $passBox = New-Object System.Windows.Forms.TextBox
    $passBox.Location = New-Object System.Drawing.Point(95, 88)
    $passBox.Size = New-Object System.Drawing.Size(328, 23)
    $passBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($passBox)

    $connectButton = New-Object System.Windows.Forms.Button
    $connectButton.Text = 'Conectar'
    $connectButton.Location = New-Object System.Drawing.Point(15, 137)
    $connectButton.Size = New-Object System.Drawing.Size(110, 32)
    $connectButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($connectButton)
    $dialog.AcceptButton = $connectButton

    $withoutButton = New-Object System.Windows.Forms.Button
    $withoutButton.Text = 'Tentar sem senha'
    $withoutButton.Location = New-Object System.Drawing.Point(137, 137)
    $withoutButton.Size = New-Object System.Drawing.Size(135, 32)
    $withoutButton.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $dialog.Controls.Add($withoutButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = 'Cancelar'
    $cancelButton.Location = New-Object System.Drawing.Point(284, 137)
    $cancelButton.Size = New-Object System.Drawing.Size(135, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.CancelButton = $cancelButton

    try {
        $choice = $dialog.ShowDialog($Parent)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Ignore) { return @{ WithoutCredential=$true } }
        if ($choice -ne [System.Windows.Forms.DialogResult]::OK) { return @{ Cancelled=$true } }
        return @{ User=$userBox.Text.Trim(); Password=$passBox.Text }
    } finally { $dialog.Dispose() }
}

function Initialize-PrinterNetOnlyProcess {
    if ('PrinterNetOnlyProcess' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PrinterNetOnlyProcess {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb; public string lpReserved; public string lpDesktop; public string lpTitle;
        public int dwX; public int dwY; public int dwXSize; public int dwYSize;
        public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute;
        public int dwFlags; public short wShowWindow; public short cbReserved2;
        public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError;
    }
    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId;
    }
    [DllImport("advapi32.dll", EntryPoint="CreateProcessWithLogonW", CharSet=CharSet.Unicode, SetLastError=true)]
    public static extern bool Create(string user, string domain, string password, int logonFlags,
        string application, string commandLine, int creationFlags, IntPtr environment,
        string directory, ref STARTUPINFO startup, out PROCESS_INFORMATION process);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool GetExitCodeProcess(IntPtr handle, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool TerminateProcess(IntPtr handle, uint exitCode);
    [DllImport("kernel32.dll", SetLastError=true)] public static extern bool CloseHandle(IntPtr handle);
}
'@ -ErrorAction Stop
}

# Teste de Socket TCP com timeout rígido (evita congelamento da UI)
function Test-TcpPortSafe {
    param(
        [string]$HostOrIp,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $client.BeginConnect($HostOrIp, $Port, $null, $null)
        $success = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if (-not $success) {
            $client.Close()
            return $false
        }
        $client.EndConnect($ar)
        $client.Close()
        return $true
    } catch {
        try { $client.Close() } catch {}
        return $false
    }
}

# Teste de Ping ICMP com timeout (1500ms)
function Test-HostPingSafe {
    param(
        [string]$HostOrIp,
        [int]$TimeoutMs = 1500
    )
    try {
        $ping = New-Object System.Net.NetworkInformation.Ping
        $reply = $ping.Send($HostOrIp, $TimeoutMs)
        return ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success)
    } catch {
        return $false
    }
}

# Resolver nome DNS com tratamento de erro
function Resolve-HostSafe {
    param([string]$HostOrIp)
    try {
        $entry = [System.Net.Dns]::GetHostEntry($HostOrIp)
        return $entry.HostName
    } catch {
        return $HostOrIp
    }
}

# Obter lista de impressoras instaladas via WMI (compatível com Win 7 SP1 e versões superiores)
function Get-InstalledPrintersWmi {
    try {
        return @(Get-CimInstance -ClassName Win32_Printer -OperationTimeoutSec 4 -ErrorAction Stop)
    } catch {
        Write-AppLog -Message "Falha ao obter impressoras locais: $($_.Exception.Message)" -Level "ERRO"
        return @()
    }
}

function Get-CurrentWindowsBuild {
    $key = $null
    try {
        $key = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey('SOFTWARE\Microsoft\Windows NT\CurrentVersion', $false)
        if ($key) { return [int]$key.GetValue('CurrentBuildNumber', '0') }
    } catch {} finally {
        if ($key) { $key.Close() }
    }
    return [Environment]::OSVersion.Version.Build
}

function Get-NetworkAccessActionMode {
    param([int]$BuildNumber)
    if ($BuildNumber -lt 22000) { return 'Win10PrinterDiagnosis' }
    return 'Network24H2Repair'
}

function Get-SharedPrinterAccessDiagnosis {
    param([string]$UNCPath, [string]$AlternateHost = '')
    if ($UNCPath -notmatch '^\\\\([^\\]+)\\([^\\]+)$') {
        return @{ Valid=$false; Message='Selecione uma impressora compartilhada no formato \\SERVIDOR\Fila.' }
    }
    $server = $matches[1]
    $share = $matches[2]
    $hosts = @($server)
    if ($AlternateHost -and $AlternateHost -ne $server -and $AlternateHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $hosts += $AlternateHost
    }
    $checks = @()
    foreach ($hostName in $hosts) {
        $smb = Test-TcpPortSafe -HostOrIp $hostName -Port 445 -TimeoutMs 1500
        $rpc = Test-TcpPortSafe -HostOrIp $hostName -Port 135 -TimeoutMs 1500
        $checks += [pscustomobject]@{ Host=$hostName; SMB=$smb; RPC=$rpc }
    }
    $usable = $checks | Where-Object SMB | Select-Object -First 1
    $detail = @($checks | ForEach-Object {
        '{0}: SMB 445 {1}; RPC 135 {2}' -f $_.Host,$(if ($_.SMB) {'aberta'} else {'fechada'}),$(if ($_.RPC) {'aberta'} else {'fechada'})
    }) -join "`n"
    $queueStatus = 'não consultada'
    $driverName = ''
    $localDriverAvailable = $false
    $remoteJob = $null
    if ($usable -and $usable.RPC -and (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
        try {
            $remoteJob = Start-Job -ArgumentList $server,$share -ScriptBlock {
                param($computer,$queueShare)
                try {
                    $printer = Get-Printer -ComputerName $computer -ErrorAction Stop |
                        Where-Object { $_.ShareName -ieq $queueShare } | Select-Object -First 1
                    if ($printer) {
                        @{ Status='acessível'; DriverName=[string]$printer.DriverName }
                    } else {
                        @{ Status='não encontrada'; DriverName='' }
                    }
                } catch {
                    $accessDenied = [string]$_.Exception.Message -match 'acesso.*negado|access.*denied|0x80070005'
                    @{ Status=$(if ($accessDenied) { 'acesso negado' } else { 'consulta falhou' }); DriverName=''; Error=[string]$_.Exception.Message }
                }
            }
            if (Wait-Job -Job $remoteJob -Timeout 6) {
                $remote = Receive-Job -Job $remoteJob -ErrorAction Stop | Select-Object -First 1
                $queueStatus = [string]$remote.Status
                $driverName = [string]$remote.DriverName
                if ($driverName) {
                    $localDriverAvailable = @(Get-InstalledDriversSafe | Where-Object { $_ -ieq $driverName }).Count -gt 0
                }
            } else {
                Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue
                $queueStatus = 'consulta excedeu 6 segundos'
            }
        } catch { $queueStatus = 'consulta falhou' }
        finally { if ($remoteJob) { Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue } }
    }
    $nextStep = if (-not $usable) {
        'O compartilhamento não responde em SMB 445. Confira rede, firewall e nome/IP antes de instalar.'
    } elseif (-not $usable.RPC) {
        'SMB responde, mas RPC 135 não. A instalação automática pode falhar; verifique o RPC no servidor. A porta local pode funcionar se o driver estiver instalado neste PC.'
    } elseif ($queueStatus -eq 'acesso negado') {
        'A consulta de gerenciamento remoto foi negada. Isso não comprova falta de permissão para imprimir. Confira autenticação, driver e privilégio de administrador na instalação.'
    } elseif ($driverName -and -not $localDriverAvailable) {
        "O driver '$driverName' não está instalado neste cliente. Use um pacote compatível do fabricante e execute a instalação como administrador antes de tentar novamente."
    } else {
        'A rede responde. Se a conexão normal falha, tente a porta local com o driver correto instalado e autenticação válida no servidor.'
    }
    $adminLine = if (Test-IsAdmin) { 'sim' } else { 'não; a instalação de driver remoto geralmente exige elevação' }
    $driverLine = if ($driverName) { "$driverName (instalado neste cliente: $(if ($localDriverAvailable) {'sim'} else {'não'}))" } else { 'não identificado nesta consulta' }
    return @{
        Valid=$true; Server=$server; Share=$share; SMBReachable=[bool]$usable
        SuggestedHost=$(if ($usable) { [string]$usable.Host } else { '' }); RemoteQueueStatus=$queueStatus
        DriverName=$driverName; LocalDriverAvailable=$localDriverAvailable
        Message="Caminho: $UNCPath`n$detail`nConsulta remota da fila: $queueStatus`nDriver da fila: $driverLine`nAdministrador neste PC: $adminLine`n`n$nextStep"
    }
}

# Obter drivers instalados no Windows
function Get-InstalledDriversSafe {
    $driversList = New-Object System.Collections.ArrayList
    # PrintManagement consulta o cadastro real do Spooler. O WMI pode omitir
    # drivers instalados quando outra consulta ja retornou alguns resultados.
    try {
        if (Get-Command Get-PrinterDriver -ErrorAction SilentlyContinue) {
            foreach ($d in @(Get-PrinterDriver -ErrorAction Stop)) {
                if ($d.Name -and -not $driversList.Contains([string]$d.Name)) {
                    [void]$driversList.Add([string]$d.Name)
                }
            }
        }
    } catch {}
    try {
        $wmiDrivers = Get-WmiObject -Class Win32_PrinterDriver -ErrorAction SilentlyContinue
        if ($wmiDrivers) {
            foreach ($d in $wmiDrivers) {
                $dName = $d.Name
                # Limpar nome do driver (muitas vezes vem no formato "DriverName,3,Windows x64")
                if ($dName -match "^([^,]+)") {
                    $dName = $matches[1]
                }
                if ($dName -and -not $driversList.Contains($dName)) {
                    [void]$driversList.Add($dName)
                }
            }
        }
    } catch {}

    # Se os cadastros de driver estiverem indisponiveis, usar as filas locais.
    if ($driversList.Count -eq 0) {
        $printers = Get-InstalledPrintersWmi
        foreach ($p in $printers) {
            if ($p.DriverName -and -not $driversList.Contains($p.DriverName)) {
                [void]$driversList.Add($p.DriverName)
            }
        }
    }

    $sorted = $driversList | Sort-Object
    return $sorted
}

# Obter trabalhos na fila de impressão
function Get-PrintJobsSafe {
    try {
        $jobs = Get-WmiObject -Class Win32_PrintJob -ErrorAction SilentlyContinue
        return $jobs
    } catch {
        return @()
    }
}

# Executar comando PrintUIEntry nativo com tratamento de erros
function Invoke-PrintUICommand {
    param([string]$Arguments, [switch]$NoWait)

    Write-AppLog -Message "Executando rundll32 printui.dll,PrintUIEntry $Arguments" -Level "INFO"
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Comando não executado: rundll32 printui.dll,PrintUIEntry $Arguments" -Level "SIMULACAO"
        return 0
    }

    try {
        if ($NoWait) {
            Start-Process -FilePath 'rundll32.exe' -ArgumentList "printui.dll,PrintUIEntry $Arguments" -ErrorAction Stop | Out-Null
            return 0
        }
        $proc = Start-Process -FilePath "rundll32.exe" -ArgumentList "printui.dll,PrintUIEntry $Arguments" -PassThru -Wait
        return $proc.ExitCode
    } catch {
        Write-AppLog -Message "Erro ao disparar PrintUIEntry: $($_.Exception.Message)" -Level "ERRO"
        return -1
    }
}

# Definir impressora como padrão usando WScript.Network e fallback WMI
function Set-DefaultPrinterSafe {
    param([string]$PrinterName)

    Write-AppLog -Message "Definindo impressora como padrão: $PrinterName" -Level "INFO"
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seria definida como padrão: $PrinterName" -Level "SIMULACAO"
        return $true
    }

    $success = $false
    try {
        $netObj = New-Object -ComObject WScript.Network
        $netObj.SetDefaultPrinter($PrinterName)
        $success = $true
    } catch {
        Write-AppLog -Message "WScript.Network SetDefaultPrinter falhou. Tentando WMI..." -Level "AVISO"
        try {
            $escapedName = $PrinterName.Replace("\", "\\").Replace("'", "''")
            $wmiP = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name = '$escapedName'"
            if ($wmiP) {
                $res = $wmiP.SetDefaultPrinter()
                if ($res.ReturnValue -eq 0) { $success = $true }
            }
        } catch {
            Write-AppLog -Message "WMI SetDefaultPrinter também falhou: $($_.Exception.Message)" -Level "ERRO"
        }
    }
    return $success
}

# Conectar impressora compartilhada por caminho UNC (\\SERVIDOR\SHARE)
# ==============================================================================
# INSTALACAO AUTOMATICA DE DRIVERS VIA REDE (\\SERVIDOR\print$) & CONEXAO UNC
# ==============================================================================
function Install-RemotePrinterDriverFromPrintShare {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Server,
        [Parameter(Mandatory=$false)]
        [string]$ShareName = ""
    )

    $cleanServer = $Server.Trim().TrimStart("\").TrimEnd("\")
    if (-not $cleanServer) { return @{ Success = $false; Message = "Servidor inv" + [char]0xE1 + "lido." } }
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] O driver da impressora '$ShareName' seria verificado no servidor $cleanServer; nenhuma política, pacote ou driver será alterado." -Level "SIMULACAO"
        return @{ Success = $true; Simulated = $true; Count = 0; Message = "Instalação simulada." }
    }

    # 2. Teste rapido de conectividade SMB na porta 445 (timeout 400ms para evitar travamento)
    $tcpOk = Test-TcpPortSafe -HostOrIp $cleanServer -Port 445 -TimeoutMs 400

    if (-not $tcpOk) {
        Write-AppLog -Message ("Servidor $cleanServer n" + [char]0xE3 + "o respondeu na porta 445 (SMB/Compartilhamento).") -Level "AVISO"
        return @{ Success = $false; Message = ("Servidor $cleanServer inacess" + [char]0xED + "vel na porta 445") }
    }

    # 3. Localizar compartilhamento de drivers print$
    $arch = if ([Environment]::Is64BitOperatingSystem) { "x64" } else { "W32X86" }
    $pccPath = "\\$cleanServer\print$\$arch\PCC"

    if (-not (Test-Path $pccPath)) {
        $altPcc = "\\$cleanServer\print$\PCC"
        if (Test-Path $altPcc) { $pccPath = $altPcc }
        else {
            Write-AppLog -Message ("Compartilhamento print$\PCC n" + [char]0xE3 + "o acess" + [char]0xED + "vel em $cleanServer.") -Level "AVISO"
            return @{ Success = $false; Message = "Compartilhamento print$ inacessivel" }
        }
    }

    Write-AppLog -Message ("Buscando pacotes de driver em \\$cleanServer\print$...") -Level "INFO"
    $cabs = Get-ChildItem -Path $pccPath -Filter "*.cab" -ErrorAction SilentlyContinue
    if (-not $cabs -or $cabs.Count -eq 0) {
        Write-AppLog -Message ("Nenhum pacote .cab encontrado no reposit" + [char]0xF3 + "rio print$ de $cleanServer.") -Level "AVISO"
        return @{ Success = $false; Message = "Nenhum pacote .cab encontrado" }
    }

    # Consultar o driver exato da fila remota: nomes de CAB ou marcas não identificam um modelo com segurança.
    if (-not $ShareName) {
        return @{ Success = $false; Message = "Compartilhamento da impressora não informado." }
    }
    $remoteJob = $null
    $driverName = ''
    try {
        $escapedShare = $ShareName.Replace("'", "''")
        $remoteJob = Get-WmiObject -Class Win32_Printer -ComputerName $cleanServer -Filter "ShareName = '$escapedShare'" -AsJob -ErrorAction Stop
        if (-not (Wait-Job -Job $remoteJob -Timeout 5)) {
            Stop-Job -Job $remoteJob -ErrorAction SilentlyContinue
            throw "Tempo esgotado ao consultar o driver remoto."
        }
        $remotePrinter = Receive-Job -Job $remoteJob -ErrorAction Stop |
            Where-Object { $_.ShareName -eq $ShareName } | Select-Object -First 1
        $driverName = ([string]$remotePrinter.DriverName).Trim()
    } catch {
        Write-AppLog -Message "Não foi possível identificar o driver da fila '$ShareName' em ${cleanServer}: $($_.Exception.Message)" -Level "AVISO"
    } finally {
        if ($remoteJob) { Remove-Job -Job $remoteJob -Force -ErrorAction SilentlyContinue }
    }
    if (-not $driverName -and (Get-Command Get-Printer -ErrorAction SilentlyContinue)) {
        $printJob = $null
        try {
            $printJob = Start-Job -ArgumentList $cleanServer,$ShareName -ScriptBlock {
                param($srv,$sh)
                Get-Printer -ComputerName $srv -ErrorAction Stop |
                    Where-Object { $_.ShareName -eq $sh } | Select-Object -First 1
            }
            if (-not (Wait-Job -Job $printJob -Timeout 5)) {
                Stop-Job -Job $printJob -ErrorAction SilentlyContinue
                throw 'Tempo esgotado ao consultar a fila pelo Spooler.'
            }
            $printerViaSpooler = Receive-Job -Job $printJob -ErrorAction Stop
            $driverName = ([string]$printerViaSpooler.DriverName).Trim()
            if ($driverName) {
                Write-AppLog -Message "Driver da fila '$ShareName' identificado pelo Spooler: $driverName" -Level "INFO"
            }
        } catch {
            Write-AppLog -Message "Consulta alternativa do driver em ${cleanServer} falhou: $($_.Exception.Message)" -Level "AVISO"
        } finally {
            if ($printJob) { Remove-Job -Job $printJob -Force -ErrorAction SilentlyContinue }
        }
    }
    if (-not $driverName) {
        return @{ Success = $false; Message = "O driver remoto nao foi identificado por WMI nem pelo Spooler." }
    }
    if (Get-InstalledDriversSafe | Where-Object { $_ -eq $driverName }) {
        Write-AppLog -Message "Driver '$driverName' já instalado localmente." -Level "INFO"
        return @{ Success = $true; Count = 0; DriverName = $driverName; Message = "Driver já instalado." }
    }

    # Inspecionar os CABs até encontrar um INF que declare o modelo exato. Instalar apenas esse driver.
    $tempBase = Join-Path $env:TEMP ("PnpDriver_" + [Guid]::NewGuid().ToString("N"))
    try {
        New-Item -ItemType Directory -Path $tempBase -Force -ErrorAction Stop | Out-Null
        $cabIndex = 0
        foreach ($cab in @($cabs | Sort-Object LastWriteTime -Descending)) {
            $cabIndex++
            $cabDest = Join-Path $tempBase ("pacote_" + $cabIndex)
            New-Item -ItemType Directory -Path $cabDest -Force -ErrorAction Stop | Out-Null
            $expand = Start-Process -FilePath "expand.exe" -ArgumentList "-R `"$($cab.FullName)`" -F:* `"$cabDest`"" -Wait -WindowStyle Hidden -PassThru -ErrorAction Stop
            if ($expand.ExitCode -ne 0) {
                Write-AppLog -Message "Falha ao extrair '$($cab.Name)' (código $($expand.ExitCode))." -Level "AVISO"
                continue
            }
            foreach ($inf in @(Get-ChildItem -Path $cabDest -Filter "*.inf" -Recurse -ErrorAction SilentlyContinue)) {
                $infBytes = [System.IO.File]::ReadAllBytes($inf.FullName)
                $hasBom = ($infBytes.Length -ge 2 -and (($infBytes[0] -eq 0xFF -and $infBytes[1] -eq 0xFE) -or ($infBytes[0] -eq 0xFE -and $infBytes[1] -eq 0xFF))) -or
                          ($infBytes.Length -ge 3 -and $infBytes[0] -eq 0xEF -and $infBytes[1] -eq 0xBB -and $infBytes[2] -eq 0xBF)
                $infText = if ($hasBom) { [System.IO.File]::ReadAllText($inf.FullName) } else { [System.Text.Encoding]::Default.GetString($infBytes) }
                if ($infText.IndexOf($driverName, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

                $catMatch = [regex]::Match($infText, '(?im)^\s*CatalogFile(?:\.[^=\r\n]+)?\s*=\s*([^\r\n;]+)')
                $catName = if ($catMatch.Success) { $catMatch.Groups[1].Value.Trim().Trim('"') } else { "" }
                $catFile = if ($catName) { Get-ChildItem -Path $cabDest -Filter $catName -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 } else { $null }
                $signed = $false
                if ($catFile) {
                    $signature = Get-AuthenticodeSignature -FilePath $catFile.FullName
                    $signed = ($signature.Status -eq [System.Management.Automation.SignatureStatus]::Valid)
                }
                if (-not $signed) {
                    $answer = [System.Windows.Forms.MessageBox]::Show($form,
                        "O pacote '$($cab.Name)' declara o driver '$driverName', mas não foi possível validar sua assinatura. Deseja instalá-lo mesmo assim?",
                        "Confirmar driver sem assinatura validada", [System.Windows.Forms.MessageBoxButtons]::YesNo,
                        [System.Windows.Forms.MessageBoxIcon]::Warning)
                    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                        Write-AppLog -Message "Instalação do driver '$driverName' recusada: assinatura não validada." -Level "AVISO"
                        continue
                    }
                }

                Write-AppLog -Message "Instalando somente o driver '$driverName' de '$($cab.Name)' ($($inf.Name))." -Level "INFO"
                $exitCode = Invoke-PrintUICommand -Arguments "/ia /m `"$driverName`" /f `"$($inf.FullName)`""
                $installed = $false
                for ($attempt = 0; $attempt -lt 3; $attempt++) {
                    $installed = @(Get-InstalledDriversSafe | Where-Object { $_ -eq $driverName }).Count -gt 0
                    if ($installed) { break }
                    Start-Sleep -Milliseconds 500
                }
                if ($exitCode -eq 0 -and $installed) {
                    Write-AppLog -Message "Driver '$driverName' instalado e confirmado no Windows." -Level "SUCESSO"
                    return @{ Success = $true; Count = 1; DriverName = $driverName; Message = "Driver instalado e confirmado." }
                }
                Write-AppLog -Message "Instalação de '$driverName' não confirmada (PrintUI código $exitCode; instalado=$installed)." -Level "AVISO"
            }
        }
    } catch {
        Write-AppLog -Message "Erro ao identificar ou instalar driver '$driverName': $($_.Exception.Message)" -Level "ERRO"
        return @{ Success = $false; Count = 0; DriverName = $driverName; Message = $_.Exception.Message }
    } finally {
        if (Test-Path -Path $tempBase) {
            Remove-Item -Path $tempBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    return @{ Success = $false; Count = 0; DriverName = $driverName; Message = "Nenhum pacote compatível foi instalado ou confirmado." }
}

function Test-PrinterConnectionInstalled {
    param([string]$UNCPath)
    if ($UNCPath -notmatch '^\\\\([^\\]+)\\([^\\]+)$') { return $false }
    $server = $matches[1]
    $share = $matches[2]
    try {
        foreach ($printer in @(Get-InstalledPrintersWmi)) {
            if (-not $printer.Network) { continue }
            if ([string]$printer.Name -ieq $UNCPath) { return $true }
            if (([string]$printer.ServerName).TrimStart('\') -ieq $server -and
                [string]$printer.ShareName -ieq $share) { return $true }
        }
    } catch {
        Write-AppLog -Message "Nao foi possivel conferir a fila local: $($_.Exception.Message)" -Level "AVISO"
    }
    return $false
}

function Test-PrinterShareInstalled {
    param([string]$UNCPath, [object[]]$InstalledPrinters)
    if ($UNCPath -notmatch '^\\\\([^\\]+)\\([^\\]+)$') { return $false }
    $hostName = $matches[1]
    $shareName = $matches[2]
    foreach ($printer in @($InstalledPrinters)) {
        if ([string]$printer.Name -ieq $UNCPath) { return $true }
        if ([string]$printer.PortName -ieq $UNCPath) { return $true }
        if ($printer.Network -and ([string]$printer.ServerName).TrimStart('\') -ieq $hostName -and
            [string]$printer.ShareName -ieq $shareName) { return $true }
        if ($hostName -ieq $env:COMPUTERNAME -and $printer.Shared -and
            [string]$printer.ShareName -ieq $shareName) { return $true }
    }
    return $false
}

function Wait-PrinterConnectionInstalled {
    param([string]$UNCPath, [int]$Attempts = 6)
    for ($attempt = 0; $attempt -lt $Attempts; $attempt++) {
        if (Test-PrinterConnectionInstalled -UNCPath $UNCPath) { return $true }
        if ($script:cancelPrinterConnection) { return $false }
        if ($attempt -lt ($Attempts - 1)) { Start-Sleep -Milliseconds 500 }
    }
    return $false
}

function Invoke-LocalPortInstallElevated {
    param([string]$UNCPath, [string]$DriverName, [string]$QueueName, [string]$InfPath = '')

    if ($global:SimulationMode) {
        return @{ Success=$false; Simulated=$true; Message='A instalação por porta local foi bloqueada no modo Simulação.' }
    }
    if (-not $LocalPortInstallPath -or -not (Test-Path -LiteralPath $LocalPortInstallPath)) {
        return @{ Success=$false; Message='O instalador interno da porta local não foi encontrado no EXE.' }
    }
    $requestPath = Join-Path $env:TEMP ('PrinterLocalPort_' + [Guid]::NewGuid().ToString('N') + '.request.xml')
    $resultPath = Join-Path $env:TEMP ('PrinterLocalPort_' + [Guid]::NewGuid().ToString('N') + '.result.xml')
    $process = $null
    try {
        @{ UNCPath=$UNCPath; DriverName=$DriverName; QueueName=$QueueName; InfPath=$InfPath } |
            Export-Clixml -LiteralPath $requestPath -Force -ErrorAction Stop
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}" -ResultPath "{2}"' -f $LocalPortInstallPath,$requestPath,$resultPath
        Write-AppLog -Message "Instalando fila local '$QueueName' na porta $UNCPath com o driver '$DriverName'." -Level 'INFO'
        $start = @{ FilePath='powershell.exe'; ArgumentList=$arguments; WindowStyle='Hidden'; PassThru=$true; ErrorAction='Stop' }
        if (-not (Test-IsAdmin)) { $start.Verb = 'RunAs' }
        $result = $null
        $portServer = ([regex]::Match($UNCPath,'^\\\\([^\\]+)\\')).Groups[1].Value
        if ((Test-IsAdmin) -and $script:authenticatedPrinterServer -ieq $portServer -and $script:authenticatedPrinterCredential) {
            Write-AppLog -Message "Instalação por porta local usará a identidade de rede $($script:authenticatedPrinterCredential.UserName)." -Level 'INFO'
            $result = Invoke-BoundedPrinterAttempt -UNCPath $UNCPath -Method LocalPort -LocalPortRequestPath $requestPath -TimeoutSeconds 60 -NetworkCredential $script:authenticatedPrinterCredential -CredentialServer $portServer
            if ($result.TimedOut -or $result.Cancelled) { return $result }
        } else { $process = Start-Process @start }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($process -and -not $process.HasExited) {
            if ($watch.Elapsed.TotalSeconds -ge 60) {
                try { $process.Kill() } catch {}
                Write-AppLog -Message 'Instalação por porta local excedeu 60 segundos e foi interrompida.' -Level 'AVISO'
                return @{ Success=$false; Message='A instalação por porta local excedeu 60 segundos. Confira o Spooler e tente novamente após identificar a etapa no log.' }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if (-not $result) {
            if (-not (Test-Path -LiteralPath $resultPath)) {
                return @{ Success=$false; Message="O instalador terminou com código $($process.ExitCode), sem retornar um resultado. Verifique a autorização de administrador." }
            }
            $result = Import-Clixml -LiteralPath $resultPath -ErrorAction Stop
        }
        if ($result.Success) {
            $confirmed = $null
            for ($attempt = 0; $attempt -lt 6; $attempt++) {
                if (Get-Command Get-Printer -ErrorAction SilentlyContinue) {
                    $localQueue = Get-Printer -Name $QueueName -ErrorAction SilentlyContinue
                    if ($localQueue -and [string]$localQueue.PortName -ieq $UNCPath) { $confirmed = $localQueue }
                }
                if (-not $confirmed) {
                    $confirmed = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue |
                        Where-Object { [string]$_.Name -ieq $QueueName -and [string]$_.PortName -ieq $UNCPath } |
                        Select-Object -First 1
                }
                if ($confirmed) { break }
                if ($attempt -lt 5) { Start-Sleep -Milliseconds 500 }
            }
            if (-not $confirmed) {
                return @{ Success=$false; Message='O instalador informou sucesso, mas a fila não apareceu no Windows deste PC.' }
            }
            Write-AppLog -Message "Fila local '$QueueName' confirmada na porta $UNCPath. Método da porta: $($result.PortMethod)." -Level 'SUCESSO'
            return @{ Success=$true; Code=0; ConnectedUNC=$QueueName; PortUNC=$UNCPath; LocalPort=$true; Message='Fila local instalada e confirmada.' }
        }
        $detail = "Etapa: $($result.Stage)`nErro: $($result.Message)`nCódigo: $($result.HResult)`nIdentificador: $($result.ErrorId)`nMétodo da porta: $($result.PortMethod)`nCódigo nativo: $($result.NativeCode)`nErro CIM anterior: $($result.CimPortError)"
        Write-AppLog -Message ("Instalação por porta local falhou: " + ($detail -replace "`r?`n", ' | ')) -Level 'AVISO'
        return @{ Success=$false; Message=$detail; Stage=[string]$result.Stage; HResult=[string]$result.HResult }
    } catch {
        Write-AppLog -Message "Não foi possível iniciar o instalador de porta local: $($_.Exception.Message)" -Level 'ERRO'
        return @{ Success=$false; Message=$_.Exception.Message }
    } finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $requestPath,$resultPath -Force -ErrorAction SilentlyContinue
    }
}

function Show-LocalPortFallbackDialog {
    param([string]$UNCPath, [string]$AlternateHost = '', [string]$PreviousError = '', [string]$SuggestedDriverName = '', [switch]$Direct)

    if ($global:SimulationMode) { return $null }
    if ($UNCPath -notmatch '^\\\\([^\\]+)\\([^\\]+)$') { return $null }
    $server = $matches[1]
    $share = $matches[2]

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'Instalar impressora compartilhada por porta local'
    $dialog.Size = New-Object System.Drawing.Size(640, 520)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font('Segoe UI', 9)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Location = New-Object System.Drawing.Point(16, 14)
    $intro.Size = New-Object System.Drawing.Size(590, 61)
    $intro.Text = if ($Direct) {
        "Esta opção cria neste computador uma fila local apontando para a impressora compartilhada. Selecione um driver compatível com este PC. O Windows pedirá autorização de administrador."
    } else {
        "A conexão normal falhou. Esta opção cria uma fila local apontando para o mesmo compartilhamento. Selecione um driver compatível com este PC. O Windows pedirá autorização de administrador."
    }
    $dialog.Controls.Add($intro)

    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Location = New-Object System.Drawing.Point(16, 84)
    $lblPath.AutoSize = $true
    $lblPath.Text = 'Porta (caminho da impressora compartilhada):'
    $dialog.Controls.Add($lblPath)
    $cmbPath = New-Object System.Windows.Forms.ComboBox
    $cmbPath.Location = New-Object System.Drawing.Point(16, 105)
    $cmbPath.Size = New-Object System.Drawing.Size(590, 24)
    $cmbPath.DropDownStyle = 'DropDown'
    [void]$cmbPath.Items.Add($UNCPath)
    if ($AlternateHost -and $AlternateHost -ne $server -and $AlternateHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$cmbPath.Items.Add(('\\' + $AlternateHost + '\' + $share))
    }
    $cmbPath.SelectedIndex = 0
    $dialog.Controls.Add($cmbPath)

    $lblQueue = New-Object System.Windows.Forms.Label
    $lblQueue.Location = New-Object System.Drawing.Point(16, 143)
    $lblQueue.AutoSize = $true
    $lblQueue.Text = 'Nome que a impressora terá neste PC:'
    $dialog.Controls.Add($lblQueue)
    $txtQueue = New-Object System.Windows.Forms.TextBox
    $txtQueue.Location = New-Object System.Drawing.Point(16, 164)
    $txtQueue.Size = New-Object System.Drawing.Size(590, 24)
    $txtQueue.Text = "$share em $server"
    $dialog.Controls.Add($txtQueue)

    $lblDriver = New-Object System.Windows.Forms.Label
    $lblDriver.Location = New-Object System.Drawing.Point(16, 202)
    $lblDriver.AutoSize = $true
    $lblDriver.Text = 'Driver para Windows 10 (nome exato do modelo):'
    $dialog.Controls.Add($lblDriver)
    $cmbDriver = New-Object System.Windows.Forms.ComboBox
    $cmbDriver.Location = New-Object System.Drawing.Point(16, 223)
    $cmbDriver.Size = New-Object System.Drawing.Size(590, 24)
    $cmbDriver.DropDownStyle = 'DropDown'
    foreach ($driverName in @(Get-InstalledDriversSafe)) { [void]$cmbDriver.Items.Add([string]$driverName) }
    if ($SuggestedDriverName) {
        $cmbDriver.Text = $SuggestedDriverName
    } elseif ($share -ieq 'MP' -and $cmbDriver.Items.Contains('MP-4200 TH')) {
        $cmbDriver.Text = 'MP-4200 TH'
    }
    $dialog.Controls.Add($cmbDriver)
    $btnRefreshDrivers = New-Object System.Windows.Forms.Button
    $btnRefreshDrivers.Text = 'Atualizar drivers'
    $btnRefreshDrivers.Location = New-Object System.Drawing.Point(470, 194)
    $btnRefreshDrivers.Size = New-Object System.Drawing.Size(136, 26)
    $btnRefreshDrivers.Add_Click({
        $selectedDriver = $cmbDriver.Text.Trim()
        $cmbDriver.Items.Clear()
        foreach ($availableDriver in @(Get-InstalledDriversSafe)) {
            [void]$cmbDriver.Items.Add([string]$availableDriver)
        }
        $cmbDriver.Text = $selectedDriver
        if ($selectedDriver -and $cmbDriver.Items.Contains($selectedDriver)) {
            $status.ForeColor = [System.Drawing.Color]::DarkGreen
            $status.Text = "Driver '$selectedDriver' encontrado neste PC."
        } else {
            $status.ForeColor = [System.Drawing.Color]::DarkRed
            $status.Text = "Driver '$selectedDriver' não encontrado. Instale o driver para este Windows."
        }
    })
    $dialog.Controls.Add($btnRefreshDrivers)

    $btnVendorInstaller = New-Object System.Windows.Forms.Button
    $btnVendorInstaller.Text = 'Instalar driver...'
    $btnVendorInstaller.Location = New-Object System.Drawing.Point(310, 194)
    $btnVendorInstaller.Size = New-Object System.Drawing.Size(150, 26)
    $btnVendorInstaller.Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Filter = 'Instalador do fabricante (*.exe;*.msi)|*.exe;*.msi'
        try {
            if ($picker.ShowDialog($dialog) -ne [System.Windows.Forms.DialogResult]::OK) { return }
            $installerPath = $picker.FileName
            $signature = Get-AuthenticodeSignature -LiteralPath $installerPath -ErrorAction Stop
            if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
                [System.Windows.Forms.MessageBox]::Show($dialog,
                    "O Windows não validou a assinatura deste instalador ($($signature.Status)). Escolha o pacote oficial assinado do fabricante.",
                    'Instalador não validado', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            $installerArgs = @{ Verb='RunAs'; PassThru=$true; ErrorAction='Stop' }
            if ([IO.Path]::GetExtension($installerPath) -ieq '.msi') {
                $installerArgs.FilePath = 'msiexec.exe'
                $installerArgs.ArgumentList = '/i "' + $installerPath + '"'
            } else { $installerArgs.FilePath = $installerPath }
            $status.ForeColor = [System.Drawing.Color]::DarkBlue
            $status.Text = 'Instalador do fabricante aberto. Conclua as telas dele.'
            $vendorProcess = Start-Process @installerArgs
            $wait = [Diagnostics.Stopwatch]::StartNew()
            while (-not $vendorProcess.HasExited -and $wait.Elapsed.TotalSeconds -lt 180) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 200
            }
            $vendorProcess.Dispose()
            $driverWanted = $cmbDriver.Text.Trim()
            $cmbDriver.Items.Clear()
            foreach ($availableDriver in @(Get-InstalledDriversSafe)) { [void]$cmbDriver.Items.Add([string]$availableDriver) }
            $cmbDriver.Text = $driverWanted
            if ($driverWanted -and $cmbDriver.Items.Contains($driverWanted)) {
                $status.ForeColor = [System.Drawing.Color]::DarkGreen
                $status.Text = "Driver '$driverWanted' instalado e confirmado neste PC."
            } else {
                $status.ForeColor = [System.Drawing.Color]::DarkGoldenrod
                $status.Text = "Driver '$driverWanted' ainda não apareceu. Conclua o instalador e clique em 'Atualizar drivers'."
            }
        } catch {
            $status.ForeColor = [System.Drawing.Color]::DarkRed
            $status.Text = "Instalador não concluído: $($_.Exception.Message)"
        } finally { $picker.Dispose() }
    })
    $dialog.Controls.Add($btnVendorInstaller)

    $lblInf = New-Object System.Windows.Forms.Label
    $lblInf.Location = New-Object System.Drawing.Point(16, 261)
    $lblInf.AutoSize = $true
    $lblInf.Text = 'INF oficial do fabricante (opcional se o driver já estiver instalado):'
    $dialog.Controls.Add($lblInf)
    $txtInf = New-Object System.Windows.Forms.TextBox
    $txtInf.Location = New-Object System.Drawing.Point(16, 282)
    $txtInf.Size = New-Object System.Drawing.Size(485, 24)
    $dialog.Controls.Add($txtInf)
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = 'Procurar...'
    $btnBrowse.Location = New-Object System.Drawing.Point(510, 280)
    $btnBrowse.Size = New-Object System.Drawing.Size(96, 28)
    $btnBrowse.Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Filter = 'Arquivos de driver (*.inf)|*.inf'
        if ($picker.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) { $txtInf.Text = $picker.FileName }
        $picker.Dispose()
    })
    $dialog.Controls.Add($btnBrowse)

    $lblNote = New-Object System.Windows.Forms.Label
    $lblNote.Location = New-Object System.Drawing.Point(16, 319)
    $lblNote.Size = New-Object System.Drawing.Size(590, 48)
    $lblNote.Text = 'A porta local ainda precisa de acesso à rede e permissão de impressão no PC servidor. Se selecionar um INF, digite o nome do modelo que aparece no pacote. Depois da instalação, faça uma página de teste.'
    $dialog.Controls.Add($lblNote)

    $lblNote.Height = 24
    $btnServerDriver = New-Object System.Windows.Forms.Button
    $btnServerDriver.Text = 'Receber driver do servidor (sem download da internet)'
    $btnServerDriver.Location = New-Object System.Drawing.Point(16, 343)
    $btnServerDriver.Size = New-Object System.Drawing.Size(590, 27)
    $btnServerDriver.Add_Click({
        $btnServerDriver.Enabled = $false
        try {
            $port = $cmbPath.Text.Trim()
            $credential = $null
            if ($port -notmatch '^\\\\([^\\]+)\\[^\\]+$') { throw 'Informe o caminho \\SERVIDOR\Fila.' }
            $driverServer = $matches[1]
            if ($script:authenticatedPrinterServer -ieq $driverServer) { $credential = $script:authenticatedPrinterCredential }
            $script:cancelPrinterConnection = $false
            $status.Text = 'Recebendo o driver preparado no servidor...'
            $received = Invoke-BoundedPrinterAttempt -UNCPath $port -Method InstallDriver -TimeoutSeconds 40 -NetworkCredential $credential -CredentialServer $driverServer
            Write-AppLog -Message "Receber driver: $($received.Message)" -Level $(if ($received.Success) { 'SUCESSO' } else { 'AVISO' })
            $status.Text = $received.Message
            if ($received.Success) {
                $cmbDriver.Items.Clear()
                foreach ($availableDriver in @(Get-InstalledDriversSafe)) { [void]$cmbDriver.Items.Add([string]$availableDriver) }
                $cmbDriver.SelectedItem = $received.DriverName
                $status.ForeColor = [System.Drawing.Color]::DarkGreen
            } else { $status.ForeColor = [System.Drawing.Color]::DarkRed }
        } catch { $status.Text = $_.Exception.Message }
        finally { $btnServerDriver.Enabled = $true }
    })
    $dialog.Controls.Add($btnServerDriver)

    $status = New-Object System.Windows.Forms.Label
    $status.Location = New-Object System.Drawing.Point(16, 372)
    $status.Size = New-Object System.Drawing.Size(590, 29)
    $status.ForeColor = [System.Drawing.Color]::DarkRed
    $status.Text = ''
    $dialog.Controls.Add($status)

    $btnInstall = New-Object System.Windows.Forms.Button
    $btnInstall.Text = 'Instalar por porta local'
    $btnInstall.Location = New-Object System.Drawing.Point(302, 402)
    $btnInstall.Size = New-Object System.Drawing.Size(174, 30)
    $dialog.Controls.Add($btnInstall)
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = New-Object System.Drawing.Point(486, 402)
    $btnCancel.Size = New-Object System.Drawing.Size(120, 30)
    $btnCancel.Add_Click({ $dialog.Close() })
    $dialog.Controls.Add($btnCancel)

    $script:localPortDialogResult = $null
    $btnInstall.Add_Click({
        $port = $cmbPath.Text.Trim()
        $queue = $txtQueue.Text.Trim()
        $driver = $cmbDriver.Text.Trim()
        $inf = $txtInf.Text.Trim()
        if ($port -notmatch '^\\\\[^\\]+\\[^\\]+$' -or -not $queue -or -not $driver) {
            $status.Text = 'Preencha o caminho \\SERVIDOR\Fila, o nome local e o driver.'
            return
        }
        if ($inf -and -not (Test-Path -LiteralPath $inf -PathType Leaf)) {
            $status.Text = 'O arquivo INF selecionado não existe.'
            return
        }
        if (-not $inf -and -not (@(Get-InstalledDriversSafe) -icontains $driver)) {
            $message = "O driver '$driver' não está instalado neste computador.`n`nInstale primeiro o driver oficial compatível com este Windows, clique em 'Atualizar drivers' e tente novamente."
            if ($share -ieq 'MP' -and $driver -ieq 'MP-4200 TH') {
                $officialInstaller = Join-Path $ScriptDir 'Drivers\MP4200TH_v5\Spooler_Bematech\BematechSpoolerDrivers_x64_v5.0.0.4.exe'
                if (Test-Path -LiteralPath $officialInstaller -PathType Leaf) {
                    $message += "`n`nInstalador x64 do fabricante incluído na pasta:`n$officialInstaller"
                }
            }
            $status.ForeColor = [System.Drawing.Color]::DarkRed
            $status.Text = "Driver '$driver' ausente neste PC."
            [System.Windows.Forms.MessageBox]::Show($dialog, $message, 'Driver necessário', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $btnInstall.Enabled = $false
        $btnCancel.Enabled = $false
        $status.ForeColor = [System.Drawing.Color]::DarkBlue
        $status.Text = 'Aguarde a autorização do Windows e a confirmação da fila...'
        [System.Windows.Forms.Application]::DoEvents()
        $attempt = Invoke-LocalPortInstallElevated -UNCPath $port -DriverName $driver -QueueName $queue -InfPath $inf
        if ($attempt.Success) {
            $script:localPortDialogResult = $attempt
            $dialog.Close()
            return
        }
        $status.ForeColor = [System.Drawing.Color]::DarkRed
        $status.Text = 'A instalação falhou. Veja a mensagem para corrigir e tentar novamente.'
        [System.Windows.Forms.MessageBox]::Show($dialog, [string]$attempt.Message, 'Falha na instalação', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        $btnInstall.Enabled = $true
        $btnCancel.Enabled = $true
    })
    try {
        [void]$dialog.ShowDialog($form)
        return $script:localPortDialogResult
    } finally {
        $dialog.Dispose()
    }
}

function Offer-Win10LocalPortFallback {
    param([string]$UNCPath, [string]$AlternateHost = '', [object]$PreviousResult)
    if ((Get-CurrentWindowsBuild) -ge 22000 -or $global:SimulationMode -or
        -not $PreviousResult -or $PreviousResult.Success -or $PreviousResult.Code -in @(53,1223)) {
        return @{ Handled=$false; Result=$null }
    }
    $message = "O Windows 10 não registrou $UNCPath pela conexão normal.`n`n$($PreviousResult.Message)`n`nDeseja instalar uma fila local apontando para esse compartilhamento? É necessário ter o driver compatível instalado neste PC."
    $answer = [System.Windows.Forms.MessageBox]::Show($form, $message, 'Alternativa para Windows 10', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
        return @{ Handled=$true; Result=$null }
    }
    return @{ Handled=$true; Result=(Show-LocalPortFallbackDialog -UNCPath $UNCPath -AlternateHost $AlternateHost -PreviousError $PreviousResult.Message -SuggestedDriverName $PreviousResult.DriverName) }
}

function Invoke-BoundedPrinterAttempt {
    param(
        [string]$UNCPath,
        [ValidateSet('AddPrinter','WScript','PrintUI','PublishDriver','InstallDriver','LocalPort')][string]$Method,
        [int]$TimeoutSeconds = 25,
        [pscredential]$NetworkCredential,
        [string]$CredentialServer = '',
        [string]$LocalPortRequestPath = ''
    )
    $resultPath = ''
    $process = $null
    $nativeProcess = $null
    try {
        if ($UNCPath -match '"') { return @{ Success=$false; Message='O caminho contém aspas inválidas.' } }
        if ($Method -eq 'LocalPort') {
            if (-not $LocalPortInstallPath -or -not (Test-Path -LiteralPath $LocalPortInstallPath) -or
                -not $LocalPortRequestPath -or -not (Test-Path -LiteralPath $LocalPortRequestPath) -or $LocalPortRequestPath -match '"') {
                return @{ Success=$false; Message='Rotina ou dados da instalação por porta local ausentes.' }
            }
            $resultPath = Join-Path $env:TEMP ('PrinterConnect_' + [Guid]::NewGuid().ToString('N') + '.xml')
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -RequestPath "{1}" -ResultPath "{2}"' -f $LocalPortInstallPath,$LocalPortRequestPath,$resultPath
            $executable = Join-Path $PSHOME 'powershell.exe'
        } elseif ($Method -in @('AddPrinter','WScript','PublishDriver','InstallDriver')) {
            if (-not $PrinterConnectionPath -or -not (Test-Path -LiteralPath $PrinterConnectionPath)) {
                return @{ Success=$false; Message='Rotina interna de conexão não encontrada no EXE.' }
            }
            $resultPath = Join-Path $env:TEMP ('PrinterConnect_' + [Guid]::NewGuid().ToString('N') + '.xml')
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -UNCPath "{1}" -ResultPath "{2}" -Method {3}' -f $PrinterConnectionPath,$UNCPath,$resultPath,$Method
            $executable = Join-Path $PSHOME 'powershell.exe'
        } else {
            $arguments = 'printui.dll,PrintUIEntry /in /q /n "' + $UNCPath + '"'
            $executable = Join-Path $env:WINDIR 'System32\rundll32.exe'
        }
        if ($NetworkCredential) {
            Initialize-PrinterNetOnlyProcess
            $network = $NetworkCredential.GetNetworkCredential()
            $domain = if ($network.Domain) { $network.Domain } else { $CredentialServer }
            if (-not $domain) { return @{ Success=$false; Message='Informe a conta no formato SERVIDOR\usuario para autenticar a impressão.' } }
            $startInfo = New-Object PrinterNetOnlyProcess+STARTUPINFO
            $startInfo.cb = [Runtime.InteropServices.Marshal]::SizeOf($startInfo)
            $nativeProcess = New-Object PrinterNetOnlyProcess+PROCESS_INFORMATION
            $commandLine = '"' + $executable + '" ' + $arguments
            $created = [PrinterNetOnlyProcess]::Create($network.UserName,$domain,$network.Password,2,
                $executable,$commandLine,0x08000000,[IntPtr]::Zero,$env:WINDIR,[ref]$startInfo,[ref]$nativeProcess)
            $network = $null
            if (-not $created) {
                $code = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
                return @{ Success=$false; Message="Não foi possível iniciar conexão com credenciais de rede (Windows $code)."; Code=$code }
            }
        } else {
            $process = Start-Process -FilePath $executable -ArgumentList $arguments -WindowStyle Hidden -PassThru -ErrorAction Stop
        }
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while ($true) {
            $exited = if ($nativeProcess) { [PrinterNetOnlyProcess]::WaitForSingleObject($nativeProcess.hProcess,0) -eq 0 } else { $process.HasExited }
            if ($exited) { break }
            if ($script:cancelPrinterConnection) {
                try {
                    if ($nativeProcess) { [void][PrinterNetOnlyProcess]::TerminateProcess($nativeProcess.hProcess,1223) }
                    else { $process.Kill(); [void]$process.WaitForExit(2000) }
                } catch {}
                return @{ Success=$false; Cancelled=$true; Message='Conexão cancelada pelo usuário.' }
            }
            if ($timer.Elapsed.TotalSeconds -ge $TimeoutSeconds) {
                $stageMessage = ''
                if ($resultPath -and (Test-Path -LiteralPath ($resultPath + '.progress'))) {
                    try { $stageMessage = ' Etapa: ' + [IO.File]::ReadAllText($resultPath + '.progress') } catch {}
                }
                try {
                    if ($nativeProcess) { [void][PrinterNetOnlyProcess]::TerminateProcess($nativeProcess.hProcess,1460) }
                    else { $process.Kill(); [void]$process.WaitForExit(2000) }
                } catch {}
                return @{ Success=$false; TimedOut=$true; Message="A tentativa $Method excedeu $TimeoutSeconds segundos e foi interrompida.$stageMessage" }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $exitCode = if ($nativeProcess) { $nativeExit = [uint32]0; [void][PrinterNetOnlyProcess]::GetExitCodeProcess($nativeProcess.hProcess,[ref]$nativeExit); $nativeExit } else { $process.ExitCode }
        if ($Method -in @('AddPrinter','WScript','PublishDriver','InstallDriver','LocalPort')) {
            if (-not (Test-Path -LiteralPath $resultPath)) {
                return @{ Success=$false; Message="$Method terminou com código $exitCode, sem resultado." }
            }
            return (Import-Clixml -LiteralPath $resultPath -ErrorAction Stop)
        }
        return @{ Success=($exitCode -eq 0); Message="PrintUI terminou com código $exitCode." }
    } catch {
        return @{ Success=$false; Message=$_.Exception.Message }
    } finally {
        if ($process) { $process.Dispose() }
        if ($nativeProcess) {
            [void][PrinterNetOnlyProcess]::CloseHandle($nativeProcess.hThread)
            [void][PrinterNetOnlyProcess]::CloseHandle($nativeProcess.hProcess)
        }
        if ($resultPath) { Remove-Item -LiteralPath $resultPath,($resultPath + '.progress') -Force -ErrorAction SilentlyContinue }
    }
}

function Connect-UNCPrinterSafe {
    param([string]$UNCPath, [string]$AlternateHost = "")

    Write-AppLog -Message "Iniciando conexao com impressora UNC: $UNCPath" -Level "INFO"
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULACAO] Nenhuma impressora foi conectada: $UNCPath" -Level "SIMULACAO"
        return @{ Success=$true; Simulated=$true; Code=0; Message="Conexao simulada." }
    }

    $cleanUNC = $UNCPath.Trim()
    if ($cleanUNC -notmatch '^\\\\([^\\]+)\\([^\\]+)$') {
        return @{ Success=$false; Code=87; Message="Caminho UNC invalido: $cleanUNC" }
    }
    $server = $matches[1]
    $share = $matches[2]
    $networkCredential = if ($script:authenticatedPrinterServer -ieq $server) { $script:authenticatedPrinterCredential } else { $null }
    if ($networkCredential) {
        Write-AppLog -Message "Conexão de impressão em $server usará credenciais de rede de $($networkCredential.UserName)." -Level 'INFO'
    } else {
        Write-AppLog -Message "Conexão de impressão em $server sem credenciais explícitas do servidor; identidade local: $env:USERDOMAIN\$env:USERNAME." -Level 'AVISO'
    }

    $candidates = @($cleanUNC)
    if (-not $AlternateHost -and $server -notmatch '^\d{1,3}(\.\d{1,3}){3}$') {
        try {
            $resolved = [System.Net.Dns]::GetHostAddresses($server) |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.IPAddressToString -notlike '127.*' } |
                Select-Object -First 1
            if ($resolved) { $AlternateHost = $resolved.IPAddressToString }
        } catch {}
    }
    if ($AlternateHost -and $AlternateHost -ne $server -and
        $AlternateHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
        $candidates += ('\\' + $AlternateHost + '\' + $share)
    }

    $reachable = @($candidates | Where-Object {
        $hostPart = ([regex]::Match($_, '^\\\\([^\\]+)\\')).Groups[1].Value
        if (Test-TcpPortSafe -HostOrIp $hostPart -Port 445 -TimeoutMs 1500) {
            Write-AppLog -Message "SMB 445 acessivel em $hostPart." -Level "INFO"
            $true
        } else {
            Write-AppLog -Message "SMB 445 inacessivel em $hostPart." -Level "AVISO"
            $false
        }
    })
    if ($reachable.Count -eq 0) {
        return @{ Success=$false; Code=53; Message="O servidor nao responde na porta SMB 445 pelo nome nem pelo IP. Verifique o compartilhamento e a rede." }
    }
    if (Test-PrinterConnectionInstalled -UNCPath $cleanUNC) {
        return @{ Success=$true; Code=0; ConnectedUNC=$cleanUNC; Message="Impressora ja conectada neste usuario." }
    }
    try {
        $localQueue = Get-InstalledPrintersWmi |
            Where-Object { -not $_.Network -and $candidates -icontains [string]$_.PortName } |
            Select-Object -First 1
        if ($localQueue) {
            Write-AppLog -Message "Fila local '$($localQueue.Name)' já usa a porta $($localQueue.PortName)." -Level 'INFO'
            return @{ Success=$true; Code=0; ConnectedUNC=[string]$localQueue.Name; PortUNC=[string]$localQueue.PortName; LocalPort=$true; Message='Fila local já instalada neste PC.' }
        }
    } catch {
        Write-AppLog -Message "Não foi possível conferir as filas locais: $($_.Exception.Message)" -Level 'AVISO'
    }

    # Uma transferência de driver pode ser tentada uma vez, dentro do prazo total.
    $failures = @()
    $timer = [Diagnostics.Stopwatch]::StartNew()
    foreach ($candidate in $reachable) {
        $addPrinterInvalidName = $false
        foreach ($method in @('AddPrinter','WScript','PrintUI')) {
            if ($script:cancelPrinterConnection) {
                Write-AppLog -Message "Conexão cancelada antes de tentar $method em $candidate." -Level 'AVISO'
                return @{ Success=$false; Code=1223; Message='Conexão cancelada.' }
            }
            $remaining = [int][Math]::Floor(70 - $timer.Elapsed.TotalSeconds)
            if ($remaining -le 0) {
                Write-AppLog -Message "Prazo total de 70 segundos atingido para $cleanUNC." -Level 'AVISO'
                return @{ Success=$false; Code=1460; Message='A conexão excedeu 70 segundos e foi interrompida. Confira o Spooler no computador que compartilha a impressora.' }
            }
            $perAttempt = [Math]::Min($(if ($method -eq 'PrintUI') { 25 } else { 20 }), $remaining)
            Write-AppLog -Message "Tentando $method em $candidate (limite: $perAttempt segundos)." -Level 'INFO'
            $attempt = Invoke-BoundedPrinterAttempt -UNCPath $candidate -Method $method -TimeoutSeconds $perAttempt -NetworkCredential $networkCredential -CredentialServer $server
            if ($attempt.Cancelled) {
                Write-AppLog -Message "Conexão cancelada em $candidate." -Level 'AVISO'
                return @{ Success=$false; Code=1223; Message='Conexão cancelada.' }
            }
            if ($attempt.TimedOut) {
                Write-AppLog -Message "Tempo esgotado em $candidate via ${method}: $($attempt.Message)" -Level 'AVISO'
                return @{ Success=$false; Code=1460; Message='O Windows demorou demais para conectar. A tentativa foi interrompida; verifique a fila e o Spooler no computador que compartilha a impressora.' }
            }
            $confirmationAttempts = if ($attempt.Success) { 6 } else { 2 }
            if (Wait-PrinterConnectionInstalled -UNCPath $candidate -Attempts $confirmationAttempts) {
                Write-AppLog -Message "Conexão $candidate confirmada no Windows via $method." -Level 'SUCESSO'
                return @{ Success=$true; Code=0; ConnectedUNC=$candidate; Message='Impressora conectada e confirmada.' }
            }
            if ($script:cancelPrinterConnection) {
                Write-AppLog -Message "Conexão cancelada após $method em $candidate." -Level 'AVISO'
                return @{ Success=$false; Code=1223; Message='Conexão cancelada.' }
            }
            $failure = "$method em ${candidate}: $($attempt.Message) A fila não foi registrada."
            $failures += $failure
            Write-AppLog -Message $failure -Level 'AVISO'
            if ([string]$attempt.Message -match 'driver necessário|driver.*não pode ser recuperado|driver.*cannot be retrieved|required driver.*not available') {
                Write-AppLog -Message "Buscando o driver preparado no servidor para $candidate." -Level 'INFO'
                $remaining = [int][Math]::Floor(70 - $timer.Elapsed.TotalSeconds)
                if ($remaining -le 0) { return @{ Success=$false; Code=1460; Message='Prazo da conexão esgotado antes de receber o driver.' } }
                $transfer = Invoke-BoundedPrinterAttempt -UNCPath $candidate -Method InstallDriver -TimeoutSeconds ([Math]::Min(30,$remaining)) -NetworkCredential $networkCredential -CredentialServer $server
                Write-AppLog -Message "Driver do servidor: $($transfer.Message)" -Level $(if ($transfer.Success) { 'SUCESSO' } else { 'AVISO' })
                if ($transfer.Cancelled) { return @{ Success=$false; Code=1223; Message='Transferência cancelada.' } }
                if ($transfer.TimedOut) { return @{ Success=$false; Code=1460; Message=$transfer.Message } }
                if ($transfer.Success) {
                    $remaining = [int][Math]::Floor(70 - $timer.Elapsed.TotalSeconds)
                    if ($remaining -gt 0) {
                        $retry = Invoke-BoundedPrinterAttempt -UNCPath $candidate -Method AddPrinter -TimeoutSeconds ([Math]::Min(20,$remaining)) -NetworkCredential $networkCredential -CredentialServer $server
                        if ($retry.Cancelled) { return @{ Success=$false; Code=1223; Message='Conexão cancelada.' } }
                        if (Wait-PrinterConnectionInstalled -UNCPath $candidate -Attempts 2) {
                            Write-AppLog -Message "Fila $candidate confirmada após preparar o driver local." -Level 'SUCESSO'
                            return @{ Success=$true; Code=0; ConnectedUNC=$candidate; Message='Driver instalado e impressora conectada.' }
                        }
                        Write-AppLog -Message "Nova tentativa após preparar o driver: $($retry.Message)" -Level 'AVISO'
                    }
                    return @{ Success=$false; Code=1797; DriverName=$transfer.DriverName; Message="O driver '$($transfer.DriverName)' está instalado neste PC, mas a conexão padrão ainda falhou. A alternativa por porta local pode usar esse driver sem baixar um instalador." }
                }
                return @{ Success=$false; Code=1797; Message="O Windows não conseguiu obter o driver pela conexão padrão. Transferência pelo EXE: $($transfer.Message)" }
            }
            $invalidName = [string]$attempt.Message -match '0x80070709|nome da impressora é inválido|nome de servidor ou de impressora é inválido|printer name is invalid'
            if ($method -eq 'AddPrinter') { $addPrinterInvalidName = [bool]$invalidName }
            if ($method -eq 'WScript' -and $addPrinterInvalidName -and $invalidName) {
                Write-AppLog -Message "Add-Printer e WScript retornaram nome inválido em $candidate. PrintUI não será repetido para este endereço; confirme o driver local e tente a porta local." -Level 'AVISO'
                break
            }
        }
    }

    $reason = ($failures | Select-Object -Last 2) -join '; '
    Write-AppLog -Message "Falha confirmada para $cleanUNC. $reason" -Level "ERRO"
    if (($failures -join ' ') -match '0x80070709|nome da impressora é inválido|printer name is invalid') {
        return @{ Success=$false; Code=1801; Message="O Windows rejeitou a conexão com 0x80070709. O compartilhamento pode existir, mas o cliente não conseguiu registrar a fila ou obter o driver. Use o diagnóstico e a instalação por porta local." }
    }
    return @{ Success=$false; Code=-1; Message="O Windows não registrou $cleanUNC. Confira o nome da fila, as permissões e o Spooler no computador que a compartilha. Detalhes no log." }
}

function Ensure-RemotePrinterConnectedAndDriverInstalled {
    param([string]$UNCPath)
    if (-not $UNCPath -or $UNCPath -notlike "\\*") { return @{ Success = $true } }
    $cleanUNC = $UNCPath.Trim()
    $server = ""
    $share = ""
    if ($cleanUNC -match "^\\\\([^\\]+)\\(.+)$") {
        $server = $matches[1]
        $share = $matches[2]
    }
    if ($server.ToUpper() -eq $env:COMPUTERNAME.ToUpper() -or $server -eq "127.0.0.1" -or $server.ToLower() -eq "localhost") {
        return @{ Success = $true }
    }
    $isInstalled = $false
    try {
        [System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null
        $installed = [System.Drawing.Printing.PrinterSettings]::InstalledPrinters
        foreach ($inst in $installed) {
            if ($inst.ToUpper() -eq $cleanUNC.ToUpper()) {
                $isInstalled = $true; break
            }
        }
    } catch {}
    if ($isInstalled) {
        Write-AppLog -Message ("Impressora remota '$cleanUNC' j" + [char]0xE1 + " est" + [char]0xE1 + " conectada no Windows.") -Level "INFO"
        return @{ Success = $true }
    }
    Write-AppLog -Message ("Impressora remota '$cleanUNC' detectada. Baixando driver do servidor e conectando...") -Level "INFO"
    $res = Connect-UNCPrinterSafe -UNCPath $cleanUNC
    return $res
}

# Criar Porta de Impressora TCP/IP nativa via WMI (sem depender de Add-PrinterPort do Win8+)
function New-TCPIPPrinterPortSafe {
    param(
        [string]$IPAddress,
        [int]$PortNumber = 9100,
        [string]$Protocol = "RAW", # RAW ou LPR
        [string]$QueueName = "lp"
    )

    $portName = "IP_$IPAddress"
    Write-AppLog -Message "Verificando/Criando porta TCP/IP: $portName (IP: $IPAddress, Porta: $PortNumber, Proto: $Protocol)" -Level "INFO"

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seria criada a porta TCP/IP $portName" -Level "SIMULACAO"
        return @{ Success = $true; PortName = $portName }
    }

    try {
        # Verificar se a porta já existe
        $existing = Get-WmiObject -Class Win32_TCPIPPrinterPort -Filter "Name = '$portName'" -ErrorAction SilentlyContinue
        if ($existing) {
            Write-AppLog -Message "Porta TCP/IP $portName já existe no sistema." -Level "INFO"
            return @{ Success = $true; PortName = $portName }
        }

        # Criar nova instância via classe WMI Win32_TCPIPPrinterPort
        $portClass = [wmiclass]"\\.\root\cimv2:Win32_TCPIPPrinterPort"
        $newPort = $portClass.CreateInstance()
        $newPort.Name = $portName
        $newPort.Protocol = if ($Protocol -eq "LPR") { 2 } else { 1 }
        $newPort.HostAddress = $IPAddress
        $newPort.PortNumber = [int]$PortNumber
        $newPort.SNMPEnabled = $false
        if ($Protocol -eq "LPR") {
            $newPort.Queue = $QueueName
        }
        $newPort.Put() | Out-Null

        Write-AppLog -Message "Porta TCP/IP $portName criada com sucesso via WMI." -Level "SUCESSO"
        return @{ Success = $true; PortName = $portName }
    } catch {
        Write-AppLog -Message "Falha ao criar porta TCP/IP via WMI: $($_.Exception.Message)" -Level "ERRO"
        return @{ Success = $false; Message = $_.Exception.Message }
    }
}

# Instalar Impressora Local (Porta TCP/IP ou USB) utilizando driver existente
function Install-LocalPrinterSafe {
    param(
        [string]$PrinterName,
        [string]$PortName,
        [string]$DriverName
    )

    Write-AppLog -Message "Instalando impressora local '$PrinterName' usando porta '$PortName' e driver '$DriverName'" -Level "INFO"

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seria instalada a impressora '$PrinterName'" -Level "SIMULACAO"
        return @{ Success = $true; Message = "Simulação de instalação bem-sucedida." }
    }

    # Usar PrintUIEntry /if /b "Nome" /f "" /r "Porta" /m "Driver"
    $args = "/if /b `"$PrinterName`" /f `"`" /r `"$PortName`" /m `"$DriverName`""
    $exitCode = Invoke-PrintUICommand -Arguments $args

    if ($exitCode -eq 0) {
        Write-AppLog -Message "Impressora '$PrinterName' instalada com sucesso." -Level "SUCESSO"
        return @{ Success = $true; Message = "Impressora instalada com sucesso." }
    } else {
        $msgErro = Traduzir-ErroImpressao -ExitCode $exitCode
        Write-AppLog -Message "Falha ao instalar impressora ($exitCode): $msgErro" -Level "ERRO"
        return @{ Success = $false; Message = $msgErro; Code = $exitCode }
    }
}

# Tradução dos códigos de erro mais frequentes de impressão no Windows
function Traduzir-ErroImpressao {
    param([int]$ExitCode)

    switch ($ExitCode) {
        0          { return "Operação realizada com sucesso." }
        5          { return "Acesso negado (0x00000005). Verifique credenciais ou permissões no compartilhamento." }
        2          { return "Caminho ou impressora não encontrada (0x00000002). O nome da impressora ou o servidor está incorreto." }
        6          { return "Identificador inválido (0x00000006). A impressora pode ter sido removida do servidor." }
        87         { return "Parâmetro incorreto (0x00000057). O driver selecionado é incompatível ou o formato do comando é inválido." }
        1797       { return "Driver de impressora desconhecido (0x00000705). O driver correto precisa ser instalado previamente no computador." }
        283        { return "Erro 0x0000011b (RpcAuthnLevelExemption / PrintNightmare). O servidor ou cliente bloqueia conexão RPC sem criptografia. Recomenda-se atualizar ambos os sistemas ou revisar políticas de Point and Print via GPO." }
        3012       { return "A impressora já existe no sistema com este nome." }
        default    { return "Erro de impressão retornado pelo Windows (Código $ExitCode). Consulte os logs para detalhes." }
    }
}

# ------------------------------------------------------------------------------
# 4. FUNÇÕES DE REPARO DO SPOOLER E FILA DE IMPRESSÃO
# ------------------------------------------------------------------------------

# Reiniciar serviço Spooler com validação de status
function Restart-SpoolerServiceSafe {
    Write-AppLog -Message "Iniciando procedimento de reinício do Spooler de Impressão..." -Level "INFO"

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seria reiniciado o serviço Spooler (sc stop / sc start)" -Level "SIMULACAO"
        return $true
    }

    try {
        # 1. Parar serviço
        Start-Process -FilePath "sc.exe" -ArgumentList "stop spooler" -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 2

        # 2. Configurar inicialização automática
        Start-Process -FilePath "sc.exe" -ArgumentList "config spooler start= auto" -Wait -WindowStyle Hidden

        # 3. Iniciar serviço
        Start-Process -FilePath "sc.exe" -ArgumentList "start spooler" -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 2

        # 4. Validar se está ativo
        $svc = Get-Service -Name "spooler" -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) {
            Write-AppLog -Message "Serviço Spooler reiniciado e em execução normal." -Level "SUCESSO"
            return $true
        } else {
            Write-AppLog -Message "Spooler não iniciou. Verifique dependências (HTTP, RPCSS)." -Level "AVISO"
            return $false
        }
    } catch {
        Write-AppLog -Message "Falha ao reiniciar Spooler: $($_.Exception.Message)" -Level "ERRO"
        return $false
    }
}

# Limpar com segurança estritamente os arquivos *.SPL e *.SHD da pasta spool
function Clear-SpoolFilesSafe {
    Write-AppLog -Message "Iniciando limpeza de arquivos travados no Spooler..." -Level "INFO"

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seriam apagados arquivos *.SHD e *.SPL de System32\spool\PRINTERS" -Level "SIMULACAO"
        return $true
    }

    try {
        # Parar Spooler antes de apagar arquivos
        Start-Process -FilePath "sc.exe" -ArgumentList "stop spooler" -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 2

        $spoolFolder = Join-Path -Path $env:SystemRoot -ChildPath "System32\spool\PRINTERS"
        if (Test-Path -Path $spoolFolder) {
            $filesRemoved = 0
            $items = Get-ChildItem -Path $spoolFolder -Include *.spl, *.shd -Recurse -Force -ErrorAction SilentlyContinue
            foreach ($item in $items) {
                try {
                    Remove-Item -Path $item.FullName -Force -ErrorAction SilentlyContinue
                    $filesRemoved++
                } catch {}
            }
            Write-AppLog -Message "Total de arquivos de fila purgados: $filesRemoved" -Level "SUCESSO"
        }

        # Reiniciar Spooler
        Start-Process -FilePath "sc.exe" -ArgumentList "start spooler" -Wait -WindowStyle Hidden
        Start-Sleep -Seconds 2

        return $true
    } catch {
        Write-AppLog -Message "Erro durante a limpeza de arquivos de spool: $($_.Exception.Message)" -Level "ERRO"
        return $false
    }
}

# Remover flags de Pausa e Modo Offline de todas as impressoras
function Reset-PrintersStateSafe {
    Write-AppLog -Message "Removendo estados 'Pausada' e 'Trabalhar Offline' das impressoras..." -Level "INFO"

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seriam redefinidos atributos Paused e WorkOffline via WMI" -Level "SIMULACAO"
        return $true
    }

    try {
        $printers = Get-WmiObject -Class Win32_Printer -ErrorAction SilentlyContinue
        foreach ($p in $printers) {
            $changed = $false
            if ($p.Paused) {
                try {
                    $p.Resume() | Out-Null
                    $changed = $true
                    Write-AppLog -Message "Impressora '$($p.Name)': Pausa removida." -Level "INFO"
                } catch {}
            }
            if ($p.WorkOffline) {
                try {
                    $p.WorkOffline = $false
                    $p.Put() | Out-Null
                    $changed = $true
                    Write-AppLog -Message "Impressora '$($p.Name)': Modo Offline desativado." -Level "INFO"
                } catch {}
            }
        }
        return $true
    } catch {
        Write-AppLog -Message "Erro ao redefinir estados de impressoras: $($_.Exception.Message)" -Level "ERRO"
        return $false
    }
}

# ------------------------------------------------------------------------------
# 5. CONSTRUÇÃO DA INTERFACE GRÁFICA (WINDOWS FORMS - 1024x768 COMPACTO)
# ------------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Arrumar Impressora VG [v1.9.9]"
$form.Size = New-Object System.Drawing.Size(990, 680)
$form.MinimumSize = New-Object System.Drawing.Size(900, 620)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

# Painel Superior (Cabeçalho com Identificação e Modo Simulação)
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlHeader.Height = 55
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(33, 43, 54)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "Arrumar Impressora VG"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(12, 8)
$pnlHeader.Controls.Add($lblTitle)

$isAdmin = Test-IsAdmin
$adminText = if ($isAdmin) { "Administrador: SIM" } else { "Administrador: NÃO (Privilégio Limitado)" }
$lblSubTitle = New-Object System.Windows.Forms.Label
$lblSubTitle.Text = "Host: $env:COMPUTERNAME | Usuário: $env:USERNAME | $adminText"
$lblSubTitle.ForeColor = [System.Drawing.Color]::FromArgb(180, 195, 210)
$lblSubTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSubTitle.AutoSize = $true
$lblSubTitle.Location = New-Object System.Drawing.Point(14, 30)
$pnlHeader.Controls.Add($lblSubTitle)

$chkSimulation = New-Object System.Windows.Forms.CheckBox
$chkSimulation.Text = "Somente diagnosticar (Modo Simulação)"
$chkSimulation.ForeColor = [System.Drawing.Color]::Gold
$chkSimulation.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chkSimulation.AutoSize = $true
$chkSimulation.Location = New-Object System.Drawing.Point(680, 16)
$chkSimulation.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$chkSimulation.Add_CheckedChanged({
    $global:SimulationMode = $chkSimulation.Checked
    if ($global:SimulationMode) {
        Write-AppLog -Message "MODO SIMULAÇÃO ATIVADO: impressoras, drivers, serviços e Registro não serão alterados. Logs e exportações solicitadas ainda podem ser gravados." -Level "AVISO"
        Update-StatusStrip -Text "Modo Simulação Ativo (Somente Leitura)" -Color [System.Drawing.Color]::Orange
    } else {
        Write-AppLog -Message "MODO SIMULAÇÃO DESATIVADO: Modificações autorizadas." -Level "INFO"
        Update-StatusStrip -Text "Pronto para operações." -Color [System.Drawing.Color]::DarkGreen
    }
})
$pnlHeader.Controls.Add($chkSimulation)

# Barra de Status Inferior (StatusStrip)
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$statusStrip.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($statusStrip)

$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Pronto."
$statusLabel.ForeColor = [System.Drawing.Color]::Black
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
[void]$statusStrip.Items.Add($statusLabel)

$statusTag = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusTag.Text = "SISTEMA OPERACIONAL: OK"
$statusTag.ForeColor = [System.Drawing.Color]::DarkGreen
$statusTag.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
[void]$statusStrip.Items.Add($statusTag)

function Update-StatusStrip {
    param(
        [string]$Text,
        $Color = [System.Drawing.Color]::Black,
        [string]$Tag = ""
    )
    if ($Color -is [string]) {
        $cName = $Color.Replace("[System.Drawing.Color]::", "").Trim()
        try {
            $Color = [System.Drawing.Color]::FromName($cName)
        } catch {
            $Color = [System.Drawing.Color]::Black
        }
    }
    $statusLabel.Text = $Text
    if ($Tag) {
        $statusTag.Text = $Tag
        $statusTag.ForeColor = $Color
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# Painel de Carregamento e Progresso (Animado e Responsivo)
$pnlLoading = New-Object System.Windows.Forms.Panel
$pnlLoading.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlLoading.Height = 36
$pnlLoading.BackColor = [System.Drawing.Color]::FromArgb(235, 243, 253)
$pnlLoading.Visible = $false
$form.Controls.Add($pnlLoading)

$lblLoadingSpinner = New-Object System.Windows.Forms.Label
$lblLoadingSpinner.Text = [char]0x25D0
$lblLoadingSpinner.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblLoadingSpinner.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$lblLoadingSpinner.Location = New-Object System.Drawing.Point(12, 6)
$lblLoadingSpinner.Size = New-Object System.Drawing.Size(26, 24)
$pnlLoading.Controls.Add($lblLoadingSpinner)

$lblLoadingText = New-Object System.Windows.Forms.Label
$lblLoadingText.Text = "Carregando..."
$lblLoadingText.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblLoadingText.ForeColor = [System.Drawing.Color]::FromArgb(24, 76, 120)
$lblLoadingText.Location = New-Object System.Drawing.Point(40, 7)
$lblLoadingText.AutoSize = $true
$pnlLoading.Controls.Add($lblLoadingText)

$pbLoadingMarquee = New-Object System.Windows.Forms.ProgressBar
$pbLoadingMarquee.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$pbLoadingMarquee.MarqueeAnimationSpeed = 25
$pbLoadingMarquee.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pbLoadingMarquee.Height = 5
$pnlLoading.Controls.Add($pbLoadingMarquee)

$script:cancelPrinterConnection = $false
$btnCancelConnection = New-Object System.Windows.Forms.Button
$btnCancelConnection.Text = 'Cancelar'
$btnCancelConnection.Dock = [System.Windows.Forms.DockStyle]::Right
$btnCancelConnection.Width = 92
$btnCancelConnection.Visible = $false
$btnCancelConnection.Add_Click({
    $script:cancelPrinterConnection = $true
    $btnCancelConnection.Enabled = $false
    $lblLoadingText.Text = 'Cancelando a tentativa...'
})
$pnlLoading.Controls.Add($btnCancelConnection)

# Timer de animacao do icone giratorio (Spinner)
$script:spinnerFrames = @([char]0x25D0, [char]0x25D3, [char]0x25D1, [char]0x25D2)
$script:spinnerIndex = 0

$tmrSpinner = New-Object System.Windows.Forms.Timer
$tmrSpinner.Interval = 90
$tmrSpinner.Add_Tick({
    $script:spinnerIndex = ($script:spinnerIndex + 1) % $script:spinnerFrames.Length
    $lblLoadingSpinner.Text = $script:spinnerFrames[$script:spinnerIndex]
})

function Show-LoadingIndicator {
    param(
        [string]$Message = "Executando operacao...",
        [System.Windows.Forms.Button]$Button = $null
    )
    $lblLoadingText.Text = $Message
    $pnlLoading.Visible = $true
    $tmrSpinner.Start()
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    if ($Button -and -not $Button.IsDisposed) {
        if (-not $Button.Tag) { $Button.Tag = $Button.Text }
        $Button.Enabled = $false
        $Button.Text = ([char]0x23F3 + " Aguarde...")
    }

    Update-StatusStrip -Text $Message -Color [System.Drawing.Color]::FromArgb(0, 102, 204) -Tag "PROCESSANDO..."
    [System.Windows.Forms.Application]::DoEvents()
}

function Hide-LoadingIndicator {
    param(
        [System.Windows.Forms.Button]$Button = $null,
        [string]$SuccessMessage = ""
    )
    $tmrSpinner.Stop()
    $pnlLoading.Visible = $false
    $form.Cursor = [System.Windows.Forms.Cursors]::Default

    if ($Button -and -not $Button.IsDisposed) {
        if ($Button.Tag) {
            $Button.Text = [string]$Button.Tag
            $Button.Tag = $null
        }
        $Button.Enabled = $true
    }

    if ($SuccessMessage) {
        Update-StatusStrip -Text $SuccessMessage -Color [System.Drawing.Color]::FromArgb(46, 125, 50) -Tag "CONCLUIDO"
    } else {
        Update-StatusStrip -Text "Pronto." -Color [System.Drawing.Color]::Black -Tag "PRONTO"
    }
    [System.Windows.Forms.Application]::DoEvents()
}

# TabControl Principal (8 Abas)
# ==============================================================================
# 3.1 FUNCOES DE RESOLUCAO DE NOME / COMPARTILHAMENTO
# ==============================================================================
$script:ipHostCache = @{}
$script:printerMapCache = @{}



function Get-NetBiosNameDirect {
    param([string]$TargetIP)
    try {
        $udp = New-Object System.Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 400
        $udp.Client.SendTimeout = 400
        $packet = [byte[]]@(
            0x80, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x20, 0x43, 0x4B, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41, 0x41,
            0x41, 0x41, 0x41, 0x41, 0x41, 0x00, 0x00, 0x21,
            0x00, 0x01
        )
        $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse($TargetIP)), 137
        [void]$udp.Send($packet, $packet.Length, $ep)
        $remoteEp = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
        $resp = $udp.Receive([ref]$remoteEp)
        $udp.Close()
        if ($resp -and $resp.Length -ge 57) {
            $numNames = [int]$resp[56]
            for ($k = 0; $k -lt $numNames; $k++) {
                $offset = 57 + ($k * 18)
                if ($offset + 18 -le $resp.Length) {
                    $rawName = [System.Text.Encoding]::ASCII.GetString($resp, $offset, 15).Trim()
                    $type = [int]$resp[$offset + 15]
                    $flags = [int]$resp[$offset + 16]
                    $isGroup = ($flags -band 0x80) -ne 0
                    if (-not $isGroup -and ($type -eq 0x00 -or $type -eq 0x20) -and $rawName) {
                        return $rawName
                    }
                }
            }
        }
    } catch {}
    return ""
}

function Resolve-ComputerNameFromIpFast {
    param([string]$IpOrHost)
    if (-not $IpOrHost) { return "" }
    $clean = $IpOrHost.Trim().TrimStart("\").TrimEnd("\")
    if (-not $clean) { return "" }
    if ($clean -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        return $clean.ToUpper()
    }
    if ($clean -eq "127.0.0.1") { return $env:COMPUTERNAME.ToUpper() }
    if ($script:ipHostCache.ContainsKey($clean)) {
        return $script:ipHostCache[$clean]
    }
    $resolvedName = Get-NetBiosNameDirect -TargetIP $clean
    if (-not $resolvedName) {
        try {
            $asyncRes = [System.Net.Dns]::BeginGetHostEntry($clean, $null, $null)
            if ($asyncRes.AsyncWaitHandle.WaitOne(200)) {
                $entry = [System.Net.Dns]::EndGetHostEntry($asyncRes)
                if ($entry -and $entry.HostName) {
                    $h = ($entry.HostName -split "\.")[0].Trim()
                    if ($h -and $h -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
                        $resolvedName = $h.ToUpper()
                    }
                }
            }
        } catch {}
    }
    if (-not $resolvedName) {
        try {
            $w = Get-WmiObject Win32_OperatingSystem -ComputerName $clean -ErrorAction SilentlyContinue
            if ($w -and $w.CSName) { $resolvedName = $w.CSName.ToUpper() }
        } catch {}
    }
    if (-not $resolvedName) { $resolvedName = $clean }
    $script:ipHostCache[$clean] = $resolvedName.ToUpper()
    return $script:ipHostCache[$clean]
}

function Get-HostAndIpDisplay {
    param(
        [string]$HostOrIp,
        [string]$KnownIp = ""
    )
    if (-not $HostOrIp) { return "" }
    $clean = $HostOrIp.Trim().TrimStart("\").TrimEnd("\")
    if (-not $clean) { return "" }
    if ($clean.Contains(" \ ")) { return $clean }

    $hostName = ""
    $ipAddr = ""

    if ($clean -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        $ipAddr = $clean
        $hostName = Resolve-ComputerNameFromIpFast $ipAddr
    } else {
        $hostName = $clean.ToUpper()
        if ($KnownIp -and $KnownIp -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
            $ipAddr = $KnownIp
        } elseif ($hostName -eq $env:COMPUTERNAME.ToUpper()) {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | Where-Object { $_.AddressFamily -eq "InterNetwork" -and $_.IPAddressToString -notlike "127.*" -and $_.IPAddressToString -notlike "169.254.*" }
                if ($ips) { $ipAddr = ($ips | Select-Object -First 1).IPAddressToString }
            } catch {}
        } else {
            try {
                $ips = [System.Net.Dns]::GetHostAddresses($hostName) | Where-Object { $_.AddressFamily -eq "InterNetwork" -and $_.IPAddressToString -notlike "127.*" }
                if ($ips) { $ipAddr = ($ips | Select-Object -First 1).IPAddressToString }
            } catch {}
        }
    }

    if ($hostName -and $ipAddr -and $hostName -ne $ipAddr) {
        return "$hostName \ $ipAddr"
    } elseif ($hostName) {
        return $hostName
    } elseif ($ipAddr) {
        return $ipAddr
    }
    return $clean
}

function Format-PrinterAsNamedUNC {
    param([string]$PrinterInput)
    if (-not $PrinterInput) { return "" }
    $p = $PrinterInput.Trim()
    if ($p.StartsWith("\\") -or $p.Contains("\")) {
        $parts = $p.TrimStart("\").Split("\")
        if ($parts.Length -ge 2) {
            $server = $parts[0]
            $share = ($parts[1..($parts.Length - 1)]) -join "\"
            if ($server.ToUpper() -eq $env:COMPUTERNAME.ToUpper() -or $server -eq "127.0.0.1" -or $server.ToLower() -eq "localhost") {
                return "\\$($env:COMPUTERNAME)\$share"
            }
            if ($script:printerMapCache.ContainsKey($p) -and $script:printerMapCache[$p].ShareName) {
                $share = $script:printerMapCache[$p].ShareName
            }
            # Preservar o nome ou IP escolhido pelo tecnico. Converter IP para nome
            # pode produzir 0x00000709 quando o nome resolvido nao serve para impressao.
            return "\\$server\$share"
        }
        return $p
    }
    if ($script:printerMapCache.ContainsKey($p)) {
        $info = $script:printerMapCache[$p]
        if ($info.ServerName) {
            $srv = $info.ServerName.TrimStart("\")
            $resolvedSrv = Resolve-ComputerNameFromIpFast -IpOrHost $srv
            $sh = if ($info.ShareName) { $info.ShareName } else { $p.Replace("\\$srv\", "") }
            return "\\$resolvedSrv\$sh"
        }
        $shareName = if ($info.ShareName) { $info.ShareName } else { ($p -replace "[^A-Za-z0-9_\-]", "") }
        if (-not $shareName) { $shareName = "Impressora" }
        return "\\$($env:COMPUTERNAME)\$shareName"
    }
    $shareName = ($p -replace "[^A-Za-z0-9_\-]", "")
    if (-not $shareName) { $shareName = "Impressora" }
    return "\\$($env:COMPUTERNAME)\$shareName"
}

$tabControl = New-Object System.Windows.Forms.TabControl
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($tabControl)
$tabControl.BringToFront()

# Criar as 8 abas
$tab1 = New-Object System.Windows.Forms.TabPage; $tab1.Text = "1. Diagnóstico"
$tab2 = New-Object System.Windows.Forms.TabPage; $tab2.Text = "2. Impressoras Instaladas"
$tab3 = New-Object System.Windows.Forms.TabPage; $tab3.Text = "3. Impressoras da Rede"

$tab4 = New-Object System.Windows.Forms.TabPage; $tab4.Text = "4. Instalar por Caminho"
$tab5 = New-Object System.Windows.Forms.TabPage; $tab5.Text = "5. Instalar por IP"
$tab6 = New-Object System.Windows.Forms.TabPage; $tab6.Text = ("6. Fila e Spooler")
$tab7 = New-Object System.Windows.Forms.TabPage; $tab7.Text = ("7. " + [char]0xC1 + "rea de Trabalho Remota")
$tab8 = New-Object System.Windows.Forms.TabPage; $tab8.Text = ("8. Relat" + [char]0xF3 + "rio e Logs")

$tabControl.TabPages.Add($tab1)
$tabControl.TabPages.Add($tab2)
$tabControl.TabPages.Add($tab3)

$tabControl.TabPages.Add($tab4)
$tabControl.TabPages.Add($tab5)
$tabControl.TabPages.Add($tab6)
$tabControl.TabPages.Add($tab7)
$tabControl.TabPages.Add($tab8)

# ==============================================================================
# ABA 1: DIAGNÓSTICO DO COMPUTADOR
# ==============================================================================
$pnlDiagTop = New-Object System.Windows.Forms.Panel
$pnlDiagTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlDiagTop.Height = 45
$tab1.Controls.Add($pnlDiagTop)

$btnRunFullDiag = New-Object System.Windows.Forms.Button
$btnRunFullDiag.Text = "Executar Diagnóstico Completo"
$btnRunFullDiag.Size = New-Object System.Drawing.Size(220, 32)
$btnRunFullDiag.Location = New-Object System.Drawing.Point(10, 6)
$btnRunFullDiag.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnRunFullDiag.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnRunFullDiag.ForeColor = [System.Drawing.Color]::White
$btnRunFullDiag.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlDiagTop.Controls.Add($btnRunFullDiag)

$btnCopyDiag = New-Object System.Windows.Forms.Button
$btnCopyDiag.Text = "Copiar Diagnóstico"
$btnCopyDiag.Size = New-Object System.Drawing.Size(150, 32)
$btnCopyDiag.Location = New-Object System.Drawing.Point(240, 6)
$pnlDiagTop.Controls.Add($btnCopyDiag)

$txtDiagReport = New-Object System.Windows.Forms.TextBox
$txtDiagReport.Multiline = $true
$txtDiagReport.ReadOnly = $true
$txtDiagReport.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtDiagReport.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtDiagReport.Font = New-Object System.Drawing.Font("Consolas", 9.5)
$txtDiagReport.BackColor = [System.Drawing.Color]::White
$tab1.Controls.Add($txtDiagReport)
$txtDiagReport.BringToFront()

$btnCopyDiag.Add_Click({
    if ($txtDiagReport.Text) {
        [System.Windows.Forms.Clipboard]::SetText($txtDiagReport.Text)
        [System.Windows.Forms.MessageBox]::Show("Diagnóstico copiado para a Área de Transferência!", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

$btnRunFullDiag.Add_Click({
    Show-LoadingIndicator -Message "Executando diagnóstico completo do sistema..." -Button $btnRunFullDiag
    $txtDiagReport.Text = "Coletando informações do sistema, aguarde..."
    try {

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("           RELATÓRIO DE DIAGNÓSTICO DO COMPUTADOR E SUBSISTEMA DE IMPRESSÃO     ")
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("Data e Hora: $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))")
    [void]$sb.AppendLine("Modo Simulação: $(if ($global:SimulationMode) { 'ATIVADO (Somente Diagnóstico)' } else { 'DESATIVADO (Operações Ativas)' })")
    [void]$sb.AppendLine()

    # 1. Informações de Sistema Operacional
    [void]$sb.AppendLine("[1. SISTEMA OPERACIONAL]")
    try {
        $os = Get-WmiObject -Class Win32_OperatingSystem -ErrorAction SilentlyContinue
        [void]$sb.AppendLine("Sistema: $($os.Caption) $($os.CSDVersion)")
        [void]$sb.AppendLine("Versão / Build: $($os.Version) (Build $($os.BuildNumber))")
        [void]$sb.AppendLine("Arquitetura: $($os.OSArchitecture)")
    } catch {
        [void]$sb.AppendLine("SO: Windows (WMI indisponível: $($_.Exception.Message))")
    }
    [void]$sb.AppendLine("Nome do Computador: $env:COMPUTERNAME")
    [void]$sb.AppendLine("Usuário Atual: $env:USERNAME")
    [void]$sb.AppendLine("Privilégios de Administrador: $(if (Test-IsAdmin) { 'SIM' } else { 'NÃO (Algumas ações podem falhar)' })")

    # Sessão Local ou RDP
    $isRdp = [System.Windows.Forms.SystemInformation]::TerminalServerSession
    $sessionName = $env:SESSIONNAME
    [void]$sb.AppendLine("Tipo de Sessão: $(if ($isRdp) { "Área de Trabalho Remota / RDP (Sessão: $sessionName)" } else { "Sessão Local / Console ($sessionName)" })")
    [void]$sb.AppendLine()

    # 2. Configurações de Rede IPv4
    [void]$sb.AppendLine("[2. CONFIGURAÇÕES DE REDE]")
    try {
        $adapters = Get-WmiObject -Query "SELECT * FROM Win32_NetworkAdapterConfiguration WHERE IPEnabled = True" -ErrorAction SilentlyContinue
        if ($adapters) {
            foreach ($nic in $adapters) {
                [void]$sb.AppendLine("Adaptador: $($nic.Description)")
                $ips = ($nic.IPAddress | Where-Object { $_ -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$" }) -join ", "
                [void]$sb.AppendLine("  IPv4: $ips")
                $gw = ($nic.DefaultIPGateway) -join ", "
                [void]$sb.AppendLine("  Gateway: $(if ($gw) { $gw } else { 'Nenhum' })")
                $dns = ($nic.DNSServerSearchOrder) -join ", "
                [void]$sb.AppendLine("  Servidores DNS: $(if ($dns) { $dns } else { 'Padrão' })")
            }
        } else {
            [void]$sb.AppendLine("Nenhum adaptador IPv4 ativo encontrado via WMI.")
        }
    } catch {
        [void]$sb.AppendLine("Falha ao coletar dados de rede: $($_.Exception.Message)")
    }
    [void]$sb.AppendLine()

    # 3. Estado do Serviço Spooler
    [void]$sb.AppendLine("[3. SERVIÇO SPOOLER DE IMPRESSÃO]")
    try {
        $spooler = Get-Service -Name "spooler" -ErrorAction SilentlyContinue
        $wmiSpooler = Get-WmiObject -Class Win32_Service -Filter "Name = 'Spooler'" -ErrorAction SilentlyContinue
        [void]$sb.AppendLine("Status do Serviço: $(if ($spooler) { $spooler.Status } else { 'Não Identificado' })")
        [void]$sb.AppendLine("Tipo de Inicialização: $(if ($wmiSpooler) { $wmiSpooler.StartMode } else { 'Desconhecido' })")
    } catch {
        [void]$sb.AppendLine("Erro ao consultar serviço Spooler: $($_.Exception.Message)")
    }

    # Contagem de arquivos presos na pasta de spool
    $spoolPath = Join-Path -Path $env:SystemRoot -ChildPath "System32\spool\PRINTERS"
    $spoolCount = 0
    if (Test-Path -Path $spoolPath) {
        $spoolFiles = Get-ChildItem -Path $spoolPath -Include *.spl, *.shd -Recurse -Force -ErrorAction SilentlyContinue
        if ($spoolFiles) { $spoolCount = $spoolFiles.Count }
    }
    [void]$sb.AppendLine("Arquivos temporários no Spool (PRINTERS): $spoolCount")
    [void]$sb.AppendLine()

    # 4. Inventário de Impressoras
    [void]$sb.AppendLine("[4. INVENTÁRIO DE IMPRESSORAS]")
    $allPrinters = Get-InstalledPrintersWmi
    $stuckJobs = Get-PrintJobsSafe

    $offlineCount = 0
    $pausedCount = 0
    $sharedCount = 0
    $rdpCount = 0
    $defaultPrinterName = "Nenhuma"

    foreach ($p in $allPrinters) {
        if ($p.Default) { $defaultPrinterName = $p.Name }
        if ($p.WorkOffline) { $offlineCount++ }
        if ($p.Paused) { $pausedCount++ }
        if ($p.Shared) { $sharedCount++ }
        if ($p.Name -match "(?i)(redirected|redirecionada)") { $rdpCount++ }
    }

    [void]$sb.AppendLine("Total de Impressoras Instaladas: $($allPrinters.Count)")
    [void]$sb.AppendLine("Impressora Padrão: $defaultPrinterName")
    [void]$sb.AppendLine("Impressoras em Modo Offline: $offlineCount")
    [void]$sb.AppendLine("Impressoras Pausadas: $pausedCount")
    [void]$sb.AppendLine("Impressoras Compartilhadas em Rede: $sharedCount")
    [void]$sb.AppendLine("Impressoras Redirecionadas por RDP: $rdpCount")
    [void]$sb.AppendLine("Trabalhos Presos nas Filas (Global): $($stuckJobs.Count)")
    [void]$sb.AppendLine()

    [void]$sb.AppendLine("[5. DETALHES DAS IMPRESSORAS INSTALADAS]")
    foreach ($p in $allPrinters) {
        $tipo = if ($p.Network) { "Rede (UNC)" } else { "Local" }
        $flags = @()
        if ($p.Default) { $flags += "PADRÃO" }
        if ($p.WorkOffline) { $flags += "OFFLINE" }
        if ($p.Paused) { $flags += "PAUSADA" }
        if ($p.Shared) { $flags += "COMPARTILHADA ($($p.ShareName))" }
        $flagStr = if ($flags.Count -gt 0) { " [" + ($flags -join ", ") + "]" } else { " [OK]" }

        [void]$sb.AppendLine("- $($p.Name)$flagStr")
        [void]$sb.AppendLine("   Tipo: $tipo | Porta: $($p.PortName) | Driver: $($p.DriverName)")
    }
    [void]$sb.AppendLine()

    # 6. Verificação de Eventos Recentes de Impressão no Visualizador de Eventos
    [void]$sb.AppendLine("[6. EVENTOS RECENTES DE ERRO DE IMPRESSÃO (ÚLTIMAS 48 HORAS)]")
    try {
        $twoDaysAgo = (Get-Date).AddDays(-2)
        $events = Get-EventLog -LogName System -EntryType Error, Warning -After $twoDaysAgo -ErrorAction SilentlyContinue |
                  Where-Object { $_.Source -match "(?i)(print|spooler)" } | Select-Object -First 5
        if ($events) {
            foreach ($ev in $events) {
                [void]$sb.AppendLine("- [$($ev.TimeGenerated.ToString('dd/MM HH:mm'))] ID: $($ev.EventID) | Fonte: $($ev.Source)")
                $evMsg = ($ev.Message -split "`r`n")[0]
                if ($evMsg.Length -gt 100) { $evMsg = $evMsg.Substring(0, 97) + "..." }
                [void]$sb.AppendLine("   Mensagem: $evMsg")
            }
        } else {
            [void]$sb.AppendLine("Nenhum erro crítico de spooler/impressão registrado no log System nas últimas 48h.")
        }
    } catch {
        [void]$sb.AppendLine("Consulta ao log de eventos indisponível ou limitada nesta sessão.")
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine("================================================================================")
    [void]$sb.AppendLine("Fim do Diagnóstico.")

    $txtDiagReport.Text = $sb.ToString()
    Write-AppLog -Message "Diagnóstico completo executado com sucesso." -Level "SUCESSO"
    } finally {
        Hide-LoadingIndicator -Button $btnRunFullDiag -SuccessMessage "Diagnóstico concluído."
    }
})

# ==============================================================================
# ABA 2: IMPRESSORAS INSTALADAS
# ==============================================================================
$pnlPrintersTop = New-Object System.Windows.Forms.Panel
$pnlPrintersTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlPrintersTop.Height = 82
$tab2.Controls.Add($pnlPrintersTop)

$btnRefreshPrinters = New-Object System.Windows.Forms.Button
$btnRefreshPrinters.Text = "Atualizar"
$btnRefreshPrinters.Size = New-Object System.Drawing.Size(80, 32)
$btnRefreshPrinters.Location = New-Object System.Drawing.Point(8, 6)
$pnlPrintersTop.Controls.Add($btnRefreshPrinters)

$btnSetDefault = New-Object System.Windows.Forms.Button
$btnSetDefault.Text = "Definir Padrão"
$btnSetDefault.Size = New-Object System.Drawing.Size(110, 32)
$btnSetDefault.Location = New-Object System.Drawing.Point(92, 6)
$pnlPrintersTop.Controls.Add($btnSetDefault)

$btnOpenQueue = New-Object System.Windows.Forms.Button
$btnOpenQueue.Text = "Abrir Fila"
$btnOpenQueue.Size = New-Object System.Drawing.Size(80, 32)
$btnOpenQueue.Location = New-Object System.Drawing.Point(206, 6)
$pnlPrintersTop.Controls.Add($btnOpenQueue)

$btnPrintTest = New-Object System.Windows.Forms.Button
$btnPrintTest.Text = "Teste Windows"
$btnPrintTest.Size = New-Object System.Drawing.Size(105, 32)
$btnPrintTest.Location = New-Object System.Drawing.Point(290, 6)
$pnlPrintersTop.Controls.Add($btnPrintTest)

$btnThermalTest = New-Object System.Windows.Forms.Button
$btnThermalTest.Text = "Teste RAW / Térmica"
$btnThermalTest.Size = New-Object System.Drawing.Size(140, 32)
$btnThermalTest.Location = New-Object System.Drawing.Point(399, 6)
$btnThermalTest.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 205)
$pnlPrintersTop.Controls.Add($btnThermalTest)

$btnOpenProps = New-Object System.Windows.Forms.Button
$btnOpenProps.Text = "Propriedades"
$btnOpenProps.Size = New-Object System.Drawing.Size(95, 32)
$btnOpenProps.Location = New-Object System.Drawing.Point(543, 6)
$pnlPrintersTop.Controls.Add($btnOpenProps)

$btnFixPrinter = New-Object System.Windows.Forms.Button
$btnFixPrinter.Text = "Despausar / Online"
$btnFixPrinter.Size = New-Object System.Drawing.Size(125, 32)
$btnFixPrinter.Location = New-Object System.Drawing.Point(642, 6)
$pnlPrintersTop.Controls.Add($btnFixPrinter)

$btnRemoveConn = New-Object System.Windows.Forms.Button
$btnRemoveConn.Text = "Remover"
$btnRemoveConn.Size = New-Object System.Drawing.Size(90, 32)
$btnRemoveConn.Location = New-Object System.Drawing.Point(771, 6)
$btnRemoveConn.ForeColor = [System.Drawing.Color]::DarkRed
$pnlPrintersTop.Controls.Add($btnRemoveConn)

$btnPublishDriver = New-Object System.Windows.Forms.Button
$btnPublishDriver.Text = 'Preparar driver para outros PCs'
$btnPublishDriver.Size = New-Object System.Drawing.Size(250, 30)
$btnPublishDriver.Location = New-Object System.Drawing.Point(8, 44)
$pnlPrintersTop.Controls.Add($btnPublishDriver)

$dgvPrinters = New-Object System.Windows.Forms.DataGridView
$dgvPrinters.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvPrinters.ReadOnly = $true
$dgvPrinters.AllowUserToAddRows = $false
$dgvPrinters.AllowUserToDeleteRows = $false
$dgvPrinters.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvPrinters.MultiSelect = $false
$dgvPrinters.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvPrinters.BackgroundColor = [System.Drawing.Color]::White
$tab2.Controls.Add($dgvPrinters)
$dgvPrinters.BringToFront()

# Configuração de Colunas do DataGridView
[void]$dgvPrinters.Columns.Add("Name", "Nome")
[void]$dgvPrinters.Columns.Add("Status", "Status")
[void]$dgvPrinters.Columns.Add("Default", "Padrão")
[void]$dgvPrinters.Columns.Add("Type", "Tipo")
[void]$dgvPrinters.Columns.Add("Shared", "Compartilhada")
[void]$dgvPrinters.Columns.Add("Port", "Porta")
[void]$dgvPrinters.Columns.Add("IP", "Endereço IP")
[void]$dgvPrinters.Columns.Add("Driver", "Driver")
[void]$dgvPrinters.Columns.Add("Jobs", "Docs Fila")

function Refresh-PrintersGrid {
    Update-StatusStrip -Text "Atualizando lista de impressoras..." -Color [System.Drawing.Color]::Blue
    $dgvPrinters.Rows.Clear()
    $printers = Get-InstalledPrintersWmi
    $jobs = Get-PrintJobsSafe

    foreach ($p in $printers) {
        $pName = $p.Name
        $statusStr = "Pronta"
        if ($p.WorkOffline) { $statusStr = "Offline" }
        if ($p.Paused) { $statusStr = "Pausada" }

        $isDefault = if ($p.Default) { "Sim" } else { "Não" }
        $tipo = if ($p.Network) { "Rede (UNC)" } else { "Local" }
        $shared = if ($p.Shared) { "Sim ($($p.ShareName))" } else { "Não" }
        $port = $p.PortName

        # Detectar IP da porta
        $ip = ""
        if ($port -match "IP_([0-9\.]+)") {
            $ip = $matches[1]
        } elseif ($port -match "([0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3})") {
            $ip = $matches[1]
        }

        # Contar documentos nesta fila
        $queueCount = 0
        if ($jobs) {
            $matchingJobs = $jobs | Where-Object { $_.Name -like "*$pName*" }
            if ($matchingJobs) { $queueCount = $matchingJobs.Count }
        }

        $rowIndex = $dgvPrinters.Rows.Add($pName, $statusStr, $isDefault, $tipo, $shared, $port, $ip, $p.DriverName, $queueCount)

        # Destaque visual: Padrão em verde suave, Offline/Pausada em amarelo
        if ($p.Default) {
            $dgvPrinters.Rows[$rowIndex].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        }
        if ($p.WorkOffline -or $p.Paused) {
            $dgvPrinters.Rows[$rowIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        }
    }
    Update-StatusStrip -Text "Lista de impressoras atualizada ($($printers.Count) encontradas)." -Color [System.Drawing.Color]::DarkGreen
}

$btnRefreshPrinters.Add_Click({ Refresh-PrintersGrid })

$btnPublishDriver.Add_Click({
    if ($global:SimulationMode) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Modo simulação: nenhum pacote será publicado.', 'Driver do servidor') | Out-Null
        return
    }
    if ($dgvPrinters.SelectedRows.Count -eq 0) { return }
    try {
        $name = [string]$dgvPrinters.SelectedRows[0].Cells['Name'].Value
        $printer = Get-Printer -ErrorAction Stop | Where-Object { $_.Name -ieq $name } | Select-Object -First 1
        if (-not $printer.Shared -or $printer.Name -like '\\*') { throw 'Selecione uma impressora local compartilhada neste PC.' }
        $script:cancelPrinterConnection = $false
        Show-LoadingIndicator -Message 'Preparando o driver para os outros computadores...' -Button $btnPublishDriver
        $published = Invoke-BoundedPrinterAttempt -UNCPath ('\\' + $env:COMPUTERNAME + '\' + $printer.ShareName) -Method PublishDriver -TimeoutSeconds 40
        Write-AppLog -Message "Preparar driver: $($published.Message)" -Level $(if ($published.Success) { 'SUCESSO' } else { 'ERRO' })
        [System.Windows.Forms.MessageBox]::Show($form, $published.Message, 'Driver do servidor') | Out-Null
    } catch {
        Write-AppLog -Message "Preparar driver: $($_.Exception.Message)" -Level 'ERRO'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Driver do servidor') | Out-Null
    } finally { Hide-LoadingIndicator -Button $btnPublishDriver }
})

# Ação: Definir como Padrão
$btnSetDefault.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na tabela.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $selectedName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value
    $ok = Set-DefaultPrinterSafe -PrinterName $selectedName
    if ($global:SimulationMode) {
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] A impressora padrão não foi alterada.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($ok) {
        [System.Windows.Forms.MessageBox]::Show("A impressora '$selectedName' foi definida como padrão com sucesso.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        Refresh-PrintersGrid
    } else {
        [System.Windows.Forms.MessageBox]::Show("Não foi possível definir '$selectedName' como padrão. Consulte os logs.", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# Ação: Abrir Fila
$btnOpenQueue.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) { return }
    $selectedName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value
    Invoke-PrintUICommand -Arguments "/o /n `"$selectedName`"" -NoWait | Out-Null
})

# Ação: Abrir Propriedades
$btnOpenProps.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) { return }
    $selectedName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value
    Invoke-PrintUICommand -Arguments "/p /n `"$selectedName`"" -NoWait | Out-Null
})

# Ação: Imprimir Teste (Oficial do Windows com confirmação)
$btnPrintTest.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) { return }
    $selectedName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Página de teste seria enviada para '$selectedName'." -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhuma página de teste foi enviada.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $resp = [System.Windows.Forms.MessageBox]::Show("Deseja enviar uma página de teste padrão do Windows para a impressora:`n`n$selectedName?", "Confirmar Impressão de Teste", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
        try {
            Show-LoadingIndicator -Message "Enviando página de teste para $selectedName..." -Button $btnPrintTest
            $ret = Invoke-PrintUICommand -Arguments "/k /n `"$selectedName`""
            if ($ret -eq 0) {
                [System.Windows.Forms.MessageBox]::Show("Página de teste enviada com sucesso para a fila.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
                Write-AppLog -Message "Página de teste enviada para '$selectedName'." -Level "SUCESSO"
            } else {
                [System.Windows.Forms.MessageBox]::Show("Falha ao enviar página de teste (Código $ret).", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        } finally {
            Hide-LoadingIndicator -Button $btnPrintTest -SuccessMessage "Página de teste enviada."
        }
    }
})

# Ação: Teste Térmico RAW com Proteção de Segurança
$btnThermalTest.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na tabela.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    $pName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value
    $port = $dgvPrinters.SelectedRows[0].Cells["Port"].Value
    $ip = $dgvPrinters.SelectedRows[0].Cells["IP"].Value

    # Modal de Segurança para Teste Térmico RAW
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Teste Térmico RAW Seguro - " + $pName
    $dlg.Size = New-Object System.Drawing.Size(520, 340)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblWarn = New-Object System.Windows.Forms.Label
    $lblWarn.Text = "ATENÇÃO DE SEGURANÇA:`nO envio de comandos RAW para impressoras jato de tinta ou laser convencionais pode resultar em dezenas de páginas em branco impressas.`n`nSomente utilize esta função se tiver certeza de que a impressora é térmica (Bematech, Elgin, Epson, Zebra, Argox) e selecione a linguagem correspondente."
    $lblWarn.ForeColor = [System.Drawing.Color]::DarkRed
    $lblWarn.Location = New-Object System.Drawing.Point(15, 15)
    $lblWarn.Size = New-Object System.Drawing.Size(480, 75)
    $dlg.Controls.Add($lblWarn)

    $lblLang = New-Object System.Windows.Forms.Label
    $lblLang.Text = "Linguagem / Padrão Térmico:"
    $lblLang.Location = New-Object System.Drawing.Point(15, 100)
    $lblLang.AutoSize = $true
    $dlg.Controls.Add($lblLang)

    $cmbLang = New-Object System.Windows.Forms.ComboBox
    $cmbLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbLang.Location = New-Object System.Drawing.Point(15, 122)
    $cmbLang.Size = New-Object System.Drawing.Size(470, 23)
    [void]$cmbLang.Items.Add("ESC/POS - Cupom Térmico (Bematech MP-4200 / Elgin i9 / Epson TM-T20)")
    [void]$cmbLang.Items.Add("PPLB - Etiqueta de Teste (Argox OS-214 Plus)")
    [void]$cmbLang.Items.Add("ZPL II - Etiqueta de Teste (Zebra ZD220 / GC420 / ZD230)")
    [void]$cmbLang.Items.Add("Texto ASCII Simples (Com avanço de linha)")
    $cmbLang.SelectedIndex = 0
    $dlg.Controls.Add($cmbLang)

    $chkConsent = New-Object System.Windows.Forms.CheckBox
    $chkConsent.Text = "Estou ciente do modelo da impressora e autorizo o envio do comando RAW."
    $chkConsent.Location = New-Object System.Drawing.Point(15, 165)
    $chkConsent.Size = New-Object System.Drawing.Size(480, 35)
    $dlg.Controls.Add($chkConsent)

    $btnSend = New-Object System.Windows.Forms.Button
    $btnSend.Text = "Enviar Teste RAW"
    $btnSend.Location = New-Object System.Drawing.Point(15, 215)
    $btnSend.Size = New-Object System.Drawing.Size(160, 35)
    $btnSend.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnSend.ForeColor = [System.Drawing.Color]::White
    $btnSend.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSend.Enabled = $false
    $dlg.Controls.Add($btnSend)

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(185, 215)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 35)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dlg.Controls.Add($btnCancel)

    $chkConsent.Add_CheckedChanged({
        $btnSend.Enabled = $chkConsent.Checked
    })

    $btnSend.Add_Click({
        try {
            Show-LoadingIndicator -Message "Transmitindo teste térmico para $pName..." -Button $btnSend
            $selectedIdx = $cmbLang.SelectedIndex
        $payload = ""
        $langName = ""

        switch ($selectedIdx) {
            0 {
                $langName = "ESC/POS"
                $payload = "`e@`ea`x01TESTE SUPORTE TECNICO`n" +
                           "ASSISTENTE DE IMPRESSORAS`n" +
                           "--------------------------------`n" +
                           "Host: $env:COMPUTERNAME`n" +
                           "Data: $((Get-Date).ToString('dd/MM/yyyy HH:mm:ss'))`n" +
                           "Impressora: $pName`n" +
                           "Status: OK - Teste Concluido`n`n`n`n`n`em"
            }
            1 {
                $langName = "PPLB"
                $payload = "`nN`nB50,20,0,1,2,4,40,B,`"TESTE PPLB`"`nA50,70,0,3,1,1,N,`"ASSISTENTE IMPRESSORAS`"`nA50,100,0,2,1,1,N,`"DATA: $((Get-Date).ToString('dd/MM/yy HH:mm'))`"`nP1`n"
            }
            2 {
                $langName = "ZPL II"
                $payload = "^XA^FO50,50^ADN,36,20^FDTESTE SUPORTE TECNICO^FS^FO50,100^ADN,20,10^FDASSISTENTE DE IMPRESSORAS^FS^FO50,130^ADN,18,10^FDHOST: $env:COMPUTERNAME^FS^FO50,160^ADN,18,10^FDDATA: $((Get-Date).ToString('dd/MM/yyyy HH:mm'))^FS^XZ"
            }
            default {
                $langName = "ASCII"
                $payload = "TESTE SUPORTE TECNICO - IMPRESSAO TEXTO PURO`r`n" +
                           "Computador: $env:COMPUTERNAME`r`n" +
                           "Data: $((Get-Date).ToString())`r`n`r`n`r`n"
            }
        }

        Write-AppLog -Message "Iniciando envio de teste térmico RAW ($langName) para '$pName'..." -Level "INFO"

        if ($global:SimulationMode) {
            Write-AppLog -Message "[SIMULAÇÃO] Teste térmico RAW ($langName) seria transmitido para '$pName'." -Level "SIMULACAO"
            [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO]`n`nComando RAW ($langName) simulado com sucesso.`nNenhum dado físico foi transmitido.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            $dlg.Close()
            return
        }

        $sent = $false
        if ($ip -and ($ip -match "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$")) {
            try {
                $sock = New-Object System.Net.Sockets.TcpClient
                $ar = $sock.BeginConnect($ip, 9100, $null, $null)
                if ($ar.AsyncWaitHandle.WaitOne(2000, $false)) {
                    $sock.EndConnect($ar)
                    $stream = $sock.GetStream()
                    $bytes = [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes($payload)
                    $stream.Write($bytes, 0, $bytes.Length)
                    $stream.Flush()
                    $sock.Close()
                    $sent = $true
                    Write-AppLog -Message "Comando RAW transmitido com sucesso via socket TCP para $($ip):9100." -Level "SUCESSO"
                }
            } catch {
                Write-AppLog -Message "Falha ao enviar RAW via socket TCP: $($_.Exception.Message)" -Level "AVISO"
            }
        }

        if (-not $sent) {
            try {
                $tmpFile = Join-Path -Path $env:TEMP -ChildPath ("raw_test_" + [Guid]::NewGuid().ToString("N") + ".prn")
                [System.IO.File]::WriteAllText($tmpFile, $payload, [System.Text.Encoding]::GetEncoding("ISO-8859-1"))
                [void]$global:TempFilesCreated.Add($tmpFile)

                if ($pName -match "^\\\\") {
                    Start-Process -FilePath "cmd.exe" -ArgumentList "/c copy /b `"$tmpFile`" `"$pName`"" -Wait -WindowStyle Hidden
                    $sent = $true
                } else {
                    if ($port -match "^(LPT|COM)") {
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c copy /b `"$tmpFile`" $port" -Wait -WindowStyle Hidden
                        $sent = $true
                    } else {
                        Invoke-PrintUICommand -Arguments "/k /n `"$pName`"" | Out-Null
                        $sent = $true
                    }
                }
                Write-AppLog -Message "Comando RAW despachado para a impressora '$pName'." -Level "SUCESSO"
            } catch {
                Write-AppLog -Message "Falha ao despachar arquivo RAW: $($_.Exception.Message)" -Level "ERRO"
            }
        }

        if ($sent) {
            [System.Windows.Forms.MessageBox]::Show("Comando de teste RAW ($langName) despachado para a impressora '$pName'.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } else {
            [System.Windows.Forms.MessageBox]::Show("Não foi possível entregar o comando RAW. Verifique conexão e status da porta.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        }
    } finally {
        Hide-LoadingIndicator -Button $btnSend -SuccessMessage "Teste térmico processado."
    }
    $dlg.Close()
})

    [void]$dlg.ShowDialog($form)
})

# Ação: Corrigir / Despausar / Tirar Offline
$btnFixPrinter.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) { return }
    $selectedName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Corrigindo status da impressora $selectedName (Pausa e Offline)" -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO]`n`nSeriam removidos os estados de Pausa e Modo Offline de:`n$selectedName", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    try {
        $escaped = $selectedName.Replace("\", "\\").Replace("'", "''")
        $p = Get-WmiObject -Query "SELECT * FROM Win32_Printer WHERE Name = '$escaped'"
        if ($p) {
            if ($p.Paused) { $p.Resume() | Out-Null }
            if ($p.WorkOffline) { $p.WorkOffline = $false; $p.Put() | Out-Null }
            Write-AppLog -Message "Impressora '$selectedName' corrigida (despausada e online)." -Level "SUCESSO"
            [System.Windows.Forms.MessageBox]::Show("Estados de Pausa e Offline corrigidos para '$selectedName'.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            Refresh-PrintersGrid
        }
    } catch {
        Write-AppLog -Message "Erro ao corrigir impressora: $($_.Exception.Message)" -Level "ERRO"
        [System.Windows.Forms.MessageBox]::Show("Erro ao tentar corrigir impressora: $($_.Exception.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# Ação: Remover Conexão com Confirmação Segura
$btnRemoveConn.Add_Click({
    if ($dgvPrinters.SelectedRows.Count -eq 0) { return }
    $selectedName = $dgvPrinters.SelectedRows[0].Cells["Name"].Value
    $tipo = $dgvPrinters.SelectedRows[0].Cells["Type"].Value

    $avisoMsg = "Tem certeza de que deseja remover a impressora:`n`n$selectedName`n`n" +
                "NOTA IMPORTANTE:`n" +
                "- Se for uma impressora de rede, somente a conexão do usuário será desconectada.`n" +
                "- Os drivers instalados no Windows NÃO serão excluídos.`n" +
                "- Esta ação não pode ser desfeita automaticamente."

    $resp = [System.Windows.Forms.MessageBox]::Show($avisoMsg, "Confirmar Remoção de Impressora", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Seria removida a impressora $selectedName" -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO]`n`nA impressora não foi removida.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    Write-AppLog -Message "Iniciando remoção da impressora '$selectedName'..." -Level "INFO"
    $removido = $false
    try {
        if ($tipo -like "*Rede*") {
            # Remover conexão de rede via WScript.Network ou PrintUIEntry /dn
            try {
                $netObj = New-Object -ComObject WScript.Network
                $netObj.RemovePrinterConnection($selectedName)
                $removido = $true
            } catch {
                $code = Invoke-PrintUICommand -Arguments "/dn /n `"$selectedName`""
                if ($code -eq 0) { $removido = $true }
            }
        } else {
            # Remover impressora local via PrintUIEntry /dl (não remove driver)
            $code = Invoke-PrintUICommand -Arguments "/dl /n `"$selectedName`""
            if ($code -eq 0) { $removido = $true }
        }

        if ($removido) {
            Write-AppLog -Message "Impressora '$selectedName' removida com sucesso." -Level "SUCESSO"
            [System.Windows.Forms.MessageBox]::Show("A impressora foi removida do sistema.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            Refresh-PrintersGrid
        } else {
            Write-AppLog -Message "Falha ao remover a impressora '$selectedName'." -Level "ERRO"
            [System.Windows.Forms.MessageBox]::Show("Não foi possível remover a impressora. Verifique permissões.", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } catch {
        Write-AppLog -Message "Erro ao remover impressora: $($_.Exception.Message)" -Level "ERRO"
        [System.Windows.Forms.MessageBox]::Show("Erro: $($_.Exception.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
})

# ==============================================================================
# ABA 3: IMPRESSORAS DA REDE (BUSCA AUTOMATICA, SMB E CONEXAO)
# ==============================================================================
$pnlNetTop = New-Object System.Windows.Forms.Panel
$pnlNetTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlNetTop.Height = 85
$pnlNetTop.BackColor = [System.Drawing.Color]::FromArgb(240, 243, 246)
$tab3.Controls.Add($pnlNetTop)

$btnAutoScan = New-Object System.Windows.Forms.Button
$btnAutoScan.Text = "Varrer Rede e Atualizar Impressoras"
$btnAutoScan.Size = New-Object System.Drawing.Size(260, 34)
$btnAutoScan.Location = New-Object System.Drawing.Point(12, 10)
$btnAutoScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnAutoScan.ForeColor = [System.Drawing.Color]::White
$btnAutoScan.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnAutoScan.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$pnlNetTop.Controls.Add($btnAutoScan)

$btnToggleManual = New-Object System.Windows.Forms.Button
$btnToggleManual.Text = "Busca por Servidor Especifico..."
$btnToggleManual.Size = New-Object System.Drawing.Size(220, 34)
$btnToggleManual.Location = New-Object System.Drawing.Point(280, 10)
$pnlNetTop.Controls.Add($btnToggleManual)

$lblNetFilter = New-Object System.Windows.Forms.Label
$lblNetFilter.Text = "Filtro:"
$lblNetFilter.Location = New-Object System.Drawing.Point(505, 18)
$lblNetFilter.AutoSize = $true
$pnlNetTop.Controls.Add($lblNetFilter)

$txtFilter = New-Object System.Windows.Forms.TextBox
$txtFilter.Location = New-Object System.Drawing.Point(545, 15)
$txtFilter.Size = New-Object System.Drawing.Size(105, 23)
$pnlNetTop.Controls.Add($txtFilter)

$btnFix70911b = New-Object System.Windows.Forms.Button
$btnFix70911b.Text = "Resolver erro 709 / 11b"
$btnFix70911b.Size = New-Object System.Drawing.Size(190, 30)
$btnFix70911b.Location = New-Object System.Drawing.Point(755, 47)
$btnFix70911b.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$btnFix70911b.BackColor = [System.Drawing.Color]::FromArgb(178, 79, 18)
$btnFix70911b.ForeColor = [System.Drawing.Color]::White
$btnFix70911b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFix70911b.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$pnlNetTop.Controls.Add($btnFix70911b)

$btnFixNetwork24H2 = New-Object System.Windows.Forms.Button
$btnFixNetwork24H2.Text = "Corrigir acesso à rede (24H2)"
$script:currentWindowsBuild = Get-CurrentWindowsBuild
$script:networkAccessActionMode = Get-NetworkAccessActionMode -BuildNumber $script:currentWindowsBuild
if ($script:networkAccessActionMode -eq 'Win10PrinterDiagnosis') {
    $btnFixNetwork24H2.Text = 'Diagnóstico Win10 → 11'
}
$btnFixNetwork24H2.Size = New-Object System.Drawing.Size(190, 30)
$btnFixNetwork24H2.Location = New-Object System.Drawing.Point(755, 10)
$btnFixNetwork24H2.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$btnFixNetwork24H2.BackColor = [System.Drawing.Color]::FromArgb(35, 99, 142)
$btnFixNetwork24H2.ForeColor = [System.Drawing.Color]::White
$btnFixNetwork24H2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFixNetwork24H2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$pnlNetTop.Controls.Add($btnFixNetwork24H2)

$btnDiagnoseShare = New-Object System.Windows.Forms.Button
$btnDiagnoseShare.Text = 'Diagnóstico detalhado'
$btnDiagnoseShare.Size = New-Object System.Drawing.Size(96, 68)
$btnDiagnoseShare.Location = New-Object System.Drawing.Point(655, 10)
$btnDiagnoseShare.BackColor = [System.Drawing.Color]::FromArgb(69, 79, 92)
$btnDiagnoseShare.ForeColor = [System.Drawing.Color]::White
$btnDiagnoseShare.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlNetTop.Controls.Add($btnDiagnoseShare)

$pnlNetTop.Add_Resize({
    $left = [Math]::Max(655, $pnlNetTop.ClientSize.Width - $btnFix70911b.Width - 12)
    $btnFix70911b.Left = $left
    $btnFixNetwork24H2.Left = $left
})

$lblScanStatus = New-Object System.Windows.Forms.Label
$lblScanStatus.Text = "Status: Aguardando varredura da rede..."
$lblScanStatus.Location = New-Object System.Drawing.Point(14, 52)
$lblScanStatus.Size = New-Object System.Drawing.Size(625, 28)
$lblScanStatus.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(50, 70, 90)
$pnlNetTop.Controls.Add($lblScanStatus)

# Painel de busca manual (retrátil)
$pnlNetSearch = New-Object System.Windows.Forms.GroupBox
$pnlNetSearch.Text = "Busca Manual de Servidor de Impressao"
$pnlNetSearch.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlNetSearch.Height = 113
$pnlNetSearch.Visible = $false
$tab3.Controls.Add($pnlNetSearch)

$lblServerHost = New-Object System.Windows.Forms.Label
$lblServerHost.Text = "Servidor / IP:"
$lblServerHost.Location = New-Object System.Drawing.Point(12, 22)
$lblServerHost.AutoSize = $true
$pnlNetSearch.Controls.Add($lblServerHost)

$txtServerHost = New-Object System.Windows.Forms.TextBox
$txtServerHost.Text = ""
$txtServerHost.Location = New-Object System.Drawing.Point(95, 19)
$txtServerHost.Size = New-Object System.Drawing.Size(180, 23)
$pnlNetSearch.Controls.Add($txtServerHost)

$lblNetUser = New-Object System.Windows.Forms.Label
$lblNetUser.Text = "Usuario (Opc.):"
$lblNetUser.Location = New-Object System.Drawing.Point(290, 22)
$lblNetUser.AutoSize = $true
$pnlNetSearch.Controls.Add($lblNetUser)

$txtNetUser = New-Object System.Windows.Forms.TextBox
$txtNetUser.Location = New-Object System.Drawing.Point(380, 19)
$txtNetUser.Size = New-Object System.Drawing.Size(130, 23)
$pnlNetSearch.Controls.Add($txtNetUser)

$lblNetPass = New-Object System.Windows.Forms.Label
$lblNetPass.Text = "Senha (Memoria):"
$lblNetPass.Location = New-Object System.Drawing.Point(525, 22)
$lblNetPass.AutoSize = $true
$pnlNetSearch.Controls.Add($lblNetPass)

$txtNetPass = New-Object System.Windows.Forms.TextBox
$txtNetPass.UseSystemPasswordChar = $true
$txtNetPass.Location = New-Object System.Drawing.Point(635, 19)
$txtNetPass.Size = New-Object System.Drawing.Size(120, 23)
$pnlNetSearch.Controls.Add($txtNetPass)

$btnTestServer = New-Object System.Windows.Forms.Button
$btnTestServer.Text = "Testar Servidor (Ping/SMB)"
$btnTestServer.Location = New-Object System.Drawing.Point(15, 55)
$btnTestServer.Size = New-Object System.Drawing.Size(180, 30)
$pnlNetSearch.Controls.Add($btnTestServer)

$btnFindShares = New-Object System.Windows.Forms.Button
$btnFindShares.Text = "Buscar Compartilhamentos"
$btnFindShares.Location = New-Object System.Drawing.Point(205, 55)
$btnFindShares.Size = New-Object System.Drawing.Size(200, 30)
$btnFindShares.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnFindShares.ForeColor = [System.Drawing.Color]::White
$btnFindShares.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlNetSearch.Controls.Add($btnFindShares)

$lblNetAuthNote = New-Object System.Windows.Forms.Label
$lblNetAuthNote.Text = 'Se informar uma conta do servidor, a sessão autenticada permanecerá ativa para instalar a impressora. Ex.: SERVIDOR\usuario.'
$lblNetAuthNote.Location = New-Object System.Drawing.Point(15, 88)
$lblNetAuthNote.Size = New-Object System.Drawing.Size(820, 19)
$lblNetAuthNote.ForeColor = [System.Drawing.Color]::DimGray
$pnlNetSearch.Controls.Add($lblNetAuthNote)

$btnToggleManual.Add_Click({
    $pnlNetSearch.Visible = -not $pnlNetSearch.Visible
    if ($pnlNetSearch.Visible) {
        $btnToggleManual.Text = "Ocultar Busca por Servidor"
    } else {
        $btnToggleManual.Text = "Busca por Servidor Especifico..."
    }
})

# Tabela de compartilhamentos e impressoras de rede encontrados
$dgvNetPrinters = New-Object System.Windows.Forms.DataGridView
$dgvNetPrinters.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvNetPrinters.ReadOnly = $true
$dgvNetPrinters.AllowUserToAddRows = $false
$dgvNetPrinters.AllowUserToDeleteRows = $false
$dgvNetPrinters.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvNetPrinters.MultiSelect = $false
$dgvNetPrinters.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvNetPrinters.BackgroundColor = [System.Drawing.Color]::White
$tab3.Controls.Add($dgvNetPrinters)
$dgvNetPrinters.BringToFront()

[void]$dgvNetPrinters.Columns.Add("ShareName", "Nome da Impressora")
[void]$dgvNetPrinters.Columns.Add("Type", "Tipo / Protocolo")
[void]$dgvNetPrinters.Columns.Add("UNC", "Caminho UNC / Endereco IP")
    [void]$dgvNetPrinters.Columns.Add("Server", "Hostname \ IP")
[void]$dgvNetPrinters.Columns.Add("Status", "Status no Windows")

# Painel Inferior de Conexao
$pnlNetBottom = New-Object System.Windows.Forms.Panel
$pnlNetBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlNetBottom.Height = 65
$tab3.Controls.Add($pnlNetBottom)

$chkNetDefault = New-Object System.Windows.Forms.CheckBox
$chkNetDefault.Text = "Definir como impressora padrao apos conectar"
$chkNetDefault.Location = New-Object System.Drawing.Point(12, 12)
$chkNetDefault.AutoSize = $true
$pnlNetBottom.Controls.Add($chkNetDefault)

$chkNetTestPage = New-Object System.Windows.Forms.CheckBox
$chkNetTestPage.Text = "Imprimir pagina de teste apos conectar"
$chkNetTestPage.Location = New-Object System.Drawing.Point(12, 36)
$chkNetTestPage.AutoSize = $true
$pnlNetBottom.Controls.Add($chkNetTestPage)

$btnConnectSelected = New-Object System.Windows.Forms.Button
$btnConnectSelected.Text = "Conectar Impressora Selecionada"
$btnConnectSelected.Size = New-Object System.Drawing.Size(260, 42)
$btnConnectSelected.Location = New-Object System.Drawing.Point(620, 10)
$btnConnectSelected.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnConnectSelected.ForeColor = [System.Drawing.Color]::White
$btnConnectSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnectSelected.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$pnlNetBottom.Controls.Add($btnConnectSelected)

$btnLocalPortSelected = New-Object System.Windows.Forms.Button
$btnLocalPortSelected.Text = 'Instalar via porta local'
$btnLocalPortSelected.Size = New-Object System.Drawing.Size(225, 42)
$btnLocalPortSelected.Location = New-Object System.Drawing.Point(385, 10)
$btnLocalPortSelected.BackColor = [System.Drawing.Color]::FromArgb(20, 90, 145)
$btnLocalPortSelected.ForeColor = [System.Drawing.Color]::White
$btnLocalPortSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnLocalPortSelected.Font = New-Object System.Drawing.Font('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$pnlNetBottom.Controls.Add($btnLocalPortSelected)

function Get-SubnetAddressCandidates {
    param([string]$IPAddress, [string]$SubnetMask)
    if ($IPAddress -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        $SubnetMask -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return @() }
    try {
        $ipBytes = [System.Net.IPAddress]::Parse($IPAddress).GetAddressBytes()
        $maskBytes = [System.Net.IPAddress]::Parse($SubnetMask).GetAddressBytes()
        if ($ipBytes.Length -ne 4 -or $maskBytes.Length -ne 4) { return @() }
        [long]$ipNumber = 0
        [long]$maskNumber = 0
        for ($i = 0; $i -lt 4; $i++) {
            $ipNumber = ($ipNumber -shl 8) -bor $ipBytes[$i]
            $maskNumber = ($maskNumber -shl 8) -bor $maskBytes[$i]
        }
        [long]$network = $ipNumber -band $maskNumber
        [long]$broadcast = $network -bor ([long]4294967295 -bxor $maskNumber)
        if (($broadcast - $network - 1) -gt 254) {
            $network = $ipNumber -band [long]4294967040
            $broadcast = $network + 255
        }
        for ([long]$value = $network + 1; $value -lt $broadcast; $value++) {
            if ($value -eq $ipNumber) { continue }
            $a = ($value -shr 24) -band 255
            $b = ($value -shr 16) -band 255
            $c = ($value -shr 8) -band 255
            $d = $value -band 255
            Write-Output "$a.$b.$c.$d"
        }
    } catch { return @() }
}

function Get-PrinterDiscoveryTargets {
    param([string[]]$InitialIps = @())
    $seen = @{}
    $targets = New-Object System.Collections.ArrayList
    foreach ($ip in $InitialIps) {
        if ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and
            -not $seen.ContainsKey($ip)) {
            $seen[$ip] = $true
            [void]$targets.Add($ip)
        }
    }
    try {
        foreach ($adapter in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
            if ($adapter.OperationalStatus -ne [System.Net.NetworkInformation.OperationalStatus]::Up -or
                $adapter.NetworkInterfaceType -eq [System.Net.NetworkInformation.NetworkInterfaceType]::Loopback) { continue }
            $gateway = @($adapter.GetIPProperties().GatewayAddresses | Where-Object {
                $_.Address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and
                $_.Address.IPAddressToString -ne '0.0.0.0'
            })
            if ($gateway.Count -eq 0) { continue }
            foreach ($address in $adapter.GetIPProperties().UnicastAddresses) {
                if ($address.Address.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork -or
                    -not $address.IPv4Mask) { continue }
                $ip = $address.Address.IPAddressToString
                if ($ip -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)') { continue }
                foreach ($candidate in @(Get-SubnetAddressCandidates -IPAddress $ip -SubnetMask $address.IPv4Mask.IPAddressToString)) {
                    if ($targets.Count -ge 512) { break }
                    if (-not $seen.ContainsKey($candidate)) {
                        $seen[$candidate] = $true
                        [void]$targets.Add($candidate)
                    }
                }
            }
        }
    } catch {
        Write-AppLog -Message "Nao foi possivel obter todas as sub-redes locais: $($_.Exception.Message)" -Level "AVISO"
    }
    return $targets.ToArray()
}

function Test-OpenPrinterPorts {
    param([string[]]$Addresses, [int[]]$Ports = @(445,9100), [int]$TimeoutMs = 350)
    $found = @{}
    for ($offset = 0; $offset -lt $Addresses.Count; $offset += 24) {
        $pending = New-Object System.Collections.ArrayList
        foreach ($ip in @($Addresses[$offset..([Math]::Min($offset + 23, $Addresses.Count - 1))])) {
            foreach ($port in $Ports) {
                $client = New-Object System.Net.Sockets.TcpClient
                try {
                    $async = $client.BeginConnect($ip, $port, $null, $null)
                    [void]$pending.Add([pscustomobject]@{ Ip=$ip; Port=$port; Client=$client; Async=$async })
                } catch { $client.Close() }
            }
        }
        $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
        foreach ($item in $pending) {
            try {
                $remaining = [Math]::Max(0, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                if ($item.Async.AsyncWaitHandle.WaitOne($remaining, $false)) {
                    $item.Client.EndConnect($item.Async)
                    if (-not $found.ContainsKey($item.Ip)) { $found[$item.Ip] = @{} }
                    $found[$item.Ip][$item.Port] = $true
                }
            } catch {
            } finally {
                $item.Async.AsyncWaitHandle.Close()
                $item.Client.Close()
            }
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    return $found
}

function Invoke-NetViewSafe {
    param([string]$Server, [int]$TimeoutMs = 4000)
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = 'net.exe'
    $start.Arguments = 'view "\\' + $Server + '"'
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    try {
        $oem = [Text.Encoding]::GetEncoding([Globalization.CultureInfo]::CurrentCulture.TextInfo.OEMCodePage)
        $start.StandardOutputEncoding = $oem
        $start.StandardErrorEncoding = $oem
    } catch {}
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        if (-not $process.WaitForExit($TimeoutMs)) {
            $process.Kill()
            Write-AppLog -Message "Tempo esgotado ao listar compartilhamentos em $Server." -Level "AVISO"
            return @()
        }
        if ($process.ExitCode -ne 0) {
            Write-AppLog -Message "net view em $Server retornou codigo $($process.ExitCode); não foi possível listar os compartilhamentos desse endereço." -Level "AVISO"
        }
        return @($process.StandardOutput.ReadToEnd() -split '\r?\n')
    } finally { $process.Dispose() }
}

# Funcao Principal de Varredura Automatica de Impressoras na Rede
function Invoke-AutoNetworkScan {
    Show-LoadingIndicator -Message "Varrendo rede local e localizando impressoras..." -Button $btnAutoScan
    $lblScanStatus.Text = "Status: Varrendo rede local e buscando impressoras ativas..."
    $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
    $dgvNetPrinters.Rows.Clear()
    [System.Windows.Forms.Application]::DoEvents()
    try {

    $installed = Get-InstalledPrintersWmi
    $count = 0
    $seenUNC = @{}

    # 1. Impressoras compartilhadas no computador local (servidor de caixa/terminais)
    try {
        $localShares = Get-WmiObject -Class Win32_Share -Filter "Type = 1" -ErrorAction SilentlyContinue
        if ($localShares) {
            foreach ($ls in $localShares) {
                $unc = "\\$($env:COMPUTERNAME)\$($ls.Name)"
                if (-not $seenUNC.ContainsKey($unc)) {
                    $seenUNC[$unc] = 1
                    $status = "Disponivel para Conectar"
                    if (Test-PrinterShareInstalled -UNCPath $unc -InstalledPrinters $installed) {
                        $status = "Ja Instalada no Sistema"
                    }
                    $serverDisp = Get-HostAndIpDisplay $env:COMPUTERNAME
                    $rIdx = $dgvNetPrinters.Rows.Add($ls.Name, "Compartilhada Local (SMB)", $unc, $serverDisp, $status)
                    if ($status -like "*Ja Instalada*") {
                        $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                    } else {
                        $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
                    }
                    $count++
                }
            }
        }
    } catch {}

    # 2. Impressoras no Active Directory (caso em Dominio corporativo)
    try {
        $compSys = Get-WmiObject -Class Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($compSys -and $compSys.PartOfDomain) {
            $adSearch = [adsisearcher]"(objectCategory=printQueue)"
            $adSearch.PageSize = 50
            $adResults = $adSearch.FindAll()
            if ($adResults) {
                foreach ($r in $adResults) {
                    $props = $r.Properties
                    $unc = [string]$props["uncname"][0]
                    $pName = [string]$props["printername"][0]
                    $sName = [string]$props["servername"][0]
                    if ($unc -and -not $seenUNC.ContainsKey($unc)) {
                        $seenUNC[$unc] = 1
                        $status = "Disponivel para Conectar"
                        if (Test-PrinterShareInstalled -UNCPath $unc -InstalledPrinters $installed) {
                            $status = "Ja Instalada no Sistema"
                        }
                        $serverDisp = Get-HostAndIpDisplay $sName
                        $rIdx = $dgvNetPrinters.Rows.Add($pName, "Dominio / AD", $unc, $serverDisp, $status)
                        if ($status -like "*Ja Instalada*") {
                            $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                        } else {
                            $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
                        }
                        $count++
                    }
                }
            }
        }
    } catch {}

    # 3. ARP e sondagem limitada dos enderecos da sub-rede local
    try {
        $arpOutput = cmd.exe /c "arp -a"
        $activeIps = @()
        foreach ($line in $arpOutput) {
            if ($line -match "^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([0-9a-f\-]{17})\s+") {
                $ip = $matches[1]
                if ($ip -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' -and
                    $ip -notmatch '\.255$') {
                    $activeIps += $ip
                }
            }
        }

        $activeIps = @(Get-PrinterDiscoveryTargets -InitialIps $activeIps)
        $lblScanStatus.Text = "Status: Testando $($activeIps.Count) enderecos da rede local..."
        [System.Windows.Forms.Application]::DoEvents()
        $portMap = Test-OpenPrinterPorts -Addresses $activeIps
        foreach ($ip in $activeIps) {
            # Testar porta 9100 (Impressora RAW de rede direta)
            $is9100 = $portMap.ContainsKey($ip) -and $portMap[$ip].ContainsKey(9100)

            if ($is9100) {
                $unc = "IP_$ip"
                if (-not $seenUNC.ContainsKey($unc)) {
                    $seenUNC[$unc] = 1
                    $status = "Disponivel para Conectar"
                    if ($installed | Where-Object { ([string]$_.PortName -match [regex]::Escape($ip)) -or ([string]$_.Name -ieq "IP_$ip") }) {
                        $status = "Ja Instalada no Sistema"
                    }
                    $serverDisp = Get-HostAndIpDisplay $ip
                    $rIdx = $dgvNetPrinters.Rows.Add("Impressora RAW ($ip)", "Rede TCP/IP Direta (Porta 9100)", $unc, $serverDisp, $status)
                    if ($status -like "*Ja Instalada*") {
                        $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                    } else {
                        $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
                    }
                    $count++
                }
            }

            # Testar porta SMB 445 para descobrir compartilhamentos
            $is445 = $portMap.ContainsKey($ip) -and $portMap[$ip].ContainsKey(445)

            if ($is445) {
                try {
                    $nv = Invoke-NetViewSafe -Server $ip
                    foreach ($l in $nv) {
                        if ($l -match "(?i)^\s*(.+?)\s{2,}(Print|Impress)\S*(\s|$)") {
                            $shareName = $matches[1].Trim()
                            $srvName = Resolve-ComputerNameFromIpFast $ip
                            $unc = "\\$srvName\$shareName"
                            if (-not $seenUNC.ContainsKey($unc)) {
                                $seenUNC[$unc] = 1
                                $status = "Disponivel para Conectar"
                                if (Test-PrinterShareInstalled -UNCPath $unc -InstalledPrinters $installed) {
                                    $status = "Ja Instalada no Sistema"
                                }
                                $serverDisp = Get-HostAndIpDisplay $srvName $ip
                                $rIdx = $dgvNetPrinters.Rows.Add($shareName, "Compartilhada SMB", $unc, $serverDisp, $status)
                                if ($status -like "*Ja Instalada*") {
                                    $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
                                } else {
                                    $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
                                }
                                $count++
                            }
                        }
                    }
                } catch {}
            }
            [System.Windows.Forms.Application]::DoEvents()
        }
    } catch {}

    if ($count -gt 0) {
        $lblScanStatus.Text = "Status: $count impressora(s) localizada(s) na rede. Selecione uma na lista e clique em 'Conectar Impressora Selecionada'."
        $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
        Update-StatusStrip -Text "Varredura concluida. $count impressora(s) encontrada(s) na rede." -Color "DarkGreen" -Tag "REDE: OK"
        # Selecionar a primeira linha por conveniencia
        if ($dgvNetPrinters.Rows.Count -gt 0) {
            $dgvNetPrinters.Rows[0].Selected = $true
        }
    } else {
        $lblScanStatus.Text = "Status: Nenhuma impressora compartilhada localizada automaticamente. Utilize a busca manual por servidor ou instale por IP."
        $lblScanStatus.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        Update-StatusStrip -Text "Nenhuma impressora localizada na varredura automatica." -Color "DarkGoldenrod" -Tag "REDE: AVISO"
    }
    } finally {
        Hide-LoadingIndicator -Button $btnAutoScan
    }
}

$btnAutoScan.Add_Click({ Invoke-AutoNetworkScan })

function Wait-PrinterRepairProcess {
    param([System.Diagnostics.Process]$Process, [string]$ErrorCode)
    $progressForm = New-Object System.Windows.Forms.Form
    $progressForm.Text = "Corrigindo erro $ErrorCode"
    $progressForm.Size = New-Object System.Drawing.Size(415, 150)
    $progressForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $progressForm.ControlBox = $false
    $progressForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $progressForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "Aplicando ajustes e reiniciando o Spooler. Aguarde..."
    $label.Location = New-Object System.Drawing.Point(18, 18)
    $label.Size = New-Object System.Drawing.Size(370, 28)
    $progressForm.Controls.Add($label)
    $bar = New-Object System.Windows.Forms.ProgressBar
    $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $bar.MarqueeAnimationSpeed = 25
    $bar.Location = New-Object System.Drawing.Point(18, 58)
    $bar.Size = New-Object System.Drawing.Size(370, 22)
    $progressForm.Controls.Add($bar)
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 250
    $timer.Add_Tick({ if ($Process.HasExited) { $progressForm.Close() } })
    $progressForm.Add_Shown({ $timer.Start() })
    try { $progressForm.ShowDialog($form) | Out-Null }
    finally { $timer.Stop(); $timer.Dispose(); $progressForm.Dispose() }
    $Process.WaitForExit()
    return $Process.ExitCode
}

$btnFix70911b.Add_Click({
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Nenhuma correção 709/11b foi aplicada." -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show($form, "[MODO SIMULAÇÃO] Nenhum ajuste de Registro ou serviço foi executado.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Corrigir erro de impressora"
    $dialog.Size = New-Object System.Drawing.Size(560, 288)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = "Qual erro deseja corrigir neste computador?"
    $intro.Location = New-Object System.Drawing.Point(18, 15)
    $intro.Size = New-Object System.Drawing.Size(510, 25)
    $dialog.Controls.Add($intro)
    $opt709 = New-Object System.Windows.Forms.RadioButton
    $opt709.Text = "Erro 0x00000709"
    $opt709.Location = New-Object System.Drawing.Point(18, 51)
    $opt709.Size = New-Object System.Drawing.Size(500, 27)
    $opt709.Checked = $true
    $dialog.Controls.Add($opt709)
    $desc709 = New-Object System.Windows.Forms.Label
    $desc709.Text = "Aplica ajustes RPC compatíveis com a versão do Windows e reinicia o Spooler."
    $desc709.Location = New-Object System.Drawing.Point(39, 79)
    $desc709.Size = New-Object System.Drawing.Size(490, 34)
    $dialog.Controls.Add($desc709)
    $opt11b = New-Object System.Windows.Forms.RadioButton
    $opt11b.Text = "Erro 0x0000011b"
    $opt11b.Location = New-Object System.Drawing.Point(18, 125)
    $opt11b.Size = New-Object System.Drawing.Size(500, 27)
    $dialog.Controls.Add($opt11b)
    $desc11b = New-Object System.Windows.Forms.Label
    $desc11b.Text = "Aplica RpcAuthnLevelPrivacyEnabled=0 neste PC. Se a impressora estiver em outro PC, execute também no host."
    $desc11b.Location = New-Object System.Drawing.Point(39, 153)
    $desc11b.Size = New-Object System.Drawing.Size(490, 42)
    $dialog.Controls.Add($desc11b)
    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Executar correção"
    $btnApply.Location = New-Object System.Drawing.Point(279, 207)
    $btnApply.Size = New-Object System.Drawing.Size(140, 32)
    $btnApply.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnApply)
    $dialog.AcceptButton = $btnApply
    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(429, 207)
    $btnCancel.Size = New-Object System.Drawing.Size(99, 32)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel)
    $dialog.CancelButton = $btnCancel
    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $errorCode = if ($opt709.Checked) { "709" } else { "11b" }
    } finally { $dialog.Dispose() }
    if (-not $PrinterFixPath -or -not [IO.File]::Exists($PrinterFixPath)) {
        Write-AppLog -Message "Rotina interna do erro $errorCode ausente." -Level "ERRO"
        [System.Windows.Forms.MessageBox]::Show($form, "A rotina de correção não foi encontrada no EXE.", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $server = ""
    if ($dgvNetPrinters.SelectedRows.Count -gt 0) {
        $candidate = [string]$dgvNetPrinters.SelectedRows[0].Cells["UNC"].Value
        if ($candidate -match '^\\\\([A-Za-z0-9][A-Za-z0-9._-]{0,62})\\') { $server = $matches[1] }
    }
    $folderName = 'Erro_' + $errorCode + '_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $outputPath = Join-Path $LogsDir $folderName
    $reportPath = Join-Path $outputPath 'Relatorio.txt'
    try {
        Write-AppLog -Message "Iniciando correção direta do erro $errorCode. Servidor selecionado: $server. Relatório: $reportPath" -Level "INFO"
        Update-StatusStrip -Text "Corrigindo erro $errorCode neste computador..." -Color "DarkOrange"
        [System.Windows.Forms.Application]::DoEvents()
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PrinterFixPath + '" -ErrorCode ' + $errorCode + ' -OutputDirectory "' + $outputPath + '" -PrinterServer "' + $server + '"'
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -PassThru -ErrorAction Stop
        $exitCode = Wait-PrinterRepairProcess -Process $process -ErrorCode $errorCode
        $result = if ($exitCode -eq 0) { 'Ajustes locais aplicados e confirmados.' } elseif ($exitCode -eq 10) { 'Ajustes locais aplicados; há verificações pendentes.' } else { "Correção não concluída (código $exitCode)." }
        $notes = @()
        if ([IO.File]::Exists($reportPath)) {
            $notes = @(Get-Content -LiteralPath $reportPath | Where-Object { $_ -like 'AVISO:*' })
        }
        $message = $result + [Environment]::NewLine + [Environment]::NewLine + ($notes -join [Environment]::NewLine) + [Environment]::NewLine + [Environment]::NewLine + "Relatório: $reportPath"
        $level = if ($exitCode -eq 0) { "SUCESSO" } else { "AVISO" }
        $color = if ($exitCode -eq 0) { "DarkGreen" } else { "DarkOrange" }
        Write-AppLog -Message "$result Relatório: $reportPath" -Level $level
        Update-StatusStrip -Text $result -Color $color
        $icon = if ($exitCode -ge 20) { [System.Windows.Forms.MessageBoxIcon]::Error } elseif ($exitCode -eq 10) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Information }
        [System.Windows.Forms.MessageBox]::Show($form, $message, "Erro $errorCode", [System.Windows.Forms.MessageBoxButtons]::OK, $icon) | Out-Null
    } catch {
        Write-AppLog -Message ("Falha ao iniciar correção {0}: {1}" -f $errorCode,$_.Exception.Message) -Level "ERRO"
        Update-StatusStrip -Text "Falha ao iniciar correção $errorCode." -Color "DarkRed"
        [System.Windows.Forms.MessageBox]::Show($form, "Não foi possível iniciar a correção: $($_.Exception.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

$btnFixNetwork24H2.Add_Click({
    if ($script:networkAccessActionMode -eq 'Win10PrinterDiagnosis') {
        if ($dgvNetPrinters.SelectedRows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show($form, 'Selecione a impressora compartilhada na lista antes de abrir o diagnóstico.', 'Diagnóstico Win10 → 11', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $row = $dgvNetPrinters.SelectedRows[0]
        $unc = Format-PrinterAsNamedUNC ([string]$row.Cells['UNC'].Value)
        $alternateIp = ''
        $serverDisplay = [string]$row.Cells['Server'].Value
        if ($serverDisplay -match '((?:\d{1,3}\.){3}\d{1,3})') { $alternateIp = $matches[1] }
        $diagnosis = Get-SharedPrinterAccessDiagnosis -UNCPath $unc -AlternateHost $alternateIp
        Write-AppLog -Message ("Diagnóstico Win10 → 11: " + ($diagnosis.Message -replace "`r?`n", ' | ')) -Level 'INFO'
        $message = $diagnosis.Message + "`n`nA correção 24H2 altera SMB e não resolve a instalação do driver desta impressora no Windows 10."
        if ($diagnosis.RemoteQueueStatus -eq 'acesso negado') {
            $pnlNetSearch.Visible = $true
            $txtServerHost.Text = [string]$diagnosis.Server
            if ($script:authenticatedPrinterServer -ieq $diagnosis.Server) {
                $message += "`n`nA sessão SMB já foi autenticada como $script:authenticatedPrinterUser. A consulta de gerenciamento negada não comprova que a impressão será negada. Tente conectar; se falhar, confira o driver e execute o EXE como administrador."
            } else {
                $message += "`n`nDigite acima o usuário e a senha de uma conta do computador servidor, clique em 'Buscar Compartilhamentos' e tente a conexão. Use a senha da conta, não o PIN."
            }
            [System.Windows.Forms.MessageBox]::Show($form, $message, 'Autenticação necessária',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            $txtNetUser.Focus() | Out-Null
            return
        }
        if (-not $diagnosis.Valid -or -not $diagnosis.SMBReachable -or $global:SimulationMode) {
            if ($global:SimulationMode) { $message += "`n`nO modo Simulação bloqueia a instalação." }
            [System.Windows.Forms.MessageBox]::Show($form, $message, 'Diagnóstico Win10 → 11', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            return
        }
        $message += "`n`nDeseja instalar uma fila local com a porta $unc? O driver precisa estar instalado neste PC."
        $answer = [System.Windows.Forms.MessageBox]::Show($form, $message, 'Diagnóstico Win10 → 11', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
            $localResult = Show-LocalPortFallbackDialog -UNCPath $unc -AlternateHost $alternateIp -Direct
            if ($localResult -and $localResult.Success) {
                Refresh-PrintersGrid
                $row.Cells['Status'].Value = 'Ja Instalada no Sistema'
                Update-StatusStrip -Text "Fila $($localResult.ConnectedUNC) instalada na porta $($localResult.PortUNC)." -Color 'DarkGreen'
                [System.Windows.Forms.MessageBox]::Show($form, "Fila instalada: $($localResult.ConnectedUNC)`nPorta: $($localResult.PortUNC)`n`nQuando a impressora física estiver conectada, imprima uma página de teste para confirmar a comunicação.", 'Instalação concluída', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            }
        }
        return
    }
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] A correção de acesso à rede 24H2 não foi executada." -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show($form, "[MODO SIMULAÇÃO] Nenhuma configuração SMB ou RPC foi alterada.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Corrigir acesso à rede após atualização 24H2"
    $dialog.Size = New-Object System.Drawing.Size(610, 326)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $intro = New-Object System.Windows.Forms.Label
    $intro.Text = "Escolha a função deste PC. A rotina altera configurações SMB deste computador, salva os valores anteriores e gera um script de restauração."
    $intro.Location = New-Object System.Drawing.Point(18, 15)
    $intro.Size = New-Object System.Drawing.Size(560, 42)
    $dialog.Controls.Add($intro)

    $optClient = New-Object System.Windows.Forms.RadioButton
    $optClient.Text = "Cliente: este PC não acessa a impressora ou pasta compartilhada"
    $optClient.Location = New-Object System.Drawing.Point(18, 64)
    $optClient.Size = New-Object System.Drawing.Size(560, 27)
    $optClient.Checked = $true
    $dialog.Controls.Add($optClient)

    $descClient = New-Object System.Windows.Forms.Label
    $descClient.Text = "Permite acesso SMB como convidado e desativa a exigência de assinatura no cliente. Define AllowInsecureGuestAuth=1."
    $descClient.Location = New-Object System.Drawing.Point(39, 92)
    $descClient.Size = New-Object System.Drawing.Size(540, 42)
    $dialog.Controls.Add($descClient)

    $optHost = New-Object System.Windows.Forms.RadioButton
    $optHost.Text = "Host: este PC compartilha a impressora ou pasta"
    $optHost.Location = New-Object System.Drawing.Point(18, 145)
    $optHost.Size = New-Object System.Drawing.Size(560, 27)
    $dialog.Controls.Add($optHost)

    $descHost = New-Object System.Windows.Forms.Label
    $descHost.Text = "Desativa a exigência de assinatura no servidor. No Windows 11 22H2+, define RpcProtocols=7 para impressão."
    $descHost.Location = New-Object System.Drawing.Point(39, 173)
    $descHost.Size = New-Object System.Drawing.Size(540, 42)
    $dialog.Controls.Add($descHost)

    $btnApply = New-Object System.Windows.Forms.Button
    $btnApply.Text = "Executar correção"
    $btnApply.Location = New-Object System.Drawing.Point(328, 233)
    $btnApply.Size = New-Object System.Drawing.Size(142, 34)
    $btnApply.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnApply)
    $dialog.AcceptButton = $btnApply

    $btnCancel = New-Object System.Windows.Forms.Button
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = New-Object System.Drawing.Point(480, 233)
    $btnCancel.Size = New-Object System.Drawing.Size(100, 34)
    $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($btnCancel)
    $dialog.CancelButton = $btnCancel

    try {
        if ($dialog.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) { return }
        $repairRole = if ($optClient.Checked) { 'Cliente' } else { 'Host' }
    } finally {
        $dialog.Dispose()
    }

    if (-not $NetworkFixPath -or -not [IO.File]::Exists($NetworkFixPath)) {
        Write-AppLog -Message 'Rotina de acesso à rede ausente no pacote.' -Level 'ERRO'
        [System.Windows.Forms.MessageBox]::Show($form, "A rotina interna de rede não foi encontrada. Use a versão atualizada do EXE.", "Correção indisponível", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }

    $folderName = 'Rede_24H2_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [Guid]::NewGuid().ToString('N').Substring(0, 6)
    $outputPath = Join-Path $LogsDir $folderName
    $reportPath = Join-Path $outputPath 'Relatorio.txt'
    try {
        Write-AppLog -Message "Iniciando correção de rede 24H2 no papel $repairRole. Relatório: $reportPath" -Level 'INFO'
        Update-StatusStrip -Text "Aplicando correção de rede 24H2 neste PC ($repairRole)..." -Color 'DarkOrange'
        [System.Windows.Forms.Application]::DoEvents()
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $NetworkFixPath + '" -Role ' + $repairRole + ' -OutputDirectory "' + $outputPath + '"'
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden -Wait -PassThru -ErrorAction Stop
        $exitCode = $process.ExitCode
        $resultText = if ($exitCode -eq 0) { 'Correção confirmada pelo Windows.' } else { "Correção não concluída (código $exitCode)." }
        $level = if ($exitCode -eq 0) { 'SUCESSO' } else { 'AVISO' }
        $color = if ($exitCode -eq 0) { 'DarkGreen' } else { 'DarkRed' }
        Write-AppLog -Message "$resultText Relatório: $reportPath" -Level $level
        Update-StatusStrip -Text $resultText -Color $color
        [System.Windows.Forms.MessageBox]::Show($form, "$resultText`n`nRelatório: $reportPath`nRestauração: $outputPath\RESTAURAR-ACESSO-REDE.ps1", "Acesso à rede 24H2", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    } catch {
        Write-AppLog -Message "Falha ao iniciar correção de rede: $($_.Exception.Message)" -Level 'ERRO'
        Update-StatusStrip -Text 'Falha ao iniciar correção de rede 24H2.' -Color 'DarkRed'
        [System.Windows.Forms.MessageBox]::Show($form, "Não foi possível iniciar a correção:`n$($_.Exception.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    }
})

# Filtro em tempo real na tabela
$txtFilter.Add_TextChanged({
    $term = $txtFilter.Text.Trim()
    foreach ($row in $dgvNetPrinters.Rows) {
        if (-not $term) {
            $row.Visible = $true
        } else {
            $match = ($row.Cells["ShareName"].Value -like "*$term*") -or
                     ($row.Cells["UNC"].Value -like "*$term*") -or
                     ($row.Cells["Server"].Value -like "*$term*")
            $row.Visible = $match
        }
    }
})

# Acao: Testar Conexao com Servidor (Busca Manual)
$btnTestServer.Add_Click({
    $server = $txtServerHost.Text.Trim().TrimStart("\")
    if (-not $server) {
        [System.Windows.Forms.MessageBox]::Show("Informe o nome do servidor ou endereco IP.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    Update-StatusStrip -Text "Testando comunicacao com $server..." -Color "Blue"
    [System.Windows.Forms.Application]::DoEvents()

    $pingOk = Test-HostPingSafe -HostOrIp $server -TimeoutMs 1500
    $smb445 = Test-TcpPortSafe -HostOrIp $server -Port 445 -TimeoutMs 1500
    $smb139 = Test-TcpPortSafe -HostOrIp $server -Port 139 -TimeoutMs 1500

    $msg = "Resultado do teste para o servidor: $server`n`n" +
           "- Resposta de Ping (ICMP): $(if ($pingOk) { 'SUCESSO' } else { 'FALHA / BLOQUEADO POR FIREWALL' })`n" +
           "- Porta SMB 445 (TCP): $(if ($smb445) { 'ABERTA (Recomendado)' } else { 'FECHADA' })`n" +
           "- Porta NetBIOS 139 (TCP): $(if ($smb139) { 'ABERTA' } else { 'FECHADA' })`n`n"

    if ($smb445 -or $smb139) {
        $msg += "O servidor esta respondendo para compartilhamento de arquivos e impressoras."
        [System.Windows.Forms.MessageBox]::Show($msg, "Comunicacao Confirmada", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        Update-StatusStrip -Text "Servidor $server acessivel via rede." -Color "DarkGreen"
    } else {
        $msg += "ATENCAO: O servidor nao respondeu nas portas SMB (445/139). Verifique se o compartilhamento esta ativado e se o firewall permite trafego."
        [System.Windows.Forms.MessageBox]::Show($msg, "Falha de Comunicacao", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        Update-StatusStrip -Text "Servidor $server inacessivel nas portas SMB." -Color "DarkRed"
    }
})

# Acao: Buscar Impressoras Compartilhadas (Manual)
$btnFindShares.Add_Click({
    $server = $txtServerHost.Text.Trim().TrimStart("\")
    if ($server -notmatch '^[A-Za-z0-9._-]+$') {
        [System.Windows.Forms.MessageBox]::Show("Informe um nome ou IPv4 válido do servidor.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    Update-StatusStrip -Text "Buscando compartilhamentos de impressao em \\$server..." -Color "Blue"
    [System.Windows.Forms.Application]::DoEvents()

    # Manter a sessão SMB autenticada para a instalação subsequente.
    $user = $txtNetUser.Text.Trim()
    $pass = $txtNetPass.Text
    if (($user -and -not $pass) -or ($pass -and -not $user)) {
        $txtNetPass.Clear()
        [System.Windows.Forms.MessageBox]::Show($form, 'Informe usuário e senha juntos para autenticar no servidor.', 'Credenciais incompletas', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($user -and $pass -and -not $global:SimulationMode) {
        $credential = New-Object System.Management.Automation.PSCredential($user,(ConvertTo-SecureString $pass -AsPlainText -Force))
        $auth = Connect-PrinterServerAuthenticated -Server $server -User $user -Password $pass
        $txtNetPass.Clear()
        $pass = $null
        if (-not $auth.Success) {
            $credential = $null
            Write-AppLog -Message "Autenticação em $server falhou com código $($auth.Code)." -Level 'AVISO'
            [System.Windows.Forms.MessageBox]::Show($form, $auth.Message, 'Autenticação no servidor', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        Write-AppLog -Message "Sessão autenticada em $server com a conta $user; será mantida para a instalação." -Level 'SUCESSO'
        $script:authenticatedPrinterServer = $server
        $script:authenticatedPrinterUser = $user
        $script:authenticatedPrinterCredential = $credential
        $credential = $null
    } elseif ($user -and $pass -and $global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] A autenticação SMB em $server não foi executada." -Level "SIMULACAO"
        $txtNetPass.Clear()
        $pass = $null
    }

    $sharesFound = @()
    try {
        $netViewOutput = Invoke-NetViewSafe -Server $server
        foreach ($line in $netViewOutput) {
            if ($line -match "(?i)^\s*(.+?)\s{2,}(Print|Impress)\S*(\s|$)") {
                $sName = $matches[1].Trim()
                $sharesFound += $sName
            }
        }
    } catch {
        Write-AppLog -Message "Erro ao executar net view: $($_.Exception.Message)" -Level "AVISO"
    }

    $installed = Get-InstalledPrintersWmi
    $count = 0
    foreach ($s in $sharesFound) {
        # O nome/IP da fila precisa coincidir com o destino da sessão SMB autenticada.
        $resolvedServer = $server
        $unc = "\\$resolvedServer\$s"
        $status = "Disponivel para Conectar"
        if (Test-PrinterShareInstalled -UNCPath $unc -InstalledPrinters $installed) {
            $status = "Ja Instalada no Sistema"
        }

        $existingRow = $null
        foreach ($gridRow in $dgvNetPrinters.Rows) {
            if ([string]$gridRow.Cells['UNC'].Value -ieq $unc) { $existingRow = $gridRow; break }
        }
        if ($existingRow) {
            $existingRow.Cells['Status'].Value = $status
            $count++
            continue
        }

        $serverDisp = Get-HostAndIpDisplay $resolvedServer
        $rIndex = $dgvNetPrinters.Rows.Add($s, "Compartilhada SMB", $unc, $serverDisp, $status)
        if ($status -like "*Ja Instalada*") {
            $dgvNetPrinters.Rows[$rIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
        } else {
            $dgvNetPrinters.Rows[$rIndex].DefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        }
        $count++
    }

    if ($count -eq 0) {
        Update-StatusStrip -Text "Nenhuma impressora compartilhada encontrada em \\$server." -Color "DarkGoldenrod"
        $resp = [System.Windows.Forms.MessageBox]::Show("Nenhum compartilhamento de impressao foi detectado automaticamente em \\$server.`n`nDeseja adicionar manualmente pelo caminho na aba '4. Instalar por Caminho'?", "Nenhuma Impressora Localizada", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            $tabControl.SelectedTab = $tab4
            $txtManualUNC.Text = "\\$server\"
        }
    } else {
        Update-StatusStrip -Text "$count impressora(s) compartilhada(s) encontrada(s)." -Color "DarkGreen"
        $lblScanStatus.Text = "Status: $count compartilhamento(s) encontrado(s) em \\$server."
        $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    }
})

$btnDiagnoseShare.Add_Click({
    if ($dgvNetPrinters.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show($form, 'Selecione uma impressora compartilhada na lista.', 'Diagnóstico detalhado', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $unc = Format-PrinterAsNamedUNC ([string]$dgvNetPrinters.SelectedRows[0].Cells['UNC'].Value)
    if ($unc -notmatch '^\\\\([^\\]+)\\([^\\]+)$') {
        [System.Windows.Forms.MessageBox]::Show($form, 'O diagnóstico detalhado requer o caminho \\SERVIDOR\Fila.', 'Diagnóstico detalhado', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    if (-not $CompatibilityDiagnosisPath -or -not (Test-Path -LiteralPath $CompatibilityDiagnosisPath)) {
        [System.Windows.Forms.MessageBox]::Show($form, 'O recurso de diagnóstico não foi encontrado neste EXE.', 'Diagnóstico detalhado', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
        return
    }
    $server = $matches[1]
    $share = $matches[2]
    try {
        $btnDiagnoseShare.Enabled = $false
        Update-StatusStrip -Text "Diagnosticando $unc..." -Color 'Blue'
        [System.Windows.Forms.Application]::DoEvents()
        $reportOutput = @(& $CompatibilityDiagnosisPath -Servidor $server -Compartilhamento $share -OutputDirectory $LogsDir)
        $reportLine = @($reportOutput | Where-Object { $_ -like 'REPORT_PATH=*' } | Select-Object -First 1)
        if (-not $reportLine.Count) { throw 'O diagnóstico não informou onde gravou o relatório.' }
        $reportPath = ([string]$reportLine[0]).Substring('REPORT_PATH='.Length).Trim()
        if (-not (Test-Path -LiteralPath $reportPath -PathType Leaf)) { throw 'O arquivo de diagnóstico não foi criado.' }
        Write-AppLog -Message "Diagnóstico detalhado salvo em $reportPath." -Level 'INFO'
        Update-StatusStrip -Text "Diagnóstico salvo em $reportPath." -Color 'DarkGreen'
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"{0}"' -f $reportPath) -ErrorAction Stop | Out-Null
    } catch {
        Write-AppLog -Message "Diagnóstico detalhado falhou: $($_.Exception.Message)" -Level 'ERRO'
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Diagnóstico detalhado', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $btnDiagnoseShare.Enabled = $true
    }
})

$btnLocalPortSelected.Add_Click({
    if ($dgvNetPrinters.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show('Selecione uma impressora compartilhada na tabela.', 'Aviso', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $selectedRow = $dgvNetPrinters.SelectedRows[0]
    $tipo = [string]$selectedRow.Cells['Type'].Value
    $unc = Format-PrinterAsNamedUNC ([string]$selectedRow.Cells['UNC'].Value)
    if ($tipo -like '*TCP/IP*' -or $unc -notmatch '^\\\\[^\\]+\\[^\\]+$') {
        [System.Windows.Forms.MessageBox]::Show('A porta local é para uma impressora compartilhada no formato \\SERVIDOR\Fila. Para uma impressora com IP próprio, use Instalar por IP.', 'Caminho inválido', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($global:SimulationMode) {
        [System.Windows.Forms.MessageBox]::Show('[MODO SIMULAÇÃO] Nenhuma porta ou impressora foi criada.', 'Simulação', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $server = ([regex]::Match($unc, '^\\\\([^\\]+)\\')).Groups[1].Value
    $srvDisplay = [string]$selectedRow.Cells['Server'].Value
    $alternateIp = ''
    if ($srvDisplay -match '((?:\d{1,3}\.){3}\d{1,3})') { $alternateIp = $matches[1] }
    $nameReachable = Test-TcpPortSafe -HostOrIp $server -Port 445 -TimeoutMs 1500
    $ipReachable = $alternateIp -and (Test-TcpPortSafe -HostOrIp $alternateIp -Port 445 -TimeoutMs 1500)
    if (-not $nameReachable -and -not $ipReachable) {
        [System.Windows.Forms.MessageBox]::Show('O computador que compartilha a impressora não responde na porta SMB 445 pelo nome nem pelo IP. Verifique a rede antes de instalar a fila.', 'Servidor inacessível', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $localResult = Show-LocalPortFallbackDialog -UNCPath $unc -AlternateHost $alternateIp -Direct
    if (-not $localResult -or -not $localResult.Success) { return }
    $localName = [string]$localResult.ConnectedUNC
    if ($chkNetDefault.Checked) { Set-DefaultPrinterSafe -PrinterName $localName | Out-Null }
    if ($chkNetTestPage.Checked) { Invoke-PrintUICommand -Arguments ('/k /n "' + $localName + '"') | Out-Null }
    Refresh-PrintersGrid
    $selectedRow.Cells['Status'].Value = 'Ja Instalada no Sistema'
    $selectedRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
    Update-StatusStrip -Text "Fila $localName instalada neste PC." -Color 'DarkGreen'
    $message = "Fila instalada neste PC: $localName`nPorta: $($localResult.PortUNC)`n`nImprima uma página de teste para confirmar a impressão.`n`nDeseja abrir a fila agora?"
    if ([System.Windows.Forms.MessageBox]::Show($message, 'Instalação concluída', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information) -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-PrintUICommand -Arguments ('/o /n "' + $localName + '"') -NoWait | Out-Null
    }
})

# Acao: Conectar Impressora Selecionada (1 Clique)
$btnConnectSelected.Add_Click({
    if ($dgvNetPrinters.SelectedRows.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na tabela acima.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $unc = [string]$dgvNetPrinters.SelectedRows[0].Cells["UNC"].Value
    $unc = Format-PrinterAsNamedUNC $unc
    $tipo = [string]$dgvNetPrinters.SelectedRows[0].Cells["Type"].Value
    $pName = [string]$dgvNetPrinters.SelectedRows[0].Cells["ShareName"].Value
    $srv = [string]$dgvNetPrinters.SelectedRows[0].Cells["Server"].Value

    # Se for impressora TCP/IP direta (Porta 9100)
    if ($tipo -like "*TCP/IP*" -or $unc -match "^IP_") {
        $ip = if ($srv.Contains(" \ ")) { $srv.Split("\")[1].Trim() } else { $srv }
        $resp = [System.Windows.Forms.MessageBox]::Show("A impressora '$pName' e do tipo Rede Direta TCP/IP (IP: $ip, Porta 9100).`n`nDeseja abrir a aba '5. Instalar por IP' com os campos preenchidos para selecionar o driver e instalar?", "Instalar Impressora TCP/IP", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            $txtIPAddr.Text = $ip
            $txtIPPrinterName.Text = "Impressora_$($ip.Replace('.', '_'))"
            $tabControl.SelectedTab = $tab5
        }
        return
    }

    # A busca manual não é obrigatória para autenticar: o botão de conexão
    # aplica as credenciais preenchidas à fila selecionada antes de chamar RPC.
    $serverForConnection = ([regex]::Match($unc, '^\\\\([^\\]+)\\')).Groups[1].Value
    $enteredUser = $txtNetUser.Text.Trim()
    $enteredPassword = $txtNetPass.Text
    $storedCredentialMatches = $script:authenticatedPrinterServer -ieq $serverForConnection -and
        $script:authenticatedPrinterCredential -and
        (-not $enteredUser -or $script:authenticatedPrinterUser -ieq $enteredUser)
    if (-not $global:SimulationMode -and -not ($enteredUser -and $enteredPassword) -and -not $storedCredentialMatches) {
        $authChoice = Request-PrinterServerCredential -Server $serverForConnection -InitialUser $enteredUser -Parent $form
        if ($authChoice.Cancelled) { return }
        if ($authChoice.WithoutCredential) {
            $enteredUser = ''
            $enteredPassword = ''
            $script:authenticatedPrinterServer = ''
            $script:authenticatedPrinterUser = ''
            $script:authenticatedPrinterCredential = $null
            Write-AppLog -Message "Usuário escolheu tentar $serverForConnection sem credenciais explícitas." -Level 'AVISO'
        } else {
            $enteredUser = [string]$authChoice.User
            $enteredPassword = [string]$authChoice.Password
            if (-not $enteredUser -or -not $enteredPassword) {
                [System.Windows.Forms.MessageBox]::Show($form, 'Preencha usuário e senha da conta do servidor.',
                    'Credenciais incompletas', [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                return
            }
            $txtNetUser.Text = $enteredUser
        }
    }
    if (($enteredUser -and -not $enteredPassword -and
        ($script:authenticatedPrinterServer -ine $serverForConnection -or $script:authenticatedPrinterUser -ine $enteredUser)) -or
        ($enteredPassword -and -not $enteredUser)) {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Informe usuário e senha juntos. Use uma conta do computador $serverForConnection e a senha da conta, não o PIN.",
            'Credenciais incompletas', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if ($enteredUser -and $enteredPassword -and -not $global:SimulationMode) {
        $newCredential = New-Object System.Management.Automation.PSCredential($enteredUser,(ConvertTo-SecureString $enteredPassword -AsPlainText -Force))
        $auth = Connect-PrinterServerAuthenticated -Server $serverForConnection -User $enteredUser -Password $enteredPassword
        $txtNetPass.Clear()
        $enteredPassword = $null
        if (-not $auth.Success) {
            $newCredential = $null
            Write-AppLog -Message "Autenticação de impressão em $serverForConnection falhou com código $($auth.Code)." -Level 'AVISO'
            [System.Windows.Forms.MessageBox]::Show($form, $auth.Message, 'Autenticação no servidor',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $script:authenticatedPrinterServer = $serverForConnection
        $script:authenticatedPrinterUser = $enteredUser
        $script:authenticatedPrinterCredential = $newCredential
        $newCredential = $null
        Write-AppLog -Message "Credenciais de $enteredUser confirmadas para $serverForConnection ao clicar em Conectar." -Level 'SUCESSO'
    }

    # Se for impressora compartilhada de rede (SMB / UNC)
    try {
        $script:cancelPrinterConnection = $false
        $btnCancelConnection.Enabled = $true
        $btnCancelConnection.Visible = $true
        Show-LoadingIndicator -Message "Conectando a impressora $unc..." -Button $btnConnectSelected
        $alternateIp = ''
        if ($srv -match '((?:\d{1,3}\.){3}\d{1,3})') { $alternateIp = $matches[1] }
        $result = Connect-UNCPrinterSafe -UNCPath $unc -AlternateHost $alternateIp
        $fallbackHandled = $false
        if (-not $result.Success -and -not $result.Simulated -and $result.Code -notin @(53,1223,1801) -and $script:currentWindowsBuild -lt 22000) {
            $btnCancelConnection.Visible = $false
            Hide-LoadingIndicator -Button $btnConnectSelected
            $offer = Offer-Win10LocalPortFallback -UNCPath $unc -AlternateHost $alternateIp -PreviousResult $result
            $fallbackHandled = [bool]$offer.Handled
            if ($offer.Result) { $result = $offer.Result }
        }
    if ($result.Simulated) {
        Update-StatusStrip -Text "Simulação concluída: $unc não foi conectado." -Color "DarkGoldenrod" -Tag "SIMULAÇÃO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhuma impressora foi conectada.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    if ($result.Success) {
        $connectedUNC = if ($result.ConnectedUNC) { [string]$result.ConnectedUNC } else { $unc }
        if ($chkNetDefault.Checked) {
            Set-DefaultPrinterSafe -PrinterName $connectedUNC | Out-Null
        }
        if ($chkNetTestPage.Checked) {
            Invoke-PrintUICommand -Arguments ('/k /n "' + $connectedUNC + '"') | Out-Null
        }

        # Atualizar tabelas
        Refresh-PrintersGrid
        $dgvNetPrinters.SelectedRows[0].Cells["Status"].Value = "Ja Instalada no Sistema"
        $dgvNetPrinters.SelectedRows[0].Cells["UNC"].Value = $(if ($result.LocalPort) { $unc } else { $connectedUNC })
        $dgvNetPrinters.SelectedRows[0].DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray

        Update-StatusStrip -Text "Impressora $connectedUNC conectada com sucesso." -Color "DarkGreen"

        $posMsg = if ($result.LocalPort) {
            "Fila instalada neste PC: $connectedUNC`nPorta: $($result.PortUNC)`n`nAbra a fila e imprima uma página de teste para confirmar a impressão.`n`nDeseja abrir a fila agora?"
        } else {
            "A impressora foi conectada com sucesso!`n`n$connectedUNC`n`nA conexao permanecera salva no Windows mesmo apos fechar o assistente.`n`nDeseja abrir a fila de impressao agora?"
        }
        $resp = [System.Windows.Forms.MessageBox]::Show($posMsg, "Sucesso", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            Invoke-PrintUICommand -Arguments ('/o /n "' + $connectedUNC + '"') -NoWait | Out-Null
        }
    } elseif ($result.Code -eq 1223) {
        Update-StatusStrip -Text 'Conexão cancelada.' -Color 'DarkGoldenrod'
    } elseif ($result.Code -eq 1797) {
        Update-StatusStrip -Text 'Acesso à fila confirmado; falta o driver no Windows 10.' -Color 'DarkOrange'
        $message = "$($result.Message)`n`nUse 'Instalar via porta local' > 'Instalar driver...' para abrir o instalador do fabricante. Depois feche essa janela e clique novamente em 'Conectar Impressora Selecionada'."
        [System.Windows.Forms.MessageBox]::Show($form, $message, 'Driver necessário no cliente',
            [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    } elseif ($result.Code -eq 1801) {
        $serverForAuth = ([regex]::Match($unc, '^\\\\([^\\]+)\\')).Groups[1].Value
        $pnlNetSearch.Visible = $true
        $txtServerHost.Text = $serverForAuth
        $authAdvice = if ($script:authenticatedPrinterServer -ieq $serverForAuth) {
            "A sessão SMB já foi autenticada como $script:authenticatedPrinterUser. O erro persistiu após a autenticação.`n"
        } else {
            "Esta tentativa usou a conta local $env:USERDOMAIN\$env:USERNAME, sem credenciais do servidor. Clique novamente em 'Conectar Impressora Selecionada' e informe a conta de $serverForAuth quando solicitado. Use a senha da conta, não o PIN.`n"
        }
        $advice = "A fila $unc existe na rede, mas o Windows recusou a conexão com 0x80070709.`n`n" +
            $authAdvice +
            "Se o driver não estiver instalado neste PC, a instalação exige administrador. O botão 'Instalar via porta local' aceita o INF do fabricante e pede a elevação do Windows.`n`n" +
            "O diagnóstico da rede não comprova permissão na fila. A impressora física também precisa estar conectada para validar uma página de teste."
        if (-not (Test-IsAdmin) -and $LauncherPath -and (Test-Path -LiteralPath $LauncherPath -PathType Leaf)) {
            $answer = [System.Windows.Forms.MessageBox]::Show($form,
                $advice + "`n`nDeseja reabrir este EXE como administrador agora? Depois da elevação, autentique-se novamente no servidor.",
                'Falha ao conectar impressora', [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($answer -eq [System.Windows.Forms.DialogResult]::Yes) {
                try {
                    Start-Process -FilePath $LauncherPath -Verb RunAs -ErrorAction Stop | Out-Null
                    Write-AppLog -Message 'Reabertura como administrador solicitada após erro 0x80070709.' -Level 'INFO'
                    $form.Close()
                    return
                } catch {
                    Write-AppLog -Message "Reabertura como administrador não concluída: $($_.Exception.Message)" -Level 'AVISO'
                }
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show($form, $advice, 'Falha ao conectar impressora',
                [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
        $txtNetUser.Focus() | Out-Null
        $statusAdvice = if ($script:authenticatedPrinterServer -ieq $serverForAuth) { 'sessão autenticada; confira driver e elevação' } else { "autentique-se em $serverForAuth e confira o driver" }
        Update-StatusStrip -Text "Conexão recusada: $statusAdvice." -Color 'DarkRed'
    } elseif ($fallbackHandled) {
        Update-StatusStrip -Text "Conexão normal não instalada: $unc. A instalação por porta local pode ser tentada pelo botão dedicado." -Color 'DarkRed'
    } else {
        Update-StatusStrip -Text "Falha ao conectar impressora: $($result.Message)" -Color "DarkRed"
        $detalhes = "Não foi possível conectar $unc.`n`n$($result.Message)`n`nConfira o log para os detalhes. Se o driver já estiver instalado neste PC, selecione a impressora e use 'Instalar via porta local'."
        [System.Windows.Forms.MessageBox]::Show($detalhes, 'Falha na conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
    }
    } catch {
        Write-AppLog -Message "Falha inesperada ao conectar ${unc}: $($_.Exception.Message)" -Level 'ERRO'
        Update-StatusStrip -Text "Falha ao conectar ${unc}: $($_.Exception.Message)" -Color 'DarkRed'
        [System.Windows.Forms.MessageBox]::Show("Não foi possível concluir a conexão de $unc.`n`n$($_.Exception.Message)", 'Falha na conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $btnCancelConnection.Visible = $false
        $script:cancelPrinterConnection = $false
        Hide-LoadingIndicator -Button $btnConnectSelected
    }
})

# ==============================================================================
# ==============================================================================
# ABA 4: INSTALAR POR CAMINHO MANUAL (\\SERVIDOR\IMPRESSORA)
# ==============================================================================
$pnlManual = New-Object System.Windows.Forms.GroupBox
$pnlManual.Text = "Conectar Impressora por Caminho de Rede (UNC)"
$pnlManual.Location = New-Object System.Drawing.Point(20, 20)
$pnlManual.Size = New-Object System.Drawing.Size(920, 360)
$tab4.Controls.Add($pnlManual)

$lblManualDesc = New-Object System.Windows.Forms.Label
$lblManualDesc.Text = ("Digite o caminho no formato \\NOME_DO_COMPUTADOR\COMPARTILHAMENTO (recomendado para evitar falhas com IP din" + [char]0xE2 + "mico/DHCP):")
$lblManualDesc.Location = New-Object System.Drawing.Point(20, 30)
$lblManualDesc.AutoSize = $true
$pnlManual.Controls.Add($lblManualDesc)

$txtManualUNC = New-Object System.Windows.Forms.TextBox
$txtManualUNC.Text = "\\SERVIDOR\IMPRESSORA"
$txtManualUNC.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$txtManualUNC.Location = New-Object System.Drawing.Point(20, 55)
$txtManualUNC.Size = New-Object System.Drawing.Size(560, 27)
$pnlManual.Controls.Add($txtManualUNC)

$btnTestPath = New-Object System.Windows.Forms.Button
$btnTestPath.Text = "Testar Caminho"
$btnTestPath.Location = New-Object System.Drawing.Point(595, 53)
$btnTestPath.Size = New-Object System.Drawing.Size(140, 31)
$pnlManual.Controls.Add($btnTestPath)

$chkManualDefault = New-Object System.Windows.Forms.CheckBox
$chkManualDefault.Text = "Definir como impressora padrão após conectar"
$chkManualDefault.Location = New-Object System.Drawing.Point(20, 100)
$chkManualDefault.AutoSize = $true
$pnlManual.Controls.Add($chkManualDefault)

$chkManualTest = New-Object System.Windows.Forms.CheckBox
$chkManualTest.Text = "Imprimir página de teste após conectar"
$chkManualTest.Location = New-Object System.Drawing.Point(20, 130)
$chkManualTest.AutoSize = $true
$pnlManual.Controls.Add($chkManualTest)

$btnManualConnect = New-Object System.Windows.Forms.Button
$btnManualConnect.Text = "Conectar Agora"
$btnManualConnect.Location = New-Object System.Drawing.Point(20, 170)
$btnManualConnect.Size = New-Object System.Drawing.Size(200, 38)
$btnManualConnect.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnManualConnect.ForeColor = [System.Drawing.Color]::White
$btnManualConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnManualConnect.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$pnlManual.Controls.Add($btnManualConnect)

$txtPathDiag = New-Object System.Windows.Forms.TextBox
$txtPathDiag.Multiline = $true
$txtPathDiag.ReadOnly = $true
$txtPathDiag.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtPathDiag.Location = New-Object System.Drawing.Point(20, 220)
$txtPathDiag.Size = New-Object System.Drawing.Size(875, 120)
$txtPathDiag.Font = New-Object System.Drawing.Font("Consolas", 9)
$txtPathDiag.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)
$pnlManual.Controls.Add($txtPathDiag)

# Ação: Testar Caminho Manual
$btnTestPath.Add_Click({
    $txtManualUNC.Text = Format-PrinterAsNamedUNC $txtManualUNC.Text.Trim()
    $unc = $txtManualUNC.Text.Trim()
    if ($unc -notmatch "^\\\\([^\\]+)\\([^\\]+)$") {
        [System.Windows.Forms.MessageBox]::Show("Formato de caminho inválido.`nUtilize o padrão: \\SERVIDOR\COMPARTILHAMENTO", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $server = $matches[1]
    $share = $matches[2]

    $txtPathDiag.Text = "Testando conectividade com o caminho $unc...`r`n"
    [System.Windows.Forms.Application]::DoEvents()

    $ping = Test-HostPingSafe -HostOrIp $server -TimeoutMs 1500
    $txtPathDiag.AppendText("- Resposta ICMP (Ping) de $($server): $(if ($ping) { 'OK' } else { 'Sem resposta (pode ser bloqueado)' })`r`n")

    $smb = Test-TcpPortSafe -HostOrIp $server -Port 445 -TimeoutMs 1500
    $txtPathDiag.AppendText("- Acesso porta SMB 445 em $($server): $(if ($smb) { 'ABERTA' } else { 'FECHADA' })`r`n")

    if ($smb) {
        $txtPathDiag.AppendText("- Servidor respondeu na rede. Pronto para tentar conexão.`r`n")
    } else {
        $txtPathDiag.AppendText("- ATENÇÃO: Falha na porta SMB. Verifique firewall ou permissões de rede.`r`n")
    }
})

# Ação: Conectar Manual
$btnManualConnect.Add_Click({
    $txtManualUNC.Text = Format-PrinterAsNamedUNC $txtManualUNC.Text.Trim()
    $unc = $txtManualUNC.Text.Trim()
    if ($unc -notmatch "^\\\\([^\\]+)\\([^\\]+)$") {
        [System.Windows.Forms.MessageBox]::Show("Informe um caminho UNC válido no formato:\\SERVIDOR\IMPRESSORA", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    try {
        $script:cancelPrinterConnection = $false
        $btnCancelConnection.Enabled = $true
        $btnCancelConnection.Visible = $true
        Show-LoadingIndicator -Message "Conectando a $unc..." -Button $btnManualConnect
        $res = Connect-UNCPrinterSafe -UNCPath $unc
        $fallbackHandled = $false
        if (-not $res.Success -and -not $res.Simulated -and $res.Code -notin @(53,1223) -and $script:currentWindowsBuild -lt 22000) {
            $btnCancelConnection.Visible = $false
            Hide-LoadingIndicator -Button $btnManualConnect
            $offer = Offer-Win10LocalPortFallback -UNCPath $unc -PreviousResult $res
            $fallbackHandled = [bool]$offer.Handled
            if ($offer.Result) { $res = $offer.Result }
        }
        if ($res.Simulated) {
            Update-StatusStrip -Text "Simulação concluída: $unc não foi conectado." -Color [System.Drawing.Color]::DarkGoldenrod
            [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhuma impressora foi conectada.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        if ($res.Success) {
            $connectedUNC = if ($res.ConnectedUNC) { [string]$res.ConnectedUNC } else { $unc }
            if ($chkManualDefault.Checked) { Set-DefaultPrinterSafe -PrinterName $connectedUNC | Out-Null }
            if ($chkManualTest.Checked) { Invoke-PrintUICommand -Arguments ('/k /n "' + $connectedUNC + '"') | Out-Null }
            Refresh-PrintersGrid
            Update-StatusStrip -Text "Impressora $connectedUNC conectada." -Color [System.Drawing.Color]::DarkGreen
            $successMessage = if ($res.LocalPort) {
                "Fila instalada neste PC: $connectedUNC`nPorta: $($res.PortUNC)`n`nImprima uma página de teste para confirmar a impressão."
            } else {
                "Impressora conectada com sucesso!`n`n$connectedUNC"
            }
            [System.Windows.Forms.MessageBox]::Show($successMessage, "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } elseif ($res.Code -eq 1223) {
            Update-StatusStrip -Text 'Conexão cancelada.' -Color [System.Drawing.Color]::DarkGoldenrod
        } elseif ($fallbackHandled) {
            Update-StatusStrip -Text "Conexão normal não instalada: $unc. A porta local continua disponível na aba Impressoras da Rede." -Color [System.Drawing.Color]::DarkRed
        } else {
            Update-StatusStrip -Text "Falha na conexão: $($res.Message)" -Color [System.Drawing.Color]::DarkRed
            [System.Windows.Forms.MessageBox]::Show("Falha ao conectar $unc.`n`n$($res.Message)`n`nConfira o log. Para usar um driver já instalado neste PC, vá a 'Impressoras da Rede' e escolha 'Instalar via porta local'.", 'Falha na conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        }
    } catch {
        Write-AppLog -Message "Falha inesperada ao conectar ${unc}: $($_.Exception.Message)" -Level 'ERRO'
        Update-StatusStrip -Text "Falha ao conectar ${unc}: $($_.Exception.Message)" -Color [System.Drawing.Color]::DarkRed
        [System.Windows.Forms.MessageBox]::Show("Não foi possível concluir a conexão de $unc.`n`n$($_.Exception.Message)", 'Falha na conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } finally {
        $btnCancelConnection.Visible = $false
        $script:cancelPrinterConnection = $false
        Hide-LoadingIndicator -Button $btnManualConnect
    }
})

# ==============================================================================
# ABA 6: INSTALAR POR ENDERECO IP (TCP/IP DIRETO)
# ==============================================================================
$pnlIP = New-Object System.Windows.Forms.GroupBox
$pnlIP.Text = "Instalação de Impressora TCP/IP (Rede Direta)"
$pnlIP.Location = New-Object System.Drawing.Point(20, 20)
$pnlIP.Size = New-Object System.Drawing.Size(920, 480)
$tab5.Controls.Add($pnlIP)

$lblIPAddr = New-Object System.Windows.Forms.Label
$lblIPAddr.Text = "Endereço IPv4 da Impressora:"
$lblIPAddr.Location = New-Object System.Drawing.Point(20, 30)
$lblIPAddr.AutoSize = $true
$pnlIP.Controls.Add($lblIPAddr)

$txtIPAddr = New-Object System.Windows.Forms.TextBox
$txtIPAddr.Text = ""
$txtIPAddr.Location = New-Object System.Drawing.Point(20, 52)
$txtIPAddr.Size = New-Object System.Drawing.Size(200, 23)
$pnlIP.Controls.Add($txtIPAddr)

$btnTestIPPort = New-Object System.Windows.Forms.Button
$btnTestIPPort.Text = "Testar Comunicação IP e Porta"
$btnTestIPPort.Location = New-Object System.Drawing.Point(235, 50)
$btnTestIPPort.Size = New-Object System.Drawing.Size(210, 27)
$pnlIP.Controls.Add($btnTestIPPort)

$lblIPPrinterName = New-Object System.Windows.Forms.Label
$lblIPPrinterName.Text = "Nome de Exibição da Impressora:"
$lblIPPrinterName.Location = New-Object System.Drawing.Point(20, 90)
$lblIPPrinterName.AutoSize = $true
$pnlIP.Controls.Add($lblIPPrinterName)

$txtIPPrinterName = New-Object System.Windows.Forms.TextBox
$txtIPPrinterName.Text = "Impressora_Rede_TCP"
$txtIPPrinterName.Location = New-Object System.Drawing.Point(20, 112)
$txtIPPrinterName.Size = New-Object System.Drawing.Size(320, 23)
$pnlIP.Controls.Add($txtIPPrinterName)

# Protocolo RAW vs LPR
$lblProto = New-Object System.Windows.Forms.Label
$lblProto.Text = "Protocolo de Comunicação:"
$lblProto.Location = New-Object System.Drawing.Point(20, 150)
$lblProto.AutoSize = $true
$pnlIP.Controls.Add($lblProto)

$rbProtoRAW = New-Object System.Windows.Forms.RadioButton
$rbProtoRAW.Text = "RAW (Padrão para impressoras térmicas e de rede)"
$rbProtoRAW.Location = New-Object System.Drawing.Point(20, 172)
$rbProtoRAW.AutoSize = $true
$rbProtoRAW.Checked = $true
$pnlIP.Controls.Add($rbProtoRAW)

$rbProtoLPR = New-Object System.Windows.Forms.RadioButton
$rbProtoLPR.Text = "LPR / LPD"
$rbProtoLPR.Location = New-Object System.Drawing.Point(360, 172)
$rbProtoLPR.AutoSize = $true
$pnlIP.Controls.Add($rbProtoLPR)

$lblPortNum = New-Object System.Windows.Forms.Label
$lblPortNum.Text = "Porta TCP (RAW):"
$lblPortNum.Location = New-Object System.Drawing.Point(20, 205)
$lblPortNum.AutoSize = $true
$pnlIP.Controls.Add($lblPortNum)

$txtPortNum = New-Object System.Windows.Forms.TextBox
$txtPortNum.Text = "9100"
$txtPortNum.Location = New-Object System.Drawing.Point(130, 202)
$txtPortNum.Size = New-Object System.Drawing.Size(80, 23)
$pnlIP.Controls.Add($txtPortNum)

$lblQueueName = New-Object System.Windows.Forms.Label
$lblQueueName.Text = "Fila LPR:"
$lblQueueName.Location = New-Object System.Drawing.Point(235, 205)
$lblQueueName.AutoSize = $true
$pnlIP.Controls.Add($lblQueueName)

$txtQueueName = New-Object System.Windows.Forms.TextBox
$txtQueueName.Text = "lp"
$txtQueueName.Enabled = $false
$txtQueueName.Location = New-Object System.Drawing.Point(300, 202)
$txtQueueName.Size = New-Object System.Drawing.Size(100, 23)
$pnlIP.Controls.Add($txtQueueName)

$rbProtoRAW.Add_CheckedChanged({
    $txtQueueName.Enabled = -not $rbProtoRAW.Checked
    if ($rbProtoRAW.Checked) { $txtPortNum.Text = "9100" } else { $txtPortNum.Text = "515" }
})

# Seleção de Driver NATIVO já instalado no Windows
$lblDriver = New-Object System.Windows.Forms.Label
$lblDriver.Text = "Driver já instalado no Windows (Obrigatório selecionar um homologado):"
$lblDriver.Location = New-Object System.Drawing.Point(20, 240)
$lblDriver.AutoSize = $true
$pnlIP.Controls.Add($lblDriver)

$cmbDrivers = New-Object System.Windows.Forms.ComboBox
$cmbDrivers.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbDrivers.Location = New-Object System.Drawing.Point(20, 262)
$cmbDrivers.Size = New-Object System.Drawing.Size(450, 23)
$pnlIP.Controls.Add($cmbDrivers)

$btnRefreshDrivers = New-Object System.Windows.Forms.Button
$btnRefreshDrivers.Text = "Recarregar Drivers"
$btnRefreshDrivers.Location = New-Object System.Drawing.Point(480, 260)
$btnRefreshDrivers.Size = New-Object System.Drawing.Size(140, 27)
$pnlIP.Controls.Add($btnRefreshDrivers)

$lblDriverWarning = New-Object System.Windows.Forms.Label
$lblDriverWarning.Text = "REQUISITO DE SEGURANÇA: Esta ferramenta NÃO baixa drivers da internet nem utiliza drivers desconhecidos.`nCaso o modelo desejado (Bematech, Elgin, Epson, Argox, Zebra) não conste acima, instale primeiro o pacote oficial do fabricante."
$lblDriverWarning.ForeColor = [System.Drawing.Color]::DarkRed
$lblDriverWarning.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblDriverWarning.Location = New-Object System.Drawing.Point(20, 295)
$lblDriverWarning.Size = New-Object System.Drawing.Size(860, 35)
$pnlIP.Controls.Add($lblDriverWarning)

$chkIPDefault = New-Object System.Windows.Forms.CheckBox
$chkIPDefault.Text = "Definir como impressora padrão após instalar"
$chkIPDefault.Location = New-Object System.Drawing.Point(20, 335)
$chkIPDefault.AutoSize = $true
$pnlIP.Controls.Add($chkIPDefault)

$chkIPTest = New-Object System.Windows.Forms.CheckBox
$chkIPTest.Text = "Imprimir teste após instalar"
$chkIPTest.Location = New-Object System.Drawing.Point(20, 360)
$chkIPTest.AutoSize = $true
$pnlIP.Controls.Add($chkIPTest)

$btnInstallIPPrinter = New-Object System.Windows.Forms.Button
$btnInstallIPPrinter.Text = "Criar Porta e Instalar Impressora TCP/IP"
$btnInstallIPPrinter.Location = New-Object System.Drawing.Point(20, 400)
$btnInstallIPPrinter.Size = New-Object System.Drawing.Size(300, 40)
$btnInstallIPPrinter.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnInstallIPPrinter.ForeColor = [System.Drawing.Color]::White
$btnInstallIPPrinter.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallIPPrinter.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$pnlIP.Controls.Add($btnInstallIPPrinter)

function Populate-DriversList {
    $cmbDrivers.Items.Clear()
    $drivers = Get-InstalledDriversSafe
    foreach ($d in $drivers) {
        [void]$cmbDrivers.Items.Add($d)
    }
    # Tentar selecionar driver genérico de texto ou primeiro da lista
    $generic = $drivers | Where-Object { $_ -match "(?i)(generic|genérico|text only|apenas texto)" } | Select-Object -First 1
    if ($generic) {
        $cmbDrivers.SelectedItem = $generic
    } elseif ($cmbDrivers.Items.Count -gt 0) {
        $cmbDrivers.SelectedIndex = 0
    }
}
$btnRefreshDrivers.Add_Click({ Populate-DriversList })

# Testar IP e Porta TCP
$btnTestIPPort.Add_Click({
    $ip = $txtIPAddr.Text.Trim()
    $port = 9100
    [int]::TryParse($txtPortNum.Text.Trim(), [ref]$port) | Out-Null

    if ($ip -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        [System.Windows.Forms.MessageBox]::Show("Endereço IPv4 inválido.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    try {
        Show-LoadingIndicator -Message "Testando $ip na porta TCP $port..." -Button $btnTestIPPort

        $ping = Test-HostPingSafe -HostOrIp $ip -TimeoutMs 1500
        $tcp = Test-TcpPortSafe -HostOrIp $ip -Port $port -TimeoutMs 2000

        $msg = "Teste de Conectividade com a Impressora:`n`n" +
               "- Endereço: $ip`n" +
               "- Resposta de Ping: $(if ($ping) { 'OK' } else { 'Sem resposta ICMP' })`n" +
               "- Porta TCP $($port): $(if ($tcp) { 'ABERTA E RESPONDENDO' } else { 'FECHADA OU BLOQUEADA' })`n`n"

        if ($tcp) {
            $msg += "A impressora está online e recebendo conexões nesta porta."
            [System.Windows.Forms.MessageBox]::Show($msg, "Comunicação Confirmada", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            Update-StatusStrip -Text "Impressora $ip comunicando na porta $port." -Color [System.Drawing.Color]::DarkGreen
        } else {
            $msg += "ATENÇÃO: A porta TCP $port não respondeu. Verifique se a impressora está ligada, conectada à rede e com o IP correto configurado."
            [System.Windows.Forms.MessageBox]::Show($msg, "Falha de Conexão", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            Update-StatusStrip -Text "Falha na porta TCP $port de $ip." -Color [System.Drawing.Color]::DarkRed
        }
    } finally {
        Hide-LoadingIndicator -Button $btnTestIPPort
    }
})

# Instalar Impressora TCP/IP
$btnInstallIPPrinter.Add_Click({
    $ip = $txtIPAddr.Text.Trim()
    $pName = $txtIPPrinterName.Text.Trim()
    $driver = [string]$cmbDrivers.SelectedItem

    if ($ip -notmatch "^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$") {
        [System.Windows.Forms.MessageBox]::Show("Informe um endereço IPv4 válido.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not $pName) {
        [System.Windows.Forms.MessageBox]::Show("Informe um nome para a impressora.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }
    if (-not $driver) {
        [System.Windows.Forms.MessageBox]::Show("Selecione um driver homologado na lista.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $portNum = 9100
    [int]::TryParse($txtPortNum.Text.Trim(), [ref]$portNum) | Out-Null
    $proto = if ($rbProtoLPR.Checked) { "LPR" } else { "RAW" }
    $queue = $txtQueueName.Text.Trim()
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Impressora '$pName' seria instalada em $ip porta $portNum ($proto), usando '$driver'." -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhuma porta ou impressora foi criada.`n`nImpressora: $pName`nEndereço: $ip`nDriver: $driver", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    try {
        Show-LoadingIndicator -Message "Criando porta e registrando impressora..." -Button $btnInstallIPPrinter

        # 1. Criar Porta TCP/IP nativa
        $portResult = New-TCPIPPrinterPortSafe -IPAddress $ip -PortNumber $portNum -Protocol $proto -QueueName $queue
        if (-not $portResult.Success) {
            [System.Windows.Forms.MessageBox]::Show("Falha ao criar a porta TCP/IP:`n$($portResult.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            return
        }

        $portName = $portResult.PortName

        # 2. Instalar impressora usando PrintUIEntry
        $installRes = Install-LocalPrinterSafe -PrinterName $pName -PortName $portName -DriverName $driver
        if ($installRes.Success) {
            if ($chkIPDefault.Checked) { Set-DefaultPrinterSafe -PrinterName $pName | Out-Null }
            if ($chkIPTest.Checked) { Invoke-PrintUICommand -Arguments "/k /n `"$pName`"" | Out-Null }
            Refresh-PrintersGrid
            Update-StatusStrip -Text "Impressora '$pName' instalada com sucesso." -Color [System.Drawing.Color]::DarkGreen

            $resp = [System.Windows.Forms.MessageBox]::Show("Impressora TCP/IP '$pName' instalada com sucesso!`n`nDeseja abrir a fila de impressão agora?", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information)
            if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
                Invoke-PrintUICommand -Arguments "/o /n `"$pName`"" -NoWait | Out-Null
            }
        } else {
            [System.Windows.Forms.MessageBox]::Show("Falha ao registrar a impressora:`n$($installRes.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    } finally {
        Hide-LoadingIndicator -Button $btnInstallIPPrinter
    }
})

# ==============================================================================
# ABA 7: FILA E SPOOLER (DIAGNOSTICO E CORRECAO)
# ==============================================================================
$pnlSpoolStatus = New-Object System.Windows.Forms.GroupBox
$pnlSpoolStatus.Text = "Status do Subsistema Spooler"
$pnlSpoolStatus.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlSpoolStatus.Height = 70
$tab6.Controls.Add($pnlSpoolStatus)

$lblSpoolInfo = New-Object System.Windows.Forms.Label
$lblSpoolInfo.Text = "Status: Aguardando verificação..."
$lblSpoolInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblSpoolInfo.Location = New-Object System.Drawing.Point(15, 25)
$lblSpoolInfo.AutoSize = $true
$pnlSpoolStatus.Controls.Add($lblSpoolInfo)

$btnRefreshSpoolTab = New-Object System.Windows.Forms.Button
$btnRefreshSpoolTab.Text = "Atualizar Fila e Status"
$btnRefreshSpoolTab.Location = New-Object System.Drawing.Point(740, 20)
$btnRefreshSpoolTab.Size = New-Object System.Drawing.Size(180, 32)
$pnlSpoolStatus.Controls.Add($btnRefreshSpoolTab)

# Tabela de Documentos Presos
$pnlQueueGroup = New-Object System.Windows.Forms.GroupBox
$pnlQueueGroup.Text = "Documentos Presos nas Filas de Impressão"
$pnlQueueGroup.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlQueueGroup.Height = 180
$tab6.Controls.Add($pnlQueueGroup)

$dgvQueue = New-Object System.Windows.Forms.DataGridView
$dgvQueue.Dock = [System.Windows.Forms.DockStyle]::Fill
$dgvQueue.ReadOnly = $true
$dgvQueue.AllowUserToAddRows = $false
$dgvQueue.AllowUserToDeleteRows = $false
$dgvQueue.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvQueue.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvQueue.BackgroundColor = [System.Drawing.Color]::White
$pnlQueueGroup.Controls.Add($dgvQueue)

[void]$dgvQueue.Columns.Add("JobId", "ID")
[void]$dgvQueue.Columns.Add("Printer", "Impressora")
[void]$dgvQueue.Columns.Add("Document", "Documento")
[void]$dgvQueue.Columns.Add("Owner", "Usuário")
[void]$dgvQueue.Columns.Add("Size", "Tamanho")
[void]$dgvQueue.Columns.Add("Time", "Hora Envio")
[void]$dgvQueue.Columns.Add("Status", "Status")

# Painel com Opções Selecionáveis para Correção de Problemas
$pnlFixChecklist = New-Object System.Windows.Forms.GroupBox
$pnlFixChecklist.Text = "Ações para Correção de Problemas Comuns (Selecione as ações desejadas antes de executar)"
$pnlFixChecklist.Dock = [System.Windows.Forms.DockStyle]::Fill
$tab6.Controls.Add($pnlFixChecklist)
$pnlFixChecklist.BringToFront()

$chkOptRestartSpooler = New-Object System.Windows.Forms.CheckBox
$chkOptRestartSpooler.Text = "1. Reiniciar serviço Spooler de Impressão (Stop/Start)"
$chkOptRestartSpooler.Location = New-Object System.Drawing.Point(20, 25); $chkOptRestartSpooler.AutoSize = $true; $chkOptRestartSpooler.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptRestartSpooler)

$chkOptAutoStart = New-Object System.Windows.Forms.CheckBox
$chkOptAutoStart.Text = "2. Configurar inicialização do Spooler como Automático (sc.exe config spooler start= auto)"
$chkOptAutoStart.Location = New-Object System.Drawing.Point(20, 50); $chkOptAutoStart.AutoSize = $true; $chkOptAutoStart.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptAutoStart)

$chkOptUnpause = New-Object System.Windows.Forms.CheckBox
$chkOptUnpause.Text = "3. Retirar estado 'Pausada' de todas as impressoras instaladas"
$chkOptUnpause.Location = New-Object System.Drawing.Point(20, 75); $chkOptUnpause.AutoSize = $true; $chkOptUnpause.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptUnpause)

$chkOptClearOffline = New-Object System.Windows.Forms.CheckBox
$chkOptClearOffline.Text = "4. Retirar modo 'Trabalhar Offline' de todas as impressoras instaladas"
$chkOptClearOffline.Location = New-Object System.Drawing.Point(20, 100); $chkOptClearOffline.AutoSize = $true; $chkOptClearOffline.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptClearOffline)

$chkOptPurgeFiles = New-Object System.Windows.Forms.CheckBox
$chkOptPurgeFiles.Text = "5. Limpar arquivos travados da pasta de spool (*.SPL e *.SHD) [Cancela todos os trabalhos pendentes]"
$chkOptPurgeFiles.ForeColor = [System.Drawing.Color]::DarkRed
$chkOptPurgeFiles.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chkOptPurgeFiles.Location = New-Object System.Drawing.Point(20, 125); $chkOptPurgeFiles.AutoSize = $true; $chkOptPurgeFiles.Checked = $false
$pnlFixChecklist.Controls.Add($chkOptPurgeFiles)

$btnExecuteFixes = New-Object System.Windows.Forms.Button
$btnExecuteFixes.Text = "Executar Ações Selecionadas de Correção"
$btnExecuteFixes.Location = New-Object System.Drawing.Point(20, 165)
$btnExecuteFixes.Size = New-Object System.Drawing.Size(280, 38)
$btnExecuteFixes.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnExecuteFixes.ForeColor = [System.Drawing.Color]::White
$btnExecuteFixes.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnExecuteFixes.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$pnlFixChecklist.Controls.Add($btnExecuteFixes)

$btnQuickPurge = New-Object System.Windows.Forms.Button
$btnQuickPurge.Text = "Limpar Fila Imediatamente (Purgar Spool)"
$btnQuickPurge.Location = New-Object System.Drawing.Point(315, 165)
$btnQuickPurge.Size = New-Object System.Drawing.Size(260, 38)
$btnQuickPurge.ForeColor = [System.Drawing.Color]::DarkRed
$pnlFixChecklist.Controls.Add($btnQuickPurge)

function Update-SpoolTabStatus {
    $svc = Get-Service -Name "spooler" -ErrorAction SilentlyContinue
    $wmiSvc = Get-WmiObject -Class Win32_Service -Filter "Name = 'Spooler'" -ErrorAction SilentlyContinue

    $spoolPath = Join-Path -Path $env:SystemRoot -ChildPath "System32\spool\PRINTERS"
    $fileCount = 0
    if (Test-Path -Path $spoolPath) {
        $f = Get-ChildItem -Path $spoolPath -Include *.spl, *.shd -Recurse -Force -ErrorAction SilentlyContinue
        if ($f) { $fileCount = $f.Count }
    }

    $statusStr = if ($svc) { $svc.Status.ToString() } else { "Indefinido" }
    $startMode = if ($wmiSvc) { $wmiSvc.StartMode } else { "Desconhecido" }

    $lblSpoolInfo.Text = "Serviço Spooler: $statusStr | Inicialização: $startMode | Arquivos na pasta PRINTERS: $fileCount"
    if ($statusStr -eq "Running") {
        $lblSpoolInfo.ForeColor = [System.Drawing.Color]::DarkGreen
    } else {
        $lblSpoolInfo.ForeColor = [System.Drawing.Color]::DarkRed
    }

    # Atualizar lista de jobs
    $dgvQueue.Rows.Clear()
    $jobs = Get-PrintJobsSafe
    foreach ($j in $jobs) {
        $pName = ($j.Name -split ",")[0]
        $sizeKB = [math]::Round($j.TotalPages, 0)
        [void]$dgvQueue.Rows.Add($j.JobId, $pName, $j.Document, $j.Owner, "$($j.Size) bytes", $j.TimeSubmitted, $j.JobStatus)
    }
}

$btnRefreshSpoolTab.Add_Click({ Update-SpoolTabStatus })

# Ação: Executar Correções Selecionadas
$btnExecuteFixes.Add_Click({
    $actions = @()
    if ($chkOptRestartSpooler.Checked) { $actions += "- Reiniciar o serviço Spooler" }
    if ($chkOptAutoStart.Checked) { $actions += "- Configurar Spooler para inicialização Automática" }
    if ($chkOptUnpause.Checked) { $actions += "- Remover estado Pausada de todas as impressoras" }
    if ($chkOptClearOffline.Checked) { $actions += "- Remover modo Offline de todas as impressoras" }
    if ($chkOptPurgeFiles.Checked) { $actions += "- LIMPAR e CANCELAR todos os documentos travados no spool" }

    if ($actions.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione ao menos uma ação para executar.", "Aviso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    $msgConfirm = "As seguintes ações serão executadas no computador:`n`n" + ($actions -join "`n") + "`n`nDeseja prosseguir?"
    $icon = if ($chkOptPurgeFiles.Checked) { [System.Windows.Forms.MessageBoxIcon]::Warning } else { [System.Windows.Forms.MessageBoxIcon]::Question }
    $resp = [System.Windows.Forms.MessageBox]::Show($msgConfirm, "Confirmar Ações de Correção", [System.Windows.Forms.MessageBoxButtons]::YesNo, $icon)
    if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Correções de spooler e impressoras não foram executadas." -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhuma correção foi aplicada.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }

    try {
        Show-LoadingIndicator -Message "Executando correções do spooler..." -Button $btnExecuteFixes

        if ($chkOptPurgeFiles.Checked) {
            Clear-SpoolFilesSafe | Out-Null
        } elseif ($chkOptRestartSpooler.Checked) {
            Restart-SpoolerServiceSafe | Out-Null
        }

        if ($chkOptAutoStart.Checked -and -not $global:SimulationMode) {
            Start-Process -FilePath "sc.exe" -ArgumentList "config spooler start= auto" -Wait -WindowStyle Hidden
        }

        if ($chkOptUnpause.Checked -or $chkOptClearOffline.Checked) {
            Reset-PrintersStateSafe | Out-Null
        }

        Update-SpoolTabStatus
        Refresh-PrintersGrid
        Update-StatusStrip -Text "Procedimento de correção concluído." -Color [System.Drawing.Color]::DarkGreen
        [System.Windows.Forms.MessageBox]::Show("Procedimentos de correção executados com sucesso!", "Concluído", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    } finally {
        Hide-LoadingIndicator -Button $btnExecuteFixes
    }
})

# Ação: Limpeza Imediata de Fila
$btnQuickPurge.Add_Click({
    $confirmMsg = "ATENÇÃO TÉCNICO:`n`n" +
                  "Esta ação irá parar o Spooler, apagar TODOS os documentos presos na pasta de impressão e reiniciar o serviço.`n`n" +
                  "Todos os trabalhos de impressão pendentes serão cancelados definitivamente.`n`n" +
                  "Deseja prosseguir com a limpeza agora?"
    $resp = [System.Windows.Forms.MessageBox]::Show($confirmMsg, "Confirmar Limpeza Total da Fila", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
        if ($global:SimulationMode) {
            Write-AppLog -Message "[SIMULAÇÃO] Fila e arquivos de spool não foram limpos." -Level "SIMULACAO"
            [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhum trabalho de impressão foi apagado.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        try {
            Show-LoadingIndicator -Message "Limpando fila e restabelecendo spooler..." -Button $btnQuickPurge
            Clear-SpoolFilesSafe | Out-Null
            Update-SpoolTabStatus
            Refresh-PrintersGrid
            [System.Windows.Forms.MessageBox]::Show("A pasta de spool foi limpa e o serviço foi restabelecido.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } finally {
            Hide-LoadingIndicator -Button $btnQuickPurge
        }
    }
})

# ==============================================================================
# ABA 8: AREA DE TRABALHO REMOTA (RDP / TERMINAL SERVICES)
# ==============================================================================
$pnlRDPHeader = New-Object System.Windows.Forms.GroupBox
$pnlRDPHeader.Text = "Diagnóstico da Sessão RDP"
$pnlRDPHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlRDPHeader.Height = 85
$tab7.Controls.Add($pnlRDPHeader)

$lblRDPSession = New-Object System.Windows.Forms.Label
$lblRDPSession.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblRDPSession.Location = New-Object System.Drawing.Point(15, 25)
$lblRDPSession.AutoSize = $true
$pnlRDPHeader.Controls.Add($lblRDPSession)

$lblRDPInfoExtra = New-Object System.Windows.Forms.Label
$lblRDPInfoExtra.Location = New-Object System.Drawing.Point(15, 50)
$lblRDPInfoExtra.AutoSize = $true
$lblRDPInfoExtra.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$pnlRDPHeader.Controls.Add($lblRDPInfoExtra)

$btnRefreshRDP = New-Object System.Windows.Forms.Button
$btnRefreshRDP.Text = "Atualizar RDP"
$btnRefreshRDP.Location = New-Object System.Drawing.Point(620, 25)
$btnRefreshRDP.Size = New-Object System.Drawing.Size(120, 32)
$pnlRDPHeader.Controls.Add($btnRefreshRDP)

$btnOpenControlPrn = New-Object System.Windows.Forms.Button
$btnOpenControlPrn.Text = "Abrir Impressoras do Windows"
$btnOpenControlPrn.Location = New-Object System.Drawing.Point(750, 25)
$btnOpenControlPrn.Size = New-Object System.Drawing.Size(180, 32)
$pnlRDPHeader.Controls.Add($btnOpenControlPrn)

$btnOpenControlPrn.Add_Click({
    Start-Process "control.exe" "printers"
})

$dgvRDP = New-Object System.Windows.Forms.DataGridView
$dgvRDP.Dock = [System.Windows.Forms.DockStyle]::Top
$dgvRDP.Height = 220
$dgvRDP.ReadOnly = $true
$dgvRDP.AllowUserToAddRows = $false
$dgvRDP.AllowUserToDeleteRows = $false
$dgvRDP.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$dgvRDP.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::Fill
$dgvRDP.BackgroundColor = [System.Drawing.Color]::White
$tab7.Controls.Add($dgvRDP)

[void]$dgvRDP.Columns.Add("Name", "Nome da Impressora")
[void]$dgvRDP.Columns.Add("Type", "Tipo / Origem")
[void]$dgvRDP.Columns.Add("Port", "Porta (TS / Local)")
[void]$dgvRDP.Columns.Add("Duplicate", "Alerta de Duplicação")

$txtRDPGuide = New-Object System.Windows.Forms.TextBox
$txtRDPGuide.Multiline = $true
$txtRDPGuide.ReadOnly = $true
$txtRDPGuide.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtRDPGuide.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtRDPGuide.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtRDPGuide.BackColor = [System.Drawing.Color]::FromArgb(250, 252, 255)
$tab7.Controls.Add($txtRDPGuide)
$txtRDPGuide.BringToFront()

function Update-RDPDiagnostics {
    $isRdp = [System.Windows.Forms.SystemInformation]::TerminalServerSession
    $sessionName = $env:SESSIONNAME

    if ($isRdp) {
        $lblRDPSession.Text = "Sessão Atual: REMOTA / RDP ATIVA (Sessão: $sessionName)"
        $lblRDPSession.ForeColor = [System.Drawing.Color]::DarkBlue
        $lblRDPInfoExtra.Text = "O usuário está conectado via Área de Trabalho Remota. Impressoras do cliente podem estar redirecionadas."
    } else {
        $lblRDPSession.Text = "Sessão Atual: LOCAL / CONSOLE ($sessionName)"
        $lblRDPSession.ForeColor = [System.Drawing.Color]::DarkGreen
        $lblRDPInfoExtra.Text = "Sessão física ou de console detectada (não é RDP nativo)."
    }

    $dgvRDP.Rows.Clear()
    $printers = Get-InstalledPrintersWmi
    $namesSeen = @{}

    foreach ($p in $printers) {
        $isRedir = ($p.Name -match "(?i)(redirected|redirecionada|\(redirecionado\))")
        $tipo = if ($isRedir) { "Redirecionada por RDP" } else { "Local / Servidor" }

        # Verificar duplicatas
        $cleanBase = $p.Name -replace "(?i)\s*(em sessão|\(redirecionada|\(redirected).*", ""
        $dupAlert = "Normal"
        if ($namesSeen.ContainsKey($cleanBase)) {
            $dupAlert = "Possível Conexão Duplicada"
        } else {
            $namesSeen[$cleanBase] = 1
        }

        $rIndex = $dgvRDP.Rows.Add($p.Name, $tipo, $p.PortName, $dupAlert)
        if ($isRedir) {
            $dgvRDP.Rows[$rIndex].DefaultCellStyle.ForeColor = [System.Drawing.Color]::DarkBlue
        }
        if ($dupAlert -ne "Normal") {
            $dgvRDP.Rows[$rIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 230)
        }
    }

    # Guia orientativo para o técnico
    $guideText = "GUIA DE SUPORTE - IMPRESSORAS EM SESSÕES RDP:`r`n`r`n" +
                 "1. HABILITAÇÃO NO CLIENTE: O redirecionamento de impressoras deve ser marcado nas opções do cliente de RDP (Aba 'Recursos Locais' -> 'Impressoras') ANTES de iniciar a conexão.`r`n" +
                 "2. DRIVER COMPATÍVEL NO SERVIDOR: Para que a impressora redirecionada funcione corretamente, o driver com NOME EXATO deve estar instalado no servidor, ou o recurso 'Remote Desktop Easy Print' deve estar ativado.`r`n" +
                 "3. PORTAS TS001, TS002, ETC: Cada sessão remota cria portas virtuais dinâmicas. Se a sessão for desconectada e reconectada, o número da porta pode mudar, deixando filas órfãs.`r`n" +
                 "4. DUPLICATAS: Se houver múltiplas impressoras com o mesmo nome e sufixos numéricos diferentes, encerre a sessão do usuário (Logoff) para descarregar o cache de portas TS.`r`n" +
                 "5. POLÍTICAS DE GRUPO: Esta ferramenta não modifica GPOs silenciosamente. Caso o redirecionamento esteja bloqueado por política da empresa, consulte o administrador de rede."

    $txtRDPGuide.Text = $guideText
}

$btnRefreshRDP.Add_Click({ Update-RDPDiagnostics })

# ==============================================================================
# ABA 9: RELATORIO E LOGS
# ==============================================================================
$pnlLogsTop = New-Object System.Windows.Forms.Panel
$pnlLogsTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlLogsTop.Height = 45
$tab8.Controls.Add($pnlLogsTop)

$btnRefreshLogView = New-Object System.Windows.Forms.Button
$btnRefreshLogView.Text = "Atualizar Log"
$btnRefreshLogView.Size = New-Object System.Drawing.Size(110, 32)
$btnRefreshLogView.Location = New-Object System.Drawing.Point(10, 6)
$pnlLogsTop.Controls.Add($btnRefreshLogView)

$btnCopyLog = New-Object System.Windows.Forms.Button
$btnCopyLog.Text = "Copiar Log Completo"
$btnCopyLog.Size = New-Object System.Drawing.Size(150, 32)
$btnCopyLog.Location = New-Object System.Drawing.Point(130, 6)
$pnlLogsTop.Controls.Add($btnCopyLog)

$btnExportReport = New-Object System.Windows.Forms.Button
$btnExportReport.Text = "Exportar Relatório..."
$btnExportReport.Size = New-Object System.Drawing.Size(140, 32)
$btnExportReport.Location = New-Object System.Drawing.Point(290, 6)
$pnlLogsTop.Controls.Add($btnExportReport)

$btnOpenLogsFolder = New-Object System.Windows.Forms.Button
$btnOpenLogsFolder.Text = "Abrir Pasta Logs"
$btnOpenLogsFolder.Size = New-Object System.Drawing.Size(130, 32)
$btnOpenLogsFolder.Location = New-Object System.Drawing.Point(440, 6)
$pnlLogsTop.Controls.Add($btnOpenLogsFolder)

$btnClearOldLogs = New-Object System.Windows.Forms.Button
$btnClearOldLogs.Text = "Limpar Logs Antigos (+7 dias)"
$btnClearOldLogs.Size = New-Object System.Drawing.Size(180, 32)
$btnClearOldLogs.Location = New-Object System.Drawing.Point(580, 6)
$pnlLogsTop.Controls.Add($btnClearOldLogs)

$btnCleanAndExit = New-Object System.Windows.Forms.Button
$btnCleanAndExit.Text = "Encerrar e Limpar Temporários"
$btnCleanAndExit.Size = New-Object System.Drawing.Size(190, 32)
$btnCleanAndExit.Location = New-Object System.Drawing.Point(770, 6)
$btnCleanAndExit.BackColor = [System.Drawing.Color]::FromArgb(200, 50, 50)
$btnCleanAndExit.ForeColor = [System.Drawing.Color]::White
$btnCleanAndExit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCleanAndExit.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$pnlLogsTop.Controls.Add($btnCleanAndExit)

$script:txtLogViewer = New-Object System.Windows.Forms.TextBox
$script:txtLogViewer.Multiline = $true
$script:txtLogViewer.ReadOnly = $true
$script:txtLogViewer.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$script:txtLogViewer.WordWrap = $false
$script:txtLogViewer.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:txtLogViewer.Font = New-Object System.Drawing.Font("Consolas", 9)
$script:txtLogViewer.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 30)
$script:txtLogViewer.ForeColor = [System.Drawing.Color]::FromArgb(220, 230, 240)
$tab8.Controls.Add($script:txtLogViewer)
$script:txtLogViewer.BringToFront()

function Reload-LogViewer {
    if (Test-Path -Path $global:LogFilePath) {
        try {
            $content = [System.IO.File]::ReadAllText($global:LogFilePath)
            $script:txtLogViewer.Text = $content
            $script:txtLogViewer.SelectionStart = $script:txtLogViewer.TextLength
            $script:txtLogViewer.ScrollToCaret()
        } catch {}
    }
}

$btnRefreshLogView.Add_Click({ Reload-LogViewer })

$btnCopyLog.Add_Click({
    if ($script:txtLogViewer.Text) {
        [System.Windows.Forms.Clipboard]::SetText($script:txtLogViewer.Text)
        [System.Windows.Forms.MessageBox]::Show("Log da sessão copiado para a Área de Transferência.", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

$btnExportReport.Add_Click({
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "Arquivos de Log (*.log;*.txt)|*.log;*.txt"
    $sfd.FileName = "Relatorio_Atendimento_$($env:COMPUTERNAME)_$((Get-Date).ToString('yyyyMMdd')).txt"
    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            [System.IO.File]::WriteAllText($sfd.FileName, $script:txtLogViewer.Text)
            [System.Windows.Forms.MessageBox]::Show("Relatório exportado com sucesso para:`n$($sfd.FileName)", "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Erro ao exportar arquivo: $($_.Exception.Message)", "Erro", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        }
    }
})

$btnOpenLogsFolder.Add_Click({
    if (Test-Path -Path $LogsDir) {
        Start-Process "explorer.exe" "`"$LogsDir`""
    }
})

$btnClearOldLogs.Add_Click({
    if ($global:SimulationMode) {
        Write-AppLog -Message "[SIMULAÇÃO] Limpeza de logs antigos não executada." -Level "SIMULACAO"
        [System.Windows.Forms.MessageBox]::Show("[MODO SIMULAÇÃO] Nenhum log foi excluído.", "Simulação", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        return
    }
    $resp = [System.Windows.Forms.MessageBox]::Show("Deseja apagar os arquivos de log com mais de 7 dias de idade da pasta Logs?`n`nO log desta sessão atual será mantido.", "Confirmar Exclusão de Logs Antigos", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
        $countDeleted = 0
        $threshold = (Get-Date).AddDays(-7)
        $files = Get-ChildItem -Path $LogsDir -Filter "*.log" -ErrorAction SilentlyContinue
        foreach ($f in $files) {
            if ($f.FullName -ne $global:LogFilePath -and $f.LastWriteTime -lt $threshold) {
                try {
                    Remove-Item -Path $f.FullName -Force -ErrorAction SilentlyContinue
                    $countDeleted++
                } catch {}
            }
        }
        Write-AppLog -Message "Limpeza de logs antigos: $countDeleted arquivos removidos." -Level "INFO"
        [System.Windows.Forms.MessageBox]::Show("$countDeleted log(s) antigo(s) removido(s).", "Concluído", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})

$btnCleanAndExit.Add_Click({
    Write-AppLog -Message "Encerrando aplicação e limpando buffers temporários de sessão..." -Level "INFO"
    foreach ($temp in $global:TempFilesCreated) {
        if (Test-Path -Path $temp) {
            try { Remove-Item -Path $temp -Force -ErrorAction SilentlyContinue } catch {}
        }
    }
    $form.Close()
})

# ==============================================================================
# CARREGAMENTO INICIAL DE DADOS AO ABRIR O FORMULÁRIO
# ==============================================================================
$tabControl.Add_SelectedIndexChanged({

    if ($tabControl.SelectedTab -eq $tab6) { Update-SpoolTabStatus }
    if ($tabControl.SelectedTab -eq $tab7) { Update-RDPDiagnostics }
})

$interfacePath = if ($PrinterConnectionPath) { Join-Path (Split-Path -Parent $PrinterConnectionPath) 'INTERFACE.ps1' } else { Join-Path $PSScriptRoot 'scripts\INTERFACE.ps1' }
if (Test-Path -LiteralPath $interfacePath) {
    . $interfacePath
    Set-PrinterAppLayout
}

$form.Add_Shown({

    Refresh-PrintersGrid
    Reload-LogViewer
    Update-StatusStrip -Text "Assistente de Impressoras pronto para uso." -Color "DarkGreen" -Tag "PRONTO"
})

# Executar a aplicação Windows Forms
[void]$form.ShowDialog()

# Registro de saída limpa no log
Write-AppLog -Message "Sessão do Assistente de Impressoras encerrada normalmente." -Level "INFO"
Write-AppLog -Message "================================================================================" -Level "INFO"
