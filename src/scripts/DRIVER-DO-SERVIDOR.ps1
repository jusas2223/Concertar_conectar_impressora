param(
    [Parameter(Mandatory=$true)][string]$UNCPath,
    [ValidateSet('PublishDriver','InstallDriver')][string]$Action,
    [string]$ProgressPath = ''
)

# Called only by the bounded worker. Credentials remain in its network token.
$ErrorActionPreference = 'Stop'
$stage = $null
$archive = $null
function Set-DriverStage([string]$message) {
    if ($ProgressPath) { [IO.File]::WriteAllText($ProgressPath,$message,[Text.Encoding]::UTF8) }
}
$native = @'
using System;
using System.ComponentModel;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class PrinterDriverTransfer {
 [StructLayout(LayoutKind.Sequential)] public struct INFO6 {
  public uint Version; public IntPtr Name, Environment, Driver, Data, Config, Help, Dependencies, Monitor, DataType, Previous;
  public System.Runtime.InteropServices.ComTypes.FILETIME Date;
  public ulong DriverVersion; public IntPtr Manufacturer, Url, HardwareId, Provider;
 }
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool OpenPrinterW(string name,out IntPtr handle,IntPtr defaults);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool ClosePrinter(IntPtr handle);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetPrinterW(IntPtr handle,uint level,IntPtr buffer,uint size,out uint needed);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetPrinterDriverW(IntPtr handle,string environment,uint level,IntPtr buffer,uint size,out uint needed);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool AddPrinterDriverExW(string server,uint level,ref INFO6 info,uint flags);
 static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
 public static string QueueDriver(string queue) {
  IntPtr h=IntPtr.Zero,b=IntPtr.Zero;
  try { Check(OpenPrinterW(queue,out h,IntPtr.Zero)); uint size;
   GetPrinterW(h,2,IntPtr.Zero,0,out size); if(size==0 || size>4194304) throw new Win32Exception(Marshal.GetLastWin32Error());
   b=Marshal.AllocHGlobal((int)size); Check(GetPrinterW(h,2,b,size,out size));
   return Marshal.PtrToStringUni(Marshal.ReadIntPtr(b,4*IntPtr.Size));
  } finally { if(b!=IntPtr.Zero) Marshal.FreeHGlobal(b); if(h!=IntPtr.Zero) ClosePrinter(h); }
 }
 public static Dictionary<string,object> LocalDriver(string queue,string environment) {
  IntPtr h=IntPtr.Zero,b=IntPtr.Zero;
  try { Check(OpenPrinterW(queue,out h,IntPtr.Zero)); uint size;
   GetPrinterDriverW(h,environment,6,IntPtr.Zero,0,out size); if(size==0 || size>4194304) throw new Win32Exception(Marshal.GetLastWin32Error());
   b=Marshal.AllocHGlobal((int)size); Check(GetPrinterDriverW(h,environment,6,b,size,out size));
   INFO6 i=(INFO6)Marshal.PtrToStructure(b,typeof(INFO6)); var r=new Dictionary<string,object>();
   r["Version"]=i.Version; r["Name"]=Marshal.PtrToStringUni(i.Name); r["Environment"]=Marshal.PtrToStringUni(i.Environment);
   r["Driver"]=Marshal.PtrToStringUni(i.Driver); r["Data"]=Marshal.PtrToStringUni(i.Data); r["Config"]=Marshal.PtrToStringUni(i.Config);
   r["Help"]=Marshal.PtrToStringUni(i.Help); r["Monitor"]=Marshal.PtrToStringUni(i.Monitor); r["DataType"]=Marshal.PtrToStringUni(i.DataType);
   var files=new List<string>(); IntPtr p=i.Dependencies;
   if(p!=IntPtr.Zero) { while(Marshal.ReadInt16(p)!=0) { string s=Marshal.PtrToStringUni(p); files.Add(s); p=IntPtr.Add(p,(s.Length+1)*2); if(files.Count>128) throw new Exception("Dependencias invalidas."); } }
   r["Dependencies"]=files.ToArray(); return r;
  } finally { if(b!=IntPtr.Zero) Marshal.FreeHGlobal(b); if(h!=IntPtr.Zero) ClosePrinter(h); }
 }
 public static void Install(string name,string environment,string driver,string data,string config,string help,string[] dependencies,string dataType) {
  var allocated=new List<IntPtr>();
  Func<string,IntPtr> str=s=>{ if(String.IsNullOrEmpty(s)) return IntPtr.Zero; var p=Marshal.StringToHGlobalUni(s); allocated.Add(p); return p; };
  try { var i=new INFO6(); i.Version=3; i.Name=str(name); i.Environment=str(environment); i.Driver=str(driver); i.Data=str(data); i.Config=str(config); i.Help=str(help);
   i.Dependencies=str(String.Join("\0",dependencies)+"\0\0"); i.DataType=str(dataType);
   Check(AddPrinterDriverExW(null,6,ref i,0x18));
  } finally { foreach(var p in allocated) Marshal.FreeHGlobal(p); }
 }
}
'@

