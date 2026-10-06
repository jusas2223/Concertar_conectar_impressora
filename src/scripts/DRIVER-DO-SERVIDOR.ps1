param(
    [string]$UNCPath,
    [ValidateSet('PublishDriver','InstallDriver','PrepareHost','PrepareClient')][string]$Action = 'InstallDriver',
    [string]$ProgressPath = '',
    [string]$Server = '',
    [string]$ShareName = '',
    [string]$DriverName = '',
    [string]$StateDirectory = ''
)

# Called only by the bounded worker. Credentials remain in its network token.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'IMPRESSAO-COMUM.ps1')
$stage = $null
$archive = $null
$policy = $null
$infError = $null
$preparedPackageFound = $null
$legacyRegistration = $null
$script:driverOperationStage='Preparar transferência'
$script:driverOperationScope='Local'
$script:driverOperationResource=''
function Set-DriverStage([string]$message,[string]$Scope='Local',[string]$Resource='') {
    $script:driverOperationStage=$message
    $script:driverOperationScope=$Scope
    $script:driverOperationResource=$Resource
    if ($ProgressPath) { [IO.File]::WriteAllText($ProgressPath,$message,[Text.Encoding]::UTF8) }
}
function Copy-DriverSourceFile {
    param([string]$Source,[string]$Destination)
    $inputStream=$null;$outputStream=$null
    try{
        Set-DriverStage 'Ler arquivo do driver' -Scope $(if($Source.StartsWith('\\')){'Remote'}else{'Local'}) -Resource $Source
        $inputStream=[IO.File]::OpenRead($Source)
        Set-DriverStage 'Gravar arquivo do driver no cliente' -Resource $Destination
        $outputStream=[IO.File]::Open($Destination,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
        $inputStream.CopyTo($outputStream)
    }finally{if($outputStream){$outputStream.Dispose()};if($inputStream){$inputStream.Dispose()}}
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
 [StructLayout(LayoutKind.Sequential)] public struct INFO8 {
  public INFO6 Base; public IntPtr Processor, Setup, Profiles, Inf; public uint Attributes; public IntPtr CoreDependencies;
  public System.Runtime.InteropServices.ComTypes.FILETIME MinDate; public ulong MinVersion;
 }
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool OpenPrinterW(string name,out IntPtr handle,IntPtr defaults);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool ClosePrinter(IntPtr handle);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetPrinterW(IntPtr handle,uint level,IntPtr buffer,uint size,out uint needed);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool GetPrinterDriverW(IntPtr handle,string environment,uint level,IntPtr buffer,uint size,out uint needed);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool AddPrinterDriverExW(string server,uint level,ref INFO6 info,uint flags);
 static void Check(bool ok) { if(!ok) throw new Win32Exception(Marshal.GetLastWin32Error()); }
 public static string DriverInf(string queue,string environment) {
  IntPtr h=IntPtr.Zero,b=IntPtr.Zero;
  try { Check(OpenPrinterW(queue,out h,IntPtr.Zero));uint size;
   GetPrinterDriverW(h,environment,8,IntPtr.Zero,0,out size);if(size==0 || size>4194304)throw new Win32Exception(Marshal.GetLastWin32Error());
   b=Marshal.AllocHGlobal((int)size);Check(GetPrinterDriverW(h,environment,8,b,size,out size));
   INFO8 i=(INFO8)Marshal.PtrToStructure(b,typeof(INFO8));return Marshal.PtrToStringUni(i.Inf);
  }finally{if(b!=IntPtr.Zero)Marshal.FreeHGlobal(b);if(h!=IntPtr.Zero)ClosePrinter(h);}
 }
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
   // Keep existing files when they are not older. COPY_ALL_FILES can attempt
   // to overwrite an identical DLL already loaded by the local spooler.
   const uint APD_COPY_NEW_FILES=0x8, APD_COPY_FROM_DIRECTORY=0x10;
   Check(AddPrinterDriverExW(null,6,ref i,APD_COPY_NEW_FILES|APD_COPY_FROM_DIRECTORY));
  } finally { foreach(var p in allocated) Marshal.FreeHGlobal(p); }
 }
}
'@

