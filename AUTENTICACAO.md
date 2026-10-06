# Autenticação sob demanda — versão 1.10.5

## Como usar

No servidor, prepare o host e o driver da fila compartilhada. No cliente, selecione o computador pelo hostname (padrão) ou IP e clique em Conectar. Não é necessário preencher uma conta antes de tentar: o programa usa a sessão atual.

Se o Windows identificar recusa de acesso remoto, a janela de conta informa a etapa e o recurso recusado. Digite uma conta do computador servidor, por exemplo `COMPUTADOR\usuario`, e sua senha de conta, não o PIN. A mesma rotina atende Conectar, Instalar por caminho, Receber driver e Instalar via porta local.

Na cascata, uma fila confirmada como compartilhamento de impressão também permite oferecer outra conta após falha nativa 709/11b/bcb e falha dos demais níveis. Recupera a tentativa com credencial explícita da versão 1.9.7 sem pedir senha quando a sessão atual já conecta. Uma tentativa com conta explícita não abre novamente essa oferta por erro ambíguo.

O programa solicita uma conta e repete a operação no máximo uma vez por ação. Uma conta anterior recusada pode ser substituída. Cancelar encerra; Manter sessão atual conserva o erro da primeira tentativa sem repetir a operação.

## O que foi corrigido

- O worker de transferência devolve código nativo, etapa, recurso, escopo local/remoto e indicação de autenticação necessária.
- Acesso negado ao driver não é anunciado como pacote ausente e não fica oculto pelo 709 de uma tentativa anterior.
- Arquivos remotos são abertos para leitura; falhas de criação/gravação local não pedem senha de rede.
- A credencial solicitada usa o worker com identidade de rede isolada. Pastas e sessões SMB de outras aplicações não são desconectadas para substituí-la.
- O worker confere a sessão de rede e, quando a recusa veio de print$, verifica também leitura do recurso solicitado. A instalação e a fila ainda precisam de suas próprias validações.
- Erro local ao criar uma porta só permite solicitar conta quando uma consulta da fila remota também comprova recusa de acesso/autenticação.
- Cancelamento, prazo excedido e fila já instalada com job pendente/erro não iniciam outra tentativa ou outro job.

Um código 709 ou 87 isolado não comprova senha ausente. Pacote inexistente, servidor indisponível, conflito de sessão 1219 e elevação local recusada recebem seus próprios erros. Se a conta continua sem permissão, informar uma senha não altera a autorização do servidor.

## Verificação da entrega

19 scripts de verificação passaram em Windows PowerShell 5.1, incluindo 22 cenários de autenticação e 11 cenários de cascata. Cobrem recusa de leitura do driver após 709, substituição de credencial recusada, senha rejeitada, cancelamento, ausência de pacote, erro local, conta alternativa após 709 com compartilhamento confirmado, erro 87, job em erro e limite de repetição.

O worker real de sessão/leitura foi executado no host, sem alterar conta, driver ou fila. Esse host permitiu a leitura também na tentativa com identidade alternativa; portanto esse teste não comprova rejeição real de senha em outro servidor. As recusas de acesso foram verificadas com fixtures controladas.

Os testes não comprovam impressão física nem encerram a validação da MP em um cliente Windows 10 real. Acesso já permitido não exige senha. A nova oferta após fila confirmada é uma tentativa de recuperação; não declara que 709 ou 87 sejam sempre erros de autenticação.
