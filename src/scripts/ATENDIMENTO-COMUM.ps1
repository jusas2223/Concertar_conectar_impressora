# Serviços de atendimento. Sem consultas ou alterações ao carregar o arquivo.
function Test-PrinterIPv4 {
    param([string]$Address)
    $parts=$Address.Split('.')
    if($parts.Count -ne 4){return $false}
    foreach($part in $parts){if($part -notmatch '^\d{1,3}$' -or [int]$part -gt 255){return $false}}
    $parsed=$null
    return ([Net.IPAddress]::TryParse($Address,[ref]$parsed) -and $parsed.AddressFamily -eq 'InterNetwork')
}
function Get-ExactSupportPrinter {
    param([string]$Name)
    return (Get-Printer -ErrorAction Stop|Where-Object Name -ieq $Name|Select-Object -First 1)
}
function Test-SupportTcpPortConfiguration {
    param($Port,[string]$IPAddress,[int]$PortNumber,[string]$Protocol,[string]$LprQueue)
    if(-not $Port){return $false}
    if([string]$Port.HostAddress -ine $IPAddress -or [int]$Port.Protocol -ne $(if($Protocol -eq 'LPR'){2}else{1})){return $false}
    if($Protocol -eq 'LPR'){return ([string]$Port.Queue -ceq $LprQueue -and [int]$Port.PortNumber -eq 515)}
    return ([int]$Port.PortNumber -eq $PortNumber)
}
function New-SupportTcpPort {
    param([string]$IPAddress,[int]$PortNumber=9100,[ValidateSet('RAW','LPR')][string]$Protocol='RAW',[string]$LprQueue='lp')
    if(-not(Test-PrinterIPv4 $IPAddress) -or $PortNumber -lt 1 -or $PortNumber -gt 65535){throw 'Endereço IPv4 ou porta TCP inválidos.'}
    if($Protocol -eq 'LPR' -and ($PortNumber -ne 515 -or [string]::IsNullOrWhiteSpace($LprQueue) -or $LprQueue -match '[\x00-\x1f]')){throw 'LPR requer a porta 515 e um nome de fila válido.'}
    $base='IP_'+$IPAddress;$name=$base
    $ports=@(Get-WmiObject -Class Win32_TCPIPPrinterPort -ErrorAction Stop)
    $existing=$ports|Where-Object Name -ieq $name|Select-Object -First 1
    if($existing -and (Test-SupportTcpPortConfiguration $existing $IPAddress $PortNumber $Protocol $LprQueue)){return @{Success=$true;PortName=$name;Existing=$true}}
    if($existing){
        $sha=[Security.Cryptography.SHA256]::Create()
        try{$suffix=([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($LprQueue)))).Replace('-','').Substring(0,8)}finally{$sha.Dispose()}
        $name=$base+'_'+$Protocol+'_'+$PortNumber+'_'+$suffix
        $existing=$ports|Where-Object Name -ieq $name|Select-Object -First 1
        if($existing){if(Test-SupportTcpPortConfiguration $existing $IPAddress $PortNumber $Protocol $LprQueue){return @{Success=$true;PortName=$name;Existing=$true}};throw 'A porta alternativa existente tem configuração diferente; nenhuma porta foi alterada.'}
    }
    $new=New-SupportTcpPortInstance
    $new.Name=$name;$new.Protocol=if($Protocol -eq 'LPR'){2}else{1};$new.HostAddress=$IPAddress;$new.PortNumber=$PortNumber;$new.SNMPEnabled=$false
    if($Protocol -eq 'LPR'){$new.Queue=$LprQueue}
    $new.Put()|Out-Null
    $verified=Get-WmiObject -Class Win32_TCPIPPrinterPort -ErrorAction Stop|Where-Object Name -ieq $name|Select-Object -First 1
    if(-not(Test-SupportTcpPortConfiguration $verified $IPAddress $PortNumber $Protocol $LprQueue)){throw 'Porta criada, mas suas propriedades não foram confirmadas.'}
    return @{Success=$true;PortName=$name;Existing=$false}
}
function New-SupportTcpPortInstance {
    $class=[wmiclass]'\\.\root\cimv2:Win32_TCPIPPrinterPort';return $class.CreateInstance()
}
function Install-SupportLocalPrinter {
    param([string]$QueueName,[string]$PortName,[string]$DriverName,[int]$Seconds=10)
    if([string]::IsNullOrWhiteSpace($QueueName) -or [string]::IsNullOrWhiteSpace($PortName) -or [string]::IsNullOrWhiteSpace($DriverName)){throw 'Informe fila, porta e driver identificado.'}
    $environment=if([Environment]::Is64BitOperatingSystem){'Windows x64'}else{'Windows NT x86'}
    if($env:PROCESSOR_ARCHITECTURE -eq 'ARM64'){$environment='Windows ARM64'}
    $driver=Get-PrinterDriver -ErrorAction Stop|Where-Object {$_.Name -ieq $DriverName -and $_.PrinterEnvironment -ieq $environment}|Select-Object -First 1
    if(-not $driver){throw "Driver '$DriverName' não está instalado neste computador."}
    $existing=Get-ExactSupportPrinter $QueueName
    if($existing -and ([string]$existing.PortName -ine $PortName -or [string]$existing.DriverName -ine $DriverName)){throw 'Já existe uma fila com esse nome e outra porta ou driver; nenhuma fila foi substituída.'}
    if(-not $existing){Add-Printer -Name $QueueName -DriverName $DriverName -PortName $PortName -ErrorAction Stop}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    do{$printer=Get-ExactSupportPrinter $QueueName
        if($printer -and [string]$printer.PortName -ieq $PortName -and [string]$printer.DriverName -ieq $DriverName){return @{Success=$true;QueueInstalled=$true;QueueName=$printer.Name;ConnectedUNC=$printer.Name;PortName=$printer.PortName;DriverName=$printer.DriverName;Existing=[bool]$existing;Message='Fila, porta e driver confirmados no Windows.'}}
        Start-Sleep -Milliseconds 250
    }while($clock.Elapsed.TotalSeconds -lt $Seconds)
    throw 'O Windows não confirmou a fila, porta e driver solicitados em 10 segundos.'
}
function Invoke-SupportSpoolerAction {
    param([ValidateSet('Restart','AutoStart','Purge')][string]$Action)
    $service=Get-Service Spooler -ErrorAction Stop
    if($Action -eq 'AutoStart'){
        Set-Service Spooler -StartupType Automatic -ErrorAction Stop
        $state=Get-CimInstance Win32_Service -Filter "Name='Spooler'" -OperationTimeoutSec 3 -ErrorAction Stop
        if($state.StartMode -ne 'Auto'){throw 'Inicialização automática não confirmada.'}
        return @{Success=$true;Action=$Action;Message='Inicialização automática confirmada.'}
    }
    $removed=0;$errors=New-Object Collections.ArrayList
    try{
        if($service.Status -ne 'Stopped'){Stop-Service Spooler -Force -ErrorAction Stop;$service.WaitForStatus('Stopped',[TimeSpan]::FromSeconds(10))}
        if((Get-Service Spooler -ErrorAction Stop).Status -ne 'Stopped'){throw 'Spooler não parou; nenhum arquivo foi excluído.'}
        if($Action -eq 'Purge'){
            $folder=Join-Path $env:WINDIR 'System32\spool\PRINTERS'
            $setting=Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Print\Printers' -Name DefaultSpoolDirectory -ErrorAction SilentlyContinue
            if($setting.DefaultSpoolDirectory){$folder=[Environment]::ExpandEnvironmentVariables([string]$setting.DefaultSpoolDirectory)}
            $folder=[IO.Path]::GetFullPath($folder).TrimEnd('\')
            if($folder -eq [IO.Path]::GetPathRoot($folder).TrimEnd('\') -or $folder -ieq $env:WINDIR.TrimEnd('\')){throw 'Pasta de spool inválida; limpeza recusada.'}
            foreach($file in @(Get-ChildItem -LiteralPath $folder -File -ErrorAction Stop|Where-Object Extension -in @('.spl','.shd'))){
                if([IO.Path]::GetFullPath($file.DirectoryName).TrimEnd('\') -ine $folder){throw 'Arquivo fora da pasta de spool.'}
                try{Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop;if(Test-Path -LiteralPath $file.FullName){throw 'Arquivo permanece na pasta.'};$removed++}catch{[void]$errors.Add($_.Exception.Message)}
            }
        }
    }finally{Start-Service Spooler -ErrorAction Stop;$service=Get-Service Spooler -ErrorAction Stop;$service.WaitForStatus('Running',[TimeSpan]::FromSeconds(10))}
    if((Get-Service Spooler -ErrorAction Stop).Status -ne 'Running'){throw 'Spooler não voltou à execução.'}
    return @{Success=($errors.Count -eq 0);Action=$Action;FilesRemoved=$removed;Errors=@($errors.ToArray());Message=$(if($Action -eq 'Purge'){"Limpeza: $removed arquivo(s) excluído(s); $($errors.Count) falha(s). Spooler em execução."}else{'Spooler reiniciado e confirmado. Tipo de inicialização preservado.'})}
}
function Reset-SupportPrinterState {
    param([string]$QueueName,[bool]$Unpause,[bool]$ClearOffline)
    $items=@(Get-WmiObject Win32_Printer -ErrorAction Stop|Where-Object {-not $QueueName -or $_.Name -ieq $QueueName})
    if($QueueName -and -not $items.Count){throw 'Impressora selecionada não encontrada.'}
    $results=New-Object Collections.ArrayList
    foreach($printer in $items){
        try{
            if($Unpause -and ($printer.Paused -or ([int]$printer.PrinterState -band 1))){$resume=$printer.Resume();if($resume.ReturnValue -and $resume.ReturnValue -ne 0){throw "Resume retornou $($resume.ReturnValue)."}}
            if($ClearOffline -and $printer.WorkOffline){$printer.WorkOffline=$false;$printer.Put()|Out-Null}
            $after=Get-WmiObject Win32_Printer -ErrorAction Stop|Where-Object Name -ieq $printer.Name|Select-Object -First 1
            if(-not $after -or ($Unpause -and ($after.Paused -or ([int]$after.PrinterState -band 1))) -or ($ClearOffline -and $after.WorkOffline)){throw 'Estado solicitado não confirmado.'}
            [void]$results.Add(@{Success=$true;QueueName=$printer.Name;Message='Estados selecionados confirmados.'})
        }catch{[void]$results.Add(@{Success=$false;QueueName=$printer.Name;Message=$_.Exception.Message})}
    }
    return @{Success=(@($results|Where-Object {-not $_.Success}).Count -eq 0);Actions=@($results.ToArray());Message='Resultado por impressora disponível.'}
}
function Remove-SupportPrintJobs {
    param([string]$QueueName,[int[]]$JobIds,[string]$DocumentName='',[switch]$All)
    if(-not(Get-ExactSupportPrinter $QueueName)){throw 'Fila selecionada não encontrada.'}
    $jobs=@(Get-PrintJob -PrinterName $QueueName -ErrorAction Stop)
    $targets=@($jobs|Where-Object {$All -or $_.ID -in $JobIds})
    if(-not $All -and -not $JobIds.Count){throw 'Selecione um documento.'}
    if($DocumentName -and @($targets|Where-Object DocumentName -cne $DocumentName).Count){throw 'O ID agora identifica outro documento; cancelamento recusado.'}
    $results=New-Object Collections.ArrayList
    foreach($job in $targets){
        try{
            $current=Get-PrintJob -PrinterName $QueueName -ErrorAction Stop|Where-Object ID -eq $job.ID|Select-Object -First 1
            if($current -and ([string]$current.DocumentName -cne [string]$job.DocumentName -or [string]$current.SubmittedTime -cne [string]$job.SubmittedTime)){throw 'ID reutilizado por outro documento; cancelamento recusado.'}
            if($current){Remove-PrintJob -PrinterName $QueueName -ID $job.ID -ErrorAction Stop}
            $clock=[Diagnostics.Stopwatch]::StartNew()
            do{$left=@(Get-PrintJob -PrinterName $QueueName -ErrorAction Stop|Where-Object ID -eq $job.ID);if(-not $left.Count){break};Start-Sleep -Milliseconds 150}while($clock.Elapsed.TotalSeconds -lt 3)
            if($left.Count){throw 'Documento ainda consta na fila.'}
            [void]$results.Add(@{Success=$true;QueueName=$QueueName;JobId=$job.ID;DocumentName=$job.DocumentName;Message='Remoção confirmada.'})
        }catch{[void]$results.Add(@{Success=$false;QueueName=$QueueName;JobId=$job.ID;Message=$_.Exception.Message})}
    }
    return @{Success=(@($results|Where-Object {-not $_.Success}).Count -eq 0);QueueName=$QueueName;Actions=@($results.ToArray());Removed=@($results|Where-Object Success).Count;Message="$(@($results|Where-Object Success).Count) documento(s) removido(s) da fila selecionada. Outros documentos e filas preservados."}
}
function ConvertTo-SupportSafeData {
    param($Value,[int]$Depth=0)
    if($null -eq $Value){return $null}
    if($Value -is [Management.Automation.PSCredential] -or $Value -is [Security.SecureString] -or $Value -is [scriptblock]){return '[excluído]'}
    if($Depth -gt 10){return '[limite de profundidade]'}
    if($Value -is [string]){return ($Value -replace '(?im)(senha|password|pwd)\s*[:=]\s*("[^"]*"|[^\r\n;]+)','$1=[excluído]')}
    if($Value -is [DateTime]){return $Value.ToString('o')}
    if($Value -is [Enum] -or $Value -is [TimeSpan]){return [string]$Value}
    if($Value -is [ValueType]){return $Value}
    if($Value -is [Collections.IDictionary]){
        $safe=[ordered]@{}
        foreach($key in $Value.Keys){if([string]$key -match '(?i)password|senha|credential|securestring|secret|token|rawbase64|payload'){continue};$safe[[string]$key]=ConvertTo-SupportSafeData $Value[$key] ($Depth+1)}
        return $safe
    }
    if($Value -is [Collections.IEnumerable]){return ,@($Value|ForEach-Object {ConvertTo-SupportSafeData $_ ($Depth+1)})}
    $safe=[ordered]@{}
    foreach($property in $Value.PSObject.Properties){if($property.Name -match '(?i)password|senha|credential|securestring|secret|token|rawbase64|payload'){continue};$safe[$property.Name]=ConvertTo-SupportSafeData $property.Value ($Depth+1)}
    return $safe
}
function Get-SupportDiagnosticSnapshot {
    param([string]$Server='',[string]$ShareName='')
    $issues=New-Object Collections.ArrayList
    $version=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $snapshot=[ordered]@{Kind='AssistenteImpressoras.Diagnostico';Schema=1;AppVersion='1.11.0';CapturedAt=(Get-Date).ToString('o');Computer=$env:COMPUTERNAME;User=[Security.Principal.WindowsIdentity]::GetCurrent().Name;
        OSBuild=([string]$version.CurrentBuildNumber+'.'+[string]$version.UBR);OSVersion=$version.DisplayVersion;Architecture=$env:PROCESSOR_ARCHITECTURE;Server=$Server;ShareName=$ShareName;Printers=@();Drivers=@();Ports=@();Jobs=@();Events=@();IPv4=@();Policies=@();SMBSessions=@();PrintersQuerySucceeded=$false;DriversQuerySucceeded=$false;Issues=@()}
    try{$snapshot.Spooler=[string](Get-Service Spooler -ErrorAction Stop).Status}catch{[void]$issues.Add('Spooler: '+$_.Exception.Message)}
    try{$snapshot.Printers=@(Get-Printer -ErrorAction Stop|Select-Object Name,ShareName,Shared,DriverName,PortName,Type,PrinterStatus,ComputerName);$snapshot.PrintersQuerySucceeded=$true}catch{[void]$issues.Add('Filas: '+$_.Exception.Message)}
    try{$snapshot.Drivers=@(Get-PrinterDriver -ErrorAction Stop|Select-Object Name,MajorVersion,PrinterEnvironment,IsPackageAware,DriverVersion);$snapshot.DriversQuerySucceeded=$true}catch{[void]$issues.Add('Drivers: '+$_.Exception.Message)}
    try{$snapshot.Ports=@(Get-PrinterPort -ErrorAction Stop|Select-Object Name,Description,PrinterHostAddress,PortNumber,Protocol,SNMPEnabled)}catch{[void]$issues.Add('Portas: '+$_.Exception.Message)}
    foreach($printer in $snapshot.Printers){try{$snapshot.Jobs+=@(Get-PrintJob -PrinterName $printer.Name -ErrorAction Stop|Select-Object @{N='QueueName';E={$printer.Name}},ID,DocumentName,UserName,SubmittedTime,JobStatus)}catch{[void]$issues.Add('Jobs de '+$printer.Name+': consulta indisponível')}}
    try{$snapshot.IPv4=@(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop|Select-Object -ExpandProperty IPAddress)}catch{[void]$issues.Add('Endereços locais indisponíveis')}
    try{$snapshot.SMBSessions=@(Get-SmbConnection -ErrorAction Stop|Select-Object ServerName,ShareName,UserName,Dialect)}catch{[void]$issues.Add('Sessões SMB: consulta indisponível')}
    foreach($entry in @(
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\RPC';Names=@('RpcUseNamedPipeProtocol','RpcProtocols','RpcAuthentication','RpcOverNamedPipesAuthLevel')},
        @{Path='HKLM:\SYSTEM\CurrentControlSet\Control\Print';Names=@('RpcAuthnLevelPrivacyEnabled')},
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\PointAndPrint';Names=@('RestrictDriverInstallationToAdministrators','NoWarningNoElevationOnInstall','UpdatePromptSettings')},
        @{Path='HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Printers\WPP';Names=@('WindowsProtectedPrintMode','WindowsProtectedPrintGroupPolicyState')}
    )){foreach($name in $entry.Names){$snapshot.Policies+=@(Get-PrinterPolicyValue -Path ($entry.Path -replace '^HKLM:\\','') -Name $name)}}
    foreach($kind in @('Client','Server')){try{$configuration=if($kind -eq 'Client'){Get-SmbClientConfiguration -ErrorAction Stop}else{Get-SmbServerConfiguration -ErrorAction Stop};$snapshot['SMB'+$kind]=@{RequireSecuritySignature=$configuration.RequireSecuritySignature;EnableInsecureGuestLogons=$configuration.EnableInsecureGuestLogons}}catch{[void]$issues.Add('SMB '+$kind+': consulta indisponível')}}
    try{$snapshot.Events=@(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-PrintService/Admin';StartTime=(Get-Date).AddHours(-48)} -MaxEvents 25 -ErrorAction Stop|Select-Object TimeCreated,Id,LevelDisplayName,Message)}catch{[void]$issues.Add('PrintService/Admin: sem eventos recentes ou consulta indisponível')}
    $snapshot.Issues=@($issues.ToArray());return (ConvertTo-SupportSafeData $snapshot)
}
function Compare-SupportDiagnosticSnapshots {
    param($HostReport,$ClientReport)
    if($HostReport.Kind -ne 'AssistenteImpressoras.Diagnostico' -or $HostReport.Schema -ne 1){throw 'Selecione um diagnóstico JSON exportado por este EXE.'}
    $lines=New-Object Collections.ArrayList
    [void]$lines.Add("Host: $($HostReport.Computer), build $($HostReport.OSBuild), coleta $($HostReport.CapturedAt)")
    [void]$lines.Add("Cliente: $($ClientReport.Computer), build $($ClientReport.OSBuild), coleta $($ClientReport.CapturedAt)")
    if($HostReport.Computer -ieq $ClientReport.Computer){[void]$lines.Add('Os dois relatórios são do mesmo computador. Comparação entre PCs inconclusiva.')}
    if([DateTime]::Parse($HostReport.CapturedAt).ToUniversalTime() -lt (Get-Date).ToUniversalTime().AddHours(-48)){[void]$lines.Add('Relatório do host tem mais de 48 horas; pode não refletir o estado atual.')}
    foreach($printer in @($HostReport.Printers|Where-Object Shared)){
        $driver=@($ClientReport.Drivers|Where-Object Name -ieq $printer.DriverName)
        $aliases=@($HostReport.Computer)+@($HostReport.IPv4)
        $queues=@($ClientReport.Printers|Where-Object {
            $path=if($_.Name -match '^\\\\'){[string]$_.Name}else{[string]$_.PortName}
            if($path -notmatch '^\\\\([^\\]+)\\([^\\]+)$'){return $false}
            return ($Matches[1] -iin $aliases -and $Matches[2] -ieq $printer.ShareName)
        })
        $driverState=if($ClientReport.DriversQuerySucceeded){[string]($driver.Count -gt 0)}else{'consulta indisponível'}
        $queueState=if($ClientReport.PrintersQuerySucceeded){[string]($queues.Count -gt 0)}else{'consulta indisponível'}
        [void]$lines.Add("Compartilhamento $($printer.ShareName): driver '$($printer.DriverName)'; mesmo nome no cliente=$driverState; fila correspondente=$queueState.")
        $hostDriver=@($HostReport.Drivers|Where-Object Name -ieq $printer.DriverName)
        if($driver.Count -and $hostDriver.Count -and -not @($driver|Where-Object PrinterEnvironment -iin @($hostDriver.PrinterEnvironment)).Count){[void]$lines.Add('Arquiteturas de driver diferentes; pacote específico do cliente pode ser necessário.')}
    }
    foreach($report in @($HostReport,$ClientReport)){
        if(@($report.Policies|Where-Object {$_.Name -eq 'WindowsProtectedPrintMode' -and $_.Exists -and [int]$_.Value -eq 1}).Count){[void]$lines.Add("$($report.Computer): Registro indica Windows Protected Print ativo; verificar compatibilidade com drivers de terceiros.")}
        foreach($issue in @($report.Issues)){[void]$lines.Add($report.Computer+': '+$issue)}
    }
    [void]$lines.Add('Mesmo nome de driver não comprova arquivos iguais. Este comparativo não confirma autenticação remota, recebimento de job ou impressão física.')
    return @{Success=$true;Message=($lines -join [Environment]::NewLine);HostReport=$HostReport;ClientReport=$ClientReport}
}
function Export-SupportBundle {
    param([string]$OutputPath,[string]$LogPath,[string]$RecordsDirectory,[string]$Server='',[string]$ShareName='',[string]$Since='')
    if([IO.Path]::GetExtension($OutputPath) -ine '.zip'){throw 'Selecione um arquivo ZIP.'}
    $root=Join-Path $env:TEMP ('PrinterSupportExport_'+[Guid]::NewGuid().ToString('N'));$content=Join-Path $root 'Conteudo';[void][IO.Directory]::CreateDirectory($content)
    $utf8=[Text.UTF8Encoding]::new($true)
    try{
        $snapshot=Get-SupportDiagnosticSnapshot -Server $Server -ShareName $ShareName
        [IO.File]::WriteAllText((Join-Path $content 'Diagnostico.json'),($snapshot|ConvertTo-Json -Depth 12),$utf8)
        if($LogPath -and (Test-Path -LiteralPath $LogPath)){[IO.File]::WriteAllText((Join-Path $content 'Atendimento.log'),(ConvertTo-SupportSafeData ([IO.File]::ReadAllText($LogPath))),$utf8)}
        $recordFiles=@(if($RecordsDirectory -and (Test-Path -LiteralPath $RecordsDirectory)){Get-ChildItem -LiteralPath $RecordsDirectory -Filter '*.json' -File|Sort-Object Name|Select-Object -Last 100})
        if($recordFiles.Count){$folder=Join-Path $content 'Tentativas';[void][IO.Directory]::CreateDirectory($folder);foreach($file in $recordFiles){if($file.Length -gt 2097152){continue};$data=ConvertTo-SupportSafeData ([IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json);[IO.File]::WriteAllText((Join-Path $folder $file.Name),($data|ConvertTo-Json -Depth 12),$utf8)}}
        $policyRoot=Join-Path $env:LOCALAPPDATA 'AssistenteImpressoras\Politicas'
        $threshold=if($Since){[DateTime]::Parse($Since)}else{Get-Date}
        foreach($file in @(Get-ChildItem -LiteralPath $policyRoot -Filter '*.clixml' -File -ErrorAction SilentlyContinue|Where-Object {$_.LastWriteTime -ge $threshold -and $_.Length -le 1048576}|Select-Object -First 30)){
            try{$folder=Join-Path $content 'EstadosAnteriores';[void][IO.Directory]::CreateDirectory($folder);$state=ConvertTo-SupportSafeData (Import-Clixml -LiteralPath $file.FullName -ErrorAction Stop);[IO.File]::WriteAllText((Join-Path $folder ($file.BaseName+'.json')),($state|ConvertTo-Json -Depth 12),$utf8)}catch{}
        }
        [IO.File]::WriteAllText((Join-Path $content 'LEIA-ME.txt'),"Atendimento gerado pelo Assistente 1.11.0.`r`nDiagnostico.json pode ser importado no comparativo do outro computador.`r`nEstados anteriores são dados de auditoria; não executar como scripts de restauração.`r`nFila instalada, job enviado e impressão no papel são etapas diferentes.",$utf8)
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive=Join-Path $root 'export.zip';[IO.Compression.ZipFile]::CreateFromDirectory($content,$archive)
        [IO.File]::Copy($archive,[IO.Path]::GetFullPath($OutputPath),$true)
        return @{Success=$true;OutputPath=$OutputPath;Snapshot=$snapshot;Message='Atendimento exportado com log atual, tentativas, diagnóstico e estados relacionados à sessão.'}
    }finally{if([IO.Path]::GetFullPath($root).StartsWith([IO.Path]::GetFullPath($env:TEMP)+'\',[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue}}
}
function Invoke-SupportWorkerOperation {
    param([Collections.IDictionary]$Request,[string]$CheckpointPath='')
    if($Request.Action -in @('TestPage','TestRaw')){
        $printer=Get-ExactSupportPrinter $Request.QueueName
        if(-not $printer){throw 'A fila selecionada não está instalada neste usuário.'}
        if([string]$printer.PortName -match '^(PORTPROMPT:|FILE:)$'){throw 'Essa fila solicita um arquivo de saída. Abra suas preferências e faça o teste manualmente; nenhum documento foi enviado pelo assistente.'}
    }
    switch([string]$Request.Action){
        TestPage {return (Test-PrinterJobDelivery -QueueName $Request.QueueName -UNCPath $Request.UNCPath -Seconds 5 -CheckpointPath $CheckpointPath)}
        TestRaw {if(-not $Request.RawBase64 -or $Request.RawBase64.Length -gt 131072){throw 'Comando RAW ausente ou excessivo.'};return (Test-PrinterJobDelivery -QueueName $Request.QueueName -UNCPath $Request.UNCPath -Seconds 5 -RawBytes ([Convert]::FromBase64String($Request.RawBase64)) -CheckpointPath $CheckpointPath)}
        TcpPort {return (New-SupportTcpPort -IPAddress $Request.IPAddress -PortNumber $Request.PortNumber -Protocol $Request.Protocol -LprQueue $Request.LprQueue)}
        LocalPrinter {return (Install-SupportLocalPrinter -QueueName $Request.QueueName -PortName $Request.PortName -DriverName $Request.DriverName)}
        RemoveJobs {return (Remove-SupportPrintJobs -QueueName $Request.QueueName -JobIds $Request.JobIds -DocumentName $Request.DocumentName -All:([bool]$Request.All))}
        ResetState {return (Reset-SupportPrinterState -QueueName $Request.QueueName -Unpause ([bool]$Request.Unpause) -ClearOffline ([bool]$Request.ClearOffline))}
        Maintenance {
            $results=New-Object Collections.ArrayList
            foreach($action in @($Request.Actions)){
                try{
                    if($action -eq 'ResetState'){$step=Reset-SupportPrinterState -QueueName $Request.QueueName -Unpause ([bool]$Request.Unpause) -ClearOffline ([bool]$Request.ClearOffline)}
                    else{$step=Invoke-SupportSpoolerAction -Action $action}
                }catch{$step=@{Success=$false;Action=$action;Message=$_.Exception.Message}}
                [void]$results.Add($step)
            }
            return @{Success=(@($results|Where-Object {-not $_.Success}).Count -eq 0);Actions=@($results.ToArray());Message=(@($results|ForEach-Object {$(if($_.Success){'OK: '}else{'Falha: '})+$_.Message}) -join [Environment]::NewLine)}
        }
        Snapshot {return @{Success=$true;Snapshot=(Get-SupportDiagnosticSnapshot -Server $Request.Server -ShareName $Request.ShareName);Message='Diagnóstico coletado; campos indisponíveis foram identificados.'}}
        Compare {
            $file=Get-Item -LiteralPath $Request.ReportPath -ErrorAction Stop
            if($file.Length -gt 8388608){throw 'Relatório maior que 8 MB.'}
            $hostReport=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json -ErrorAction Stop
            return (Compare-SupportDiagnosticSnapshots -HostReport $hostReport -ClientReport (Get-SupportDiagnosticSnapshot))
        }
        Bundle {return (Export-SupportBundle -OutputPath $Request.OutputPath -LogPath $Request.LogPath -RecordsDirectory $Request.RecordsDirectory -Server $Request.Server -ShareName $Request.ShareName -Since $Request.Since)}
        default {throw 'Operação de atendimento desconhecida.'}
    }
}