function Get-PackageKey([string]$share,[string]$arch) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($share.ToUpperInvariant()))).Replace('-','').ToLowerInvariant() + '-' + $arch + '.zip') }
    finally { $hash.Dispose() }
}

function Get-LegacyPrinterDriverState {
    param($Manifest,[string]$Environment)
    $driver=Get-PrinterDriver -ErrorAction Stop | Where-Object { $_.Name -ieq $Manifest.DriverName -and $_.PrinterEnvironment -ieq $Environment } | Select-Object -First 1
    $paths=if($driver){@($driver.Path,$driver.DriverPath,$driver.DataFile,$driver.ConfigFile,$driver.HelpFile)+@($driver.DependentFiles)}else{@()}
    $architecture=if($Environment -eq 'Windows x64'){'x64'}else{'W32X86'}
    $directories=@((Join-Path $env:WINDIR "System32\spool\drivers\$architecture\3")) + @($paths | Where-Object {$_} | ForEach-Object {Split-Path -Parent $_} | Where-Object {$_} | Select-Object -Unique)
    $matched=@{};$mismatches=New-Object Collections.Generic.List[string]
    foreach($file in @($Manifest.Files | Where-Object {$_.Core -ne $true})){
        $candidates=@($paths | Where-Object {$_ -and [IO.Path]::GetFileName($_) -ieq $file.Name}) + @($directories | ForEach-Object {Join-Path $_ $file.Name})
        foreach($candidate in @($candidates | Select-Object -Unique)){
            if(-not (Test-Path -LiteralPath $candidate -PathType Leaf)){continue}
            try{if((Get-FileHash -LiteralPath $candidate -Algorithm SHA256 -ErrorAction Stop).Hash -ieq $file.SHA256){$matched[$file.Name]=$candidate;break}}catch{}
        }
        if(-not $matched.ContainsKey($file.Name)){$mismatches.Add([string]$file.Name)}
    }
    $bindingsMatch=[bool]$driver
    if($driver){
        $roles=@{Driver=@($driver.Path,$driver.DriverPath);Data=@($driver.DataFile);Config=@($driver.ConfigFile);Help=@($driver.HelpFile)}
        foreach($field in @('Driver','Data','Config','Help')){
            if($Manifest.$field -and -not @($roles[$field] | Where-Object {$_ -and [IO.Path]::GetFileName($_) -ieq $Manifest.$field}).Count){$bindingsMatch=$false}
        }
        foreach($dependency in @($Manifest.Dependencies)){
            if(-not @($driver.DependentFiles | Where-Object {$_ -and [IO.Path]::GetFileName($_) -ieq $dependency}).Count){$bindingsMatch=$false}
        }
    }
    return @{Confirmed=($driver -and $driver.MajorVersion -eq 3 -and $bindingsMatch -and $mismatches.Count -eq 0);Existing=[bool]$driver;MatchingPaths=$matched;Mismatches=@($mismatches.ToArray())}
}

