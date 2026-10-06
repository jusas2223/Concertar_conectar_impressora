param([string]$SourceRoot=(Split-Path -Parent $PSScriptRoot),[string]$RenderPath='')
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$path=Join-Path $SourceRoot 'src\AssistenteImpressoras.ps1'
$source=[IO.File]::ReadAllText($path)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0].Message}
foreach($name in @('New-ExplicitPrinterCredentialSelection','Connect-PrinterUsingExplicitCredential','Connect-PrinterUsingAvailableSession','Invoke-PrinterOperationUsingAvailableSession','Use-PrinterCredentialForEndpoint','Get-SelectedPrinterConnectionTarget','Resolve-PrinterConnectionEndpoint')){
    $fn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
    if(-not $fn){throw "Função ausente: $name"}
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert([bool]$Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Format-PrinterAsNamedUNC {param($Path) return $Path}
function Resolve-PrinterEndpointAddresses {throw 'Modo manual aguardou DNS antes de abrir a janela'}
$cmbNetEndpointMode=[pscustomobject]@{SelectedIndex=0}
$dgvNetPrinters=[pscustomobject]@{SelectedRows=@([pscustomobject]@{Cells=@{UNC=[pscustomobject]@{Value='\\192.0.2.11\Fila'};Type=[pscustomobject]@{Value='Compartilhada SMB'};Server=[pscustomobject]@{Value='192.0.2.11'}}})}
$manualTarget=Get-SelectedPrinterConnectionTarget -ManualCredential
Assert ($manualTarget.Success -and $manualTarget.UNCPath -ceq '\\192.0.2.11\Fila') 'Descoberta sem hostname bloqueou a janela de conta'
$script:logs=New-Object Collections.Generic.List[string]
function Write-AppLog {param($Message,$Level)
    Assert (-not $Message.Contains('Fixture-password')) 'Senha no log'
    $script:logs.Add($Message)
}
$inputCases=@(
    @{Server='NOVO-HOST';User='conta';ExpectedUser='NOVO-HOST\conta';ExpectedUNC='\\NOVO-HOST\Fila (1)'},
    @{Server='192.0.2.11';User='ORIGINAL\conta';ExpectedUser='ORIGINAL\conta';ExpectedUNC='\\192.0.2.11\Fila (1)'},
    @{Server='servidor.exemplo.local';User='DOMINIO\conta';ExpectedUser='DOMINIO\conta';ExpectedUNC='\\servidor.exemplo.local\Fila (1)'},
    @{Server='NOVO-HOST';User='.\conta';ExpectedUser='NOVO-HOST\conta';ExpectedUNC='\\NOVO-HOST\Fila (1)'},
    @{Server='NOVO-HOST';User='conta@exemplo.local';ExpectedUser='conta@exemplo.local';ExpectedUNC='\\NOVO-HOST\Fila (1)'}
)
foreach($case in $inputCases){
    $choice=@{Server=$case.Server;User=$case.User;Password='Fixture-password'}
    $selection=New-ExplicitPrinterCredentialSelection -UNCPath '\\ORIGINAL\Fila (1)' -Choice $choice
    Assert ($selection.Success -and $selection.UNCPath -ceq $case.ExpectedUNC -and $selection.Credential.UserName -ceq $case.ExpectedUser) 'Destino/conta alterados'
    Assert (-not $choice.Password -and -not $selection.Contains('Password')) 'Senha em texto mantida no resultado'
    Assert ($selection.SourceUNC -ceq '\\ORIGINAL\Fila (1)') 'Origem da seleção perdida'
}
foreach($invalid in @(
    @{Server='SER VIDOR';User='conta';Password='Fixture-password'},
    @{Server='SERVIDOR\Pasta';User='conta';Password='Fixture-password'},
    @{Server='999.0.0.1';User='conta';Password='Fixture-password'},
    @{Server='1.2';User='conta';Password='Fixture-password'},
    @{Server='SERVIDOR';User='';Password='Fixture-password'},
    @{Server='SERVIDOR';User='SERVIDOR\';Password='Fixture-password'},
    @{Server='SERVIDOR';User='conta';Password=''}
)){
    $result=New-ExplicitPrinterCredentialSelection -UNCPath '\\ORIGINAL\Fila (1)' -Choice $invalid
    Assert (-not $result.Success -and $result.Code -eq 87 -and -not $invalid.Password) 'Entrada inválida foi aceita ou senha permaneceu em texto'
}
$cancel=New-ExplicitPrinterCredentialSelection -UNCPath '\\ORIGINAL\Fila (1)' -Choice @{Cancelled=$true}
Assert ($cancel.Cancelled -and $cancel.Code -eq 1223) 'Cancelamento perdido'

# Exercita a função real sem acessar rede, instalar driver ou enviar trabalho.
function Invoke-BoundedPrinterAttempt {
    param($UNCPath,$Method,$TimeoutSeconds,$NetworkCredential,$CredentialServer)
    $script:authCalls++
    Assert ($script:connectCalls -eq 0 -and $Method -eq 'Authenticate' -and $TimeoutSeconds -eq 15) 'Conexão começou antes de autenticar'
    Assert ($UNCPath -ceq '\\NOVO-HOST\Fila (1)' -and $CredentialServer -ceq 'NOVO-HOST') 'Autenticação usou outro destino'
    Assert ($NetworkCredential.UserName -ceq 'NOVO-HOST\conta') 'Autenticação perdeu a conta informada'
    return $script:authResult.Clone()
}
function Connect-UNCPrinterSafe {
    param($UNCPath,$AlternateHost,$ValidationMode)
    $script:connectCalls++
    if($script:explicitMode){
        Assert ($script:authCalls -eq 1 -and $script:authenticatedPrinterServer -ceq 'NOVO-HOST' -and $script:authenticatedPrinterCredential.UserName -ceq 'NOVO-HOST\conta') 'Primeira tentativa não usou identidade explícita'
        Assert ($UNCPath -ceq '\\NOVO-HOST\Fila (1)' -and -not $AlternateHost) 'Servidor explícito foi substituído por IP antigo'
    }
    Assert ($ValidationMode -ceq $script:expectedValidation) 'Validação/página de teste alterada'
    return $script:connectionResult.Clone()
}
function Reset-Fixture {
    $script:authCalls=0;$script:connectCalls=0;$script:promptCalls=0;$script:explicitMode=$true
    $script:authenticatedPrinterServer='ANTIGO';$script:authenticatedPrinterCredential=$null
    $script:authResult=@{Success=$true;Code=0}
    $script:connectionResult=@{Success=$false;Code=1223;Cancelled=$true;Cascaded=$true}
    $script:expectedValidation='QueueOnly';$global:SimulationMode=$false
}
$selection=New-ExplicitPrinterCredentialSelection -UNCPath '\\ORIGINAL\Fila (1)' -Choice @{Server='NOVO-HOST';User='conta';Password='Fixture-password'}
foreach($case in @('connected','driver-error','job-pending','denied','timeout','cancelled','simulation')){
    Reset-Fixture
    switch($case){
        connected {$script:connectionResult=@{Success=$true;QueueInstalled=$true;ConnectedUNC=$selection.UNCPath}}
        driver-error {$script:connectionResult=@{Success=$false;Code=1797;Stage='Instalar driver'}}
        job-pending {$script:expectedValidation='TestPage';$script:connectionResult=@{Success=$false;QueueInstalled=$true;JobValidated=$false;Code=5}}
        denied {$script:authResult=@{Success=$false;Code=1326;Message='Conta recusada'}}
        timeout {$script:authResult=@{Success=$false;TimedOut=$true;Code=-1}}
        cancelled {$script:authResult=@{Success=$false;Cancelled=$true;Code=-1}}
        simulation {$global:SimulationMode=$true}
    }
    $r=Connect-PrinterUsingExplicitCredential -Selection $selection -ValidationMode $script:expectedValidation
    $connectExpected=$case -in @('connected','driver-error','job-pending')
    Assert ($script:connectCalls -eq [int]$connectExpected) "Conexão indevida em $case"
    Assert ($script:authCalls -eq [int]($case -ne 'simulation')) "Autenticação indevida em $case"
    if($case -eq 'connected'){Assert ($r.Success -and $r.QueueInstalled) 'Sucesso validado perdido'}
    if($case -eq 'driver-error'){Assert (-not $r.Success -and $r.Code -eq 1797) 'Erro de driver virou sucesso'}
    if($case -eq 'job-pending'){Assert (-not $r.Success -and $r.QueueInstalled -and -not $r.JobValidated) 'Job pendente virou sucesso'}
    if($case -eq 'denied'){Assert ($r.Code -eq 1326 -and $script:authenticatedPrinterServer -eq 'ANTIGO') 'Conta recusada foi reutilizada'}
    if($case -eq 'timeout'){Assert ($r.Code -eq 1460) 'Prazo perdido'}
    if($case -eq 'cancelled'){Assert ($r.Code -eq 1223) 'Cancelamento da autenticação perdido'}
    if($case -eq 'simulation'){Assert ($r.Simulated) 'Simulação perdida'}
}

# Executa os eventos reais dos controles, com operação final cancelada para
# impedir mensagens/ações externas. A opção normal continua usando sessão atual.
$green=[regex]::Match($source,'(?s)\$btnConnectSelected\.Add_Click\(\{(?<body>.*?)\r?\n\}\)')
$checked=[regex]::Match($source,'(?s)\$chkNetWin11\.Add_CheckedChanged\(\{(?<body>.*?)\r?\n\}\)')
Assert ($green.Success -and $checked.Success) 'Eventos do modo Win 11 ausentes'
$greenHandler=[scriptblock]::Create($green.Groups['body'].Value)
$checkedHandler=[scriptblock]::Create($checked.Groups['body'].Value)
$form=New-Object Windows.Forms.Form
$txtNetUser=New-Object Windows.Forms.TextBox
$txtNetPass=New-Object Windows.Forms.TextBox
$btnConnectSelected=New-Object Windows.Forms.Button
$chkNetWin11=[pscustomobject]@{Checked=$true;Enabled=$true;IsDisposed=$false}
$cmbNetEndpointMode=[pscustomobject]@{Enabled=$true;IsDisposed=$false}
$row=[pscustomobject]@{Cells=@{UNC=[pscustomobject]@{Value='\\ORIGINAL\Fila (1)'};Type=[pscustomobject]@{Value='Compartilhada SMB'};ShareName=[pscustomobject]@{Value='Fila (1)'};Server=[pscustomobject]@{Value='ORIGINAL \ 192.0.2.10'}}}
$dgvNetPrinters=[pscustomobject]@{SelectedRows=@($row);Enabled=$true;IsDisposed=$false}
$lblNetConnectionPath=[pscustomobject]@{Text=''}
$btnCancelConnection=[pscustomobject]@{Enabled=$true;Visible=$false}
$chkNetTestPage=[pscustomobject]@{Checked=$false}
$script:currentWindowsBuild=26200
function Get-SelectedPrinterConnectionTarget {return @{Success=$true;UNCPath='\\ORIGINAL\Fila (1)';Mode='Hostname';Aliases=@('ORIGINAL','192.0.2.10')}}
function Format-PrinterAsNamedUNC {param($Path) return $Path}
function Request-ExplicitPrinterConnectionCredential {param($UNCPath,$InitialUser,$Parent) $script:promptCalls++;return $script:promptResult}
function Show-LoadingIndicator {param($Message,$Button) $Button.Enabled=$false}
function Hide-LoadingIndicator {param($Button) $Button.Enabled=$true}
function Update-StatusStrip {param($Text,$Color,$Tag)}
try {
    foreach($case in @('mark-then-connect','checked-no-pending','different-row','normal-session','cancel-prompt')){
        Reset-Fixture
        $script:pendingPrinterConnectionCredential=$null;$script:promptResult=$selection
        $chkNetWin11.Checked=$case -ne 'normal-session'
        if($case -eq 'mark-then-connect'){
            & $checkedHandler
            Assert ($script:pendingPrinterConnectionCredential -eq $selection -and $script:authCalls -eq 0 -and $script:connectCalls -eq 0) 'Marcar a caixa começou a conectar'
        }
        if($case -eq 'different-row'){$script:pendingPrinterConnectionCredential=@{SourceUNC='\\OUTRO\Outra fila';Success=$true}}
        if($case -eq 'normal-session'){$script:explicitMode=$false;$script:authenticatedPrinterServer='';$txtNetPass.Clear()}
        if($case -eq 'cancel-prompt'){$script:promptResult=@{Success=$false;Cancelled=$true;Code=1223}}
        & $greenHandler
        Assert ($script:promptCalls -eq [int]($case -ne 'normal-session')) "Quantidade de diálogos incorreta em $case"
        Assert ($script:connectCalls -eq [int]($case -ne 'cancel-prompt')) "Conexão indevida em $case"
        Assert ($script:authCalls -eq [int]($case -notin @('cancel-prompt','normal-session'))) "Autenticação indevida em $case"
        Assert (-not $script:pendingPrinterConnectionCredential) 'Conta de uma tentativa anterior permaneceu pendente'
        Assert ($chkNetWin11.Enabled -and $cmbNetEndpointMode.Enabled -and $dgvNetPrinters.Enabled -and $btnConnectSelected.Enabled -and -not $btnCancelConnection.Visible) 'Controles permaneceram bloqueados'
    }
    Reset-Fixture;$chkNetWin11.Checked=$true;$script:promptResult=@{Success=$false;Cancelled=$true;Code=1223}
    & $checkedHandler
    Assert (-not $chkNetWin11.Checked -and -not $script:pendingPrinterConnectionCredential -and $script:connectCalls -eq 0) 'Cancelar deixou caixa/conta pendente'
} finally {$form.Dispose();$txtNetUser.Dispose();$txtNetPass.Dispose();$btnConnectSelected.Dispose()}

# Renderiza a janela construída pelo código real sem abrir/operar apps do usuário.
$dialogFn=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Request-PrinterServerCredential'},$true)
. ([scriptblock]::Create($dialogFn.Extent.Text.Replace('$dialog.ShowDialog($Parent)','(Invoke-TestCredentialDialog -Dialog $dialog)')))
function Invoke-TestCredentialDialog {
    param($Dialog)
    $serverBox=$Dialog.Controls['CredentialServer'];$userBox=$Dialog.Controls['CredentialUser'];$passBox=$Dialog.Controls['CredentialPassword']
    Assert ($serverBox -and $userBox -and $passBox -and $passBox.UseSystemPasswordChar) 'Campos de autenticação ausentes ou senha exposta'
    Assert ($serverBox.ReadOnly -eq (-not $script:serverEditable)) 'Servidor editável no modo incorreto'
    Assert ($serverBox.Bottom -lt $userBox.Top -and $userBox.Bottom -lt $passBox.Top -and $passBox.Bottom -lt $Dialog.ClientSize.Height) 'Campos sobrepostos'
    if($RenderPath -and $script:serverEditable){
        $Dialog.StartPosition='Manual';$Dialog.Location=[Drawing.Point]::new(-16000,-16000);$Dialog.ShowInTaskbar=$false
        $Dialog.Show();[Windows.Forms.Application]::DoEvents()
        $bitmap=New-Object Drawing.Bitmap($Dialog.Width,$Dialog.Height)
        try {$Dialog.DrawToBitmap($bitmap,[Drawing.Rectangle]::new(0,0,$bitmap.Width,$bitmap.Height));$bitmap.Save($RenderPath,[Drawing.Imaging.ImageFormat]::Png)}finally{$bitmap.Dispose();$Dialog.Close()}
    }
    return [Windows.Forms.DialogResult]::Cancel
}
$script:serverEditable=$true
Request-PrinterServerCredential -Server 'SERVIDOR' -AllowServerEdit -RequireCredential -Reason 'Informe a conta antes de conectar.' | Out-Null
$script:serverEditable=$false
Request-PrinterServerCredential -Server 'SERVIDOR' -Reason 'Acesso recusado na tentativa atual.' | Out-Null
'OK: entradas dinâmicas, senha em memória, autenticação antes da cascata, cancelamento/prazo, eventos Win 11/normal e janela renderizada.'
