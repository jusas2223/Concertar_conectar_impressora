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
$script:startupClock = [Diagnostics.Stopwatch]::StartNew()
[System.Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms") | Out-Null
[System.Reflection.Assembly]::LoadWithPartialName("System.Drawing") | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()

# Obter diretório do script de forma compatível com PS 2.0 / 3.0 / 5.1+ e executável
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
if ($AppDirectory) {
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
# Ao rodar de uma pasta de rede, a abertura não espera uma tentativa de escrita SMB.
$appRoot = [IO.Path]::GetPathRoot($ScriptDir)
$networkDirectory = $ScriptDir.StartsWith('\\')
if (-not $networkDirectory -and $appRoot) {
    try { $networkDirectory = ([IO.DriveInfo]::new($appRoot).DriveType -eq [IO.DriveType]::Network) } catch {}
}
if ($networkDirectory) { $logCandidates = @($logCandidates[1],$logCandidates[2]) }
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
Write-AppLog -Message "Início de Atendimento - Assistente de Impressoras (Suporte Técnico)" -Level "INFO"
Write-AppLog -Message "Versão do app: 1.10.7 | PowerShell: $($PSVersionTable.PSVersion) | Processo: $([IntPtr]::Size * 8) bits" -Level "INFO"
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
    param([string]$Server, [string]$InitialUser = '', [System.Windows.Forms.IWin32Window]$Parent,
        [string]$Reason='', [switch]$AllowServerEdit, [switch]$RequireCredential)

    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = if($RequireCredential){'Conectar usando conta do servidor'}else{"Conta para impressora em $Server"}
    $dialog.ClientSize = [System.Drawing.Size]::new(510, 282)
    $dialog.Font = [System.Drawing.Font]::new('Segoe UI', 9)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false

    $instruction = [System.Windows.Forms.Label]::new()
    $instruction.Text = $(if($Reason){$Reason}else{'O Windows recusou o acesso com a sessão atual.'}) + "`nUse uma conta com permissão no servidor e a senha da conta, não o PIN."
    $instruction.Location = [System.Drawing.Point]::new(15, 12)
    $instruction.Size = [System.Drawing.Size]::new(478, 75)
    $dialog.Controls.Add($instruction)

    $serverLabel = [System.Windows.Forms.Label]::new()
    $serverLabel.Text = 'Hostname ou IP:'
    $serverLabel.Location = [System.Drawing.Point]::new(15, 107)
    $serverLabel.AutoSize = $true
    $dialog.Controls.Add($serverLabel)
    $serverBox = [System.Windows.Forms.TextBox]::new()
    $serverBox.Name = 'CredentialServer'
    $serverBox.Location = [System.Drawing.Point]::new(154, 103)
    $serverBox.Size = [System.Drawing.Size]::new(340, 25)
    $serverBox.Text = $Server
    $serverBox.ReadOnly = -not $AllowServerEdit
    $dialog.Controls.Add($serverBox)

    $userLabel = [System.Windows.Forms.Label]::new()
    $userLabel.Text = 'Usuário:'
    $userLabel.Location = [System.Drawing.Point]::new(15, 146)
    $userLabel.AutoSize = $true
    $dialog.Controls.Add($userLabel)
    $userBox = [System.Windows.Forms.TextBox]::new()
    $userBox.Name = 'CredentialUser'
    $userBox.Location = [System.Drawing.Point]::new(154, 142)
    $userBox.Size = [System.Drawing.Size]::new(340, 25)
    $userBox.Text = if ($InitialUser) { $InitialUser } elseif($RequireCredential){''} else { "$Server\" }
    $dialog.Controls.Add($userBox)

    $passLabel = [System.Windows.Forms.Label]::new()
    $passLabel.Text = 'Senha:'
    $passLabel.Location = [System.Drawing.Point]::new(15, 185)
    $passLabel.AutoSize = $true
    $dialog.Controls.Add($passLabel)
    $passBox = [System.Windows.Forms.TextBox]::new()
    $passBox.Name = 'CredentialPassword'
    $passBox.Location = [System.Drawing.Point]::new(154, 181)
    $passBox.Size = [System.Drawing.Size]::new(340, 25)
    $passBox.UseSystemPasswordChar = $true
    $dialog.Controls.Add($passBox)

    $connectButton = [System.Windows.Forms.Button]::new()
    $connectButton.Text = if($RequireCredential){'Usar esta conta'}else{'Conectar'}
    $connectButton.Location = [System.Drawing.Point]::new(15, 231)
    $connectButton.Size = [System.Drawing.Size]::new(135, 34)
    $connectButton.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($connectButton)
    $dialog.AcceptButton = $connectButton

    $withoutButton = [System.Windows.Forms.Button]::new()
    $withoutButton.Text = 'Manter sessão atual'
    $withoutButton.Location = [System.Drawing.Point]::new(163, 231)
    $withoutButton.Size = [System.Drawing.Size]::new(156, 34)
    $withoutButton.DialogResult = [System.Windows.Forms.DialogResult]::Ignore
    $withoutButton.Visible = -not $RequireCredential
    $dialog.Controls.Add($withoutButton)

    $cancelButton = [System.Windows.Forms.Button]::new()
    $cancelButton.Text = 'Cancelar'
    $cancelButton.Location = [System.Drawing.Point]::new(332, 231)
    $cancelButton.Size = [System.Drawing.Size]::new(162, 34)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.CancelButton = $cancelButton

    try {
        $choice = $dialog.ShowDialog($Parent)
        if ($choice -eq [System.Windows.Forms.DialogResult]::Ignore) { return @{ WithoutCredential=$true } }
        if ($choice -ne [System.Windows.Forms.DialogResult]::OK) { return @{ Cancelled=$true } }
        return @{ Server=$serverBox.Text.Trim(); User=$userBox.Text.Trim(); Password=$passBox.Text }
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
        $portServer = ([regex]::Match($UNCPath,'^\\\\([^\\]+)\\')).Groups[1].Value
        $hasNetworkCredential=[bool]($script:authenticatedPrinterServer -ieq $portServer -and $script:authenticatedPrinterCredential)
        @{ UNCPath=$UNCPath; DriverName=$DriverName; QueueName=$QueueName; InfPath=$InfPath; HasNetworkCredential=$hasNetworkCredential } |
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
        $diagnostic=@("Destino=$UNCPath")
        foreach($field in @('AttemptId','WorkerVersion','FailureScope','RemoteAccessCode','ShareLookupCode','RecoveryReason','CredentialRetryRecommended','NeedsAuthentication')){
            if($result.ContainsKey($field)){$diagnostic+=($field+'='+(([string]$result[$field]) -replace '[\r\n]',' '))}
        }
        Write-AppLog -Message ('Decisão de recuperação da porta local: '+($diagnostic -join ' | ')) -Level INFO
        $result.Message=$detail
        return $result
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

    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = 'Instalar impressora compartilhada por porta local'
    $dialog.Size = [System.Drawing.Size]::new(640, 520)
    $dialog.StartPosition = 'CenterParent'
    $dialog.FormBorderStyle = 'FixedDialog'
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = [System.Drawing.Font]::new('Segoe UI', 9)

    $intro = [System.Windows.Forms.Label]::new()
    $intro.Location = [System.Drawing.Point]::new(16, 14)
    $intro.Size = [System.Drawing.Size]::new(590, 61)
    $intro.Text = if ($Direct) {
        "Esta opção cria neste computador uma fila local apontando para a impressora compartilhada. Selecione um driver compatível com este PC. O Windows pedirá autorização de administrador."
    } else {
        "A conexão normal falhou. Esta opção cria uma fila local apontando para o mesmo compartilhamento. Selecione um driver compatível com este PC. O Windows pedirá autorização de administrador."
    }
    $dialog.Controls.Add($intro)

    $lblPath = [System.Windows.Forms.Label]::new()
    $lblPath.Location = [System.Drawing.Point]::new(16, 84)
    $lblPath.AutoSize = $true
    $lblPath.Text = 'Porta (caminho da impressora compartilhada):'
    $dialog.Controls.Add($lblPath)
    $cmbPath = [System.Windows.Forms.ComboBox]::new()
    $cmbPath.Location = [System.Drawing.Point]::new(16, 105)
    $cmbPath.Size = [System.Drawing.Size]::new(590, 24)
    $cmbPath.DropDownStyle = 'DropDown'
    [void]$cmbPath.Items.Add($UNCPath)
    if ($AlternateHost -and $AlternateHost -ne $server -and $AlternateHost -match '^\d{1,3}(\.\d{1,3}){3}$') {
        [void]$cmbPath.Items.Add(('\\' + $AlternateHost + '\' + $share))
    }
    $cmbPath.SelectedIndex = 0
    $dialog.Controls.Add($cmbPath)

    $lblQueue = [System.Windows.Forms.Label]::new()
    $lblQueue.Location = [System.Drawing.Point]::new(16, 143)
    $lblQueue.AutoSize = $true
    $lblQueue.Text = 'Nome que a impressora terá neste PC:'
    $dialog.Controls.Add($lblQueue)
    $txtQueue = [System.Windows.Forms.TextBox]::new()
    $txtQueue.Location = [System.Drawing.Point]::new(16, 164)
    $txtQueue.Size = [System.Drawing.Size]::new(590, 24)
    $txtQueue.Text = "$share em $server"
    $dialog.Controls.Add($txtQueue)

    $lblDriver = [System.Windows.Forms.Label]::new()
    $lblDriver.Location = [System.Drawing.Point]::new(16, 202)
    $lblDriver.AutoSize = $true
    $lblDriver.Text = 'Driver para este computador (nome exato do modelo):'
    $dialog.Controls.Add($lblDriver)
    $cmbDriver = [System.Windows.Forms.ComboBox]::new()
    $cmbDriver.Location = [System.Drawing.Point]::new(16, 223)
    $cmbDriver.Size = [System.Drawing.Size]::new(590, 24)
    $cmbDriver.DropDownStyle = 'DropDown'
    foreach ($driverName in @(Get-InstalledDriversSafe)) { [void]$cmbDriver.Items.Add([string]$driverName) }
    if ($SuggestedDriverName) {
        $cmbDriver.Text = $SuggestedDriverName
    } elseif ($share -ieq 'MP' -and $cmbDriver.Items.Contains('MP-4200 TH')) {
        $cmbDriver.Text = 'MP-4200 TH'
    }
    $dialog.Controls.Add($cmbDriver)
    $btnRefreshDrivers = [System.Windows.Forms.Button]::new()
    $btnRefreshDrivers.Text = 'Atualizar drivers'
    $btnRefreshDrivers.Location = [System.Drawing.Point]::new(470, 194)
    $btnRefreshDrivers.Size = [System.Drawing.Size]::new(136, 26)
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

    $btnVendorInstaller = [System.Windows.Forms.Button]::new()
    $btnVendorInstaller.Text = 'Instalar driver...'
    $btnVendorInstaller.Location = [System.Drawing.Point]::new(310, 194)
    $btnVendorInstaller.Size = [System.Drawing.Size]::new(150, 26)
    $btnVendorInstaller.Add_Click({
        $picker = [System.Windows.Forms.OpenFileDialog]::new()
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

    $lblInf = [System.Windows.Forms.Label]::new()
    $lblInf.Location = [System.Drawing.Point]::new(16, 261)
    $lblInf.AutoSize = $true
    $lblInf.Text = 'INF oficial do fabricante (opcional se o driver já estiver instalado):'
    $dialog.Controls.Add($lblInf)
    $txtInf = [System.Windows.Forms.TextBox]::new()
    $txtInf.Location = [System.Drawing.Point]::new(16, 282)
    $txtInf.Size = [System.Drawing.Size]::new(485, 24)
    $dialog.Controls.Add($txtInf)
    $btnBrowse = [System.Windows.Forms.Button]::new()
    $btnBrowse.Text = 'Procurar...'
    $btnBrowse.Location = [System.Drawing.Point]::new(510, 280)
    $btnBrowse.Size = [System.Drawing.Size]::new(96, 28)
    $btnBrowse.Add_Click({
        $picker = [System.Windows.Forms.OpenFileDialog]::new()
        $picker.Filter = 'Arquivos de driver (*.inf)|*.inf'
        if ($picker.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) { $txtInf.Text = $picker.FileName }
        $picker.Dispose()
    })
    $dialog.Controls.Add($btnBrowse)

    $lblNote = [System.Windows.Forms.Label]::new()
    $lblNote.Location = [System.Drawing.Point]::new(16, 319)
    $lblNote.Size = [System.Drawing.Size]::new(590, 48)
    $lblNote.Text = 'A porta local ainda precisa de acesso à rede e permissão de impressão no PC servidor. Se selecionar um INF, digite o nome do modelo que aparece no pacote. Depois da instalação, faça uma página de teste.'
    $dialog.Controls.Add($lblNote)

    $lblNote.Height = 24
    $btnServerDriver = [System.Windows.Forms.Button]::new()
    $btnServerDriver.Text = 'Receber driver do servidor (sem download da internet)'
    $btnServerDriver.Location = [System.Drawing.Point]::new(16, 343)
    $btnServerDriver.Size = [System.Drawing.Size]::new(590, 27)
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
            $received = Invoke-PrinterOperationUsingAvailableSession -UNCPath $port -RequestCredential {
                param($hostName,$failure)
                Request-PrinterServerCredential -Server $hostName -InitialUser $script:authenticatedPrinterUser -Parent $dialog -Reason (Get-PrinterCredentialReason $failure)
            } -Attempt {
                $credential=if($script:authenticatedPrinterServer -ieq $driverServer){$script:authenticatedPrinterCredential}else{$null}
                Invoke-BoundedPrinterAttempt -UNCPath $port -Method InstallDriver -TimeoutSeconds 40 -NetworkCredential $credential -CredentialServer $driverServer
            }
            Write-AppLog -Message "Receber driver: $($received.Message)" -Level $(if ($received.Success) { 'SUCESSO' } else { 'AVISO' })
            $status.Text = $received.Message
            if ($received.Success) {
                $cmbDriver.Items.Clear()
                foreach ($availableDriver in @(Get-InstalledDriversSafe)) { [void]$cmbDriver.Items.Add([string]$availableDriver) }
                $cmbDriver.SelectedItem = $received.DriverName
                $status.ForeColor = [System.Drawing.Color]::DarkGreen
            } else {
                $status.ForeColor = [System.Drawing.Color]::DarkRed
                $status.Text = 'Falha ao receber driver; consulte a mensagem.'
                $detail="Etapa: $($received.Stage)`nRecurso: $($received.Resource)`nCódigo: $($received.Code)`n`n$($received.Message)"
                [System.Windows.Forms.MessageBox]::Show($dialog,$detail,'Não foi possível receber o driver',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        } catch { $status.Text = $_.Exception.Message }
        finally { $btnServerDriver.Enabled = $true }
    })
    $dialog.Controls.Add($btnServerDriver)

    $status = [System.Windows.Forms.Label]::new()
    $status.Location = [System.Drawing.Point]::new(16, 372)
    $status.Size = [System.Drawing.Size]::new(590, 29)
    $status.ForeColor = [System.Drawing.Color]::DarkRed
    $status.Text = ''
    $dialog.Controls.Add($status)

    $btnInstall = [System.Windows.Forms.Button]::new()
    $btnInstall.Text = 'Instalar por porta local'
    $btnInstall.Location = [System.Drawing.Point]::new(302, 402)
    $btnInstall.Size = [System.Drawing.Size]::new(174, 30)
    $dialog.Controls.Add($btnInstall)
    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = 'Cancelar'
    $btnCancel.Location = [System.Drawing.Point]::new(486, 402)
    $btnCancel.Size = [System.Drawing.Size]::new(120, 30)
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
        $attempt = Invoke-PrinterOperationUsingAvailableSession -UNCPath $port -RequestCredential {
            param($hostName,$failure)
            Request-PrinterServerCredential -Server $hostName -InitialUser $script:authenticatedPrinterUser -Parent $dialog -Reason (Get-PrinterCredentialReason $failure)
        } -Attempt { Invoke-LocalPortInstallElevated -UNCPath $port -DriverName $driver -QueueName $queue -InfPath $inf }
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
        [ValidateSet('Cascade','AddPrinter','WScript','PrintUI','PublishDriver','InstallDriver','PrepareHost','PrepareClient','LocalPort','Authenticate','RestoreClientPolicies','RestoreHostPolicies')][string]$Method,
        [int]$TimeoutSeconds = 25,
        [pscredential]$NetworkCredential,
        [string]$CredentialServer = '',
        [string]$LocalPortRequestPath = '', [string]$AccessResource = '',
        [ValidateSet('TestPage','QueueOnly')][string]$ValidationMode='QueueOnly'
    )
    $resultPath = ''
    $process = $null
    $nativeProcess = $null
    function Stop-PrinterWorkerTree {
        param([int]$WorkerId)
        if($WorkerId -le 0){return}
        # Includes PnPUtil spawned by the worker; do not leave an installer running
        # after cancelling only its PowerShell parent.
        $killer=$null
        try{
            $killer=Start-Process -FilePath (Join-Path $env:WINDIR 'System32\taskkill.exe') -ArgumentList ('/PID '+$WorkerId+' /T /F') -WindowStyle Hidden -PassThru -ErrorAction Stop
            if(-not $killer.WaitForExit(1500)){$killer.Kill()}
        }catch{}finally{if($killer){$killer.Dispose()}}
    }
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
        } elseif ($Method -in @('Cascade','AddPrinter','WScript','PublishDriver','InstallDriver','PrepareHost','PrepareClient','Authenticate','RestoreClientPolicies','RestoreHostPolicies')) {
            if (-not $PrinterConnectionPath -or -not (Test-Path -LiteralPath $PrinterConnectionPath)) {
                return @{ Success=$false; Message='Rotina interna de conexão não encontrada no EXE.' }
            }
            $resultPath = Join-Path $env:TEMP ('PrinterConnect_' + [Guid]::NewGuid().ToString('N') + '.xml')
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -UNCPath "{1}" -ResultPath "{2}" -Method {3}' -f $PrinterConnectionPath,$UNCPath,$resultPath,$Method
            if($Method -eq 'Cascade'){
                $arguments += ' -ValidationMode '+$ValidationMode
                if($NetworkCredential){$arguments += ' -HasNetworkCredential'}
            }
            if($Method -eq 'Authenticate' -and $AccessResource){
                if($AccessResource -match '["\x00-\x1f]'){return @{Success=$false;Code=87;Message='Recurso remoto inválido.'}}
                $arguments += ' -AccessResource "'+$AccessResource+'"'
            }
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
                    Stop-PrinterWorkerTree -WorkerId $(if($nativeProcess){$nativeProcess.dwProcessId}else{$process.Id})
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
                    Stop-PrinterWorkerTree -WorkerId $(if($nativeProcess){$nativeProcess.dwProcessId}else{$process.Id})
                    if ($nativeProcess) { [void][PrinterNetOnlyProcess]::TerminateProcess($nativeProcess.hProcess,1460) }
                    else { $process.Kill(); [void]$process.WaitForExit(2000) }
                } catch {}
                return @{ Success=$false; TimedOut=$true; Message="A tentativa $Method excedeu $TimeoutSeconds segundos e foi interrompida.$stageMessage" }
            }
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        $exitCode = if ($nativeProcess) { $nativeExit = [uint32]0; [void][PrinterNetOnlyProcess]::GetExitCodeProcess($nativeProcess.hProcess,[ref]$nativeExit); $nativeExit } else { $process.ExitCode }
        if ($Method -in @('Cascade','AddPrinter','WScript','PublishDriver','InstallDriver','PrepareHost','PrepareClient','LocalPort','Authenticate','RestoreClientPolicies','RestoreHostPolicies')) {
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
    param([string]$UNCPath,[string]$AlternateHost='',
        [ValidateSet('TestPage','QueueOnly')][string]$ValidationMode='QueueOnly')
    if($global:SimulationMode){return @{Success=$true;Simulated=$true;Code=0;Message='Conexão simulada; nenhuma alteração ou job enviado.'}}
    $cleanUNC=$UNCPath.Trim()
    if(-not $cleanUNC.StartsWith('\\')){return @{Success=$false;Code=87;Message='Caminho UNC inválido.'}}
    $parts=$cleanUNC.Substring(2).Split([char]92)
    if($parts.Length -ne 2 -or -not $parts[0] -or -not $parts[1]){return @{Success=$false;Code=87;Message='Caminho UNC inválido.'}}
    $server=$parts[0]
    if(-not(Test-TcpPortSafe -HostOrIp $server -Port 445 -TimeoutMs 1500)){
        $message="O computador $server não responde na porta SMB 445. Execute neste computador que compartilha a impressora: Impressoras locais > Preparar host e driver. Isso verifica os serviços e as regras de compartilhamento. Firewall de terceiros ou regras de domínio também podem impedir o acesso."
        Write-AppLog -Message ("Conexão interrompida antes do Spooler: $cleanUNC; SMB 445 inacessível. "+$message) -Level ERRO
        return @{Success=$false;Code=53;Stage='Verificar acesso SMB ao servidor';Resource=$cleanUNC;Message=$message}
    }
    $credential=if($script:authenticatedPrinterServer -ieq $server){$script:authenticatedPrinterCredential}else{$null}
    Write-AppLog -Message "Iniciando cascata nativa/driver/porta local para $cleanUNC." -Level INFO
    $attempt=Invoke-BoundedPrinterAttempt -UNCPath $cleanUNC -Method Cascade -TimeoutSeconds 180 -NetworkCredential $credential -CredentialServer $server -ValidationMode $ValidationMode
    foreach($step in @($attempt.History)){if(-not [string]::IsNullOrWhiteSpace([string]$step)){Write-AppLog -Message ([string]$step) -Level INFO}}
    $diagnostic=@("Destino=$cleanUNC")
    foreach($field in @('AttemptId','WorkerVersion','Success','QueueInstalled','Stage','Code','NativeCode','FailureScope','NativeConnectionCode','RemoteAccessCode','ShareLookupCode','AuthenticationCode','RecoveryReason','CredentialRetryRecommended','NeedsAuthentication','DriverName','DriverConfirmed','DriverAvailability','DriverQueryCode','InfLookupCode','InfLookupStage','PreparedPackageFound','PortMethod')){
        if($attempt.ContainsKey($field)){$diagnostic+=($field+'='+(([string]$attempt[$field]) -replace '[\r\n]',' '))}
    }
    if($attempt.ContainsKey('NativeAttemptCodes')){$diagnostic+=('NativeAttemptCodes='+(@($attempt.NativeAttemptCodes) -join ','))}
    Write-AppLog -Message ('Resultado da conexão: '+($diagnostic -join ' | ')) -Level INFO
    if($attempt.Cancelled){return @{Success=$false;Code=1223;Cascaded=$true;Message='Conexão cancelada; confira a fila antes de repetir.'}}
    if($attempt.TimedOut){return @{Success=$false;Code=1460;Cascaded=$true;Message=$attempt.Message}}
    if($attempt.QueueInstalled -or $attempt.Success){
        $verified=Test-PrinterShareInstalled -UNCPath $cleanUNC -InstalledPrinters (Get-InstalledPrintersWmi)
        if(-not $attempt.QueueInstalled -or -not $verified){return @{Success=$false;Code=31;Cascaded=$true;Message='Worker terminou, mas a fila não foi confirmada neste usuário.'}}
        Write-AppLog -Message $attempt.Message -Level $(if($attempt.Success){'SUCESSO'}else{'AVISO'})
    }else{
        if(-not $attempt.Code){$attempt.Code=if($attempt.NativeCode){$attempt.NativeCode}else{31}}
        Write-AppLog -Message ("Falha da cascata: "+$attempt.Message) -Level ERRO
    }
    return $attempt
}

function Connect-PrinterUsingAvailableSession {
    param([string]$UNCPath, [string]$AlternateHost='', [scriptblock]$RequestCredential,
        [string[]]$CredentialServerAliases=@(),
        [ValidateSet('TestPage','QueueOnly')][string]$ValidationMode='QueueOnly')
    return (Invoke-PrinterOperationUsingAvailableSession -UNCPath $UNCPath -CredentialServerAliases $CredentialServerAliases -RequestCredential $RequestCredential -Attempt {
        Connect-UNCPrinterSafe -UNCPath $UNCPath -AlternateHost $AlternateHost -ValidationMode $ValidationMode
    })
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

$form = [System.Windows.Forms.Form]::new()
$form.SuspendLayout()
$form.Text = "Arrumar Impressora VG [v1.10.8]"
$form.Size = [System.Drawing.Size]::new(990, 680)
$form.MinimumSize = [System.Drawing.Size]::new(900, 620)
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 246, 248)

# Painel Superior (Cabeçalho com Identificação e Modo Simulação)
$pnlHeader = [System.Windows.Forms.Panel]::new()
$pnlHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlHeader.Height = 55
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(33, 43, 54)
$form.Controls.Add($pnlHeader)

$lblTitle = [System.Windows.Forms.Label]::new()
$lblTitle.Text = "Arrumar Impressora VG"
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Font = [System.Drawing.Font]::new("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.AutoSize = $true
$lblTitle.Location = [System.Drawing.Point]::new(12, 8)
$pnlHeader.Controls.Add($lblTitle)

$isAdmin = Test-IsAdmin
$adminText = if ($isAdmin) { "Administrador: SIM" } else { "Administrador: NÃO (Privilégio Limitado)" }
$lblSubTitle = [System.Windows.Forms.Label]::new()
$lblSubTitle.Text = "Host: $env:COMPUTERNAME | Usuário: $env:USERNAME | $adminText"
$lblSubTitle.ForeColor = [System.Drawing.Color]::FromArgb(180, 195, 210)
$lblSubTitle.Font = [System.Drawing.Font]::new("Segoe UI", 8.5)
$lblSubTitle.AutoSize = $true
$lblSubTitle.Location = [System.Drawing.Point]::new(14, 30)
$pnlHeader.Controls.Add($lblSubTitle)

$chkSimulation = [System.Windows.Forms.CheckBox]::new()
$chkSimulation.Text = "Somente diagnosticar (Modo Simulação)"
$chkSimulation.ForeColor = [System.Drawing.Color]::Gold
$chkSimulation.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chkSimulation.AutoSize = $true
$chkSimulation.Location = [System.Drawing.Point]::new(680, 16)
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
$statusStrip = [System.Windows.Forms.StatusStrip]::new()
$statusStrip.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$form.Controls.Add($statusStrip)

$statusLabel = [System.Windows.Forms.ToolStripStatusLabel]::new()
$statusLabel.Text = "Pronto."
$statusLabel.ForeColor = [System.Drawing.Color]::Black
$statusLabel.Spring = $true
$statusLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
[void]$statusStrip.Items.Add($statusLabel)

$statusTag = [System.Windows.Forms.ToolStripStatusLabel]::new()
$statusTag.Text = "SISTEMA OPERACIONAL: OK"
$statusTag.ForeColor = [System.Drawing.Color]::DarkGreen
$statusTag.Font = [System.Drawing.Font]::new("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
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
$pnlLoading = [System.Windows.Forms.Panel]::new()
$pnlLoading.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlLoading.Height = 36
$pnlLoading.BackColor = [System.Drawing.Color]::FromArgb(235, 243, 253)
$pnlLoading.Visible = $false
$form.Controls.Add($pnlLoading)

$lblLoadingSpinner = [System.Windows.Forms.Label]::new()
$lblLoadingSpinner.Text = [char]0x25D0
$lblLoadingSpinner.Font = [System.Drawing.Font]::new("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblLoadingSpinner.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$lblLoadingSpinner.Location = [System.Drawing.Point]::new(12, 6)
$lblLoadingSpinner.Size = [System.Drawing.Size]::new(26, 24)
$pnlLoading.Controls.Add($lblLoadingSpinner)

$lblLoadingText = [System.Windows.Forms.Label]::new()
$lblLoadingText.Text = "Carregando..."
$lblLoadingText.Font = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblLoadingText.ForeColor = [System.Drawing.Color]::FromArgb(24, 76, 120)
$lblLoadingText.Location = [System.Drawing.Point]::new(40, 7)
$lblLoadingText.AutoSize = $true
$pnlLoading.Controls.Add($lblLoadingText)

$pbLoadingMarquee = [System.Windows.Forms.ProgressBar]::new()
$pbLoadingMarquee.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
$pbLoadingMarquee.MarqueeAnimationSpeed = 25
$pbLoadingMarquee.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pbLoadingMarquee.Height = 5
$pnlLoading.Controls.Add($pbLoadingMarquee)

$script:cancelPrinterConnection = $false
$btnCancelConnection = [System.Windows.Forms.Button]::new()
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

$tmrSpinner = [System.Windows.Forms.Timer]::new()
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
    $pbLoadingMarquee.Visible = $true
    $pbLoadingMarquee.MarqueeAnimationSpeed = 25
    $tmrSpinner.Start()
    $form.UseWaitCursor = $true
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
    $pbLoadingMarquee.MarqueeAnimationSpeed = 0
    $pbLoadingMarquee.Visible = $false
    $pnlLoading.Visible = $false
    $lblLoadingText.Text = ''
    $btnCancelConnection.Visible = $false
    $form.UseWaitCursor = $false
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
        $asyncRes=$null
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
        } catch {} finally {if($asyncRes){$asyncRes.AsyncWaitHandle.Close()}}
    }
    # Name discovery must not start an unbounded remote WMI/RPC query.
    # Keep the IP when NetBIOS and the bounded DNS lookup cannot identify it.
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
        } else {
            try {
                $ips = @(Resolve-PrinterEndpointAddresses -Server $hostName -Mode IP)
                if ($ips.Count) { $ipAddr = [string]$ips[0] }
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

function Use-PrinterCredentialForEndpoint {
    param([string]$Server, [string[]]$Aliases=@())
    # Os aliases vêm do mesmo registro descoberto; nunca de outra fila.
    if ($script:authenticatedPrinterCredential -and $script:authenticatedPrinterServer -and
        $Aliases -icontains $script:authenticatedPrinterServer -and
        $script:authenticatedPrinterServer -ine $Server) {
        $script:authenticatedPrinterServer = $Server
        Write-AppLog -Message "Reutilizando a conta já informada para o destino selecionado: $Server." -Level INFO
    }
}

function Resolve-PrinterEndpointAddresses {
    param([string]$Server, [ValidateSet('Hostname','IP')][string]$Mode)
    $async = $null
    try {
        if ($Mode -eq 'Hostname') {
            $name = Get-NetBiosNameDirect -TargetIP $Server
            if ($name) { return $name }
            $async = [Net.Dns]::BeginGetHostEntry($Server,$null,$null)
            if ($async.AsyncWaitHandle.WaitOne(800)) {
                $entry = [Net.Dns]::EndGetHostEntry($async)
                if ($entry.HostName) { return $entry.HostName.TrimEnd('.') }
            }
        } else {
            $async = [Net.Dns]::BeginGetHostAddresses($Server,$null,$null)
            if ($async.AsyncWaitHandle.WaitOne(1000)) {
                return @([Net.Dns]::EndGetHostAddresses($async) | Where-Object {
                    $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
                    $_.IPAddressToString -notlike '127.*'
                } | ForEach-Object { $_.IPAddressToString })
            }
        }
    } catch {} finally {
        if ($async) { $async.AsyncWaitHandle.Close() }
    }
    return @()
}

function Resolve-PrinterConnectionEndpoint {
    param([string]$UNCPath, [string]$ServerDisplay='',
        [ValidateSet('Hostname','IP')][string]$Mode='Hostname', [switch]$Preview)
    $match = [regex]::Match($UNCPath.Trim(), '^\\\\([^\\]+)\\([^\\]+)$')
    if (-not $match.Success) { return @{Success=$false;Message='Selecione uma impressora compartilhada com caminho UNC válido.'} }
    $originalServer = $match.Groups[1].Value
    $share = $match.Groups[2].Value
    $displayParts = @($ServerDisplay -split '\s+\\\s+' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $knownName = @($displayParts | Where-Object { $_ -match '^[A-Za-z0-9._-]+$' -and $_ -notmatch '^\d+(\.\d+){3}$' } | Select-Object -First 1)
    $knownIp = @($displayParts | Where-Object { $_ -match '^\d+(\.\d+){3}$' } | Select-Object -First 1)
    $parsed = $null
    $originalIsIp = [Net.IPAddress]::TryParse($originalServer,[ref]$parsed)
    if ((-not $originalIsIp -and $originalServer -notmatch '^[A-Za-z0-9._-]+$') -or
        ($originalServer -match '^\d+(\.\d+){3}$' -and -not $originalIsIp) -or
        ($originalIsIp -and $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork)) {
        return @{Success=$false;Message='Informe um hostname ou endereço IPv4 válido.'}
    }
    $target = $originalServer
    if ($Mode -eq 'Hostname' -and $originalIsIp) {
        $target = if ($knownName.Count) { [string]$knownName[0] } else { '' }
        if (-not $target -and -not $Preview) {
            $target = [string](@(Resolve-PrinterEndpointAddresses -Server $originalServer -Mode Hostname) | Select-Object -First 1)
        }
        $ip = $null
        if (-not $target -or [Net.IPAddress]::TryParse($target,[ref]$ip) -or $target -notmatch '^[A-Za-z0-9._-]+$') {
            return @{Success=$false;Message='Hostname não identificado. Informe o nome do computador em Buscar servidor, ou selecione Endereço IP.'}
        }
    } elseif ($Mode -eq 'IP' -and -not $originalIsIp) {
        $addresses = @()
        if (-not $Preview) { $addresses = @(Resolve-PrinterEndpointAddresses -Server $originalServer -Mode IP) }
        # Preferir a resolução atual; o IP descoberto só é usado se não houver resposta.
        $target = if ($addresses.Count) {
            if ($knownIp.Count -and $addresses -contains $knownIp[0]) { [string]$knownIp[0] } else { [string]$addresses[0] }
        } elseif ($knownIp.Count) { [string]$knownIp[0] } else { '' }
        $ip = $null
        if (-not $target -or -not [Net.IPAddress]::TryParse($target,[ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            return @{Success=$false;Message='IP não identificado. Informe o endereço em Buscar servidor, ou selecione Nome do computador.'}
        }
    }
    $aliases = @(@($originalServer,$target) + $displayParts | Select-Object -Unique)
    return @{Success=$true;Server=$target;ShareName=$share;UNCPath=('\\'+$target+'\'+$share);Mode=$Mode;Aliases=$aliases}
}

function Invoke-PrinterOperationUsingAvailableSession {
    param([string]$UNCPath,[scriptblock]$Attempt,[scriptblock]$RequestCredential,
        [string[]]$CredentialServerAliases=@())
    $server = ([regex]::Match($UNCPath, '^\\\\([^\\]+)\\')).Groups[1].Value
    Use-PrinterCredentialForEndpoint -Server $server -Aliases $CredentialServerAliases
    $result = & $Attempt
    if ($result.Success -or $result.Simulated -or $result.QueueInstalled -or
        $result.Cancelled -or $result.TimedOut -or $result.Code -in @(1223,1460) -or -not $RequestCredential) { return $result }
    $needsAccount = $result.NeedsAuthentication -or $result.CredentialRetryRecommended -or
        ($result.FailureScope -ne 'Local' -and $result.Code -in @(86,1244,1326,1327,1328,1329,1330,1331,1385,1907,1909,2202))
    if (-not $needsAccount) { return $result }
    Write-AppLog -Message "Recuperação de acesso em $server; etapa '$($result.Stage)', recurso '$($result.Resource)', código $($result.Code), motivo '$($result.RecoveryReason)'. Solicitando uma conta uma vez." -Level AVISO
    $choice = & $RequestCredential $server $result
    if (-not $choice -or $choice.Cancelled) {
        return @{Success=$false;Code=1223;Cascaded=$true;Message='Conexão cancelada na solicitação de conta.'}
    }
    if ($choice.WithoutCredential) { $result.CredentialPrompted=$true;return $result }
    try {
        if (-not $choice.User -or -not $choice.Password) {
            return @{Success=$false;Code=87;Cascaded=$true;Message='Informe usuário e senha juntos para usar outra conta.'}
        }
        $credential = New-Object Management.Automation.PSCredential($choice.User,
            (ConvertTo-SecureString $choice.Password -AsPlainText -Force))
        # Isolated network token: replacement credentials do not conflict with
        # SMB connections belonging to Explorer or other applications.
        $driverRoot='\\'+$server+'\print$'
        $accessResource=if($result.Resource -ieq $driverRoot -or ([string]$result.Resource).StartsWith($driverRoot+'\',[StringComparison]::OrdinalIgnoreCase)){[string]$result.Resource}else{''}
        $auth = Invoke-BoundedPrinterAttempt -UNCPath $UNCPath -Method Authenticate -TimeoutSeconds 15 -NetworkCredential $credential -CredentialServer $server -AccessResource $accessResource
        if (-not $auth.Success) {
            $auth.Cascaded=$true;$auth.CredentialPrompted=$true
            if($auth.Cancelled){$auth.Code=1223}
            elseif($auth.TimedOut){$auth.Code=1460}
            else{$auth.Message="A tentativa com a conta informada falhou.`nEtapa: $($auth.Stage)`nRecurso: $($auth.Resource)`nCódigo: $($auth.Code)`n`n$($auth.Message)"}
            return $auth
        }
        $script:authenticatedPrinterServer = $server
        $script:authenticatedPrinterUser = $choice.User
        $script:authenticatedPrinterCredential = $credential
        Write-AppLog -Message "Sessão de rede estabelecida em $server; repetindo a operação uma única vez para validar o acesso ao recurso." -Level INFO
    } finally { $choice.Password = $null }
    # A segunda tentativa mantém a credencial em memória e não abre outro diálogo.
    $retried=& $Attempt
    $retried.CredentialPrompted=$true
    return $retried
}

function Get-PrinterCredentialReason {
    param($Failure)
    if($Failure.CredentialRetryRecommended){return "A fila $($Failure.ConfirmedUNC) existe, mas a sessão atual não concluiu a conexão de impressão. Tente uma conta desse computador servidor."}
    $resource=([string]$Failure.Resource -replace '[\r\n]',' ')
    if($resource.Length -gt 150){$resource=$resource.Substring(0,147)+'...'}
    $stage=if($Failure.Stage){[string]$Failure.Stage}else{'acessar impressora no servidor'}
    return "Acesso recusado: $stage."+$(if($resource){"`nRecurso: $resource"}else{''})
}

function New-ExplicitPrinterCredentialSelection {
    param([string]$UNCPath, [System.Collections.IDictionary]$Choice)
    if(-not $Choice -or $Choice.Cancelled){return @{Success=$false;Cancelled=$true;Code=1223;Message='Solicitação de conta cancelada.'}}
    try {
        $match=[regex]::Match($UNCPath,'^\\\\([^\\]+)\\([^\\]+)$')
        if(-not $match.Success){return @{Success=$false;Code=87;Message='Selecione um compartilhamento de impressora válido.'}}
        $server=if($Choice.Server){([string]$Choice.Server).Trim().Trim('\')}else{$match.Groups[1].Value}
        if($server -notmatch '^[A-Za-z0-9._-]+$'){
            return @{Success=$false;Code=87;Message='Informe somente o hostname ou IP do computador servidor, sem nome de pasta ou impressora.'}
        }
        if($server -match '^[0-9.]+$'){
            $address=$null
            if($server -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($server,[ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork){
                return @{Success=$false;Code=87;Message='O endereço IPv4 informado é inválido.'}
            }
        }
        $user=([string]$Choice.User).Trim()
        if(-not $user -or $user.EndsWith('\') -or -not $Choice.Password){
            return @{Success=$false;Code=87;Message='Informe usuário e senha da conta do servidor. Use a senha da conta, não o PIN.'}
        }
        if($user.StartsWith('.\')){$user=$server+$user.Substring(1)}
        elseif($user -notmatch '[\\@]'){$user="$server\$user"}
        $credential=New-Object Management.Automation.PSCredential($user,(ConvertTo-SecureString $Choice.Password -AsPlainText -Force))
        $share=$match.Groups[2].Value
        return @{Success=$true;Server=$server;ShareName=$share;UNCPath="\\$server\$share";SourceUNC=$UNCPath;User=$user;Credential=$credential}
    } finally {$Choice.Password=$null}
}

function Request-ExplicitPrinterConnectionCredential {
    param([string]$UNCPath,[string]$InitialUser='', [System.Windows.Forms.IWin32Window]$Parent)
    $server=([regex]::Match($UNCPath,'^\\\\([^\\]+)\\')).Groups[1].Value
    $choice=Request-PrinterServerCredential -Server $server -InitialUser $InitialUser -Parent $Parent -AllowServerEdit -RequireCredential -Reason "Modo Win 11: informe a conta antes de conectar.`nCompartilhamento selecionado: $UNCPath. Ao mudar o servidor, o nome do compartilhamento será mantido."
    return (New-ExplicitPrinterCredentialSelection -UNCPath $UNCPath -Choice $choice)
}

function Connect-PrinterUsingExplicitCredential {
    param([System.Collections.IDictionary]$Selection,
        [ValidateSet('TestPage','QueueOnly')][string]$ValidationMode='QueueOnly')
    if(-not $Selection -or -not $Selection.Success -or -not $Selection.Credential){
        return @{Success=$false;Code=87;Cascaded=$true;Message='Informe a conta do servidor antes de conectar.'}
    }
    if($global:SimulationMode){
        return @{Success=$false;Simulated=$true;Code=0;Cascaded=$true;Message='Simulação: autenticação e conexão não executadas.'}
    }
    $unc=$Selection.UNCPath
    $server=$Selection.Server
    Write-AppLog -Message "Modo Win 11: autenticando a conta informada antes da conexão em $unc." -Level INFO
    $auth=Invoke-BoundedPrinterAttempt -UNCPath $unc -Method Authenticate -TimeoutSeconds 15 -NetworkCredential $Selection.Credential -CredentialServer $server
    if(-not $auth.Success){
        $auth.Cascaded=$true;$auth.CredentialPrompted=$true
        if($auth.Cancelled){$auth.Code=1223}elseif($auth.TimedOut){$auth.Code=1460}
        Write-AppLog -Message "Modo Win 11: autenticação em $server não concluída; código $($auth.Code)." -Level AVISO
        return $auth
    }
    $script:authenticatedPrinterServer=$server
    $script:authenticatedPrinterUser=$Selection.User
    $script:authenticatedPrinterCredential=$Selection.Credential
    Write-AppLog -Message "Modo Win 11: conta autenticada em $server; iniciando a conexão com essa identidade de rede." -Level INFO
    # A cascata recebe o token de rede desde a primeira chamada, sem repetir o diálogo.
    $result=Connect-UNCPrinterSafe -UNCPath $unc -ValidationMode $ValidationMode
    $result.CredentialPrompted=$true
    return $result
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

$tabControl = [System.Windows.Forms.TabControl]::new()
$tabControl.Dock = [System.Windows.Forms.DockStyle]::Fill
$tabControl.Font = [System.Drawing.Font]::new("Segoe UI", 9)
$form.Controls.Add($tabControl)
$tabControl.BringToFront()

# Criar as 8 abas
$tab1 = [System.Windows.Forms.TabPage]::new(); $tab1.Text = "1. Diagnóstico"
$tab2 = [System.Windows.Forms.TabPage]::new(); $tab2.Text = "2. Impressoras Instaladas"
$tab3 = [System.Windows.Forms.TabPage]::new(); $tab3.Text = "3. Impressoras da Rede"

$tab4 = [System.Windows.Forms.TabPage]::new(); $tab4.Text = "4. Instalar por Caminho"
$tab5 = [System.Windows.Forms.TabPage]::new(); $tab5.Text = "5. Instalar por IP"
$tab6 = [System.Windows.Forms.TabPage]::new(); $tab6.Text = ("6. Fila e Spooler")
$tab7 = [System.Windows.Forms.TabPage]::new(); $tab7.Text = ("7. " + [char]0xC1 + "rea de Trabalho Remota")
$tab8 = [System.Windows.Forms.TabPage]::new(); $tab8.Text = ("8. Relat" + [char]0xF3 + "rio e Logs")

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
$pnlDiagTop = [System.Windows.Forms.Panel]::new()
$pnlDiagTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlDiagTop.Height = 45
$tab1.Controls.Add($pnlDiagTop)

$btnRunFullDiag = [System.Windows.Forms.Button]::new()
$btnRunFullDiag.Text = "Executar Diagnóstico Completo"
$btnRunFullDiag.Size = [System.Drawing.Size]::new(220, 32)
$btnRunFullDiag.Location = [System.Drawing.Point]::new(10, 6)
$btnRunFullDiag.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnRunFullDiag.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnRunFullDiag.ForeColor = [System.Drawing.Color]::White
$btnRunFullDiag.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlDiagTop.Controls.Add($btnRunFullDiag)

$btnCopyDiag = [System.Windows.Forms.Button]::new()
$btnCopyDiag.Text = "Copiar Diagnóstico"
$btnCopyDiag.Size = [System.Drawing.Size]::new(150, 32)
$btnCopyDiag.Location = [System.Drawing.Point]::new(240, 6)
$pnlDiagTop.Controls.Add($btnCopyDiag)

$txtDiagReport = [System.Windows.Forms.TextBox]::new()
$txtDiagReport.Multiline = $true
$txtDiagReport.ReadOnly = $true
$txtDiagReport.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtDiagReport.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtDiagReport.Font = [System.Drawing.Font]::new("Consolas", 9.5)
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
$pnlPrintersTop = [System.Windows.Forms.Panel]::new()
$pnlPrintersTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlPrintersTop.Height = 82
$tab2.Controls.Add($pnlPrintersTop)

$btnRefreshPrinters = [System.Windows.Forms.Button]::new()
$btnRefreshPrinters.Text = "Atualizar"
$btnRefreshPrinters.Size = [System.Drawing.Size]::new(80, 32)
$btnRefreshPrinters.Location = [System.Drawing.Point]::new(8, 6)
$pnlPrintersTop.Controls.Add($btnRefreshPrinters)

$btnSetDefault = [System.Windows.Forms.Button]::new()
$btnSetDefault.Text = "Definir Padrão"
$btnSetDefault.Size = [System.Drawing.Size]::new(110, 32)
$btnSetDefault.Location = [System.Drawing.Point]::new(92, 6)
$pnlPrintersTop.Controls.Add($btnSetDefault)

$btnOpenQueue = [System.Windows.Forms.Button]::new()
$btnOpenQueue.Text = "Abrir Fila"
$btnOpenQueue.Size = [System.Drawing.Size]::new(80, 32)
$btnOpenQueue.Location = [System.Drawing.Point]::new(206, 6)
$pnlPrintersTop.Controls.Add($btnOpenQueue)

$btnPrintTest = [System.Windows.Forms.Button]::new()
$btnPrintTest.Text = "Teste Windows"
$btnPrintTest.Size = [System.Drawing.Size]::new(105, 32)
$btnPrintTest.Location = [System.Drawing.Point]::new(290, 6)
$pnlPrintersTop.Controls.Add($btnPrintTest)

$btnThermalTest = [System.Windows.Forms.Button]::new()
$btnThermalTest.Text = "Teste RAW / Térmica"
$btnThermalTest.Size = [System.Drawing.Size]::new(140, 32)
$btnThermalTest.Location = [System.Drawing.Point]::new(399, 6)
$btnThermalTest.BackColor = [System.Drawing.Color]::FromArgb(255, 243, 205)
$pnlPrintersTop.Controls.Add($btnThermalTest)

$btnOpenProps = [System.Windows.Forms.Button]::new()
$btnOpenProps.Text = "Propriedades"
$btnOpenProps.Size = [System.Drawing.Size]::new(95, 32)
$btnOpenProps.Location = [System.Drawing.Point]::new(543, 6)
$pnlPrintersTop.Controls.Add($btnOpenProps)

$btnFixPrinter = [System.Windows.Forms.Button]::new()
$btnFixPrinter.Text = "Despausar / Online"
$btnFixPrinter.Size = [System.Drawing.Size]::new(125, 32)
$btnFixPrinter.Location = [System.Drawing.Point]::new(642, 6)
$pnlPrintersTop.Controls.Add($btnFixPrinter)

$btnRemoveConn = [System.Windows.Forms.Button]::new()
$btnRemoveConn.Text = "Remover"
$btnRemoveConn.Size = [System.Drawing.Size]::new(90, 32)
$btnRemoveConn.Location = [System.Drawing.Point]::new(771, 6)
$btnRemoveConn.ForeColor = [System.Drawing.Color]::DarkRed
$pnlPrintersTop.Controls.Add($btnRemoveConn)

$btnPublishDriver = [System.Windows.Forms.Button]::new()
$btnPublishDriver.Text = 'Preparar host e driver'
$btnPublishDriver.Size = [System.Drawing.Size]::new(250, 30)
$btnPublishDriver.Location = [System.Drawing.Point]::new(8, 44)
$pnlPrintersTop.Controls.Add($btnPublishDriver)

$btnCompatibilityRecovery = [System.Windows.Forms.Button]::new()
$btnCompatibilityRecovery.Text = 'Preparar cliente / restaurar políticas'
$btnCompatibilityRecovery.Size = [System.Drawing.Size]::new(290, 30)
$btnCompatibilityRecovery.Location = [System.Drawing.Point]::new(268, 44)
$btnCompatibilityRecovery.Add_Click({ Show-PrinterCompatibilityRecoveryDialog })
$pnlPrintersTop.Controls.Add($btnCompatibilityRecovery)

function Show-PrinterCompatibilityRecoveryDialog {
    $dialog=[Windows.Forms.Form]::new()
    $dialog.Text='Compatibilidade e recuperação neste computador'
    $dialog.Size=[Drawing.Size]::new(480,260)
    $dialog.StartPosition='CenterParent';$dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false;$dialog.MinimizeBox=$false
    $text=[Windows.Forms.Label]::new();$text.Location=[Drawing.Point]::new(16,14);$text.Size=[Drawing.Size]::new(435,88)
    $text.Text="Cliente: este PC recebe uma impressora de outro computador.`nServidor: este PC compartilha a impressora.`nRestaurar utiliza a primeira cópia anterior válida das políticas deste EXE. Se houver mudanças, o Spooler será reiniciado. Filas e drivers são mantidos."
    $dialog.Controls.Add($text)
    $choice=[Windows.Forms.ComboBox]::new();$choice.Location=[Drawing.Point]::new(16,110);$choice.Size=[Drawing.Size]::new(435,25);$choice.DropDownStyle='DropDownList'
    [void]$choice.Items.Add('Preparar políticas de cliente (compatibilidade)')
    [void]$choice.Items.Add('Restaurar políticas de cliente')
    [void]$choice.Items.Add('Restaurar políticas de servidor')
    $choice.SelectedIndex=1;$dialog.Controls.Add($choice)
    $apply=[Windows.Forms.Button]::new();$apply.Text='Executar';$apply.Location=[Drawing.Point]::new(16,155);$apply.Size=[Drawing.Size]::new(135,32);$apply.DialogResult='OK';$dialog.Controls.Add($apply)
    $cancel=[Windows.Forms.Button]::new();$cancel.Text='Cancelar';$cancel.Location=[Drawing.Point]::new(316,155);$cancel.Size=[Drawing.Size]::new(135,32);$cancel.DialogResult='Cancel';$dialog.Controls.Add($cancel)
    $dialog.AcceptButton=$apply;$dialog.CancelButton=$cancel
    try{
        if($dialog.ShowDialog($form) -ne [Windows.Forms.DialogResult]::OK){return}
        if($global:SimulationMode){[Windows.Forms.MessageBox]::Show($form,'Simulação: nenhuma política será alterada.','Compatibilidade') | Out-Null;return}
        $method=@('PrepareClient','RestoreClientPolicies','RestoreHostPolicies')[$choice.SelectedIndex]
        $script:cancelPrinterConnection=$false
        Show-LoadingIndicator -Message 'Executando a ação de compatibilidade selecionada...' -Button $btnCompatibilityRecovery
        $result=Invoke-BoundedPrinterAttempt -UNCPath ('\\'+$env:COMPUTERNAME+'\Compatibilidade') -Method $method -TimeoutSeconds 90
        Write-AppLog -Message ("Compatibilidade ($method): "+$result.Message) -Level $(if($result.Success){'SUCESSO'}else{'ERRO'})
        [Windows.Forms.MessageBox]::Show($form,[string]$result.Message,'Compatibilidade') | Out-Null
    }catch{Write-AppLog -Message $_.Exception.Message -Level ERRO;[Windows.Forms.MessageBox]::Show($form,$_.Exception.Message,'Compatibilidade') | Out-Null}
    finally{$dialog.Dispose();Hide-LoadingIndicator -Button $btnCompatibilityRecovery}
}

$dgvPrinters = [System.Windows.Forms.DataGridView]::new()
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
            $dgvPrinters.Rows[$rowIndex].DefaultCellStyle.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
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
        $preparedUNC='\\' + $env:COMPUTERNAME + '\' + $printer.ShareName
        Write-AppLog -Message "Preparar host e driver: destino $preparedUNC; fila local '$($printer.Name)'; driver '$($printer.DriverName)'." -Level INFO
        $published = Invoke-BoundedPrinterAttempt -UNCPath $preparedUNC -Method PrepareHost -TimeoutSeconds 120
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
    $dlg = [System.Windows.Forms.Form]::new()
    $dlg.Text = "Teste Térmico RAW Seguro - " + $pName
    $dlg.Size = [System.Drawing.Size]::new(520, 340)
    $dlg.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = [System.Drawing.Font]::new("Segoe UI", 9)

    $lblWarn = [System.Windows.Forms.Label]::new()
    $lblWarn.Text = "ATENÇÃO DE SEGURANÇA:`nO envio de comandos RAW para impressoras jato de tinta ou laser convencionais pode resultar em dezenas de páginas em branco impressas.`n`nSomente utilize esta função se tiver certeza de que a impressora é térmica (Bematech, Elgin, Epson, Zebra, Argox) e selecione a linguagem correspondente."
    $lblWarn.ForeColor = [System.Drawing.Color]::DarkRed
    $lblWarn.Location = [System.Drawing.Point]::new(15, 15)
    $lblWarn.Size = [System.Drawing.Size]::new(480, 75)
    $dlg.Controls.Add($lblWarn)

    $lblLang = [System.Windows.Forms.Label]::new()
    $lblLang.Text = "Linguagem / Padrão Térmico:"
    $lblLang.Location = [System.Drawing.Point]::new(15, 100)
    $lblLang.AutoSize = $true
    $dlg.Controls.Add($lblLang)

    $cmbLang = [System.Windows.Forms.ComboBox]::new()
    $cmbLang.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $cmbLang.Location = [System.Drawing.Point]::new(15, 122)
    $cmbLang.Size = [System.Drawing.Size]::new(470, 23)
    [void]$cmbLang.Items.Add("ESC/POS - Cupom Térmico (Bematech MP-4200 / Elgin i9 / Epson TM-T20)")
    [void]$cmbLang.Items.Add("PPLB - Etiqueta de Teste (Argox OS-214 Plus)")
    [void]$cmbLang.Items.Add("ZPL II - Etiqueta de Teste (Zebra ZD220 / GC420 / ZD230)")
    [void]$cmbLang.Items.Add("Texto ASCII Simples (Com avanço de linha)")
    $cmbLang.SelectedIndex = 0
    $dlg.Controls.Add($cmbLang)

    $chkConsent = [System.Windows.Forms.CheckBox]::new()
    $chkConsent.Text = "Estou ciente do modelo da impressora e autorizo o envio do comando RAW."
    $chkConsent.Location = [System.Drawing.Point]::new(15, 165)
    $chkConsent.Size = [System.Drawing.Size]::new(480, 35)
    $dlg.Controls.Add($chkConsent)

    $btnSend = [System.Windows.Forms.Button]::new()
    $btnSend.Text = "Enviar Teste RAW"
    $btnSend.Location = [System.Drawing.Point]::new(15, 215)
    $btnSend.Size = [System.Drawing.Size]::new(160, 35)
    $btnSend.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnSend.ForeColor = [System.Drawing.Color]::White
    $btnSend.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSend.Enabled = $false
    $dlg.Controls.Add($btnSend)

    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = [System.Drawing.Point]::new(185, 215)
    $btnCancel.Size = [System.Drawing.Size]::new(100, 35)
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
$pnlNetTop = [System.Windows.Forms.Panel]::new()
$pnlNetTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlNetTop.Height = 85
$pnlNetTop.BackColor = [System.Drawing.Color]::FromArgb(240, 243, 246)
$tab3.Controls.Add($pnlNetTop)

$btnAutoScan = [System.Windows.Forms.Button]::new()
$btnAutoScan.Text = "Varrer Rede e Atualizar Impressoras"
$btnAutoScan.Size = [System.Drawing.Size]::new(260, 34)
$btnAutoScan.Location = [System.Drawing.Point]::new(12, 10)
$btnAutoScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnAutoScan.ForeColor = [System.Drawing.Color]::White
$btnAutoScan.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnAutoScan.Font = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$pnlNetTop.Controls.Add($btnAutoScan)

$btnToggleManual = [System.Windows.Forms.Button]::new()
$btnToggleManual.Text = "Busca por Servidor Especifico..."
$btnToggleManual.Size = [System.Drawing.Size]::new(220, 34)
$btnToggleManual.Location = [System.Drawing.Point]::new(280, 10)
$pnlNetTop.Controls.Add($btnToggleManual)

$lblNetFilter = [System.Windows.Forms.Label]::new()
$lblNetFilter.Text = "Filtro:"
$lblNetFilter.Location = [System.Drawing.Point]::new(505, 18)
$lblNetFilter.AutoSize = $true
$pnlNetTop.Controls.Add($lblNetFilter)

$txtFilter = [System.Windows.Forms.TextBox]::new()
$txtFilter.Location = [System.Drawing.Point]::new(545, 15)
$txtFilter.Size = [System.Drawing.Size]::new(105, 23)
$pnlNetTop.Controls.Add($txtFilter)

$btnFix70911b = [System.Windows.Forms.Button]::new()
$btnFix70911b.Text = "Resolver erro 709 / 11b"
$btnFix70911b.Size = [System.Drawing.Size]::new(190, 30)
$btnFix70911b.Location = [System.Drawing.Point]::new(755, 47)
$btnFix70911b.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$btnFix70911b.BackColor = [System.Drawing.Color]::FromArgb(178, 79, 18)
$btnFix70911b.ForeColor = [System.Drawing.Color]::White
$btnFix70911b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFix70911b.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$pnlNetTop.Controls.Add($btnFix70911b)

$btnFixNetwork24H2 = [System.Windows.Forms.Button]::new()
$btnFixNetwork24H2.Text = "Corrigir acesso à rede (24H2)"
$script:currentWindowsBuild = Get-CurrentWindowsBuild
$script:networkAccessActionMode = Get-NetworkAccessActionMode -BuildNumber $script:currentWindowsBuild
if ($script:networkAccessActionMode -eq 'Win10PrinterDiagnosis') {
    $btnFixNetwork24H2.Text = 'Diagnóstico Win10 → 11'
}
$btnFixNetwork24H2.Size = [System.Drawing.Size]::new(190, 30)
$btnFixNetwork24H2.Location = [System.Drawing.Point]::new(755, 10)
$btnFixNetwork24H2.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left
$btnFixNetwork24H2.BackColor = [System.Drawing.Color]::FromArgb(35, 99, 142)
$btnFixNetwork24H2.ForeColor = [System.Drawing.Color]::White
$btnFixNetwork24H2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFixNetwork24H2.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$pnlNetTop.Controls.Add($btnFixNetwork24H2)

$btnDiagnoseShare = [System.Windows.Forms.Button]::new()
$btnDiagnoseShare.Text = 'Diagnóstico detalhado'
$btnDiagnoseShare.Size = [System.Drawing.Size]::new(96, 68)
$btnDiagnoseShare.Location = [System.Drawing.Point]::new(655, 10)
$btnDiagnoseShare.BackColor = [System.Drawing.Color]::FromArgb(69, 79, 92)
$btnDiagnoseShare.ForeColor = [System.Drawing.Color]::White
$btnDiagnoseShare.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlNetTop.Controls.Add($btnDiagnoseShare)

$pnlNetTop.Add_Resize({
    $left = [Math]::Max(655, $pnlNetTop.ClientSize.Width - $btnFix70911b.Width - 12)
    $btnFix70911b.Left = $left
    $btnFixNetwork24H2.Left = $left
})

$lblScanStatus = [System.Windows.Forms.Label]::new()
$lblScanStatus.Text = "Status: Aguardando varredura da rede..."
$lblScanStatus.Location = [System.Drawing.Point]::new(14, 52)
$lblScanStatus.Size = [System.Drawing.Size]::new(625, 28)
$lblScanStatus.Font = [System.Drawing.Font]::new("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(50, 70, 90)
$pnlNetTop.Controls.Add($lblScanStatus)

# Painel de busca manual (retrátil)
$pnlNetSearch = [System.Windows.Forms.GroupBox]::new()
$pnlNetSearch.Text = "Busca Manual de Servidor de Impressao"
$pnlNetSearch.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlNetSearch.Height = 113
$pnlNetSearch.Visible = $false
$tab3.Controls.Add($pnlNetSearch)

$lblServerHost = [System.Windows.Forms.Label]::new()
$lblServerHost.Text = "Servidor / IP:"
$lblServerHost.Location = [System.Drawing.Point]::new(12, 22)
$lblServerHost.AutoSize = $true
$pnlNetSearch.Controls.Add($lblServerHost)

$txtServerHost = [System.Windows.Forms.TextBox]::new()
$txtServerHost.Text = ""
$txtServerHost.Location = [System.Drawing.Point]::new(95, 19)
$txtServerHost.Size = [System.Drawing.Size]::new(180, 23)
$pnlNetSearch.Controls.Add($txtServerHost)

$lblNetUser = [System.Windows.Forms.Label]::new()
$lblNetUser.Text = "Usuario (Opc.):"
$lblNetUser.Location = [System.Drawing.Point]::new(290, 22)
$lblNetUser.AutoSize = $true
$pnlNetSearch.Controls.Add($lblNetUser)

$txtNetUser = [System.Windows.Forms.TextBox]::new()
$txtNetUser.Location = [System.Drawing.Point]::new(380, 19)
$txtNetUser.Size = [System.Drawing.Size]::new(130, 23)
$pnlNetSearch.Controls.Add($txtNetUser)

$lblNetPass = [System.Windows.Forms.Label]::new()
$lblNetPass.Text = "Senha (Memoria):"
$lblNetPass.Location = [System.Drawing.Point]::new(525, 22)
$lblNetPass.AutoSize = $true
$pnlNetSearch.Controls.Add($lblNetPass)

$txtNetPass = [System.Windows.Forms.TextBox]::new()
$txtNetPass.UseSystemPasswordChar = $true
$txtNetPass.Location = [System.Drawing.Point]::new(635, 19)
$txtNetPass.Size = [System.Drawing.Size]::new(120, 23)
$pnlNetSearch.Controls.Add($txtNetPass)

$btnTestServer = [System.Windows.Forms.Button]::new()
$btnTestServer.Text = "Testar Servidor (Ping/SMB)"
$btnTestServer.Location = [System.Drawing.Point]::new(15, 55)
$btnTestServer.Size = [System.Drawing.Size]::new(180, 30)
$pnlNetSearch.Controls.Add($btnTestServer)

$btnFindShares = [System.Windows.Forms.Button]::new()
$btnFindShares.Text = "Buscar Compartilhamentos"
$btnFindShares.Location = [System.Drawing.Point]::new(205, 55)
$btnFindShares.Size = [System.Drawing.Size]::new(200, 30)
$btnFindShares.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnFindShares.ForeColor = [System.Drawing.Color]::White
$btnFindShares.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$pnlNetSearch.Controls.Add($btnFindShares)

$lblNetAuthNote = [System.Windows.Forms.Label]::new()
$lblNetAuthNote.Text = 'Usuário e senha são opcionais. Deixe em branco para usar o acesso atual do Windows.'
$lblNetAuthNote.Location = [System.Drawing.Point]::new(15, 88)
$lblNetAuthNote.Size = [System.Drawing.Size]::new(820, 19)
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
$dgvNetPrinters = [System.Windows.Forms.DataGridView]::new()
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
$pnlNetBottom = [System.Windows.Forms.Panel]::new()
$pnlNetBottom.Dock = [System.Windows.Forms.DockStyle]::Bottom
$pnlNetBottom.Height = 108
$tab3.Controls.Add($pnlNetBottom)

$lblNetEndpointMode = [System.Windows.Forms.Label]::new()
$lblNetEndpointMode.Text = 'Conectar por:'
$lblNetEndpointMode.Location = [System.Drawing.Point]::new(12, 12)
$lblNetEndpointMode.AutoSize = $true
$pnlNetBottom.Controls.Add($lblNetEndpointMode)

$cmbNetEndpointMode = [System.Windows.Forms.ComboBox]::new()
$cmbNetEndpointMode.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbNetEndpointMode.Location = [System.Drawing.Point]::new(100, 8)
$cmbNetEndpointMode.Size = [System.Drawing.Size]::new(225, 25)
[void]$cmbNetEndpointMode.Items.Add('Nome do computador (hostname)')
[void]$cmbNetEndpointMode.Items.Add('Endereço IP')
$cmbNetEndpointMode.SelectedIndex = 0
$pnlNetBottom.Controls.Add($cmbNetEndpointMode)

$lblNetConnectionPath = [System.Windows.Forms.Label]::new()
$lblNetConnectionPath.Text = 'Selecione uma impressora para ver o destino.'
$lblNetConnectionPath.Location = [System.Drawing.Point]::new(338, 12)
$lblNetConnectionPath.Size = [System.Drawing.Size]::new(550, 22)
$lblNetConnectionPath.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Left -bor [System.Windows.Forms.AnchorStyles]::Right
$lblNetConnectionPath.AutoEllipsis = $true
$pnlNetBottom.Controls.Add($lblNetConnectionPath)

$chkNetDefault = [System.Windows.Forms.CheckBox]::new()
$chkNetDefault.Text = "Definir como impressora padrao apos conectar"
$chkNetDefault.Location = [System.Drawing.Point]::new(12, 48)
$chkNetDefault.AutoSize = $true
$pnlNetBottom.Controls.Add($chkNetDefault)

$chkNetTestPage = [System.Windows.Forms.CheckBox]::new()
$chkNetTestPage.Text = "Imprimir pagina de teste apos conectar"
$chkNetTestPage.Location = [System.Drawing.Point]::new(12, 72)
$chkNetTestPage.AutoSize = $true
$pnlNetBottom.Controls.Add($chkNetTestPage)

$chkNetWin11 = [System.Windows.Forms.CheckBox]::new()
$chkNetWin11.Text = 'Win 11'
$chkNetWin11.AccessibleName = 'Win 11: informar conta do servidor antes de conectar'
$chkNetWin11.AutoSize = $true
$chkNetWin11.Location = [System.Drawing.Point]::new(905, 60)
$chkNetWin11.Anchor = [System.Windows.Forms.AnchorStyles]::Top -bor [System.Windows.Forms.AnchorStyles]::Right
$pnlNetBottom.Controls.Add($chkNetWin11)
$netCredentialTip = [System.Windows.Forms.ToolTip]::new()
$netCredentialTip.SetToolTip($chkNetWin11, 'Abre hostname/IP, usuário e senha. A conta será usada desde a primeira tentativa. Também pode ser usado com outros Windows.')

$btnConnectSelected = [System.Windows.Forms.Button]::new()
$btnConnectSelected.Text = "Conectar Impressora Selecionada"
$btnConnectSelected.Size = [System.Drawing.Size]::new(260, 42)
$btnConnectSelected.Location = [System.Drawing.Point]::new(620, 48)
$btnConnectSelected.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnConnectSelected.ForeColor = [System.Drawing.Color]::White
$btnConnectSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnectSelected.Font = [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$pnlNetBottom.Controls.Add($btnConnectSelected)

$btnLocalPortSelected = [System.Windows.Forms.Button]::new()
$btnLocalPortSelected.Text = 'Instalar via porta local'
$btnLocalPortSelected.Size = [System.Drawing.Size]::new(225, 42)
$btnLocalPortSelected.Location = [System.Drawing.Point]::new(385, 48)
$btnLocalPortSelected.BackColor = [System.Drawing.Color]::FromArgb(20, 90, 145)
$btnLocalPortSelected.ForeColor = [System.Drawing.Color]::White
$btnLocalPortSelected.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnLocalPortSelected.Font = [System.Drawing.Font]::new('Segoe UI', 9.5, [System.Drawing.FontStyle]::Bold)
$pnlNetBottom.Controls.Add($btnLocalPortSelected)

function Get-SelectedPrinterConnectionTarget {
    param([switch]$Preview,[switch]$ManualCredential)
    if ($dgvNetPrinters.SelectedRows.Count -eq 0) { return @{Success=$false;Message='Selecione uma impressora na tabela.'} }
    $row = $dgvNetPrinters.SelectedRows[0]
    $path = Format-PrinterAsNamedUNC ([string]$row.Cells['UNC'].Value)
    if ([string]$row.Cells['Type'].Value -like '*TCP/IP*' -or $path -like 'IP_*') {
        return @{Success=$true;Direct=$true;UNCPath=$path}
    }
    $mode = if ($cmbNetEndpointMode.SelectedIndex -eq 1) { 'IP' } else { 'Hostname' }
    if($ManualCredential){
        $knownTarget=Resolve-PrinterConnectionEndpoint -UNCPath $path -ServerDisplay ([string]$row.Cells['Server'].Value) -Mode $mode -Preview
        if($knownTarget.Success){return $knownTarget}
        $match=[regex]::Match($path,'^\\\\([^\\]+)\\([^\\]+)$')
        if($match.Success){return @{Success=$true;Server=$match.Groups[1].Value;ShareName=$match.Groups[2].Value;UNCPath=$path;Mode='Win 11 / destino manual';Aliases=@($match.Groups[1].Value)}}
        return $knownTarget
    }
    return (Resolve-PrinterConnectionEndpoint -UNCPath $path -ServerDisplay ([string]$row.Cells['Server'].Value) -Mode $mode -Preview:$Preview)
}

function Update-PrinterConnectionTargetPreview {
    $target = Get-SelectedPrinterConnectionTarget -Preview
    $cmbNetEndpointMode.Enabled = -not $target.Direct
    $lblNetConnectionPath.Text = if ($target.Success) {
        if ($target.Direct) { 'Impressora com IP próprio: use Instalar por IP.' } else { 'Destino: '+$target.UNCPath }
    } elseif ($dgvNetPrinters.SelectedRows.Count) {
        if ($cmbNetEndpointMode.SelectedIndex -eq 1) { 'O endereço IP será resolvido ao conectar.' } else { 'Informe o hostname em Buscar servidor, ou escolha Endereço IP.' }
    } else { 'Selecione uma impressora para ver o destino.' }
}
$cmbNetEndpointMode.Add_SelectedIndexChanged({ Update-PrinterConnectionTargetPreview })
$dgvNetPrinters.Add_SelectionChanged({ Update-PrinterConnectionTargetPreview })

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
    param([ValidateRange(1,300)][int]$TimeoutSeconds=60)
    if($script:networkScanRunning){return}
    $script:networkScanRunning=$true
    $scanClock=[Diagnostics.Stopwatch]::StartNew()
    $count=0;$timeLimitReached=$false
    $completionMessage='A busca de impressoras não foi concluída.'
    $completionColor=[Drawing.Color]::DarkRed;$completionTag='REDE: ERRO'
    $lockedControls=@(@($pnlNetBottom,$pnlNetSearch,$btnToggleManual) | Where-Object {$_ -and -not $_.IsDisposed} | ForEach-Object {@{Control=$_;Enabled=$_.Enabled}})
    try {
    foreach($state in $lockedControls){$state.Control.Enabled=$false}
    Show-LoadingIndicator -Message "Varrendo rede local e localizando impressoras..." -Button $btnAutoScan
    $lblScanStatus.Text = "Status: Varrendo rede local e buscando impressoras ativas..."
    $lblScanStatus.ForeColor = [System.Drawing.Color]::FromArgb(0, 102, 204)
    $dgvNetPrinters.Rows.Clear()
    [System.Windows.Forms.Application]::DoEvents()

    $installed = Get-InstalledPrintersWmi
    $seenUNC = @{}

    # 1. Impressoras compartilhadas no computador local (servidor de caixa/terminais)
    try {
        $localShares = Get-CimInstance -ClassName Win32_Share -Filter "Type = 1" -OperationTimeoutSec 4 -ErrorAction Stop
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
                        $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
                    }
                    $count++
                }
            }
        }
    } catch {}

    # 2. Impressoras no Active Directory (caso em Dominio corporativo)
    $adSearch=$null;$adResults=$null
    try {
        $compSys = Get-CimInstance -ClassName Win32_ComputerSystem -OperationTimeoutSec 4 -ErrorAction Stop
        if ($compSys -and $compSys.PartOfDomain) {
            $adSearch = [adsisearcher]"(objectCategory=printQueue)"
            $adSearch.PageSize = 50
            $adSearch.ServerTimeLimit = [TimeSpan]::FromSeconds(6)
            $adSearch.ClientTimeout = [TimeSpan]::FromSeconds(8)
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
                            $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
                        }
                        $count++
                    }
                }
            }
        }
    } catch {} finally {
        if($adResults){$adResults.Dispose()}
        if($adSearch){$adSearch.Dispose()}
    }

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
        $checked=0
        foreach ($ip in $activeIps) {
            if($scanClock.Elapsed.TotalSeconds -ge $TimeoutSeconds){$timeLimitReached=$true;break}
            $checked++
            $progress="Consultando $checked de $($activeIps.Count) endereços: $ip"
            $lblScanStatus.Text='Status: '+$progress
            $lblLoadingText.Text=$progress
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
                        $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
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
                                    $dgvNetPrinters.Rows[$rIdx].DefaultCellStyle.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
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
        $completionMessage="Varredura concluída. $count impressora(s) encontrada(s) na rede."
        $completionColor=[Drawing.Color]::DarkGreen;$completionTag='REDE: OK'
        # Selecionar a primeira linha por conveniencia
        if ($dgvNetPrinters.Rows.Count -gt 0) {
            $dgvNetPrinters.Rows[0].Selected = $true
        }
    } else {
        $lblScanStatus.Text = "Status: Nenhuma impressora compartilhada localizada automaticamente. Utilize a busca manual por servidor ou instale por IP."
        $lblScanStatus.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        $completionMessage='Nenhuma impressora localizada na varredura automática.'
        $completionColor=[Drawing.Color]::DarkGoldenrod;$completionTag='REDE: AVISO'
    }
    if($timeLimitReached){
        $completionMessage="Busca encerrada no limite de $TimeoutSeconds segundos. $count impressora(s) encontrada(s); outros servidores podem ser consultados em Buscar servidor."
        $completionColor=[Drawing.Color]::DarkGoldenrod;$completionTag='REDE: PARCIAL'
        $lblScanStatus.Text='Status: '+$completionMessage
        $lblScanStatus.ForeColor=$completionColor
    }
    } catch {
        $completionMessage='Falha na busca de impressoras: '+$_.Exception.Message
        $completionColor=[Drawing.Color]::DarkRed;$completionTag='REDE: ERRO'
        $lblScanStatus.Text='Status: '+$completionMessage
        $lblScanStatus.ForeColor=[Drawing.Color]::DarkRed
    } finally {
        try{
            foreach($state in $lockedControls){if(-not $state.Control.IsDisposed){$state.Control.Enabled=$state.Enabled}}
            Hide-LoadingIndicator -Button $btnAutoScan
            Update-StatusStrip -Text $completionMessage -Color $completionColor -Tag $completionTag
            Write-AppLog -Message ($completionMessage+' Duração: '+[int]$scanClock.Elapsed.TotalSeconds+' s.') -Level $(if($completionTag -eq 'REDE: ERRO'){'ERRO'}elseif($timeLimitReached){'AVISO'}else{'INFO'})
        }finally{$scanClock.Stop();$script:networkScanRunning=$false}
    }
}

$btnAutoScan.Add_Click({ Invoke-AutoNetworkScan })

function Wait-PrinterRepairProcess {
    param([System.Diagnostics.Process]$Process, [string]$ErrorCode)
    $progressForm = [System.Windows.Forms.Form]::new()
    $progressForm.Text = "Corrigindo erro $ErrorCode"
    $progressForm.Size = [System.Drawing.Size]::new(415, 150)
    $progressForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $progressForm.ControlBox = $false
    $progressForm.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $progressForm.Font = [System.Drawing.Font]::new("Segoe UI", 9)
    $label = [System.Windows.Forms.Label]::new()
    $label.Text = "Aplicando ajustes e reiniciando o Spooler. Aguarde..."
    $label.Location = [System.Drawing.Point]::new(18, 18)
    $label.Size = [System.Drawing.Size]::new(370, 28)
    $progressForm.Controls.Add($label)
    $bar = [System.Windows.Forms.ProgressBar]::new()
    $bar.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $bar.MarqueeAnimationSpeed = 25
    $bar.Location = [System.Drawing.Point]::new(18, 58)
    $bar.Size = [System.Drawing.Size]::new(370, 22)
    $progressForm.Controls.Add($bar)
    $timer = [System.Windows.Forms.Timer]::new()
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
    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = "Corrigir erro de impressora"
    $dialog.Size = [System.Drawing.Size]::new(560, 288)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Font = [System.Drawing.Font]::new("Segoe UI", 9)
    $intro = [System.Windows.Forms.Label]::new()
    $intro.Text = "Qual erro deseja corrigir neste computador?"
    $intro.Location = [System.Drawing.Point]::new(18, 15)
    $intro.Size = [System.Drawing.Size]::new(510, 25)
    $dialog.Controls.Add($intro)
    $opt709 = [System.Windows.Forms.RadioButton]::new()
    $opt709.Text = "Erro 0x00000709"
    $opt709.Location = [System.Drawing.Point]::new(18, 51)
    $opt709.Size = [System.Drawing.Size]::new(500, 27)
    $opt709.Checked = $true
    $dialog.Controls.Add($opt709)
    $desc709 = [System.Windows.Forms.Label]::new()
    $desc709.Text = "Aplica ajustes RPC compatíveis com a versão do Windows e reinicia o Spooler."
    $desc709.Location = [System.Drawing.Point]::new(39, 79)
    $desc709.Size = [System.Drawing.Size]::new(490, 34)
    $dialog.Controls.Add($desc709)
    $opt11b = [System.Windows.Forms.RadioButton]::new()
    $opt11b.Text = "Erro 0x0000011b"
    $opt11b.Location = [System.Drawing.Point]::new(18, 125)
    $opt11b.Size = [System.Drawing.Size]::new(500, 27)
    $dialog.Controls.Add($opt11b)
    $desc11b = [System.Windows.Forms.Label]::new()
    $desc11b.Text = "Aplica RpcAuthnLevelPrivacyEnabled=0 neste PC. Se a impressora estiver em outro PC, execute também no host."
    $desc11b.Location = [System.Drawing.Point]::new(39, 153)
    $desc11b.Size = [System.Drawing.Size]::new(490, 42)
    $dialog.Controls.Add($desc11b)
    $btnApply = [System.Windows.Forms.Button]::new()
    $btnApply.Text = "Executar correção"
    $btnApply.Location = [System.Drawing.Point]::new(279, 207)
    $btnApply.Size = [System.Drawing.Size]::new(140, 32)
    $btnApply.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnApply)
    $dialog.AcceptButton = $btnApply
    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = [System.Drawing.Point]::new(429, 207)
    $btnCancel.Size = [System.Drawing.Size]::new(99, 32)
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
        $result = if ($exitCode -eq 0) { 'Configuração local aplicada; a conexão com a impressora ainda precisa ser validada.' } elseif ($exitCode -eq 10) { 'Configuração local aplicada; há verificações pendentes.' } else { "Correção não concluída (código $exitCode)." }
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
        $target = Get-SelectedPrinterConnectionTarget
        if (-not $target.Success) {
            [System.Windows.Forms.MessageBox]::Show($form, $target.Message, 'Destino da conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        $unc = $target.UNCPath
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
                $message += "`n`nTente primeiro Conectar Impressora Selecionada, sem preencher conta. A consulta de gerenciamento negada não prova recusa de impressão. O programa só solicitará outra conta se detectar recusa de acesso na conexão."
            }
            [System.Windows.Forms.MessageBox]::Show($form, $message, 'Consulta remota recusada',
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

    $dialog = [System.Windows.Forms.Form]::new()
    $dialog.Text = "Corrigir acesso à rede após atualização 24H2"
    $dialog.Size = [System.Drawing.Size]::new(610, 326)
    $dialog.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterParent
    $dialog.Font = [System.Drawing.Font]::new("Segoe UI", 9)

    $intro = [System.Windows.Forms.Label]::new()
    $intro.Text = "Escolha a função deste PC. A rotina altera configurações SMB deste computador, salva os valores anteriores e gera um script de restauração."
    $intro.Location = [System.Drawing.Point]::new(18, 15)
    $intro.Size = [System.Drawing.Size]::new(560, 42)
    $dialog.Controls.Add($intro)

    $optClient = [System.Windows.Forms.RadioButton]::new()
    $optClient.Text = "Cliente: este PC não acessa a impressora ou pasta compartilhada"
    $optClient.Location = [System.Drawing.Point]::new(18, 64)
    $optClient.Size = [System.Drawing.Size]::new(560, 27)
    $optClient.Checked = $true
    $dialog.Controls.Add($optClient)

    $descClient = [System.Windows.Forms.Label]::new()
    $descClient.Text = "Permite acesso SMB como convidado e desativa a exigência de assinatura no cliente. Define AllowInsecureGuestAuth=1."
    $descClient.Location = [System.Drawing.Point]::new(39, 92)
    $descClient.Size = [System.Drawing.Size]::new(540, 42)
    $dialog.Controls.Add($descClient)

    $optHost = [System.Windows.Forms.RadioButton]::new()
    $optHost.Text = "Host: este PC compartilha a impressora ou pasta"
    $optHost.Location = [System.Drawing.Point]::new(18, 145)
    $optHost.Size = [System.Drawing.Size]::new(560, 27)
    $dialog.Controls.Add($optHost)

    $descHost = [System.Windows.Forms.Label]::new()
    $descHost.Text = "Desativa a exigência de assinatura no servidor. No Windows 11 22H2+, define RpcProtocols=7 para impressão."
    $descHost.Location = [System.Drawing.Point]::new(39, 173)
    $descHost.Size = [System.Drawing.Size]::new(540, 42)
    $dialog.Controls.Add($descHost)

    $btnApply = [System.Windows.Forms.Button]::new()
    $btnApply.Text = "Executar correção"
    $btnApply.Location = [System.Drawing.Point]::new(328, 233)
    $btnApply.Size = [System.Drawing.Size]::new(142, 34)
    $btnApply.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $dialog.Controls.Add($btnApply)
    $dialog.AcceptButton = $btnApply

    $btnCancel = [System.Windows.Forms.Button]::new()
    $btnCancel.Text = "Cancelar"
    $btnCancel.Location = [System.Drawing.Point]::new(480, 233)
    $btnCancel.Size = [System.Drawing.Size]::new(100, 34)
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
        $resultText = if ($exitCode -eq 0) { 'Configuração SMB aplicada; a conexão com a impressora ainda precisa ser validada.' } else { "Correção não concluída (código $exitCode)." }
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
    if ($pass -and -not $user) {
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
            $dgvNetPrinters.Rows[$rIndex].DefaultCellStyle.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
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
    $target = Get-SelectedPrinterConnectionTarget
    if (-not $target.Success) {
        [System.Windows.Forms.MessageBox]::Show($form, $target.Message, 'Destino da conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $unc = $target.UNCPath
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
    $target = Get-SelectedPrinterConnectionTarget
    if (-not $target.Success) {
        [System.Windows.Forms.MessageBox]::Show($form, $target.Message, 'Destino da conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $unc = $target.UNCPath
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
    Use-PrinterCredentialForEndpoint -Server $server -Aliases $target.Aliases
    $localResult = Show-LocalPortFallbackDialog -UNCPath $unc -AlternateHost $alternateIp -Direct
    if (-not $localResult -or -not $localResult.Success) { return }
    $localName = [string]$localResult.ConnectedUNC
    if ($chkNetDefault.Checked) { Set-DefaultPrinterSafe -PrinterName $localName | Out-Null }
    if ($chkNetTestPage.Checked -and -not $localResult.JobValidated) { Invoke-PrintUICommand -Arguments ('/k /n "' + $localName + '"') | Out-Null }
    Refresh-PrintersGrid
    $selectedRow.Cells['Status'].Value = 'Ja Instalada no Sistema'
    $selectedRow.DefaultCellStyle.ForeColor = [System.Drawing.Color]::Gray
    Update-StatusStrip -Text "Fila $localName instalada neste PC." -Color 'DarkGreen'
    $message = "Fila instalada neste PC: $localName`nPorta: $($localResult.PortUNC)`n`nImprima uma página de teste para confirmar a impressão.`n`nDeseja abrir a fila agora?"
    if ([System.Windows.Forms.MessageBox]::Show($message, 'Instalação concluída', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Information) -eq [System.Windows.Forms.DialogResult]::Yes) {
        Invoke-PrintUICommand -Arguments ('/o /n "' + $localName + '"') -NoWait | Out-Null
    }
})

$chkNetWin11.Add_CheckedChanged({
    $script:pendingPrinterConnectionCredential=$null
    if(-not $chkNetWin11.Checked -or $global:SimulationMode){return}
    $target=Get-SelectedPrinterConnectionTarget -ManualCredential
    if(-not $target.Success -or $target.Direct){
        $chkNetWin11.Checked=$false
        [System.Windows.Forms.MessageBox]::Show($form,'Selecione uma impressora compartilhada na tabela antes de marcar Win 11.','Conta do servidor',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }
    $selection=Request-ExplicitPrinterConnectionCredential -UNCPath $target.UNCPath -InitialUser $txtNetUser.Text.Trim() -Parent $form
    if(-not $selection.Success){
        $chkNetWin11.Checked=$false
        if(-not $selection.Cancelled){[System.Windows.Forms.MessageBox]::Show($form,$selection.Message,'Conta do servidor',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null}
        return
    }
    $script:pendingPrinterConnectionCredential=$selection
    $txtNetUser.Text=$selection.User
    $txtNetPass.Clear()
    $lblNetConnectionPath.Text='Conta informada; destino: '+$selection.UNCPath
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

    $target = Get-SelectedPrinterConnectionTarget -ManualCredential:$chkNetWin11.Checked
    if (-not $target.Success) {
        [System.Windows.Forms.MessageBox]::Show($form, $target.Message, 'Destino da conexão', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    $unc = $target.UNCPath
    $explicitSelection=$null
    if($chkNetWin11.Checked -and -not $global:SimulationMode){
        $explicitSelection=$script:pendingPrinterConnectionCredential
        $script:pendingPrinterConnectionCredential=$null
        if(-not $explicitSelection -or $explicitSelection.SourceUNC -ine $unc){
            $explicitSelection=Request-ExplicitPrinterConnectionCredential -UNCPath $unc -InitialUser $txtNetUser.Text.Trim() -Parent $form
        }
        if(-not $explicitSelection.Success){
            if(-not $explicitSelection.Cancelled){[System.Windows.Forms.MessageBox]::Show($form,$explicitSelection.Message,'Conta do servidor',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null}
            return
        }
        $unc=$explicitSelection.UNCPath
        $srv=$explicitSelection.Server
        $target.Mode='Win 11 / conta informada'
        $txtNetUser.Text=$explicitSelection.User
        $txtNetPass.Clear()
        $lblNetConnectionPath.Text='Destino: '+$unc
    }
    Write-AppLog -Message ("Destino escolhido ($($target.Mode)): $unc.") -Level INFO

    # A busca manual não é obrigatória para autenticar: o botão de conexão
    # aplica as credenciais preenchidas à fila selecionada antes de chamar RPC.
    $serverForConnection = ([regex]::Match($unc, '^\\\\([^\\]+)\\')).Groups[1].Value
    $enteredUser = $txtNetUser.Text.Trim()
    $enteredPassword = $txtNetPass.Text
    if (-not $chkNetWin11.Checked -and $enteredPassword -and -not $enteredUser) {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Informe usuário e senha juntos. Use uma conta do computador $serverForConnection e a senha da conta, não o PIN.",
            'Credenciais incompletas', [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }
    if (-not $chkNetWin11.Checked -and $enteredUser -and $enteredPassword -and -not $global:SimulationMode) {
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
    $connectionControls=@(@($chkNetWin11,$cmbNetEndpointMode,$dgvNetPrinters) | ForEach-Object {@{Control=$_;Enabled=$_.Enabled}})
    try {
        foreach($state in $connectionControls){$state.Control.Enabled=$false}
        $script:cancelPrinterConnection = $false
        $btnCancelConnection.Enabled = $true
        $btnCancelConnection.Visible = $true
        Show-LoadingIndicator -Message "Conectando a impressora $unc..." -Button $btnConnectSelected
        $alternateIp = ''
        if ($srv -match '((?:\d{1,3}\.){3}\d{1,3})') { $alternateIp = $matches[1] }
        $requestAccount = {
            param($server,$failure)
            $btnCancelConnection.Visible = $false
            Hide-LoadingIndicator -Button $btnConnectSelected
            try {
                Request-PrinterServerCredential -Server $server -InitialUser $txtNetUser.Text.Trim() -Parent $form -Reason (Get-PrinterCredentialReason $failure)
            } finally {
                Show-LoadingIndicator -Message "Conectando a impressora $unc..." -Button $btnConnectSelected
                $btnCancelConnection.Visible = $true
            }
        }
        if($chkNetWin11.Checked -and -not $global:SimulationMode){
            $result=Connect-PrinterUsingExplicitCredential -Selection $explicitSelection -ValidationMode $(if($chkNetTestPage.Checked){'TestPage'}else{'QueueOnly'})
        } else {
            $result = Connect-PrinterUsingAvailableSession -UNCPath $unc -AlternateHost $alternateIp -RequestCredential $requestAccount -CredentialServerAliases $target.Aliases -ValidationMode $(if($chkNetTestPage.Checked){'TestPage'}else{'QueueOnly'})
        }
        if ($script:authenticatedPrinterServer -ieq $serverForConnection -and $script:authenticatedPrinterUser) {
            $txtNetUser.Text = $script:authenticatedPrinterUser
        }
        $fallbackHandled = $false
        if (-not $result.Cascaded -and -not $result.Success -and -not $result.Simulated -and $result.Code -notin @(53,1223,1801) -and $script:currentWindowsBuild -lt 22000) {
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
        if ($chkNetTestPage.Checked -and -not $result.JobValidationAttempted -and -not $result.JobValidated) {
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
    } elseif ($result.QueueInstalled) {
        Refresh-PrintersGrid
        $dgvNetPrinters.SelectedRows[0].Cells['Status'].Value='Instalada; teste de impressão pendente/falhou'
        Update-StatusStrip -Text 'Fila instalada. O teste de impressão não foi concluído.' -Color 'DarkGoldenrod'
        [System.Windows.Forms.MessageBox]::Show($form,"A fila foi instalada e confirmada no Windows.`n`n$($result.Message)`n`nNenhum novo job será enviado automaticamente.",'Fila instalada; verificar impressão',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
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
            "Esta tentativa usou a conta local $env:USERDOMAIN\$env:USERNAME, sem credenciais do servidor. O código 0x709 não identifica sozinho uma falha de autenticação. Se precisar usar outra conta, preencha usuário e senha na busca manual. Use a senha da conta, não o PIN.`n"
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
        foreach($state in $connectionControls){if(-not $state.Control.IsDisposed){$state.Control.Enabled=$state.Enabled}}
        Hide-LoadingIndicator -Button $btnConnectSelected
    }
})

# ==============================================================================
# ==============================================================================
# ABA 4: INSTALAR POR CAMINHO MANUAL (\\SERVIDOR\IMPRESSORA)
# ==============================================================================
$pnlManual = [System.Windows.Forms.GroupBox]::new()
$pnlManual.Text = "Conectar Impressora por Caminho de Rede (UNC)"
$pnlManual.Location = [System.Drawing.Point]::new(20, 20)
$pnlManual.Size = [System.Drawing.Size]::new(920, 360)
$tab4.Controls.Add($pnlManual)

$lblManualDesc = [System.Windows.Forms.Label]::new()
$lblManualDesc.Text = ("Digite o caminho no formato \\NOME_DO_COMPUTADOR\COMPARTILHAMENTO (recomendado para evitar falhas com IP din" + [char]0xE2 + "mico/DHCP):")
$lblManualDesc.Location = [System.Drawing.Point]::new(20, 30)
$lblManualDesc.AutoSize = $true
$pnlManual.Controls.Add($lblManualDesc)

$txtManualUNC = [System.Windows.Forms.TextBox]::new()
$txtManualUNC.Text = "\\SERVIDOR\IMPRESSORA"
$txtManualUNC.Font = [System.Drawing.Font]::new("Segoe UI", 11)
$txtManualUNC.Location = [System.Drawing.Point]::new(20, 55)
$txtManualUNC.Size = [System.Drawing.Size]::new(560, 27)
$pnlManual.Controls.Add($txtManualUNC)

$btnTestPath = [System.Windows.Forms.Button]::new()
$btnTestPath.Text = "Testar Caminho"
$btnTestPath.Location = [System.Drawing.Point]::new(595, 53)
$btnTestPath.Size = [System.Drawing.Size]::new(140, 31)
$pnlManual.Controls.Add($btnTestPath)

$chkManualDefault = [System.Windows.Forms.CheckBox]::new()
$chkManualDefault.Text = "Definir como impressora padrão após conectar"
$chkManualDefault.Location = [System.Drawing.Point]::new(20, 100)
$chkManualDefault.AutoSize = $true
$pnlManual.Controls.Add($chkManualDefault)

$chkManualTest = [System.Windows.Forms.CheckBox]::new()
$chkManualTest.Text = "Imprimir página de teste após conectar"
$chkManualTest.Location = [System.Drawing.Point]::new(20, 130)
$chkManualTest.AutoSize = $true
$pnlManual.Controls.Add($chkManualTest)

$btnManualConnect = [System.Windows.Forms.Button]::new()
$btnManualConnect.Text = "Conectar Agora"
$btnManualConnect.Location = [System.Drawing.Point]::new(20, 170)
$btnManualConnect.Size = [System.Drawing.Size]::new(200, 38)
$btnManualConnect.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnManualConnect.ForeColor = [System.Drawing.Color]::White
$btnManualConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnManualConnect.Font = [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$pnlManual.Controls.Add($btnManualConnect)

$txtPathDiag = [System.Windows.Forms.TextBox]::new()
$txtPathDiag.Multiline = $true
$txtPathDiag.ReadOnly = $true
$txtPathDiag.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtPathDiag.Location = [System.Drawing.Point]::new(20, 220)
$txtPathDiag.Size = [System.Drawing.Size]::new(875, 120)
$txtPathDiag.Font = [System.Drawing.Font]::new("Consolas", 9)
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
        $res = Connect-PrinterUsingAvailableSession -UNCPath $unc -ValidationMode $(if($chkManualTest.Checked){'TestPage'}else{'QueueOnly'}) -RequestCredential {
            param($hostName,$failure)
            Request-PrinterServerCredential -Server $hostName -Parent $form -Reason (Get-PrinterCredentialReason $failure)
        }
        $fallbackHandled = $false
        if (-not $res.Cascaded -and -not $res.CredentialPrompted -and -not $res.Success -and -not $res.Simulated -and $res.Code -notin @(53,1223) -and $script:currentWindowsBuild -lt 22000) {
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
            if ($chkManualTest.Checked -and -not $res.JobValidationAttempted -and -not $res.JobValidated) { Invoke-PrintUICommand -Arguments ('/k /n "' + $connectedUNC + '"') | Out-Null }
            Refresh-PrintersGrid
            Update-StatusStrip -Text "Impressora $connectedUNC conectada." -Color [System.Drawing.Color]::DarkGreen
            $successMessage = if ($res.LocalPort) {
                "Fila instalada neste PC: $connectedUNC`nPorta: $($res.PortUNC)`n`nImprima uma página de teste para confirmar a impressão."
            } else {
                "Impressora conectada com sucesso!`n`n$connectedUNC"
            }
            [System.Windows.Forms.MessageBox]::Show($successMessage, "Sucesso", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        } elseif ($res.QueueInstalled) {
            Refresh-PrintersGrid
            Update-StatusStrip -Text 'Fila instalada. O teste de impressão não foi concluído.' -Color [Drawing.Color]::DarkGoldenrod
            [System.Windows.Forms.MessageBox]::Show($form,"A fila foi instalada e confirmada no Windows.`n`n$($res.Message)`n`nNenhum novo job será enviado automaticamente.",'Fila instalada; verificar impressão',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
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
$pnlIP = [System.Windows.Forms.GroupBox]::new()
$pnlIP.Text = "Instalação de Impressora TCP/IP (Rede Direta)"
$pnlIP.Location = [System.Drawing.Point]::new(20, 20)
$pnlIP.Size = [System.Drawing.Size]::new(920, 480)
$tab5.Controls.Add($pnlIP)

$lblIPAddr = [System.Windows.Forms.Label]::new()
$lblIPAddr.Text = "Endereço IPv4 da Impressora:"
$lblIPAddr.Location = [System.Drawing.Point]::new(20, 30)
$lblIPAddr.AutoSize = $true
$pnlIP.Controls.Add($lblIPAddr)

$txtIPAddr = [System.Windows.Forms.TextBox]::new()
$txtIPAddr.Text = ""
$txtIPAddr.Location = [System.Drawing.Point]::new(20, 52)
$txtIPAddr.Size = [System.Drawing.Size]::new(200, 23)
$pnlIP.Controls.Add($txtIPAddr)

$btnTestIPPort = [System.Windows.Forms.Button]::new()
$btnTestIPPort.Text = "Testar Comunicação IP e Porta"
$btnTestIPPort.Location = [System.Drawing.Point]::new(235, 50)
$btnTestIPPort.Size = [System.Drawing.Size]::new(210, 27)
$pnlIP.Controls.Add($btnTestIPPort)

$lblIPPrinterName = [System.Windows.Forms.Label]::new()
$lblIPPrinterName.Text = "Nome de Exibição da Impressora:"
$lblIPPrinterName.Location = [System.Drawing.Point]::new(20, 90)
$lblIPPrinterName.AutoSize = $true
$pnlIP.Controls.Add($lblIPPrinterName)

$txtIPPrinterName = [System.Windows.Forms.TextBox]::new()
$txtIPPrinterName.Text = "Impressora_Rede_TCP"
$txtIPPrinterName.Location = [System.Drawing.Point]::new(20, 112)
$txtIPPrinterName.Size = [System.Drawing.Size]::new(320, 23)
$pnlIP.Controls.Add($txtIPPrinterName)

# Protocolo RAW vs LPR
$lblProto = [System.Windows.Forms.Label]::new()
$lblProto.Text = "Protocolo de Comunicação:"
$lblProto.Location = [System.Drawing.Point]::new(20, 150)
$lblProto.AutoSize = $true
$pnlIP.Controls.Add($lblProto)

$rbProtoRAW = [System.Windows.Forms.RadioButton]::new()
$rbProtoRAW.Text = "RAW (Padrão para impressoras térmicas e de rede)"
$rbProtoRAW.Location = [System.Drawing.Point]::new(20, 172)
$rbProtoRAW.AutoSize = $true
$rbProtoRAW.Checked = $true
$pnlIP.Controls.Add($rbProtoRAW)

$rbProtoLPR = [System.Windows.Forms.RadioButton]::new()
$rbProtoLPR.Text = "LPR / LPD"
$rbProtoLPR.Location = [System.Drawing.Point]::new(360, 172)
$rbProtoLPR.AutoSize = $true
$pnlIP.Controls.Add($rbProtoLPR)

$lblPortNum = [System.Windows.Forms.Label]::new()
$lblPortNum.Text = "Porta TCP (RAW):"
$lblPortNum.Location = [System.Drawing.Point]::new(20, 205)
$lblPortNum.AutoSize = $true
$pnlIP.Controls.Add($lblPortNum)

$txtPortNum = [System.Windows.Forms.TextBox]::new()
$txtPortNum.Text = "9100"
$txtPortNum.Location = [System.Drawing.Point]::new(130, 202)
$txtPortNum.Size = [System.Drawing.Size]::new(80, 23)
$pnlIP.Controls.Add($txtPortNum)

$lblQueueName = [System.Windows.Forms.Label]::new()
$lblQueueName.Text = "Fila LPR:"
$lblQueueName.Location = [System.Drawing.Point]::new(235, 205)
$lblQueueName.AutoSize = $true
$pnlIP.Controls.Add($lblQueueName)

$txtQueueName = [System.Windows.Forms.TextBox]::new()
$txtQueueName.Text = "lp"
$txtQueueName.Enabled = $false
$txtQueueName.Location = [System.Drawing.Point]::new(300, 202)
$txtQueueName.Size = [System.Drawing.Size]::new(100, 23)
$pnlIP.Controls.Add($txtQueueName)

$rbProtoRAW.Add_CheckedChanged({
    $txtQueueName.Enabled = -not $rbProtoRAW.Checked
    if ($rbProtoRAW.Checked) { $txtPortNum.Text = "9100" } else { $txtPortNum.Text = "515" }
})

# Seleção de Driver NATIVO já instalado no Windows
$lblDriver = [System.Windows.Forms.Label]::new()
$lblDriver.Text = "Driver já instalado no Windows (Obrigatório selecionar um homologado):"
$lblDriver.Location = [System.Drawing.Point]::new(20, 240)
$lblDriver.AutoSize = $true
$pnlIP.Controls.Add($lblDriver)

$cmbDrivers = [System.Windows.Forms.ComboBox]::new()
$cmbDrivers.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
$cmbDrivers.Location = [System.Drawing.Point]::new(20, 262)
$cmbDrivers.Size = [System.Drawing.Size]::new(450, 23)
$pnlIP.Controls.Add($cmbDrivers)

$btnRefreshDrivers = [System.Windows.Forms.Button]::new()
$btnRefreshDrivers.Text = "Recarregar Drivers"
$btnRefreshDrivers.Location = [System.Drawing.Point]::new(480, 260)
$btnRefreshDrivers.Size = [System.Drawing.Size]::new(140, 27)
$pnlIP.Controls.Add($btnRefreshDrivers)

$lblDriverWarning = [System.Windows.Forms.Label]::new()
$lblDriverWarning.Text = "REQUISITO DE SEGURANÇA: Esta ferramenta NÃO baixa drivers da internet nem utiliza drivers desconhecidos.`nCaso o modelo desejado (Bematech, Elgin, Epson, Argox, Zebra) não conste acima, instale primeiro o pacote oficial do fabricante."
$lblDriverWarning.ForeColor = [System.Drawing.Color]::DarkRed
$lblDriverWarning.Font = [System.Drawing.Font]::new("Segoe UI", 8.5)
$lblDriverWarning.Location = [System.Drawing.Point]::new(20, 295)
$lblDriverWarning.Size = [System.Drawing.Size]::new(860, 35)
$pnlIP.Controls.Add($lblDriverWarning)

$chkIPDefault = [System.Windows.Forms.CheckBox]::new()
$chkIPDefault.Text = "Definir como impressora padrão após instalar"
$chkIPDefault.Location = [System.Drawing.Point]::new(20, 335)
$chkIPDefault.AutoSize = $true
$pnlIP.Controls.Add($chkIPDefault)

$chkIPTest = [System.Windows.Forms.CheckBox]::new()
$chkIPTest.Text = "Imprimir teste após instalar"
$chkIPTest.Location = [System.Drawing.Point]::new(20, 360)
$chkIPTest.AutoSize = $true
$pnlIP.Controls.Add($chkIPTest)

$btnInstallIPPrinter = [System.Windows.Forms.Button]::new()
$btnInstallIPPrinter.Text = "Criar Porta e Instalar Impressora TCP/IP"
$btnInstallIPPrinter.Location = [System.Drawing.Point]::new(20, 400)
$btnInstallIPPrinter.Size = [System.Drawing.Size]::new(300, 40)
$btnInstallIPPrinter.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnInstallIPPrinter.ForeColor = [System.Drawing.Color]::White
$btnInstallIPPrinter.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnInstallIPPrinter.Font = [System.Drawing.Font]::new("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
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
$pnlSpoolStatus = [System.Windows.Forms.GroupBox]::new()
$pnlSpoolStatus.Text = "Status do Subsistema Spooler"
$pnlSpoolStatus.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlSpoolStatus.Height = 70
$tab6.Controls.Add($pnlSpoolStatus)

$lblSpoolInfo = [System.Windows.Forms.Label]::new()
$lblSpoolInfo.Text = "Status: Aguardando verificação..."
$lblSpoolInfo.Font = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblSpoolInfo.Location = [System.Drawing.Point]::new(15, 25)
$lblSpoolInfo.AutoSize = $true
$pnlSpoolStatus.Controls.Add($lblSpoolInfo)

$btnRefreshSpoolTab = [System.Windows.Forms.Button]::new()
$btnRefreshSpoolTab.Text = "Atualizar Fila e Status"
$btnRefreshSpoolTab.Location = [System.Drawing.Point]::new(740, 20)
$btnRefreshSpoolTab.Size = [System.Drawing.Size]::new(180, 32)
$pnlSpoolStatus.Controls.Add($btnRefreshSpoolTab)

# Tabela de Documentos Presos
$pnlQueueGroup = [System.Windows.Forms.GroupBox]::new()
$pnlQueueGroup.Text = "Documentos Presos nas Filas de Impressão"
$pnlQueueGroup.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlQueueGroup.Height = 180
$tab6.Controls.Add($pnlQueueGroup)

$dgvQueue = [System.Windows.Forms.DataGridView]::new()
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
$pnlFixChecklist = [System.Windows.Forms.GroupBox]::new()
$pnlFixChecklist.Text = "Ações para Correção de Problemas Comuns (Selecione as ações desejadas antes de executar)"
$pnlFixChecklist.Dock = [System.Windows.Forms.DockStyle]::Fill
$tab6.Controls.Add($pnlFixChecklist)
$pnlFixChecklist.BringToFront()

$chkOptRestartSpooler = [System.Windows.Forms.CheckBox]::new()
$chkOptRestartSpooler.Text = "1. Reiniciar serviço Spooler de Impressão (Stop/Start)"
$chkOptRestartSpooler.Location = [System.Drawing.Point]::new(20, 25); $chkOptRestartSpooler.AutoSize = $true; $chkOptRestartSpooler.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptRestartSpooler)

$chkOptAutoStart = [System.Windows.Forms.CheckBox]::new()
$chkOptAutoStart.Text = "2. Configurar inicialização do Spooler como Automático (sc.exe config spooler start= auto)"
$chkOptAutoStart.Location = [System.Drawing.Point]::new(20, 50); $chkOptAutoStart.AutoSize = $true; $chkOptAutoStart.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptAutoStart)

$chkOptUnpause = [System.Windows.Forms.CheckBox]::new()
$chkOptUnpause.Text = "3. Retirar estado 'Pausada' de todas as impressoras instaladas"
$chkOptUnpause.Location = [System.Drawing.Point]::new(20, 75); $chkOptUnpause.AutoSize = $true; $chkOptUnpause.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptUnpause)

$chkOptClearOffline = [System.Windows.Forms.CheckBox]::new()
$chkOptClearOffline.Text = "4. Retirar modo 'Trabalhar Offline' de todas as impressoras instaladas"
$chkOptClearOffline.Location = [System.Drawing.Point]::new(20, 100); $chkOptClearOffline.AutoSize = $true; $chkOptClearOffline.Checked = $true
$pnlFixChecklist.Controls.Add($chkOptClearOffline)

$chkOptPurgeFiles = [System.Windows.Forms.CheckBox]::new()
$chkOptPurgeFiles.Text = "5. Limpar arquivos travados da pasta de spool (*.SPL e *.SHD) [Cancela todos os trabalhos pendentes]"
$chkOptPurgeFiles.ForeColor = [System.Drawing.Color]::DarkRed
$chkOptPurgeFiles.Font = [System.Drawing.Font]::new("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chkOptPurgeFiles.Location = [System.Drawing.Point]::new(20, 125); $chkOptPurgeFiles.AutoSize = $true; $chkOptPurgeFiles.Checked = $false
$pnlFixChecklist.Controls.Add($chkOptPurgeFiles)

$btnExecuteFixes = [System.Windows.Forms.Button]::new()
$btnExecuteFixes.Text = "Executar Ações Selecionadas de Correção"
$btnExecuteFixes.Location = [System.Drawing.Point]::new(20, 165)
$btnExecuteFixes.Size = [System.Drawing.Size]::new(280, 38)
$btnExecuteFixes.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnExecuteFixes.ForeColor = [System.Drawing.Color]::White
$btnExecuteFixes.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnExecuteFixes.Font = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$pnlFixChecklist.Controls.Add($btnExecuteFixes)

$btnQuickPurge = [System.Windows.Forms.Button]::new()
$btnQuickPurge.Text = "Limpar Fila Imediatamente (Purgar Spool)"
$btnQuickPurge.Location = [System.Drawing.Point]::new(315, 165)
$btnQuickPurge.Size = [System.Drawing.Size]::new(260, 38)
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
$pnlRDPHeader = [System.Windows.Forms.GroupBox]::new()
$pnlRDPHeader.Text = "Diagnóstico da Sessão RDP"
$pnlRDPHeader.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlRDPHeader.Height = 85
$tab7.Controls.Add($pnlRDPHeader)

$lblRDPSession = [System.Windows.Forms.Label]::new()
$lblRDPSession.Font = [System.Drawing.Font]::new("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblRDPSession.Location = [System.Drawing.Point]::new(15, 25)
$lblRDPSession.AutoSize = $true
$pnlRDPHeader.Controls.Add($lblRDPSession)

$lblRDPInfoExtra = [System.Windows.Forms.Label]::new()
$lblRDPInfoExtra.Location = [System.Drawing.Point]::new(15, 50)
$lblRDPInfoExtra.AutoSize = $true
$lblRDPInfoExtra.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
$pnlRDPHeader.Controls.Add($lblRDPInfoExtra)

$btnRefreshRDP = [System.Windows.Forms.Button]::new()
$btnRefreshRDP.Text = "Atualizar RDP"
$btnRefreshRDP.Location = [System.Drawing.Point]::new(620, 25)
$btnRefreshRDP.Size = [System.Drawing.Size]::new(120, 32)
$pnlRDPHeader.Controls.Add($btnRefreshRDP)

$btnOpenControlPrn = [System.Windows.Forms.Button]::new()
$btnOpenControlPrn.Text = "Abrir Impressoras do Windows"
$btnOpenControlPrn.Location = [System.Drawing.Point]::new(750, 25)
$btnOpenControlPrn.Size = [System.Drawing.Size]::new(180, 32)
$pnlRDPHeader.Controls.Add($btnOpenControlPrn)

$btnOpenControlPrn.Add_Click({
    Start-Process "control.exe" "printers"
})

$dgvRDP = [System.Windows.Forms.DataGridView]::new()
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

$txtRDPGuide = [System.Windows.Forms.TextBox]::new()
$txtRDPGuide.Multiline = $true
$txtRDPGuide.ReadOnly = $true
$txtRDPGuide.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtRDPGuide.Dock = [System.Windows.Forms.DockStyle]::Fill
$txtRDPGuide.Font = [System.Drawing.Font]::new("Segoe UI", 9)
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
$pnlLogsTop = [System.Windows.Forms.Panel]::new()
$pnlLogsTop.Dock = [System.Windows.Forms.DockStyle]::Top
$pnlLogsTop.Height = 45
$tab8.Controls.Add($pnlLogsTop)

$btnRefreshLogView = [System.Windows.Forms.Button]::new()
$btnRefreshLogView.Text = "Atualizar Log"
$btnRefreshLogView.Size = [System.Drawing.Size]::new(110, 32)
$btnRefreshLogView.Location = [System.Drawing.Point]::new(10, 6)
$pnlLogsTop.Controls.Add($btnRefreshLogView)

$btnCopyLog = [System.Windows.Forms.Button]::new()
$btnCopyLog.Text = "Copiar Log Completo"
$btnCopyLog.Size = [System.Drawing.Size]::new(150, 32)
$btnCopyLog.Location = [System.Drawing.Point]::new(130, 6)
$pnlLogsTop.Controls.Add($btnCopyLog)

$btnExportReport = [System.Windows.Forms.Button]::new()
$btnExportReport.Text = "Exportar Relatório..."
$btnExportReport.Size = [System.Drawing.Size]::new(140, 32)
$btnExportReport.Location = [System.Drawing.Point]::new(290, 6)
$pnlLogsTop.Controls.Add($btnExportReport)

$btnOpenLogsFolder = [System.Windows.Forms.Button]::new()
$btnOpenLogsFolder.Text = "Abrir Pasta Logs"
$btnOpenLogsFolder.Size = [System.Drawing.Size]::new(130, 32)
$btnOpenLogsFolder.Location = [System.Drawing.Point]::new(440, 6)
$pnlLogsTop.Controls.Add($btnOpenLogsFolder)

$btnClearOldLogs = [System.Windows.Forms.Button]::new()
$btnClearOldLogs.Text = "Limpar Logs Antigos (+7 dias)"
$btnClearOldLogs.Size = [System.Drawing.Size]::new(180, 32)
$btnClearOldLogs.Location = [System.Drawing.Point]::new(580, 6)
$pnlLogsTop.Controls.Add($btnClearOldLogs)

$btnCleanAndExit = [System.Windows.Forms.Button]::new()
$btnCleanAndExit.Text = "Encerrar e Limpar Temporários"
$btnCleanAndExit.Size = [System.Drawing.Size]::new(190, 32)
$btnCleanAndExit.Location = [System.Drawing.Point]::new(770, 6)
$btnCleanAndExit.BackColor = [System.Drawing.Color]::FromArgb(200, 50, 50)
$btnCleanAndExit.ForeColor = [System.Drawing.Color]::White
$btnCleanAndExit.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCleanAndExit.Font = [System.Drawing.Font]::new("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$pnlLogsTop.Controls.Add($btnCleanAndExit)

$script:txtLogViewer = [System.Windows.Forms.TextBox]::new()
$script:txtLogViewer.Multiline = $true
$script:txtLogViewer.ReadOnly = $true
$script:txtLogViewer.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
$script:txtLogViewer.WordWrap = $false
$script:txtLogViewer.Dock = [System.Windows.Forms.DockStyle]::Fill
$script:txtLogViewer.Font = [System.Drawing.Font]::new("Consolas", 9)
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
    $sfd = [System.Windows.Forms.SaveFileDialog]::new()
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
$script:uiShown = $false
$script:printerTabDataLoaded = @{}
function Initialize-SelectedPrinterTab {
    # Nenhuma consulta de impressoras/driver participa da abertura da janela.
    if (-not $script:uiShown) { return }
    if ($tabControl.SelectedTab -eq $tab2 -and -not $script:printerTabDataLoaded.Local) {
        $script:printerTabDataLoaded.Local = $true
        try { Refresh-PrintersGrid } catch { $script:printerTabDataLoaded.Local = $false; throw }
    }
    if ($tabControl.SelectedTab -eq $tab5 -and -not $script:printerTabDataLoaded.Drivers) {
        $script:printerTabDataLoaded.Drivers = $true
        try { Populate-DriversList } catch { $script:printerTabDataLoaded.Drivers = $false; throw }
    }
    if ($tabControl.SelectedTab -eq $tab6) { Update-SpoolTabStatus }
    if ($tabControl.SelectedTab -eq $tab7) { Update-RDPDiagnostics }
}
$tabControl.Add_SelectedIndexChanged({
    Initialize-SelectedPrinterTab
})

$interfacePath = if ($PrinterConnectionPath) { Join-Path (Split-Path -Parent $PrinterConnectionPath) 'INTERFACE.ps1' } else { Join-Path $PSScriptRoot 'scripts\INTERFACE.ps1' }
if (Test-Path -LiteralPath $interfacePath) {
    . $interfacePath
    Set-PrinterAppLayout
}
$form.ResumeLayout($true)

$form.Add_Shown({
    $script:uiShown = $true
    Reload-LogViewer
    Update-StatusStrip -Text "Assistente de Impressoras pronto para uso." -Color "DarkGreen" -Tag "PRONTO"
    $script:startupClock.Stop()
    Write-AppLog -Message "Interface pronta em $($script:startupClock.ElapsedMilliseconds) ms; dados das abas serão consultados sob demanda." -Level INFO
})

# Executar a aplicação Windows Forms
[void]$form.ShowDialog()

# Registro de saída limpa no log
Write-AppLog -Message "Sessão do Assistente de Impressoras encerrada normalmente." -Level "INFO"
Write-AppLog -Message "================================================================================" -Level "INFO"
