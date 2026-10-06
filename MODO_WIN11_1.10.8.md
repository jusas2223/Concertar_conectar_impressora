# Modo Win 11 — versão 1.10.8

Na aba Impressoras na rede, a caixa **Win 11** fica ao lado do botão verde **Conectar impressora**. É uma escolha manual de autenticação, sem consulta prévia da versão do servidor. Pode ser usada também com outros Windows.

## Como usar

1. Selecione a impressora compartilhada na tabela.
2. Marque **Win 11**. A janela abre com o hostname/IP da seleção, usuário e senha.
3. Informe a conta do computador servidor e a senha dessa conta, não o PIN. Um usuário sem domínio é completado como `SERVIDOR\usuario`.
4. Clique em **Usar esta conta** e depois no botão verde **Conectar impressora**.

O hostname/IP pode ser editado na janela; o nome do compartilhamento selecionado é mantido. A conta é usada no processo de impressão desde a primeira tentativa, incluindo a obtenção do driver e a alternativa por porta local. Não há primeira tentativa com identidade local nem segundo pedido de conta nessa operação. A senha não vai para arquivo, log ou argumentos de processo.

Cancelar a janela ao marcar a opção desmarca a caixa. A informação é consumida pela tentativa seguinte; se você trocar a impressora ou conectar novamente com a opção marcada, a janela pede a conta novamente. Desmarcar descarta a informação pendente. Credenciais já autenticadas continuam com a regra de reutilização em memória da versão anterior.

Com a caixa **desmarcada**, continua a conexão automática da 1.10.7: tenta a sessão disponível e oferece outra conta quando necessário. A opção não altera políticas, não reinicia serviços e não envia página de teste sem a escolha existente do usuário.

## Verificação

Testes em Windows PowerShell 5.1 exercitam as entradas, o código de autenticação antes da cascata, os eventos reais da caixa e do botão verde, troca de servidor, cancelamento, prazo, erros de driver e trabalho pendente. A interface das duas edições é renderizada nas larguras 1180 e 1280 para verificar a posição dos controles.

Estes testes confirmam o fluxo do programa. A conexão real e a impressão física com esse modo ainda precisam de validação no laboratório. A VM não foi iniciada nesta entrega.
