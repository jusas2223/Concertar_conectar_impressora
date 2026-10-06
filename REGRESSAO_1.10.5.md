# Recuperação de conexão — 1.10.5

## Comparação com a versão que solicitava conta

O histórico identifica a versão 1.9.7.0, commit 86802f1, como a introdução da janela de conta antes da conexão. A 1.9.9 ainda mantinha esse comportamento. A partir da 1.10.1, o programa passou a tentar a sessão atual primeiro. Abrir a janela era uma diferença do fluxo, mas não explica sozinho toda falha de instalação.

Na 1.10.5, uma sessão aceita continua sem pergunta. Acesso remoto negado solicita uma conta uma vez. Se a conexão nativa falha com 709/11b/bcb e os demais níveis não instalam, o worker confere se o destino realmente é um compartilhamento de impressão e permite tentar outra conta. Usa a mesma identidade de rede isolada do fluxo anterior e valida a fila no usuário local. Não há filtro por nomes de computadores ou marcas.

## Regressões corrigidas

- Conectar aplicava políticas de cliente e reiniciava o Spooler. Agora essas alterações são explícitas, para evitar interromper outros PCs quando este cliente também compartilha uma impressora.
- A página era enviada mesmo com a opção desmarcada. Agora só é enviada quando solicitada.
- Um job pendente/erro fazia uma fila instalada aparecer como falha de conexão. Agora a interface mostra separadamente instalação e resultado do teste, sem repetir a conexão ou o job.
- A recusa SMB antes de iniciar o worker não deixava o motivo no log. Agora registra a etapa e orienta preparar o host no computador que compartilha a impressora.
- A preparação explícita do host verifica serviço Servidor, compartilhamento nos adaptadores ativos e três regras do aplicativo: TCP 445, TCP 135 e RPC dinâmico do processo spoolsv.exe. A resposta local 445 não é anunciada como prova de acesso remoto.
- A interface permite restaurar as políticas conhecidas de cliente/servidor pela primeira cópia válida. Não remove drivers, filas, permissões de print$, regras de firewall ou vínculos de adaptador. Valores alterados depois para algo diferente do aplicado são preservados.

## Como usar

1. No PC que compartilha a impressora, abra a 1.10.5, selecione a impressora em Impressoras locais e execute Preparar host e driver.
2. No outro PC, abra a 1.10.5, escolha hostname ou IP, selecione a fila e clique em Conectar. Deixe a página de teste desmarcada ao verificar apenas a instalação.
3. Se a janela de conta aparecer, informe uma conta do servidor e a senha de conta. O programa repete a operação uma vez.
4. Para desfazer políticas de compatibilidade do EXE, use Impressoras locais > Preparar cliente / restaurar políticas e escolha o papel. O Spooler só reinicia se houver valores a restaurar.

Trocar o EXE por uma versão antiga não desfaz políticas já aplicadas no Windows nem abre uma porta SMB bloqueada no servidor.

## Verificação e limites

- Windows PowerShell 5.1: 19 scripts passaram, incluindo 11 cenários de cascata e 22 de autenticação.
- Sintaxe/BOM, versão e conteúdo incorporado dos executáveis conferidos.
- Teste real em compartilhamento de uma impressora Argox, pelo mesmo fluxo usado no botão Conectar: conexão nativa e fila confirmadas; PID do Spooler e quantidade de cópias de políticas de cliente preservados; nenhuma solicitação de conta; nenhum novo job de validação automática.
- A fila já tinha um job de validação da versão anterior. A presença desse job foi distinguida de um novo envio.
- A VM não recebeu novas alterações nesta entrega: o acesso guestcontrol foi recusado pela conta de laboratório e o estado foi salvo novamente. Não se anuncia um novo teste Windows 10/11 bem sucedido.
- A conexão MP no Windows 10 e a impressão física não foram confirmadas nesta entrega. Driver compatível, autorização do servidor e acesso de rede continuam necessários.
