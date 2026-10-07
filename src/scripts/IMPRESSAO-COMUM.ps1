# Shared by the bounded workers. No UI and no credentials on disk.
function Get-PrinterOperationFailure {
    param([Management.Automation.ErrorRecord]$Record,[string]$Stage,[string]$Resource='',
        [ValidateSet('Remote','Local','Unknown')][string]$Scope='Local')
    $exception=$Record.Exception.GetBaseException()
    $code=0
    if($exception -is [ComponentModel.Win32Exception]){$code=$exception.NativeErrorCode}
    elseif($Record.FullyQualifiedErrorId -match '(?i)HRESULT\s+0x([0-9a-f]{8})'){$code=([Convert]::ToInt64($matches[1],16) -band 65535)}
    elseif($exception -is [UnauthorizedAccessException]){$code=5}
    elseif(([long]$exception.HResult -band 4294901760) -eq 2147942400){$code=([long]$exception.HResult -band 65535)}
    return @{Success=$false;Code=$(if($code){$code}else{31});NativeCode=$code;
        Stage=$Stage;Resource=$Resource;FailureScope=$Scope;ErrorId=[string]$Record.FullyQualifiedErrorId;
        HResult=('0x{0:X8}' -f ([long]$exception.HResult -band 4294967295));Message=$Record.Exception.Message;
        NeedsAuthentication=($Scope -eq 'Remote' -and $code -in @(5,86,1244,1326,1327,1328,1329,1330,1331,1385,1907,1909,2202))}
}
function Test-PrinterRemotePath {
    param([string]$Path,[switch]$Directory)
    # Exists/Test-Path can hide access errors as an absent package. Preserve them.
    try{$attributes=[IO.File]::GetAttributes($Path)}catch{
        $failure=Get-PrinterOperationFailure -Record $_ -Stage 'Ler caminho remoto' -Resource $Path -Scope Remote
        if($failure.NativeCode -in @(2,3)){return $false}
        throw
    }
    return (($attributes -band [IO.FileAttributes]::Directory) -ne 0) -eq [bool]$Directory
}
function Initialize-PrinterRemoteAccessApi {
    if('PrinterRemoteAccess' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class PrinterRemoteAccess {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct RESOURCE {
  public int Scope,Type,DisplayType,Usage;
  public string LocalName,RemoteName,Comment,Provider;
 }
 [DllImport("mpr.dll",CharSet=CharSet.Unicode)] static extern int WNetAddConnection2W(ref RESOURCE resource,string password,string user,int flags);
 [DllImport("winspool.drv",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool OpenPrinterW(string name,out IntPtr handle,IntPtr defaults);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool ClosePrinter(IntPtr handle);
 [DllImport("Netapi32.dll",CharSet=CharSet.Unicode)] static extern int NetShareGetInfo(string server,string share,int level,out IntPtr buffer);
 [DllImport("Netapi32.dll")] static extern int NetApiBufferFree(IntPtr buffer);
 public static int Connect(string server){var resource=new RESOURCE();resource.RemoteName="\\\\"+server+"\\IPC$";return WNetAddConnection2W(ref resource,null,null,0);}
 public static int Queue(string path){IntPtr handle; if(!OpenPrinterW(path,out handle,IntPtr.Zero))return Marshal.GetLastWin32Error();try{return 0;}finally{ClosePrinter(handle);}}
 public static int PrintShare(string server,string share){IntPtr buffer=IntPtr.Zero;try{int code=NetShareGetInfo("\\\\"+server,share,1,out buffer);if(code!=0)return code;return (Marshal.ReadInt32(buffer,IntPtr.Size)&0xffff)==2?0:67;}finally{if(buffer!=IntPtr.Zero)NetApiBufferFree(buffer);}}
}
'@ -ErrorAction Stop
}
function Test-PrinterRemoteQueueAccess {
    param([string]$UNCPath)
    Initialize-PrinterRemoteAccessApi
    return [PrinterRemoteAccess]::Queue($UNCPath)
}
function Test-PrinterNetworkSession {
    param([string]$Server)
    Initialize-PrinterRemoteAccessApi
    $code=[PrinterRemoteAccess]::Connect($Server)
    return @{Success=($code -eq 0);Code=$code;NativeCode=$code;Stage='Autenticar sessão de rede';
        Resource=('\\'+$Server+'\IPC$');FailureScope='Remote';
        NeedsAuthentication=($code -in @(5,86,1244,1326,1327,1328,1329,1330,1331,1385,1907,1909,2202));
        Message=$(if($code -eq 0){'Sessão de rede estabelecida; o acesso à fila e ao pacote ainda será validado.'}else{'O servidor recusou a sessão de rede: '+([ComponentModel.Win32Exception]::new($code).Message)+' (código '+$code+').'})}
}
function Test-PrinterSharedQueueExists {
    param([string]$Server,[string]$ShareName)
    Initialize-PrinterRemoteAccessApi
    return [PrinterRemoteAccess]::PrintShare($Server,$ShareName)
}
function Resolve-PrinterCredentialRecovery {
    param([System.Collections.IDictionary]$Failure,[string]$Server,[string]$ShareName,
        [int]$NativeConnectionCode=0,[switch]$HasNetworkCredential)
    if($Failure.Success -or $Failure.QueueInstalled -or $Failure.Cancelled -or $Failure.TimedOut){return $Failure}
    if($Failure.NeedsAuthentication){$Failure.RecoveryReason='RemoteAccessRefused';return $Failure}
    if($Failure.CredentialRetryRecommended){return $Failure}
    if($Failure.FailureScope -eq 'Local' -and $Failure.Code -in @(32,33)){
        $Failure.RecoveryReason='LocalDriverFileInUse'
        return $Failure
    }
    if($Failure.Contains('ShareLookupCode') -or $Failure.Contains('ShareLookupMessage')){return $Failure}
    $portDenied=$Failure.Code -eq 5 -and $Failure.Stage -in @('Criar porta local UNC','Validar e criar porta UNC no monitor local do Windows')
    $hasQueueProbe=$Failure.Contains('RemoteAccessCode')
    if($portDenied -and $hasQueueProbe -and $Failure.RemoteAccessCode -eq 0){
        $Failure.RecoveryReason='LocalPortDeniedRemoteQueueAccessible'
        return $Failure
    }
    if($Failure.FailureScope -eq 'Local' -and $Failure.Code -eq 5 -and -not $portDenied){
        $Failure.RecoveryReason='LocalOperationDenied'
        return $Failure
    }
    $ambiguousPort=$portDenied -and (($hasQueueProbe -and $Failure.RemoteAccessCode -in @(1801,283,3019)) -or
        (-not $hasQueueProbe -and $Failure.FailureScope -eq 'Unknown'))
    if(($portDenied -and -not $ambiguousPort) -or
        (-not $ambiguousPort -and $NativeConnectionCode -notin @(1801,283,3019))){return $Failure}
    if($HasNetworkCredential){$Failure.RecoveryReason='NetworkCredentialAlreadySupplied';return $Failure}
    try{
        $shareCode=Test-PrinterSharedQueueExists -Server $Server -ShareName $ShareName
        $Failure.ShareLookupCode=$shareCode
        if($shareCode -eq 0){
            $Failure.CredentialRetryRecommended=$true
            $Failure.RecoveryReason='PrintShareConfirmedRemoteAccessUnverified'
            $Failure.ConfirmedUNC='\\'+$Server+'\'+$ShareName
            if($NativeConnectionCode){$Failure.NativeConnectionCode=$NativeConnectionCode}
            if($portDenied){$Failure.FailureScope='Unknown'}
        }elseif($shareCode -in @(5,86,1244,1326,1327,1328,1329,1330,1331,1385,1907,1909,2202)){
            # Keep the installation code/stage; this is a separate access probe.
            $Failure.NeedsAuthentication=$true;$Failure.AuthenticationCode=$shareCode
            $Failure.RecoveryReason='PrintShareLookupRefused';$Failure.FailureScope='Remote'
        }elseif($shareCode -in @(67,2310)){
            $Failure.RecoveryReason='PrintShareNotFound'
            $Failure.Message+=' O compartilhamento de impressão informado não foi encontrado. Confira o nome de compartilhamento no computador servidor.'
        }else{$Failure.RecoveryReason='PrintShareLookupInconclusive'}
    }catch{
        $Failure.ShareLookupMessage=$_.Exception.Message
        $Failure.RecoveryReason='PrintShareLookupFailed'
    }
    return $Failure
}
function Test-PrinterDriverResourceAccess {
    param([string]$Resource)
    $stream=$null
    try{
        $attributes=[IO.File]::GetAttributes($Resource)
        if($attributes -band [IO.FileAttributes]::Directory){
            # Enumerate at least once: metadata lookup alone is not read permission.
            $iterator=[IO.Directory]::EnumerateFileSystemEntries($Resource).GetEnumerator()
            try{[void]$iterator.MoveNext()}finally{if($iterator -is [IDisposable]){$iterator.Dispose()}}
        }else{$stream=[IO.File]::OpenRead($Resource);[void]$stream.ReadByte()}
        return @{Success=$true;Code=0;Resource=$Resource;Stage='Conferir leitura do driver remoto';Message='Leitura do recurso remoto confirmada; a instalação ainda será validada.'}
    }catch{
        $failure=Get-PrinterOperationFailure -Record $_ -Stage 'Conferir leitura do driver remoto' -Resource $Resource -Scope Remote
        # A missing file is not an authentication refusal. Let the operation report it.
        if($failure.NativeCode -in @(2,3)){return @{Success=$true;Code=0;Message='Sessão estabelecida; o pacote solicitado não foi encontrado e será verificado na operação.'}}
        return $failure
    }finally{if($stream){$stream.Dispose()}}
}
function Resolve-PrinterUNC {
    param([string]$UNCPath,[string]$Server,[string]$ShareName)
    if ($UNCPath) {
        if ($UNCPath -notmatch '^\\\\([^\\/\x00-\x1f"]+)\\([^\\/\x00-\x1f"]+)$') { throw 'Use \\SERVIDOR\Compartilhamento.' }
        if (($Server -and $Server -ine $matches[1]) -or ($ShareName -and $ShareName -ine $matches[2])) { throw 'Servidor/compartilhamento não correspondem ao UNC.' }
        $Server=$matches[1]; $ShareName=$matches[2]
    }
    if (-not $Server -or -not $ShareName -or $Server -match '[\\/\x00-\x1f"]' -or $ShareName -match '[\\/\x00-\x1f"]') { throw 'Servidor e compartilhamento inválidos.' }
    return @{ Server=$Server; ShareName=$ShareName; UNCPath=('\\'+$Server+'\'+$ShareName) }
}
function Assert-PrinterAdmin {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Abra o executável como administrador para aplicar políticas e instalar drivers.' }
}
function Wait-ExactPrinter {
    param([string]$UNCPath,[string]$QueueName='',[string]$DriverName='', [int]$Seconds=10)
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do {
        $printer=Get-Printer -ErrorAction Stop | Where-Object {
            if ($QueueName) { $_.Name -ieq $QueueName -and $_.PortName -ieq $UNCPath -and $_.DriverName -ieq $DriverName }
            else { $_.Name -ieq $UNCPath -or ([string]$_.ComputerName).TrimStart('\') -ieq ((Resolve-PrinterUNC $UNCPath).Server) -and $_.ShareName -ieq ((Resolve-PrinterUNC $UNCPath).ShareName) }
        } | Select-Object -First 1
        if ($printer) { return $printer }
        if ($clock.Elapsed.TotalSeconds -ge $Seconds) { break }
        Start-Sleep -Milliseconds 250
    } while ($true)
    return $null
}
function Get-PrinterCompatibilityPolicyEntries {
    param([ValidateSet('Host','Client')][string]$Role)
    $plan=@()
    if ($Role -eq 'Host') {
        foreach($entry in @(@('RpcUseNamedPipeProtocol',1),@('RpcProtocols',7),@('RpcOverNamedPipesAuthLevel',1))) {
            $plan+=@{Path='SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC';Name=$entry[0];Value=$entry[1]}
        }
        $plan+=@{Path='SYSTEM\CurrentControlSet\Control\Print';Name='RpcAuthnLevelPrivacyEnabled';Value=0}
    } else {
        foreach($entry in @(@('RestrictDriverInstallationToAdministrators',0),@('NoWarningNoElevationOnInstall',1),@('UpdatePromptSettings',2))) {
            $plan+=@{Path='SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint';Name=$entry[0];Value=$entry[1]}
        }
        $plan+=@{Path='SYSTEM\CurrentControlSet\Services\LanmanWorkstation\Parameters';Name='AllowInsecureGuestAuth';Value=1}
    }
    return $plan
}
function Test-PrinterLocalSMBListener {
    $client=[Net.Sockets.TcpClient]::new();$pending=$null
    try{
        $pending=$client.BeginConnect('127.0.0.1',445,$null,$null)
        if(-not $pending.AsyncWaitHandle.WaitOne(1500)){return $false}
        $client.EndConnect($pending)
        return $true
    }catch{return $false}finally{if($pending){$pending.AsyncWaitHandle.Close()};$client.Close()}
}
function Enable-PrinterHostNetworkAccess {
    Assert-PrinterAdmin
    $changedAdapters=@()
    foreach($binding in @(Get-NetAdapterBinding -ComponentID ms_server -ErrorAction Stop | Where-Object { -not $_.Enabled })){
        $adapter=Get-NetAdapter -Name $binding.Name -ErrorAction SilentlyContinue
        if($adapter.Status -eq 'Up'){
            Enable-NetAdapterBinding -Name $binding.Name -ComponentID ms_server -ErrorAction Stop | Out-Null
            $changedAdapters+=$binding.Name
        }
    }
    $service=Get-Service LanmanServer -ErrorAction Stop
    Set-Service LanmanServer -StartupType Automatic -ErrorAction Stop
    if($service.Status -ne 'Running'){Start-Service LanmanServer -ErrorAction Stop}
    (Get-Service LanmanServer).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    $rules=@(
        @{Name='AssistenteImpressoras-SMB-In';DisplayName='Assistente de Impressoras - compartilhamento SMB';Port='445';Program='Any'},
        @{Name='AssistenteImpressoras-RPC-In';DisplayName='Assistente de Impressoras - endpoint RPC';Port='135';Program='Any'},
        @{Name='AssistenteImpressoras-Spooler-In';DisplayName='Assistente de Impressoras - RPC do Spooler';Port='RPC';Program=(Join-Path $env:WINDIR 'System32\spoolsv.exe')}
    )
    foreach($rule in $rules){
        $ruleParameters=@{Direction='Inbound';Action='Allow';Enabled='True';Profile='Any';Protocol='TCP';LocalPort=$rule.Port;Program=$rule.Program;RemoteAddress='Any';ErrorAction='Stop'}
        $existing=Get-NetFirewallRule -Name $rule.Name -ErrorAction SilentlyContinue
        if($existing){Set-NetFirewallRule -Name $rule.Name @ruleParameters | Out-Null}
        else{New-NetFirewallRule -Name $rule.Name -DisplayName $rule.DisplayName @ruleParameters | Out-Null}
        $verified=Get-NetFirewallRule -Name $rule.Name -ErrorAction Stop
        if([string]$verified.Enabled -ne 'True' -or [string]$verified.Action -ne 'Allow'){throw 'Regra de compartilhamento não foi confirmada: '+$rule.Name}
    }
    if(-not(Test-PrinterLocalSMBListener)){throw 'O serviço SMB não abriu a porta 445 neste PC. Confira o serviço Servidor e o vínculo de compartilhamento no adaptador.'}
    return @{Success=$true;EnabledAdapters=$changedAdapters;Message='Serviço Servidor, vínculo de compartilhamento e regras SMB/RPC preparados. A porta 445 local respondeu; o acesso a partir do outro PC ainda precisa ser conferido.'}
}
function Get-PrinterPolicyValue {
    param([string]$Path,[string]$Name)
    $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($Path,$false)
    try{
        $exists=$key -and $key.GetValueNames() -contains $Name
        return @{Path=$Path;Name=$Name;Exists=[bool]$exists;Value=$(if($exists){$key.GetValue($Name)}else{$null});Kind=$(if($exists){$key.GetValueKind($Name).ToString()}else{''})}
    }finally{if($key){$key.Close()}}
}
function Set-PrinterPolicyValue {
    param($State)
    if($State.Exists){
        $key=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($State.Path)
        try{$kind=[Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind],[string]$State.Kind);$key.SetValue($State.Name,$State.Value,$kind)}finally{$key.Close()}
    }else{
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($State.Path,$true)
        try{if($key){$key.DeleteValue($State.Name,$false)}}finally{if($key){$key.Close()}}
    }
}
function Restore-PrinterCompatibilityPolicies {
    param([ValidateSet('Host','Client')][string]$Role,[string]$StateDirectory='')
    Assert-PrinterAdmin
    if(-not $StateDirectory){$StateDirectory=Join-Path $env:LOCALAPPDATA 'AssistenteImpressoras\Politicas'}
    $plan=@(Get-PrinterCompatibilityPolicyEntries -Role $Role)
    $snapshots=@()
    foreach($file in @(Get-ChildItem -LiteralPath $StateDirectory -Filter ('Politicas_'+$Role+'_*.clixml') -File -ErrorAction SilentlyContinue)){
        try{
            $state=Import-Clixml -LiteralPath $file.FullName -ErrorAction Stop
            if($state.Role -ne $Role -or @($state.Values).Count -ne $plan.Count){Write-Verbose ('Cópia incompleta em '+$file.Name+'; papel='+$state.Role+'; valores='+@($state.Values).Count+'; esperados='+$plan.Count);continue}
            $seen=@();$valid=$true
            foreach($value in @($state.Values)){
                $entry=@($plan | Where-Object { $_.Path -ieq $value.Path -and $_.Name -ieq $value.Name })
                $id=[string]$value.Path+'|'+[string]$value.Name
                if($entry.Count -ne 1 -or $seen -icontains $id -or
                    ($value.Exists -and $value.Kind -notin @('DWord','QWord','String','ExpandString','Binary','MultiString'))){Write-Verbose ('Entrada inválida em '+$file.Name+': '+$id+'; correspondências='+$entry.Count+'; existe='+$value.Exists+'; tipo='+$value.Kind);$valid=$false;break}
                $seen+=$id
            }
            if($valid){Write-Verbose ('Cópia válida: '+$file.Name+'; data='+$state.Time);$snapshots+=@{State=$state;Path=$file.FullName;Time=[DateTime]$state.Time}}
        }catch{Write-Verbose ('Cópia de políticas ignorada: '+$file.Name+'; '+$_.Exception.Message)}
    }
    $snapshot=$snapshots | Sort-Object { $_['Time'].Ticks } | Select-Object -First 1
    if(-not $snapshot){throw 'Não há cópia anterior válida das políticas deste EXE neste usuário. Nenhuma configuração foi alterada.'}
    $before=@();$changes=@();$skipped=0
    foreach($original in @($snapshot.State.Values)){
        $current=Get-PrinterPolicyValue -Path $original.Path -Name $original.Name
        $before+=$current
        if($current.Exists -eq $original.Exists -and (-not $current.Exists -or
            ($current.Kind -eq $original.Kind -and ($current.Value -join '|') -eq ($original.Value -join '|')))){continue}
        $applied=$plan | Where-Object { $_.Path -ieq $original.Path -and $_.Name -ieq $original.Name } | Select-Object -First 1
        if(-not $current.Exists -or $current.Kind -ne 'DWord' -or $current.Value -ne $applied.Value){$skipped++;continue}
        $changes+=$original
    }
    $backup=''
    if($changes.Count){
        $backup=Join-Path $StateDirectory ('AntesRestauracao_'+$Role+'_'+[Guid]::NewGuid().ToString('N')+'.clixml')
        @{Role=$Role;Values=$before;Time=(Get-Date)} | Export-Clixml -LiteralPath $backup -Force
        foreach($value in $changes){
            Set-PrinterPolicyValue -State $value
            $confirmed=Get-PrinterPolicyValue -Path $value.Path -Name $value.Name
            if($confirmed.Exists -ne $value.Exists -or ($value.Exists -and
                ($confirmed.Kind -ne $value.Kind -or ($confirmed.Value -join '|') -ne ($value.Value -join '|')))){throw 'O Windows não confirmou a restauração. Estado antes da operação: '+$backup}
        }
        if((Get-Service Spooler).Status -eq 'Running'){Restart-Service Spooler -Force -ErrorAction Stop}else{Start-Service Spooler -ErrorAction Stop}
        (Get-Service Spooler).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    }
    return @{Success=$true;Restored=$changes.Count;Skipped=$skipped;SnapshotPath=$snapshot.Path;StatePath=$backup;
        Message="Políticas restauradas: $($changes.Count). Valores alterados depois por outra configuração e preservados: $skipped. Cópia utilizada: $($snapshot.Path). Filas, drivers e permissões de compartilhamento não são removidos."}
}
function Set-PrinterCompatibilityPolicies {
    param([ValidateSet('Host','Client')][string]$Role,[string]$StateDirectory)
    Assert-PrinterAdmin
    $plan=@(Get-PrinterCompatibilityPolicyEntries -Role $Role)
    if(-not $StateDirectory){$StateDirectory=Join-Path $env:LOCALAPPDATA 'AssistenteImpressoras\Politicas'}
    [void][IO.Directory]::CreateDirectory($StateDirectory)
    $previous=@(); $changed=$false
    foreach($item in $plan){
        $key=[Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($item.Path,$false)
        try {
            $exists=$key -and $key.GetValueNames() -contains $item.Name
            $value=if($exists){$key.GetValue($item.Name)}else{$null}
            $previous+=@{Path=$item.Path;Name=$item.Name;Exists=[bool]$exists;Value=$value;Kind=$(if($exists){$key.GetValueKind($item.Name).ToString()}else{''})}
            if(-not $exists -or $value -ne $item.Value){$changed=$true}
        }finally{if($key){$key.Close()}}
    }
    $statePath=Join-Path $StateDirectory ('Politicas_'+$Role+'_'+[Guid]::NewGuid().ToString('N')+'.clixml')
    # Save before the first mutation, even if a later registry operation fails.
    @{Role=$Role;Values=$previous;Time=(Get-Date)} | Export-Clixml -LiteralPath $statePath -Force
    foreach($item in $plan){
        $key=[Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($item.Path)
        try {$key.SetValue($item.Name,[int]$item.Value,[Microsoft.Win32.RegistryValueKind]::DWord); if($key.GetValue($item.Name) -ne $item.Value){throw 'Política não confirmada no Registro.'}}finally{$key.Close()}
    }
    if($Role -eq 'Host'){
        $printShare=Get-SmbShare -Name 'print$' -ErrorAction Stop
        $readers=([Security.Principal.SecurityIdentifier]'S-1-5-11').Translate([Security.Principal.NTAccount]).Value
        # Authenticated Users; never grant network write access to print$.
        Grant-SmbShareAccess -Name 'print$' -AccountName $readers -AccessRight Read -Force -ErrorAction Stop | Out-Null
        $acl=Get-Acl -LiteralPath $printShare.Path
        $rule=New-Object Security.AccessControl.FileSystemAccessRule($readers,'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule); Set-Acl -LiteralPath $printShare.Path -AclObject $acl -ErrorAction Stop
    }
    # Restart once per preparation, even if values match: the running Spooler
    # might still have cached settings from before a previous registry edit.
    if((Get-Service Spooler).Status -eq 'Running'){Restart-Service Spooler -Force -ErrorAction Stop}else{Start-Service Spooler -ErrorAction Stop}
    (Get-Service Spooler).WaitForStatus('Running',[TimeSpan]::FromSeconds(20))
    return @{Success=$true;Role=$Role;Changed=$changed;StatePath=$statePath;Message='Políticas aplicadas e verificadas no computador local.'}
}
function Invoke-PrinterPnPProcess {
    param([string]$InfPath,[int]$Build)
    if($Build -ge 14393){$lines=& "$env:WINDIR\System32\pnputil.exe" /add-driver $InfPath /install 2>&1}
    else{$lines=& "$env:WINDIR\System32\pnputil.exe" -i -a $InfPath 2>&1}
    return @{Code=$LASTEXITCODE;Output=@($lines | ForEach-Object { [string]$_ })}
}
function Invoke-PrinterPnPInstall {
    param([string]$Directory,[string]$DriverName,[string]$InfName='')
    Assert-PrinterAdmin
    $infs=@(Get-ChildItem -LiteralPath $Directory -Filter '*.inf' -Recurse -File -ErrorAction Stop)
    if($InfName){$infs=@($infs | Where-Object Name -ieq $InfName)}
    if(-not $infs.Count){throw 'O servidor não forneceu INF. Arquivos DLL/GPD isolados não são um pacote PnP.'}
    $build=[int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
    $output=@();$reboot=$false
    foreach($inf in $infs){
        # /add-driver and /install exist from Windows 10 1607; older builds use legacy flags.
        $processed=Invoke-PrinterPnPProcess -InfPath $inf.FullName -Build $build
        $code=$processed.Code; $lines=$processed.Output; $output+=@($lines)
        if($code -notin @(0,3010)){throw "PnPUtil recusou o pacote (código $code): $($lines -join ' ')"}
        if($code -eq 3010){$reboot=$true}
        $storeInf=$null
        if(Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue){
            $hash=(Get-FileHash -LiteralPath $inf.FullName -Algorithm SHA256).Hash
            $packages=Get-WindowsDriver -Online -All -ErrorAction Stop | Where-Object { [IO.Path]::GetFileName($_.OriginalFileName) -ieq $inf.Name }
            foreach($package in $packages){
                if(Test-Path -LiteralPath $package.OriginalFileName -PathType Leaf){
                    if((Get-FileHash -LiteralPath $package.OriginalFileName -Algorithm SHA256).Hash -ieq $hash){$storeInf=$package.OriginalFileName;break}
                }
            }
        }
        if($storeInf){Add-PrinterDriver -Name $DriverName -InfPath $storeInf -ErrorAction Stop}
        else{Add-PrinterDriver -Name $DriverName -ErrorAction Stop}
        if(Get-PrinterDriver -Name $DriverName -ErrorAction SilentlyContinue){break}
    }
    $driver=Get-PrinterDriver -Name $DriverName -ErrorAction Stop
    if(-not $driver){throw 'O pacote foi processado, mas o nome exato do driver não foi registrado.'}
    return @{Success=$true;DriverName=$driver.Name;MajorVersion=$driver.MajorVersion;RebootRequired=$reboot;Message="Driver '$DriverName' confirmado no Spooler.";PnPOutput=($output -join "`n")}
}
function Submit-PrinterValidationPage {
    param([string]$QueueName,[string]$DocumentName=('Assistente - teste '+[Guid]::NewGuid().ToString('N')))
    if(-not ('PrinterValidationGdi' -as [type])){
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class PrinterValidationGdi {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] struct DOCINFO {public int cbSize;public string name,output,datatype;public int type;}
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern IntPtr CreateDCW(string driver,string device,string output,IntPtr mode);
 [DllImport("gdi32.dll",SetLastError=true)] static extern bool DeleteDC(IntPtr dc);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern int StartDocW(IntPtr dc,ref DOCINFO info);
 [DllImport("gdi32.dll",SetLastError=true)] static extern int StartPage(IntPtr dc);
 [DllImport("gdi32.dll",SetLastError=true)] static extern int EndPage(IntPtr dc);
 [DllImport("gdi32.dll",SetLastError=true)] static extern int EndDoc(IntPtr dc);
 [DllImport("gdi32.dll",SetLastError=true)] static extern int AbortDoc(IntPtr dc);
 [DllImport("gdi32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool TextOutW(IntPtr dc,int x,int y,string text,int length);
 static void Check(int status){if(status<=0)throw new Win32Exception(Marshal.GetLastWin32Error(),"O driver recusou a página de validação.");}
 public static int Send(string queue,string document){IntPtr dc=CreateDCW("WINSPOOL",queue,null,IntPtr.Zero);if(dc==IntPtr.Zero)throw new Win32Exception(Marshal.GetLastWin32Error());bool active=false;
  try{var info=new DOCINFO();info.cbSize=Marshal.SizeOf(info);info.name=document;int id=StartDocW(dc,ref info);Check(id);active=true;Check(StartPage(dc));string text="Teste de impressao - Assistente de Impressoras";
   if(!TextOutW(dc,10,10,text,text.Length))throw new Win32Exception(Marshal.GetLastWin32Error());Check(EndPage(dc));Check(EndDoc(dc));active=false;return id;
  }finally{if(active)AbortDoc(dc);DeleteDC(dc);}
 }
}
'@ -ErrorAction Stop
    }
    return [PrinterValidationGdi]::Send($QueueName,$DocumentName)
}
function Initialize-PrinterJobNative {
    if('PrinterJobNative' -as [type]){return}
    Add-Type -TypeDefinition @'
using System;using System.Collections.Generic;using System.ComponentModel;using System.Runtime.InteropServices;
public static class PrinterJobNative {
 [StructLayout(LayoutKind.Sequential,CharSet=CharSet.Unicode)] public struct DOC { public string Name,Output,DataType; }
 [StructLayout(LayoutKind.Sequential)] public struct TIME { public ushort Year,Month,DayOfWeek,Day,Hour,Minute,Second,Milliseconds; }
 [StructLayout(LayoutKind.Sequential)] struct JOB { public uint Id;public IntPtr Printer,Machine,User,Document,DataType,TextStatus;public uint Status,Priority,Position,TotalPages,PagesPrinted;public TIME Submitted; }
 public sealed class Observation { public int Id;public string Document,Owner,StatusText;public uint Status; }
 [DllImport("winspool.drv",EntryPoint="OpenPrinterW",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool Open(string name,out IntPtr handle,IntPtr defaults);
 [DllImport("winspool.drv",EntryPoint="ClosePrinter",SetLastError=true)] static extern bool Close(IntPtr handle);
 [DllImport("winspool.drv",EntryPoint="StartDocPrinterW",CharSet=CharSet.Unicode,SetLastError=true)] static extern uint Start(IntPtr handle,uint level,ref DOC doc);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool StartPagePrinter(IntPtr handle);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool EndPagePrinter(IntPtr handle);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool EndDocPrinter(IntPtr handle);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool AbortPrinter(IntPtr handle);
 [DllImport("winspool.drv",SetLastError=true)] static extern bool WritePrinter(IntPtr handle,byte[] data,uint count,out uint written);
 [DllImport("winspool.drv",EntryPoint="EnumJobsW",SetLastError=true)] static extern bool Enum(IntPtr handle,uint first,uint count,uint level,IntPtr buffer,uint size,out uint needed,out uint returned);
 static void Check(bool ok){if(!ok)throw new Win32Exception(Marshal.GetLastWin32Error());}
 public static int SendRaw(string queue,string name,byte[] bytes){IntPtr h;Check(Open(queue,out h,IntPtr.Zero));bool active=false;
  try{DOC d=new DOC();d.Name=name;d.DataType="RAW";uint id=Start(h,1,ref d);if(id==0)throw new Win32Exception(Marshal.GetLastWin32Error());active=true;Check(StartPagePrinter(h));uint written;Check(WritePrinter(h,bytes,(uint)bytes.Length,out written));if(written!=(uint)bytes.Length)throw new Win32Exception(29,"Envio RAW incompleto.");Check(EndPagePrinter(h));Check(EndDocPrinter(h));active=false;return checked((int)id);}finally{if(active)AbortPrinter(h);Close(h);}}
 public static Observation[] Find(string path,string document){IntPtr h;Check(Open(path,out h,IntPtr.Zero));IntPtr buffer=IntPtr.Zero;
  try{uint needed,count;bool ok=Enum(h,0,512,1,IntPtr.Zero,0,out needed,out count);if(!ok&&Marshal.GetLastWin32Error()!=122)throw new Win32Exception(Marshal.GetLastWin32Error());if(needed==0)return new Observation[0];if(needed>4194304)throw new Win32Exception(8);buffer=Marshal.AllocHGlobal(checked((int)needed));Check(Enum(h,0,512,1,buffer,needed,out needed,out count));var result=new List<Observation>();int size=Marshal.SizeOf(typeof(JOB));for(uint i=0;i<count;i++){JOB j=(JOB)Marshal.PtrToStructure(IntPtr.Add(buffer,checked((int)i*size)),typeof(JOB));string name=Marshal.PtrToStringUni(j.Document);if(String.Equals(name,document,StringComparison.Ordinal)){var o=new Observation();o.Id=checked((int)j.Id);o.Document=name;o.Owner=Marshal.PtrToStringUni(j.User);o.Status=j.Status;o.StatusText=Marshal.PtrToStringUni(j.TextStatus);result.Add(o);}}return result.ToArray();}finally{if(buffer!=IntPtr.Zero)Marshal.FreeHGlobal(buffer);Close(h);}}
}
'@ -ErrorAction Stop
}
function Get-PrinterRemoteJobObservation {
    param([string]$UNCPath,[string]$DocumentName,[int]$TimeoutMilliseconds=6500)
    if($UNCPath -notmatch '^\\\\[^\\]+\\[^\\]+$'){return @{Status='NotApplicable';Observed=$false}}
    $root=Join-Path $env:TEMP ('PrinterJobProbe_'+[Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root);$process=$null
    try{
        $request=Join-Path $root 'request.xml';$answer=Join-Path $root 'answer.xml';$worker=Join-Path $root 'probe.ps1'
        @{UNCPath=$UNCPath;DocumentName=$DocumentName;CommonPath=(Join-Path $PSScriptRoot 'IMPRESSAO-COMUM.ps1');Answer=$answer}|Export-Clixml -LiteralPath $request
        [IO.File]::WriteAllText($worker,@'
param([string]$RequestPath)
$r=Import-Clixml -LiteralPath $RequestPath
try{. $r.CommonPath;Initialize-PrinterJobNative;$jobs=@([PrinterJobNative]::Find($r.UNCPath,$r.DocumentName));$result=@{Status='Queried';Observed=($jobs.Count -gt 0);Jobs=@($jobs|ForEach-Object {@{JobId=$_.Id;DocumentName=$_.Document;Owner=$_.Owner;Status=$_.Status;StatusText=$_.StatusText}})}}catch{$result=@{Status='Unavailable';Observed=$false;Code=$_.Exception.GetBaseException().NativeErrorCode;Message=$_.Exception.GetBaseException().Message}}
$result|Export-Clixml -LiteralPath $r.Answer
'@,[Text.UTF8Encoding]::new($true))
        $process=Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$worker+'" -RequestPath "'+$request+'"') -WindowStyle Hidden -PassThru -ErrorAction Stop
        if(-not $process.WaitForExit($TimeoutMilliseconds)){$process.Kill();[void]$process.WaitForExit(1500);return @{Status='TimedOut';Observed=$false;Message='Consulta ao servidor excedeu o prazo; recebimento inconclusivo.'}}
        if(-not(Test-Path -LiteralPath $answer)){return @{Status='Unavailable';Observed=$false;Message='Consulta sem resultado.'}}
        return (Import-Clixml -LiteralPath $answer)
    }catch{return @{Status='Unavailable';Observed=$false;Message=$_.Exception.Message}}
    finally{if($process){$process.Dispose()};if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
}
function Save-PrinterWorkerResult {
    param([Collections.IDictionary]$Result,[string]$Path)
    $temporary=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    try{
        $Result|Export-Clixml -LiteralPath $temporary -Force -ErrorAction Stop
        if(Test-Path -LiteralPath $Path){[IO.File]::Replace($temporary,$Path,$null)}else{[IO.File]::Move($temporary,$Path)}
    }finally{Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue}
}
function Test-PrinterJobDelivery {
    param([string]$QueueName,[int]$Seconds=10,[string]$UNCPath='',[int]$JobId=0,[string]$DocumentName='',
        [byte[]]$RawBytes,[string]$CheckpointPath='')
    if(-not $DocumentName){$DocumentName='Assistente - teste '+[Guid]::NewGuid().ToString('N')}
    $submitted=Get-Date
    if($JobId -le 0){
        if($RawBytes){Initialize-PrinterJobNative;$JobId=[PrinterJobNative]::SendRaw($QueueName,$DocumentName,$RawBytes)}
        else{$JobId=Submit-PrinterValidationPage -QueueName $QueueName -DocumentName $DocumentName}
    }
    if($JobId -le 0){throw 'Nenhum JobId foi retornado pelo Spooler.'}
    $result=@{Success=$true;QueueInstalled=$true;QueueName=$QueueName;PortUNC=$UNCPath;JobId=$JobId;DocumentName=$DocumentName;SubmittedAt=$submitted.ToString('o');
        JobAccepted=$true;JobValidated=$false;JobValidationAttempted=$true;JobObserved=$false;PhysicalPrintConfirmed=$false;
        ServerJobObserved=$false;ServerObservation='NotApplicable';JobState='Accepted';Message='Documento aceito pelo Spooler; entrega ainda não confirmada.'}
    if($CheckpointPath){Save-PrinterWorkerResult -Result $result -Path $CheckpointPath}
    $clock=[Diagnostics.Stopwatch]::StartNew();$jobs=@();$localAbsent=$false
    try{
        do{
            $jobs=@(Get-PrintJob -PrinterName $QueueName -ErrorAction Stop)
            $job=$jobs|Where-Object ID -eq $JobId|Select-Object -First 1
            if(-not $job){$localAbsent=$true;break}
            $result.JobObserved=$true;$result.JobStatus=[string]$job.JobStatus
            if($result.JobStatus -match 'Error|Retry|Offline|PaperOut|Blocked|Delet'){$result.Success=$false;$result.JobState='Error';$result.Message="Documento $JobId com estado $($job.JobStatus); não reenviado.";break}
            if($clock.Elapsed.TotalSeconds -ge $Seconds){$result.Success=$false;$result.Pending=$true;$result.JobState='Pending';$result.Message="Documento $JobId permanece na fila do cliente; não reenviado.";break}
            Start-Sleep -Milliseconds 250
        }while($true)
        $result.QueueClean=($jobs.Count -eq 0)
        if($localAbsent){$result.JobValidated=[bool]$result.JobObserved;$result.JobState=if($result.JobObserved){'LeftClientQueue'}else{'AcceptedNotObserved'};$result.Message=if($result.JobObserved){'Documento deixou a fila do cliente. Isso não confirma recebimento no servidor nem saída no papel.'}else{'Spooler aceitou o documento, mas ele não foi observado na consulta. Entrega inconclusiva.'}}
    }catch{$result.Success=$false;$result.JobState='ObservationUnavailable';$result.Message='Documento aceito; consulta da fila indisponível: '+$_.Exception.Message}
    if(-not $UNCPath -and $QueueName -match '^\\\\'){$UNCPath=$QueueName}
    if($UNCPath){
        $remote=Get-PrinterRemoteJobObservation -UNCPath $UNCPath -DocumentName $DocumentName
        $result.ServerObservation=$remote.Status;$result.ServerJobObserved=[bool]$remote.Observed;$result.ServerJobs=@($remote.Jobs)
        if($remote.Code){$result.ServerObservationCode=$remote.Code}
        if($remote.Observed){
            $result.Message+=' Documento observado no servidor.'
            if(@($remote.Jobs|Where-Object {([int]$_.Status -band 0x767) -ne 0}).Count){$result.Success=$false;$result.JobState='ServerError';$result.Message+=' Servidor informa erro, pausa, exclusão ou intervenção.'}
        }elseif($remote.Status -eq 'Queried'){$result.Message+=' Documento não observado no servidor nessa consulta.'}
        elseif($remote.Status -ne 'NotApplicable'){$result.Message+=' Consulta ao servidor indisponível; recebimento inconclusivo.'}
    }
    return $result
}
