param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot))
$ErrorActionPreference='Stop'
$source=[IO.File]::ReadAllText((Join-Path $SourceRoot 'src\scripts\DRIVER-DO-SERVIDOR.ps1'))
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
. (Join-Path $SourceRoot 'src\scripts\IMPRESSAO-COMUM.ps1')
foreach($name in @('Get-LegacyPrinterDriverState','Invoke-LegacyPrinterDriverRegistration')){
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(-not $fn){throw "Função ausente: $name"}
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
$definition=[regex]::Match($source,"(?s)\`$native = @'\r?\n(?<code>.*?)\r?\n'@")
Assert $definition.Success 'API nativa do driver ausente'
$mock=@'
 public static uint LastFlags;
 public static int InstallCalls, FailuresRemaining, FailureCode=32;
 public static bool Registered;
 public static string LastDriver, LastData, LastConfig, LastDependency;
 static bool AddPrinterDriverExW(string server,uint level,ref INFO6 info,uint flags) {
  LastFlags=flags; InstallCalls++;
  LastDriver=Marshal.PtrToStringUni(info.Driver); LastData=Marshal.PtrToStringUni(info.Data); LastConfig=Marshal.PtrToStringUni(info.Config);
  LastDependency=Marshal.PtrToStringUni(info.Dependencies);
  if(flags!=0x18)throw new Win32Exception(32);
  if(FailuresRemaining>0){FailuresRemaining--;throw new Win32Exception(FailureCode);}
  Registered=true;return true;
 }
'@
$native=[regex]::Replace($definition.Groups['code'].Value,'(?m)^ \[DllImport\("winspool.drv"[^\r\n]+ static extern bool AddPrinterDriverExW\([^\r\n]+;\r?$', $mock)
Assert ($native.Contains('public static uint LastFlags')) 'Stub da chamada nativa não foi aplicado'
Add-Type -TypeDefinition $native -ErrorAction Stop
$temp=Join-Path $env:TEMP ('PrinterDriverFileUse_'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($temp)
try {
    $vendor=Join-Path $temp 'FixtureVendor.dll';$data=Join-Path $temp 'FixtureData.gpd';$config=Join-Path $temp 'FixtureConfig.dll';$dep=Join-Path $temp 'FixtureDependency.dll'
    foreach($file in @($vendor,$data,$config,$dep)){[IO.File]::WriteAllText($file,'Fixture-driver-bytes')}
    $manifest=[pscustomobject]@{DriverName='Fabricante Modelo';Driver='FixtureVendor.dll';Data='FixtureData.gpd';Config='FixtureConfig.dll';Help='';Dependencies=@('FixtureDependency.dll');DataType='RAW';Files=@()}
    foreach($file in @($vendor,$data,$config,$dep)){$manifest.Files+=@{Name=[IO.Path]::GetFileName($file);Core=$false;SHA256=(Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash}}
    function Get-PrinterDriver {
        param($ErrorAction)
        if(-not [PrinterDriverTransfer]::Registered -and -not $script:existing){return}
        $driverPath=if($script:badBinding){Join-Path $temp 'OtherDriver.dll'}elseif([PrinterDriverTransfer]::Registered){[PrinterDriverTransfer]::LastDriver}else{$vendor}
        [pscustomobject]@{Name='Fabricante Modelo';PrinterEnvironment='Windows x64';MajorVersion=3;Path=$driverPath;DataFile=$data;ConfigFile=$config;HelpFile='';DependentFiles=@($dep)}
    }
    function Start-Sleep {param($Milliseconds) $script:delays.Add([int]$Milliseconds)}
    function Set-DriverStage {param($message,$Scope,$Resource) $script:driverOperationStage=$message}
    foreach($case in @('existing','identical-paths-reused','transient32','transient33','persistent32','other-error','unconfirmed-binding','unconfirmed-hash')){
        [PrinterDriverTransfer]::InstallCalls=0;[PrinterDriverTransfer]::FailuresRemaining=0;[PrinterDriverTransfer]::Registered=$false
        [PrinterDriverTransfer]::FailureCode=32
        $script:existing=$case -in @('existing','identical-paths-reused')
        $script:badBinding=$case -in @('identical-paths-reused','unconfirmed-binding')
        $script:delays=New-Object Collections.Generic.List[int]
        $resolved=@{'FixtureVendor.dll'=$vendor;'FixtureData.gpd'=$data;'FixtureConfig.dll'=$config;'FixtureDependency.dll'=$dep}
        switch($case){
            identical-paths-reused {$resolved['FixtureVendor.dll']=Join-Path $temp 'new-temp-copy.dll'}
            transient32 {[PrinterDriverTransfer]::FailuresRemaining=1}
            transient33 {[PrinterDriverTransfer]::FailuresRemaining=1;[PrinterDriverTransfer]::FailureCode=33}
            persistent32 {[PrinterDriverTransfer]::FailuresRemaining=10}
            other-error {[PrinterDriverTransfer]::FailuresRemaining=10;[PrinterDriverTransfer]::FailureCode=5}
            unconfirmed-hash {$manifest.Files[0].SHA256=('0'*64)}
        }
        $r=Invoke-LegacyPrinterDriverRegistration -Manifest $manifest -Resolved $resolved -Environment 'Windows x64'
        $expectedCalls=switch($case){existing{0};transient32{2};transient33{2};persistent32{3};default{1}}
        Assert ([PrinterDriverTransfer]::InstallCalls -eq $expectedCalls -and $r.RegistrationAttempts -eq $expectedCalls) "Quantidade de tentativas incorreta em $case"
        if($case -ne 'existing'){Assert ([PrinterDriverTransfer]::LastFlags -eq 0x18) 'COPY_ALL_FILES continuou ativo'}
        $successExpected=$case -in @('existing','transient32','transient33')
        Assert ([bool]$r.Success -eq $successExpected) "Confirmação incorreta em $case"
        if($case -eq 'identical-paths-reused'){Assert ([PrinterDriverTransfer]::LastDriver -ceq $vendor) 'Arquivo local idêntico não foi reutilizado'}
        if($case -eq 'persistent32'){
            Assert ($r.Code -eq 32 -and $r.FailureScope -eq 'Local' -and $r.DriverName -eq $manifest.DriverName -and $r.DriverFiles.Count -eq 4) 'Código/arquivos/driver não preservados'
            Assert (($script:delays -join ',') -eq '300,600') 'Espera indefinida ou quantidade de retries incorreta'
        }
        if($case -eq 'other-error'){Assert ($r.Code -eq 5 -and $script:delays.Count -eq 0) 'Erro de acesso repetiu instalação'}
        if($case -in @('unconfirmed-binding','unconfirmed-hash')){Assert ($r.Code -eq 31) 'Sucesso nativo foi aceito sem confirmar arquivos/vínculos'}
        $manifest.Files[0].SHA256=(Get-FileHash -LiteralPath $vendor -Algorithm SHA256).Hash
    }
    function Test-PrinterSharedQueueExists {throw 'Falha local de arquivo em uso consultou nome do compartilhamento'}
    foreach($code in @(32,33)){
        $r=Resolve-PrinterCredentialRecovery -Failure @{Success=$false;Code=$code;NativeCode=$code;FailureScope='Local';Stage='Registrar driver'} -Server SERVIDOR -ShareName Fila -NativeConnectionCode 1801
        Assert (-not $r.NeedsAuthentication -and -not $r.CredentialRetryRecommended -and $r.RecoveryReason -eq 'LocalDriverFileInUse') 'Arquivo em uso virou erro de senha/compartilhamento'
    }
} finally {
    $absolute=[IO.Path]::GetFullPath($temp)
    $parent=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($absolute.StartsWith($parent,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($absolute).StartsWith('PrinterDriverFileUse_')){Remove-Item -LiteralPath $absolute -Recurse -Force -ErrorAction SilentlyContinue}
}
'OK: oito cenários de registro, flags reais 0x18, cópia idêntica evitada, retries limitados e falha local sem senha/compartilhamento.'