function Get-PackageKey([string]$share,[string]$arch) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($share.ToUpperInvariant()))).Replace('-','').ToLowerInvariant() + '-' + $arch + '.zip') }
    finally { $hash.Dispose() }
}
function Get-SafeFileName([string]$name) {
    if (-not $name -or $name -in @('.','..') -or $name -match '[\\/:\x00-\x1f]' -or $name.Length -gt 180 -or
        [IO.Path]::GetFileName($name) -cne $name -or $name.TrimEnd(' ','.') -cne $name) { throw 'Nome de arquivo inválido no pacote do driver.' }
    return $name
}

try {
    if ($UNCPath -notmatch '^\\\\([^\\]+)\\([^\\]+)$') { throw 'Informe \\SERVIDOR\Fila.' }
    $server = $matches[1]; $share = $matches[2]
    $arch = if ([Environment]::Is64BitProcess) { 'x64' } else { 'W32X86' }
    $environment = if ($arch -eq 'x64') { 'Windows x64' } else { 'Windows NT x86' }
    $key = Get-PackageKey $share $arch
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o EXE como administrador para preparar ou instalar o driver do servidor.'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $coreFiles = @('unidrv.dll','unidrvui.dll','unires.dll','stdnames.gpd','ttfsub.gpd','pscript5.dll','ps5ui.dll','pscript.hlp','pscript.ntf')
    $stage = Join-Path $env:TEMP ('PrinterDriverTransfer_' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stage)

    if ($Action -eq 'PublishDriver') {
        Set-DriverStage 'Carregar rotina de exportação'
        Add-Type -TypeDefinition $native -ErrorAction Stop
        if ($server -notin @($env:COMPUTERNAME,'localhost','127.0.0.1')) { throw 'Prepare o driver no próprio computador que compartilha a impressora.' }
        $printer = Get-Printer -ErrorAction Stop | Where-Object { $_.Shared -and $_.ShareName -ieq $share } | Select-Object -First 1
        if (-not $printer) { throw 'Esta fila não está compartilhada neste computador.' }
        $info = [PrinterDriverTransfer]::LocalDriver($printer.Name,$environment)
        if ($info.Version -ne 3) { throw 'A transferência de arquivos atende drivers Tipo 3. Este driver exige o pacote INF do fabricante.' }
        if ($info.Monitor) { throw 'Este driver usa um monitor adicional; é necessário o pacote completo do fabricante.' }
        $root = [IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\spool\drivers'))
        $manifest = [ordered]@{ Format=1; Share=$share; DriverName=$info.Name; Environment=$environment; Version=3; DataType=$info.DataType; Files=@(); Dependencies=@() }
        $paths = @($info.Driver,$info.Data,$info.Config,$info.Help) + @($info.Dependencies)
        foreach ($path in @($paths | Where-Object { $_ } | Select-Object -Unique)) {
            $full = [IO.Path]::GetFullPath($path)
            if (-not $full.StartsWith($root + '\',[StringComparison]::OrdinalIgnoreCase)) { throw "Dependência fora da pasta de drivers: $full" }
            $name = Get-SafeFileName ([IO.Path]::GetFileName($full))
            if ($manifest.Files.Name -icontains $name) { throw 'O driver tem dependências com nomes duplicados.' }
            $core = $coreFiles -icontains $name
            $item = [ordered]@{ Name=$name; Core=$core; SHA256=''; Length=0 }
            if (-not $core) {
                if ((Get-Item -LiteralPath $full).Length -gt 67108864) { throw 'Arquivo de driver maior que 64 MB.' }
                Copy-Item -LiteralPath $full -Destination (Join-Path $stage $name)
                $item.SHA256 = (Get-FileHash -LiteralPath (Join-Path $stage $name) -Algorithm SHA256).Hash
                $item.Length = (Get-Item -LiteralPath (Join-Path $stage $name)).Length
            }
            $manifest.Files += $item
        }
        foreach ($field in @('Driver','Data','Config','Help')) { $manifest[$field] = if ($info[$field]) { [IO.Path]::GetFileName($info[$field]) } else { '' } }
        $manifest.Dependencies = @($info.Dependencies | ForEach-Object { [IO.Path]::GetFileName($_) })
        $manifest | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
        $printShare = Get-SmbShare -Name 'print$' -ErrorAction Stop
        if ([IO.Path]::GetFullPath($printShare.Path).TrimEnd('\') -ine $root) { throw 'O compartilhamento print$ não aponta para a pasta padrão de drivers.' }
        $destination = Join-Path $root 'AssistentePacotes'
        [void][IO.Directory]::CreateDirectory($destination)
        $pending = Join-Path $destination ([Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.Compression.ZipFile]::CreateFromDirectory($stage,$pending)
            if ((Get-Item -LiteralPath $pending).Length -gt 67108864) { throw 'Pacote de driver maior que 64 MB.' }
            $target = Join-Path $destination $key
            if (Test-Path -LiteralPath $target) { [IO.File]::Replace($pending,$target,[Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($pending,$target) }
        } finally { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
        return @{ Success=$true; DriverName=$info.Name; Message="Driver '$($info.Name)' preparado. No outro PC, use Conectar Impressora Selecionada; o EXE buscará o pacote em \\$server\print$." }
    }

    # The server publishes one package per share/architecture. This download uses
    # SMB only, so it does not depend on the failing Point and Print RPC download.
    Set-DriverStage 'Localizar pacote do compartilhamento no servidor'
    $packagePath = '\\' + $server + '\print$\AssistentePacotes\' + $key
    if (-not (Test-Path -LiteralPath $packagePath -PathType Leaf)) { throw "O pacote ainda não foi preparado. No servidor $server, abra o EXE como administrador, selecione a impressora em Impressoras Instaladas e clique em Preparar driver para outros PCs." }
    if ((Get-Item -LiteralPath $packagePath).Length -gt 67108864) { throw 'Pacote maior que 64 MB.' }
    $localZip = Join-Path $stage 'package.zip'
    Set-DriverStage 'Copiar pacote pela rede'
    Copy-Item -LiteralPath $packagePath -Destination $localZip
    $archive = [IO.Compression.ZipFile]::OpenRead($localZip)
    $entries = @($archive.Entries)
    if ($entries.Count -gt 130 -or $entries.Count -lt 2) { throw 'Quantidade inválida de arquivos no pacote.' }
    $names = @(); [long]$total = 0
    foreach ($entry in $entries) {
        $name = Get-SafeFileName $entry.FullName
        if ($names -icontains $name) { throw 'Arquivo duplicado no pacote.' }
        $names += $name; $total += $entry.Length
        if ($entry.Length -gt 67108864 -or $total -gt 134217728) { throw 'Conteúdo do pacote excede o limite.' }
    }
    $metadata = $entries | Where-Object FullName -ceq 'manifest.json'
    if (-not $metadata -or $metadata.Length -gt 262144) { throw 'Manifesto inválido.' }
    $reader = New-Object IO.StreamReader($metadata.Open())
    try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
    if ($manifest.Format -ne 1 -or $manifest.Version -ne 3 -or $manifest.Environment -ine $environment -or
        $manifest.Share -ine $share -or -not $manifest.DriverName -or [string]$manifest.DriverName -match '[\x00-\x1f]' -or
        ([string]$manifest.DriverName).Length -gt 255) { throw 'Pacote não corresponde à fila ou à arquitetura deste Windows.' }
    $driverName = [string]$manifest.DriverName
    if (Get-PrinterDriver -ErrorAction Stop | Where-Object { $_.Name -ieq $driverName -and $_.PrinterEnvironment -ieq $environment }) {
        return @{ Success=$true; DriverName=$driverName; Existing=$true; Message="Driver '$driverName' registrado neste PC com o mesmo nome e arquitetura. Os arquivos e a versão não foram comparados com os do servidor; o driver existente foi preservado." }
    }
    if (@($manifest.Files).Count -gt 128 -or @($manifest.Files).Count -eq 0) { throw 'Lista de arquivos inválida.' }
    Set-DriverStage 'Conferir arquivos e componentes locais'
    $resolved = @{}
    $ntRoots = @(Get-ChildItem -LiteralPath (Join-Path $env:WINDIR 'System32\DriverStore\FileRepository') -Filter ('ntprint.inf_' + $(if ($arch -eq 'x64') { 'amd64' } else { 'x86' }) + '_*') -Directory | Sort-Object LastWriteTime -Descending)
    foreach ($file in $manifest.Files) {
        $name = Get-SafeFileName ([string]$file.Name)
        if ($resolved.ContainsKey($name)) { throw 'Dependência duplicada no manifesto.' }
        if ($file.Core -eq $true) {
            if ($coreFiles -inotcontains $name) { throw 'Componente do Windows não reconhecido.' }
            $corePath = Join-Path $env:WINDIR ("System32\spool\drivers\$arch\3\$name")
            if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
                $corePath = $null
                foreach ($ntRoot in $ntRoots) {
                    $candidate = Join-Path $ntRoot.FullName ("$arch\$name")
                    if ($arch -eq 'x64') { $candidate = Join-Path $ntRoot.FullName ("Amd64\$name") }
                    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $corePath=$candidate; break }
                }
            }
            if (-not $corePath) { throw "Componente $name não encontrado neste Windows. O EXE não substitui componentes do sistema por arquivos de outra versão." }
            $resolved[$name] = $corePath
        } else {
            if ($coreFiles -icontains $name -or $name -ieq 'manifest.json' -or $file.SHA256 -notmatch '^[0-9a-fA-F]{64}$') { throw 'Dependência inválida no manifesto.' }
            $entry = $entries | Where-Object FullName -ieq $name
            if (-not $entry -or $entry.Length -ne $file.Length) { throw "Arquivo ausente ou incompleto: $name" }
            $destination = Join-Path $stage $name
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,$destination,$false)
            if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ine $file.SHA256) { throw "Integridade inválida: $name" }
            $resolved[$name] = $destination
        }
    }
    $expectedNames = @('manifest.json') + @($manifest.Files | Where-Object { $_.Core -ne $true } | ForEach-Object Name)
    if (@($names | Where-Object { $expectedNames -inotcontains $_ }).Count) { throw 'O pacote contém arquivos não declarados.' }
    foreach ($field in @('Driver','Data','Config','Help')) {
        if ($manifest.$field -and -not $resolved.ContainsKey([string]$manifest.$field)) { throw "Dependência ausente para $field." }
    }
    if (-not $manifest.Driver -or -not $manifest.Data -or -not $manifest.Config) { throw 'Driver incompleto.' }
    $dependencies = @($manifest.Dependencies | ForEach-Object { if (-not $resolved.ContainsKey([string]$_)) { throw 'Dependência não declarada.' }; $resolved[[string]$_] })
    Set-DriverStage 'Registrar driver no Windows deste PC'
    Add-Type -TypeDefinition $native -ErrorAction Stop
    [PrinterDriverTransfer]::Install($driverName,$environment,$resolved[$manifest.Driver],$resolved[$manifest.Data],$resolved[$manifest.Config],$(if ($manifest.Help) { $resolved[$manifest.Help] } else { '' }),[string[]]$dependencies,[string]$manifest.DataType)
    $confirmed = Get-PrinterDriver -ErrorAction Stop | Where-Object { $_.Name -ieq $driverName -and $_.PrinterEnvironment -ieq $environment }
    if (-not $confirmed) { throw 'O Windows não confirmou a instalação do driver.' }
    return @{ Success=$true; DriverName=$driverName; Message="Driver '$driverName' recebido de $server e instalado neste PC." }
} catch {
    return @{ Success=$false; Message=$_.Exception.Message; HResult=$_.Exception.HResult }
} finally {
    if ($archive) { $archive.Dispose() }
    if ($stage -and $stage.StartsWith((Join-Path $env:TEMP 'PrinterDriverTransfer_'),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
