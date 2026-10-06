# Busca de rede — 1.10.6

## Correções

- Todo o início da busca e o encerramento do indicador ficam dentro de try/finally. Erro na preparação da lista também encerra a animação.
- O encerramento para o timer, desativa a barra animada, oculta o painel, limpa a mensagem de carregamento, restaura o cursor e o botão.
- A mensagem de conclusão permanece no rodapé; não é substituída por Pronto antes de o usuário ver o resultado.
- Uma busca em andamento não pode iniciar outra. Conexão e busca manual dessa aba ficam desabilitadas durante a varredura e voltam ao estado anterior ao terminar.
- Resolução de nome não inicia WMI remoto sem prazo. DNS, consultas CIM locais e Active Directory usam consultas com limite de tempo.
- A busca usa um orçamento de 60 segundos antes de iniciar mais consultas de endereços. A consulta já em andamento pode terminar após esse prazo. Resultados encontrados são preservados; resultado parcial orienta buscar o servidor específico.
- Resultado de conexão sem histórico, como cancelamento ou prazo excedido, não envia mensagem vazia ao logger. Evita ocultar o resultado original por erro de registro.

## Autenticação nos dois sentidos

O mesmo fluxo atende Windows 11 → 10 e Windows 10 → 11:

1. Tenta a sessão atual, ou a conta daquele servidor já informada nesta execução.
2. Após recusa de acesso remoto, oferece outra conta uma vez. Também oferece recuperação quando a conexão nativa retornou 709/11b/bcb, a cascata não instalou e o compartilhamento foi confirmado como fila de impressão.
3. A conta pertence ao PC que compartilha a impressora. Usa a senha de conta, não o PIN.
4. Repete uma vez com a conta informada e confere a fila. Se a sessão atual já permite conectar, não solicita senha.

O preparo do host e do driver ocorre no PC que compartilha a impressora. O pedido de conta não substitui driver compatível, permissão na fila ou acesso de rede.

## Verificação

- 20 scripts passaram em Windows PowerShell 5.1. O teste da busca cobre sucesso, nenhum resultado, erro, erro ao iniciar o indicador, reentrância e orçamento de tempo.
- Os 22 cenários de autenticação e 11 cenários da cascata continuam passando.
- Busca real limitada ao servidor de teste: cinco impressoras, 1.727 ms, status REDE: OK; painel/timer desligados, cursor normal, botão habilitado.
- Executáveis privado e público recompilados; recursos incorporados conferidos.
- Não houve nova confirmação real da MP em Windows 10 → 11 nesta entrega.