function Invoke-LegacyPrinterDriverRegistration {
    param($Manifest,[hashtable]$Resolved,[string]$Environment)
    $name=[string]$Manifest.DriverName
    $state=Get-LegacyPrinterDriverState -Manifest $Manifest -Environment $Environment
    if($state.Confirmed){return @{Success=$true;DriverName=$name;Existing=$true;FilesCompared=$true;RegistrationAttempts=0;CopyPolicy='CopyNewFiles';Message="Driver '$name' confirmado por arquitetura, arquivos e vínculo do cadastro local."}}
    # Reuse byte-identical local vendor files, even before a driver is registered.
    # Their real timestamp/path prevents a fresh temporary copy becoming an update.
    foreach($file in @($Manifest.Files | Where-Object {$_.Core -ne $true})){
        if($state.MatchingPaths.ContainsKey($file.Name)){$Resolved[$file.Name]=$state.MatchingPaths[$file.Name]}
    }
    $dependencies=@($Manifest.Dependencies | ForEach-Object {$Resolved[[string]$_]})
    for($attempt=1;$attempt -le 3;$attempt++){
        Set-DriverStage "Registrar driver no Windows deste PC (tentativa $attempt/3)" -Resource $name
        try{
            [PrinterDriverTransfer]::Install($name,$Environment,$Resolved[$Manifest.Driver],$Resolved[$Manifest.Data],$Resolved[$Manifest.Config],$(if($Manifest.Help){$Resolved[$Manifest.Help]}else{''}),[string[]]$dependencies,[string]$Manifest.DataType)
        }catch{
            $failure=Get-PrinterOperationFailure -Record $_ -Stage $script:driverOperationStage -Resource $name -Scope Local
            $failure.DriverName=$name;$failure.RegistrationAttempts=$attempt;$failure.CopyPolicy='CopyNewFiles'
            if($failure.Code -notin @(32,33)){return $failure}
            $state=Get-LegacyPrinterDriverState -Manifest $Manifest -Environment $Environment
            if($state.Confirmed){return @{Success=$true;DriverName=$name;Existing=$true;FilesCompared=$true;RegistrationAttempts=$attempt;CopyPolicy='CopyNewFiles';Message="Driver '$name' confirmado após a tentativa de registro."}}
            if($attempt -eq 3){
                $failure.DriverFiles=@($Resolved.Values | Select-Object -Unique)
                $failure.Message="Um arquivo do driver '$name' está em uso neste computador (Windows $($failure.Code)). O registro foi tentado 3 vezes e não foi confirmado. Feche aplicativos/janelas que usam esta impressora e tente novamente. A opção Reiniciar Spooler está em Fila e serviços. Não é necessário informar outra senha por este erro."
                return $failure
            }
            Start-Sleep -Milliseconds (300*$attempt)
            continue
        }
        for($poll=0;$poll -lt 5;$poll++){
            $state=Get-LegacyPrinterDriverState -Manifest $Manifest -Environment $Environment
            if($state.Confirmed){return @{Success=$true;DriverName=$name;FilesCompared=$true;RegistrationAttempts=$attempt;CopyPolicy='CopyNewFiles';Message="Driver '$name' instalado e confirmado por arquitetura, arquivos e vínculo do cadastro local."}}
            if($poll -lt 4){Start-Sleep -Milliseconds 250}
        }
        return @{Success=$false;Code=31;NativeCode=31;Stage='Confirmar arquivos do driver registrado';Resource=$name;FailureScope='Local';DriverName=$name;RegistrationAttempts=$attempt;CopyPolicy='CopyNewFiles';Message="O Windows não confirmou o cadastro e os arquivos esperados do driver '$name'."}
    }
}
function Get-SafeFileName([string]$name) {
    if (-not $name -or $name -in @('.','..') -or $name -match '[\\/:\x00-\x1f]' -or $name.Length -gt 180 -or
        [IO.Path]::GetFileName($name) -cne $name -or $name.TrimEnd(' ','.') -cne $name) { throw 'Nome de arquivo inválido no pacote do driver.' }
    return $name
}

