# Conexão em cascata — versão 1.10.3

## Pelo executável

1. No servidor, selecione a impressora local compartilhada e clique em **Preparar host e driver**. Aplica as políticas de RPC solicitadas, concede leitura a Usuários Autenticados em print$, reinicia o Spooler e publica o pacote quando necessário.
2. No cliente, abra o mesmo EXE, selecione a fila e clique em **Conectar impressora**. Deixe usuário e senha em branco para usar o acesso atual do Windows. Se quiser usar outra conta desde o início, preencha ambos em **Buscar servidor**. O EXE solicita elevação na abertura, antes de coletar as credenciais.
3. A conexão aplica as políticas locais do cliente, reinicia o Spooler, executa a cascata e envia uma página de validação. O prazo total do worker é 180 segundos, com cancelamento; o encerramento inclui os processos filhos, como PnPUtil.

As políticas solicitadas reduzem as restrições de instalação de drivers e permitem guest no cliente. Os valores anteriores do Registro ficam em `%LOCALAPPDATA%\AssistenteImpressoras\Politicas`. A permissão concedida a print$ é de leitura; não dá acesso de gravação. Políticas de domínio podem prevalecer ou reaplicar configurações.

## Escolha do endereço do servidor

Na aba Impressoras da rede, use Conectar por:

- Nome do computador (hostname), padrão: mantém a fila como \\NOME_DO_PC\Compartilhamento. Não salva o IP no caminho da fila. Preserva também nomes completos de domínio.
- Endereço IP: conecta como \\IP\Compartilhamento. Se a fila foi descoberta por nome, consulta o IP atual ao clicar em Conectar. Havendo vários endereços, prefere o IP descoberto quando ele ainda consta na resolução atual. Se não houver resposta, pode usar o IP mostrado pela descoberta.

O destino é mostrado ao lado da escolha. A prévia usa apenas os dados da tabela; não consulta a rede a cada mudança de seleção. A resolução no clique é limitada por tempo e não usa consulta WMI remota. Se o hostname não for identificado, o operador informa o nome em Buscar servidor ou seleciona IP; não há troca silenciosa de modo.

Conectar, Instalar por porta local e os diagnósticos seguem a seleção. A credencial já confirmada pode ser reutilizada entre aliases de nome/IP do mesmo registro descoberto. Ela não é aplicada a outro servidor. A aba Instalar por caminho continua aceitando o UNC digitado explicitamente. Impressoras com IP próprio continuam no fluxo Instalar por IP.

## Conta somente quando necessário

O botão verde tenta primeiro a sessão atual do Windows ou a credencial do servidor já confirmada em memória. O comportamento é o mesmo para Win10 → Win10 e Win10 → Win11. Não exige senha previamente só por causa da versão do Windows.

Recusa de acesso/autenticação identificada no worker permite solicitar outra conta uma vez e repetir uma vez. Código 709, driver ausente, parâmetro inválido, servidor indisponível, conflito de sessão 1219, cancelamento e prazo excedido não abrem automaticamente a janela de conta. Fila já instalada com job em erro também não solicita conta nem reenvia o job. A escolha Manter sessão atual encerra a tentativa sem nova conexão.

A credencial permanece somente em memória durante a execução. Não aparece em argumentos, logs ou arquivos. Ao selecionar outro servidor, a credencial anterior não é aplicada a ele; um campo de usuário sem senha não obriga autenticação antes de tentar a sessão atual. Permissões do servidor continuam determinando se o acesso atual é aceito.

## Os três níveis

- Nativo: Add-Printer e confirmação da fila exata por Get-Printer, por até 10 segundos.
- Driver: identificar o nome/INF da fila, obter o pacote completo em print$\x64 ou print$\W32X86, copiar para um diretório temporário isolado, executar PnPUtil e registrar/confirmar o nome no Spooler. Repetir a conexão nativa uma vez.
- Local: Add-PrinterPort UNC e Add-Printer com o driver confirmado. Se o cmdlet retornar erro 87, a alternativa XcvData existente continua verificando a validação do monitor. Se o monitor também recusar, registrar a falha e encerrar.

Não há referências fixas a computadores, marcas ou modelos nos workers. Erros de autenticação/acesso ou rede não iniciam uma instalação cega de driver. Erro de validação do job depois da instalação não repete os níveis nem envia outro job.

## Pacotes e arquitetura

print$ é o compartilhamento de drivers, não necessariamente um pacote INF separado por impressora. Os arquivos em x64\3 podem ser compartilhados por vários drivers e não conter INF/CAT. A rotina usa o INF associado à fila ou o pacote publicado por essa fila/arquitetura; mapeamento ambíguo é recusado.

