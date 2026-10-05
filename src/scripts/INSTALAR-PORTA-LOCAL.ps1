param(
    [string]$RequestPath = '',
    [string]$ResultPath = '',
    [string]$Server = '',
    [string]$ShareName = '',
    [string]$DriverName = '',
    [string]$QueueName = '',
    [string]$InfPath = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IMPRESSAO-COMUM.ps1')
$result = @{ Success = $false; Message = 'A instalação não foi concluída.' }
$stage = 'Ler dados da instalação'
$portMethod = 'Add-PrinterPort'
$cimPortError = ''

function Add-UNCPrinterPortNative {
    param([string]$PortName)
    if (-not ('LocalPortMonitorBridge' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class LocalPortMonitorBridge {
 [StructLayout(LayoutKind.Sequential)] struct DEFAULTS { public IntPtr DataType, DevMode; public uint Access; }
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool EnumMonitorsW(string server,uint level,IntPtr buffer,uint size,out uint needed,out uint count);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool OpenPrinterW(string name,out IntPtr handle,ref DEFAULTS defaults);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool ClosePrinter(IntPtr handle);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool XcvDataW(IntPtr handle,string command,IntPtr input,uint inputSize,IntPtr output,uint outputSize,out uint needed,out uint status);
 static void Check(bool ok){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
 static void Command(IntPtr handle,string command,IntPtr input,uint bytes){uint needed,status;Check(XcvDataW(handle,command,input,bytes,IntPtr.Zero,0,out needed,out status));if(status!=0)throw new Win32Exception((int)status,command+": "+new Win32Exception((int)status).Message);}
 public static string Add(string port){
  IntPtr buffer=IntPtr.Zero,handle=IntPtr.Zero,input=IntPtr.Zero;
  try{
   uint size,count;EnumMonitorsW(null,2,IntPtr.Zero,0,out size,out count);
   if(size==0 || size>4194304)throw new Win32Exception(Marshal.GetLastWin32Error());
   buffer=Marshal.AllocHGlobal((int)size);Check(EnumMonitorsW(null,2,buffer,size,out size,out count));
   string monitor=null;
   for(int i=0;i<count;i++){
    IntPtr row=IntPtr.Add(buffer,i*3*IntPtr.Size);
    string dll=Marshal.PtrToStringUni(Marshal.ReadIntPtr(row,2*IntPtr.Size));
    string file=System.IO.Path.GetFileName(dll);
    if(String.Equals(file,"localmon.dll",StringComparison.OrdinalIgnoreCase) || String.Equals(file,"localspl.dll",StringComparison.OrdinalIgnoreCase)){
     monitor=Marshal.PtrToStringUni(Marshal.ReadIntPtr(row));break;
    }
   }
   if(monitor==null)throw new Win32Exception(3000,"Monitor local do Windows nao encontrado.");
   var defaults=new DEFAULTS();defaults.Access=1;
   Check(OpenPrinterW(",XcvMonitor "+monitor,out handle,ref defaults));
   input=Marshal.StringToHGlobalUni(port);uint bytes=(uint)((port.Length+1)*2);
   Command(handle,"PortIsValid",input,bytes);
   Command(handle,"AddPort",input,bytes);
   return monitor;
  }finally{if(input!=IntPtr.Zero)Marshal.FreeHGlobal(input);if(handle!=IntPtr.Zero)ClosePrinter(handle);if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);}
 }
}
'@ -ErrorAction Stop
    }
    [LocalPortMonitorBridge]::Add($PortName)
}

try {
    if($RequestPath){
        $request = Import-Clixml -LiteralPath $RequestPath -ErrorAction Stop
        $address=Resolve-PrinterUNC -UNCPath ([string]$request.UNCPath)
        $DriverName=[string]$request.DriverName; $QueueName=[string]$request.QueueName; $InfPath=[string]$request.InfPath
    }else{$address=Resolve-PrinterUNC -Server $Server -ShareName $ShareName}
    $unc=$address.UNCPath
    $driver=$DriverName.Trim()
    $queue=$QueueName.Trim()
    if(-not $queue){$queue=$address.ShareName+' em '+$address.Server}
    $inf=$InfPath

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
            $injected=Invoke-PrinterPnPInstall -Directory (Split-Path -Parent $inf) -DriverName $driver -InfName ([IO.Path]::GetFileName($inf))
            if(-not $injected.Success){throw $injected.Message}
            $installedDriver = Get-PrinterDriver -Name $driver -ErrorAction SilentlyContinue
        }
        if (-not $installedDriver) {
            throw "O driver '$driver' não está instalado neste PC. Selecione o INF oficial para Windows 10 ou instale o driver e tente novamente."
        }

        $createdPort = $false
        $stage = 'Criar porta local UNC'
        if (-not (Get-PrinterPort -Name $unc -ErrorAction SilentlyContinue)) {
            try {
                Add-PrinterPort -Name $unc -ErrorAction Stop
            } catch {
                # Only error 87 permits this alternative. Access denied is reported.
                $parameterError = $_.FullyQualifiedErrorId -match '(?i)0x80070057|0x00000057' -or
                    (([long]$_.Exception.HResult -band 4294967295) -eq 2147942487)
                if (-not $parameterError) { throw }
                $cimPortError = [string]$_.FullyQualifiedErrorId
                $stage = 'Validar e criar porta UNC no monitor local do Windows'
                $portMethod = 'XcvData/LocalMon'
                $monitor = Add-UNCPrinterPortNative -PortName $unc
                $confirmedPort = Get-PrinterPort -ErrorAction Stop | Where-Object { $_.Name -ieq $unc } | Select-Object -First 1
                if (-not $confirmedPort) { throw 'O monitor aceitou a operação, mas a porta não apareceu no Windows.' }
            }
            $createdPort = $true
        }
        try {
            $stage = 'Criar fila com driver e porta local'
            Add-Printer -Name $queue -DriverName $driver -PortName $unc -ErrorAction Stop
            $stage = 'Confirmar fila criada no Windows'
            $createdQueue=Wait-ExactPrinter -UNCPath $unc -QueueName $queue -DriverName $driver -Seconds 10
            if ([string]$createdQueue.PortName -ine $unc -or [string]$createdQueue.DriverName -ine $driver) {
                throw "O Windows criou a fila com porta ou driver diferente do solicitado (porta='$($createdQueue.PortName)', driver='$($createdQueue.DriverName)')."
            }
            $result = @{ Success = $true; Stage = $stage; QueueName = $queue; PortName = $unc; PortMethod=$portMethod; CimPortError=$cimPortError; Message = 'Fila local criada e confirmada no Windows.' }
        } catch {
            if ($createdPort -and -not (Get-Printer -ErrorAction SilentlyContinue | Where-Object { [string]$_.PortName -ieq $unc })) {
                Remove-PrinterPort -Name $unc -ErrorAction SilentlyContinue
            }
            throw
        }
    }
} catch {
    $result=Get-PrinterOperationFailure -Record $_ -Stage $stage -Resource $unc -Scope Local
    # Port creation touches both the local monitor and the remote queue. A local
    # denial must not be advertised as a missing network password.
    if($result.NativeCode -eq 5 -and $stage -in @('Criar porta local UNC','Validar e criar porta UNC no monitor local do Windows')){
        try{
            $remoteCode=Test-PrinterRemoteQueueAccess -UNCPath $unc
            $result.RemoteAccessCode=$remoteCode
            if($remoteCode -in @(5,86,1244,1326,1327,1328,1329,1330,1331,1385,1907,1909,2202)){
                $result.NeedsAuthentication=$true;$result.FailureScope='Remote'
            }
        }catch{$result.RemoteAccessProbeMessage=$_.Exception.Message}
    }
    $result.PortMethod=$portMethod;$result.CimPortError=$cimPortError
}

if(-not $ResultPath){return $result}
try {
    $result | Export-Clixml -LiteralPath $ResultPath -Force -ErrorAction Stop
} catch {
    exit 2
}
if ($result.Success) { exit 0 }
exit 1
