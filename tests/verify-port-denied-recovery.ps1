param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot),[string]$OutputPath='')
$ErrorActionPreference='Stop'
$root=$SourceRoot
$temp=Join-Path $env:TEMP ('PrinterCaseReplay_'+[Guid]::NewGuid().ToString('N'))
$encoding=New-Object Text.UTF8Encoding($true)
$reports=New-Object Collections.ArrayList
try {
    [void][IO.Directory]::CreateDirectory($temp)
    Copy-Item -LiteralPath (Join-Path $root 'src\scripts\CONECTAR-IMPRESSORA.ps1'),(Join-Path $root 'src\scripts\INSTALAR-PORTA-LOCAL.ps1') -Destination $temp
    $common=[IO.File]::ReadAllText((Join-Path $root 'src\scripts\IMPRESSAO-COMUM.ps1'))
    # All OS/network operations are replaced in these isolated copies. The
    # production cascade, error conversion and UI decision remain unchanged.
    $mocks=@'
function Get-Printer {param($Name,$ErrorAction) return $null}
function Wait-ExactPrinter {param($UNCPath,$QueueName,$DriverName,$Seconds) return $null}
function Get-PrinterDriver {param($Name,$ErrorAction) if($global:replayDriverReady){return [pscustomobject]@{Name='Fabricante Modelo';PrinterEnvironment='Windows x64';MajorVersion=3}}}
function Get-PrinterPort {param($Name,$ErrorAction) return $null}
function Add-Printer {param($ConnectionName,$Name,$DriverName,$PortName,$ErrorAction)
    $global:replayNativeCalls++
    throw (New-Object ComponentModel.Win32Exception(1801))
}
function Add-PrinterPort {param($Name,$ErrorAction)
    $global:replayPortCalls++
    $ex=New-Object UnauthorizedAccessException('Acesso negado simulado na porta UNC')
    $record=New-Object Management.Automation.ErrorRecord($ex,'HRESULT 0x80070005,Add-PrinterPort',[Management.Automation.ErrorCategory]::PermissionDenied,$Name)
    throw $record
}
function Test-PrinterRemoteQueueAccess {param($UNCPath)
    $global:replayQueueProbeCalls++
    if($global:replayQueueCode -eq -1){throw [TimeoutException]::new('Consulta remota inconclusiva simulada')}
    return $global:replayQueueCode
}
function Test-PrinterSharedQueueExists {param($Server,$ShareName)
    $global:replayShareProbeCalls++
    if($global:replayShareCode -eq -1){throw [TimeoutException]::new('Consulta do compartilhamento inconclusiva simulada')}
    return $global:replayShareCode
}
'@
    [IO.File]::WriteAllText((Join-Path $temp 'IMPRESSAO-COMUM.ps1'),$common+"`r`n"+$mocks,$encoding)
    [IO.File]::WriteAllText((Join-Path $temp 'DRIVER-DO-SERVIDOR.ps1'),@'
param($Server,$ShareName,$DriverName,$Action,$ProgressPath)
if($global:replayLocalDriverFailure){return @{Success=$false;Code=5;NativeCode=5;Stage='Criar pasta temporária do pacote';FailureScope='Local';Message='Acesso local negado simulado'}}
if($global:replayMissingPackage){return @{Success=$false;Code=2;Stage='Ler pacote remoto';FailureScope='Remote';Message='Consulta RPC da fila recusada com 1801; pacote preparado ausente (simulado)'}}
$global:replayDriverReady=$true
return @{Success=$true;DriverName='Fabricante Modelo';Existing=$true;FilesCompared=$true;Message='Driver existente confirmado no cenário simulado'}
'@,$encoding)
    $tokens=$null;$errors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'src\AssistenteImpressoras.ps1'),[ref]$tokens,[ref]$errors)
    if($errors.Count){throw 'Fonte principal não passou na análise sintática.'}
    $decision=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-PrinterOperationUsingAvailableSession'},$true)
    if(-not $decision){throw 'Função real da interface não encontrada.'}
    Invoke-Expression $decision.Extent.Text
    function Use-PrinterCredentialForEndpoint {param($Server,$Aliases)}
    function Write-AppLog {param($Message,$Level)}
    $cases=@(
        @{Name='709 + driver confirmado + porta 5 + OpenPrinter 1801';RemoteCode=1801;ShareCode=0;Missing=$false;ExpectedPrompt=1;ExpectedShareCalls=1},
        @{Name='709 + driver confirmado + porta 5 + OpenPrinter 5';RemoteCode=5;ShareCode=0;Missing=$false;ExpectedPrompt=1;ExpectedShareCalls=0},
        @{Name='709 + driver confirmado + porta 5 + OpenPrinter 0';RemoteCode=0;ShareCode=0;Missing=$false;ExpectedPrompt=0;ExpectedShareCalls=0},
        @{Name='709 + pacote indisponível + compartilhamento de impressão confirmado';RemoteCode=1801;ShareCode=0;Missing=$true;ExpectedPrompt=1;ExpectedShareCalls=1},
        @{Name='709 + pacote indisponível + compartilhamento inexistente';RemoteCode=1801;ShareCode=2310;Missing=$true;ExpectedPrompt=0;ExpectedShareCalls=1},
        @{Name='709 + driver confirmado + porta 5 + compartilhamento inexistente';RemoteCode=1801;ShareCode=2310;Missing=$false;ExpectedPrompt=0;ExpectedShareCalls=1},
        @{Name='709 + driver confirmado + porta 5 + consulta do compartilhamento negada';RemoteCode=1801;ShareCode=5;Missing=$false;ExpectedPrompt=1;ExpectedShareCalls=1},
        @{Name='709 + driver confirmado + porta 5 + conta já fornecida';RemoteCode=1801;ShareCode=0;Missing=$false;Credential=$true;ExpectedPrompt=0;ExpectedShareCalls=0},
        @{Name='709 + driver confirmado + porta 5 + servidor indisponível';RemoteCode=53;ShareCode=0;Missing=$false;ExpectedPrompt=0;ExpectedShareCalls=0},
        @{Name='709 + criação de pasta local negada';RemoteCode=1801;ShareCode=0;Missing=$false;LocalDriverFailure=$true;ExpectedPrompt=0;ExpectedShareCalls=0},
        @{Name='709 + driver confirmado + porta 5 + consulta do compartilhamento inconclusiva';RemoteCode=1801;ShareCode=-1;Missing=$false;ExpectedPrompt=0;ExpectedShareCalls=1},
        @{Name='709 + driver confirmado + porta 5 + consulta remota inconclusiva';RemoteCode=-1;ShareCode=0;Missing=$false;ExpectedPrompt=1;ExpectedShareCalls=1}
    )
    foreach($case in $cases){
        $global:replayNativeCalls=0;$global:replayPortCalls=0;$global:replayQueueProbeCalls=0;$global:replayShareProbeCalls=0
        $global:replayDriverReady=$false;$global:replayMissingPackage=$case.Missing
        $global:replayLocalDriverFailure=[bool]$case.LocalDriverFailure
        $global:replayQueueCode=$case.RemoteCode;$global:replayShareCode=$case.ShareCode;$global:replayPromptCalls=0
        $result=& (Join-Path $temp 'CONECTAR-IMPRESSORA.ps1') -Server 'LAB-HOST' -ShareName 'Fila Teste' -ValidationMode QueueOnly -HasNetworkCredential:([bool]$case.Credential)
        $global:replayResult=$result
        $uiResult=Invoke-PrinterOperationUsingAvailableSession -UNCPath '\\LAB-HOST\Fila Teste' -Attempt {$global:replayResult} -RequestCredential {
            param($server,$failure)
            $global:replayPromptCalls++
            return @{WithoutCredential=$true}
        }
        if($result.Success -or $result.QueueInstalled){throw 'O replay anunciou instalação inexistente.'}
        if($global:replayPromptCalls -ne $case.ExpectedPrompt -or $global:replayShareProbeCalls -ne $case.ExpectedShareCalls){throw ('Comportamento diferente do código revisado: '+$case.Name)}
        if($result.WorkerVersion -ne '1.11.0' -or -not $result.AttemptId -or -not $result.NativeAttemptCodes){throw 'Metadados da tentativa ausentes'}
        if($global:replayPortCalls -and ($result.Code -ne 5 -or $result.Stage -ne 'Criar porta local UNC')){throw 'A recuperação substituiu o erro original da porta'}
        if($case.ExpectedPrompt -and -not $result.NeedsAuthentication -and (-not $result.CredentialRetryRecommended -or $result.ConfirmedUNC -ne '\\LAB-HOST\Fila Teste')){throw 'Recuperação não corresponde ao compartilhamento selecionado'}
        [void]$reports.Add([pscustomobject]@{
            Scenario=$case.Name;Mocked=$true;Success=[bool]$result.Success;QueueInstalled=[bool]$result.QueueInstalled
            Code=$result.Code;Stage=$result.Stage;FailureScope=$result.FailureScope;RemoteAccessCode=$result.RemoteAccessCode
            NeedsAuthentication=[bool]$result.NeedsAuthentication;CredentialRetryRecommended=[bool]$result.CredentialRetryRecommended
            RecoveryReason=$result.RecoveryReason;ShareLookupCode=$result.ShareLookupCode;WorkerVersion=$result.WorkerVersion
            NativeAttempts=$global:replayNativeCalls;PortAttempts=$global:replayPortCalls
            ShareProbeCalls=$global:replayShareProbeCalls;QueueProbeCalls=$global:replayQueueProbeCalls;CredentialPrompts=$global:replayPromptCalls
        })
    }
    if($OutputPath){$reports.ToArray() | Export-Clixml -LiteralPath $OutputPath -Force}
    'OK: 12 cenários com workers/interface reais; recuperação limitada, recusa local preservada e erro original registrado.'
} finally {
    $absolute=[IO.Path]::GetFullPath($temp)
    $allowed=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($absolute.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $absolute)){
        Remove-Item -LiteralPath $absolute -Recurse -Force
    }
}