O servidor pode publicar um pacote INF completo de seu DriverStore, inclusive para drivers Tipo 4 quando disponível. Pacotes INF publicados têm manifestos com hashes e diretórios imutáveis para leitura concorrente. PnPUtil é executado apenas para o INF mapeado. Depois, Add-PrinterDriver usa o INF confirmado no DriverStore quando disponível.

Para Tipo 3 sem INF e sem monitor adicional, mantém-se o pacote legado de arquivos exportado pelo EXE. Arquivos do fabricante são conferidos por SHA-256; se o driver já existe, seus hashes são comparados antes de considerá-lo pronto. Diferenças são registradas pela API nativa. Os componentes básicos do Windows são obtidos do próprio cliente, sem substituir DLLs do Windows 10 por DLLs do Windows 11.

Cliente x86 precisa de driver x86; cliente x64 precisa de driver x64. A publicação pelo host prepara a arquitetura do processo atual; uma arquitetura adicional deve estar disponível no servidor. Pacotes incompatíveis com a versão do cliente, unsigned recusados pelo Windows, monitores/processadores adicionais sem pacote completo e ausência de INF/arquivos não podem ser corrigidos apenas por trocar os comandos.

PnPUtil usa /add-driver e /install desde Windows 10 1607. Nas builds anteriores, usa -i -a. Código 3010 fica registrado como RebootRequired; o programa não reinicia o PC automaticamente.

## Validação

Get-Printer confirma nome, porta e driver da fila local, ou UNC exato da fila remota. O retorno de processo/cmdlet sozinho não vale como sucesso.

A página de validação é renderizada pelo driver via GDI, em vez de mandar texto RAW que seria incompatível com parte dos modelos. StartDoc fornece um JobId; Get-PrintJob acompanha esse ID por até 10 segundos. Error, Retrying, Offline, PaperOut e Blocked produzem falha. Trabalho ainda presente produz resultado pendente. Outros jobs não são confundidos com o job de teste; QueueClean informa se a fila inteira está vazia.

Job que saiu da fila do cliente não comprova saída física no papel. QueueInstalled, JobValidated e PhysicalPrintConfirmed são campos distintos. Impressora desconectada ou pausada pode deixar a fila instalada e o teste pendente. Não reenviar automaticamente.

## Uso dos scripts completos

Distribua os três workers junto com IMPRESSAO-COMUM.ps1, ou use o EXE que incorpora todos. PowerShell 5.1, UTF-8 com BOM. Exemplo com parâmetros fornecidos pelo operador:

```powershell
# No servidor local, como administrador:
& .\CONECTAR-IMPRESSORA.ps1 -Server $env:COMPUTERNAME -ShareName $Compartilhamento -Method PrepareHost

# No cliente, em processo elevado com acesso de rede ao servidor:
& .\CONECTAR-IMPRESSORA.ps1 -Server $Servidor -ShareName $Compartilhamento -Method Cascade -ResultPath $ArquivoResultado

# Fila local, sem diálogos modais próprios:
& .\INSTALAR-PORTA-LOCAL.ps1 -Server $Servidor -ShareName $Compartilhamento -DriverName $DriverConfirmado
```

ResultPath produz CLIXML e arquivo .progress. Sem ResultPath, retorna um objeto ao chamador. Métodos antigos AddPrinter, WScript, PublishDriver e InstallDriver continuam disponíveis; Cascade é o padrão e é o método usado pela interface. QueueOnly dispensa a página em uma invocação explícita para teste de registro; a cascata da interface usa TestPage.

## Evidência desta entrega

- 14 testes automatizados passaram, incluindo oito cenários da cascata e casos de INF ambíguo/registro ausente.
- Windows 11: transferência SMB/registro temporário de Tipo 3 e rejeição de pacote adulterado passaram; driver de teste removido.
- Windows 11: GDI criou um job real em fila temporária pausada, retornou pendente e não anunciou impressão; job/fila removidos.
- Recursos embutidos conferidos contra os fontes, PowerShell 5.1 e BOM verificados.
- MPJOAO no Windows 10 e impressão física ainda não foram confirmadas nesta entrega. O erro 87 anterior pode continuar se o monitor do Windows 10 seguir recusando o UNC; a cascata não é uma garantia para todo hardware/política/build.

## Referências

- https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/pnputil-command-syntax
- https://learn.microsoft.com/en-us/windows/win32/printdocs/driver-info-8
- https://learn.microsoft.com/en-us/troubleshoot/windows-client/printing/windows-11-rpc-connection-updates-for-print