function Copy-ExactDriverDirectory {
    param([string]$Source,[string]$Destination)
    Set-DriverStage 'Enumerar arquivos do pacote' -Scope $(if($Source.StartsWith('\\')){'Remote'}else{'Local'}) -Resource $Source
    $root=[IO.Path]::GetFullPath($Source).TrimEnd('\')+'\'
    $files=@(Get-ChildItem -LiteralPath $Source -Recurse -File -ErrorAction Stop)
    if(Get-ChildItem -LiteralPath $Source -Recurse -Directory -ErrorAction Stop | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }){throw 'Pacote contém um diretório redirecionado.'}
    if($files.Count -gt 4096){throw 'Pacote de driver excede 4096 arquivos.'}
    [long]$total=0
    Set-DriverStage 'Criar pasta temporária do pacote' -Resource $Destination
    [void][IO.Directory]::CreateDirectory($Destination)
    foreach($file in $files){
        $full=[IO.Path]::GetFullPath($file.FullName)
        if(-not $full.StartsWith($root,[StringComparison]::OrdinalIgnoreCase) -or $file.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Caminho inválido no pacote.'}
        $total+=$file.Length
        if($total -gt 536870912){throw 'Pacote de driver excede 512 MB.'}
        $relative=$full.Substring($root.Length)
        $target=Join-Path $Destination $relative
        Set-DriverStage 'Criar pasta temporária do pacote' -Resource $target
        [void][IO.Directory]::CreateDirectory((Split-Path -Parent $target))
        Copy-DriverSourceFile -Source $full -Destination $target
    }
}

function Find-RemoteInfPackage {
    param([string]$Server,[string]$Share,[string]$Architecture,[string]$Environment,[string]$RequestedDriver)
    $root='\\'+$Server+'\print$\'+$Architecture
    $prepared=Join-Path $root ('AssistentePacotes\'+(Get-PackageKey $Share $Architecture).Replace('.zip',''))
    $metadataPath=Join-Path $prepared 'package.json'
    Set-DriverStage 'Ler manifesto remoto do driver' -Scope Remote -Resource $metadataPath
    if(Test-PrinterRemotePath -Path $metadataPath){
        $metadata=Get-Content -LiteralPath $metadataPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if($metadata.Format -ne 2 -or $metadata.Share -ine $Share -or $metadata.Environment -ine $Environment -or
            -not $metadata.DriverName -or ($RequestedDriver -and $metadata.DriverName -ine $RequestedDriver)){throw 'Pacote INF preparado não corresponde à fila/arquitetura.'}
        $infName=Get-SafeFileName ([string]$metadata.InfName)
        $folder=if($metadata.FilesDirectory){Get-SafeFileName ([string]$metadata.FilesDirectory)}else{'Files'}
        $source=Join-Path $prepared $folder
        Set-DriverStage 'Ler INF remoto' -Scope Remote -Resource (Join-Path $source $infName)
        if(-not(Test-PrinterRemotePath -Path (Join-Path $source $infName))){throw 'INF preparado ausente.'}
        return @{Source=$source;InfName=$infName;DriverName=[string]$metadata.DriverName;Hashes=$metadata.Files}
    }
    Set-DriverStage 'Ler compartilhamento de drivers' -Scope Remote -Resource $root
    if(-not(Test-PrinterRemotePath -Path $root -Directory)){throw "Compartilhamento de drivers inexistente: $root"}
    $queue='\\'+$Server+'\'+$Share
    Set-DriverStage 'Consultar driver da fila remota' -Scope Remote -Resource $queue
    $actual=[PrinterDriverTransfer]::QueueDriver($queue)
    if($RequestedDriver -and $RequestedDriver -ine $actual){throw 'O driver solicitado não corresponde à fila remota.'}
    $infPath=''
    try{$infPath=[PrinterDriverTransfer]::DriverInf($queue,$Environment)}catch{}
    Set-DriverStage 'Localizar INF no compartilhamento' -Scope Remote -Resource $root
    $infs=@(Get-ChildItem -LiteralPath $root -Filter '*.inf' -Recurse -File -ErrorAction Stop)
    if(-not $infs.Count){return $null}
    $selected=@()
    if($infPath){
        $base=[IO.Path]::GetFileName($infPath)
        $selected=@($infs | Where-Object Name -ieq $base)
        if($selected.Count -gt 1){
            $parent=Split-Path -Parent $infPath
            if($parent){$folder=Split-Path -Leaf $parent;$selected=@($selected | Where-Object { $_.Directory.Name -ieq $folder })}
        }
    }
    if(-not $selected.Count){
        # Only select an INF that declares the exact display name and Printer class.
        $escaped=[regex]::Escape($actual)
        $selected=@($infs | Where-Object {
            $text=[IO.File]::ReadAllText($_.FullName,[Text.Encoding]::Default)
            $text -match '(?im)^\s*Class\s*=\s*"?Printer"?\s*(;.*)?$' -and $text -match ('(?im)"'+$escaped+'"')
        })
    }
    if($selected.Count -ne 1){throw "Não foi possível mapear um único INF para '$actual' em $root. Prepare o pacote no EXE do servidor."}
    return @{Source=$selected[0].Directory.FullName;InfName=$selected[0].Name;DriverName=$actual;Hashes=$null}
}

function Publish-InfDriverPackage {
    param([string]$InfPath,[string]$Name,[string]$Share,[string]$Environment,[string]$Architecture,[string]$SpoolRoot)
    if(-not $InfPath -or -not(Test-Path -LiteralPath $InfPath -PathType Leaf)){return $null}
    $repository=[IO.Path]::GetFullPath((Join-Path $env:WINDIR 'System32\DriverStore\FileRepository')).TrimEnd('\')+'\'
    $full=[IO.Path]::GetFullPath($InfPath)
    if(-not $full.StartsWith($repository,[StringComparison]::OrdinalIgnoreCase)){return $null}
    $destination=Join-Path $SpoolRoot ($Architecture+'\AssistentePacotes\'+(Get-PackageKey $Share $Architecture).Replace('.zip',''))
    $filesDirectory='Files_'+[Guid]::NewGuid().ToString('N')
    $filesRoot=Join-Path $destination $filesDirectory
    # Immutable directory and atomic metadata: concurrent clients keep a complete package.
    Copy-ExactDriverDirectory -Source (Split-Path -Parent $full) -Destination $filesRoot
    $hashes=@(Get-ChildItem -LiteralPath $filesRoot -Recurse -File | ForEach-Object {
        @{Name=$_.FullName.Substring($filesRoot.Length+1);SHA256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash}
    })
    $pending=Join-Path $destination ('package_'+[Guid]::NewGuid().ToString('N')+'.tmp')
    @{Format=2;Share=$Share;DriverName=$Name;Environment=$Environment;FilesDirectory=$filesDirectory;InfName=[IO.Path]::GetFileName($full);Files=$hashes} |
        ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $pending -Encoding UTF8
    $target=Join-Path $destination 'package.json'
    if(Test-Path -LiteralPath $target){[IO.File]::Replace($pending,$target,[Management.Automation.Language.NullString]::Value)}else{[IO.File]::Move($pending,$target)}
    return @{Success=$true;DriverName=$Name;Message="Pacote INF completo de '$Name' publicado em print$ para os clientes."}
}

try {
    if($Action -eq 'PrepareClient'){return (Set-PrinterCompatibilityPolicies -Role Client -StateDirectory $StateDirectory)}
    $address=Resolve-PrinterUNC -UNCPath $UNCPath -Server $Server -ShareName $ShareName
    $server=$address.Server; $share=$address.ShareName; $UNCPath=$address.UNCPath
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

    if ($Action -in @('PublishDriver','PrepareHost')) {
        Set-DriverStage 'Carregar rotina de exportação'
        if(-not('PrinterDriverTransfer' -as [type])){Add-Type -TypeDefinition $native -ErrorAction Stop}
        if ($server -notin @($env:COMPUTERNAME,'localhost','127.0.0.1')) { throw 'Prepare o driver no próprio computador que compartilha a impressora.' }
        $printer = Get-Printer -ErrorAction Stop | Where-Object { $_.Shared -and $_.ShareName -ieq $share } | Select-Object -First 1
        if (-not $printer) { throw 'Esta fila não está compartilhada neste computador.' }
        if($Action -eq 'PrepareHost'){
            Set-DriverStage 'Preparar serviço e firewall de compartilhamento do host'
            $network=Enable-PrinterHostNetworkAccess
            Set-DriverStage $network.Message
            $policy=Set-PrinterCompatibilityPolicies -Role Host -StateDirectory $StateDirectory
            $policy.Message=$network.Message+' '+$policy.Message
            Set-DriverStage $policy.Message
        }
        $infPath=''
        try{$infPath=[PrinterDriverTransfer]::DriverInf($printer.Name,$environment)}catch{}
        $spoolRoot=Join-Path $env:WINDIR 'System32\spool\drivers'
        $infPublished=Publish-InfDriverPackage -InfPath $infPath -Name $printer.DriverName -Share $share -Environment $environment -Architecture $arch -SpoolRoot $spoolRoot
        if($infPublished){
            if($policy){$infPublished.PolicyStatePath=$policy.StatePath;$infPublished.Message+=' Políticas do host aplicadas; estado anterior: '+$policy.StatePath}
            return $infPublished
        }
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
        return @{ Success=$true; DriverName=$info.Name; PolicyStatePath=$(if($policy){$policy.StatePath}else{''}); Message="Driver '$($info.Name)' preparado. No outro PC, use Conectar Impressora Selecionada; o EXE buscará o pacote em \\$server\print$."+$(if($policy){' Políticas do host aplicadas; estado anterior: '+$policy.StatePath}else{''}) }
    }

    Set-DriverStage 'Mapear o INF da fila em print$'
    if(-not('PrinterDriverTransfer' -as [type])){Add-Type -TypeDefinition $native -ErrorAction Stop}
    $infFailure=''
    try {
        $remote=Find-RemoteInfPackage -Server $server -Share $share -Architecture $arch -Environment $environment -RequestedDriver $DriverName
        if($remote){
            $infStage=Join-Path $stage 'DriverRemoto'
            Set-DriverStage 'Copiar o pacote INF completo pela rede' -Scope Remote -Resource $remote.Source
            Copy-ExactDriverDirectory -Source $remote.Source -Destination $infStage
            foreach($file in @($remote.Hashes)){
                if(-not $file){continue}
                $candidate=[IO.Path]::GetFullPath((Join-Path $infStage ([string]$file.Name)))
                if(-not $candidate.StartsWith($infStage+'\',[StringComparison]::OrdinalIgnoreCase) -or
                    (Get-FileHash -LiteralPath $candidate -Algorithm SHA256).Hash -ine $file.SHA256){throw 'Integridade inválida no pacote INF recebido.'}
            }
            Set-DriverStage 'Injetar INF com PnPUtil e confirmar o nome do driver'
            # Select only the mapped INF, not other drivers that share a spool folder.
            $installed=Invoke-PrinterPnPInstall -Directory $infStage -DriverName $remote.DriverName -InfName $remote.InfName
            $installed.PreparedPackageFound=$true
            $installed.DriverAvailability=$(if($installed.Success){'Confirmed'}else{'Unknown'})
            return $installed
        }
    } catch {
        $infError=Get-PrinterOperationFailure -Record $_ -Stage $script:driverOperationStage -Resource $script:driverOperationResource -Scope $script:driverOperationScope
        $infError.DriverAvailability='Unknown';$infError.PreparedPackageFound=$null
        if($infError.NeedsAuthentication -or $script:driverOperationScope -eq 'Local'){return $infError}
        $infFailure=$_.Exception.Message
    }

    # Legacy non-package-aware drivers can have no INF at all. Keep the
    # generic prepared Type 3 bundle instead of inventing an INF from DLLs.
    # The server publishes one package per share/architecture. This download uses
    # SMB only, so it does not depend on the failing Point and Print RPC download.
    Set-DriverStage 'Localizar pacote do compartilhamento no servidor'
    $packagePath = '\\' + $server + '\print$\AssistentePacotes\' + $key
    Set-DriverStage 'Ler pacote legado remoto' -Scope Remote -Resource $packagePath
    $preparedPackageFound=Test-PrinterRemotePath -Path $packagePath
    if (-not $preparedPackageFound) {
        $message="Não foi possível obter o pacote de driver desta fila. O pacote preparado não foi encontrado em print$. No computador $server, selecione a fila e use Preparar host e driver."
        if($infError){$message="Não foi possível consultar/obter o driver remoto (código $($infError.Code)). O pacote preparado também não foi encontrado em print$. No computador $server, selecione a fila e use Preparar host e driver."}
        $failure=@{Success=$false;Code=2;NativeCode=2;Stage=$script:driverOperationStage;Resource=$packagePath;
            FailureScope='Remote';NeedsAuthentication=$false;DriverAvailability='Unknown';PreparedPackageFound=$false;Message=$message}
        if($infError){
            $failure.InfLookupCode=$infError.Code;$failure.InfLookupStage=$infError.Stage
            $failure.InfLookupResource=$infError.Resource;$failure.InfLookupMessage=$infFailure
            if($infError.Stage -eq 'Consultar driver da fila remota'){$failure.DriverQueryCode=$infError.Code}
        }
        return $failure
    }
    if ((Get-Item -LiteralPath $packagePath).Length -gt 67108864) { throw 'Pacote maior que 64 MB.' }
    $localZip = Join-Path $stage 'package.zip'
    Set-DriverStage 'Copiar pacote pela rede'
    Copy-DriverSourceFile -Source $packagePath -Destination $localZip
    Set-DriverStage 'Conferir pacote recebido no cliente' -Resource $localZip
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
    if($DriverName -and $DriverName -ine $driverName){throw 'O nome do driver do pacote legado não corresponde ao solicitado.'}
    $existingDriver=Get-PrinterDriver -ErrorAction Stop | Where-Object { $_.Name -ieq $driverName -and $_.PrinterEnvironment -ieq $environment } | Select-Object -First 1
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
    if(-not('PrinterDriverTransfer' -as [type])){Add-Type -TypeDefinition $native -ErrorAction Stop}
    $legacyRegistration=Invoke-LegacyPrinterDriverRegistration -Manifest $manifest -Resolved $resolved -Environment $environment
    $legacyRegistration.PreparedPackageFound=$true
    $legacyRegistration.DriverAvailability=$(if($legacyRegistration.Success){'Confirmed'}else{'Unknown'})
    if($infError){
        $legacyRegistration.InfLookupCode=$infError.Code;$legacyRegistration.InfLookupStage=$infError.Stage
        $legacyRegistration.InfLookupResource=$infError.Resource
        if($infError.Stage -eq 'Consultar driver da fila remota'){$legacyRegistration.DriverQueryCode=$infError.Code}
    }
    return $legacyRegistration
} catch {
    $failure=Get-PrinterOperationFailure -Record $_ -Stage $script:driverOperationStage -Resource $script:driverOperationResource -Scope $script:driverOperationScope
    $failure.DriverAvailability='Unknown';$failure.PreparedPackageFound=$preparedPackageFound
    if($driverName){$failure.DriverName=$driverName}
    if($infError){
        $failure.InfLookupCode=$infError.Code;$failure.InfLookupStage=$infError.Stage
        $failure.InfLookupResource=$infError.Resource;$failure.InfLookupMessage=$infFailure
        if($infError.Stage -eq 'Consultar driver da fila remota'){$failure.DriverQueryCode=$infError.Code}
    }
    return $failure
} finally {
    if ($archive) { $archive.Dispose() }
    if ($stage -and $stage.StartsWith((Join-Path $env:TEMP 'PrinterDriverTransfer_'),[StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
}
