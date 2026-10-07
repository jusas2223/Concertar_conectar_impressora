# Atendimento e validação — versão 1.11.0

## O que mudou

- Teste Windows e teste térmico usam um envio identificado pelo Spooler. Nome único do documento, JobId local, estado da fila e observação remota ficam registrados. Não há segunda impressão automática por erro ou demora.
- O programa separa fila instalada, documento aceito, documento observado no servidor e papel confirmado pelo usuário. Consulta remota negada/expirada é inconclusiva; um documento que desapareceu rapidamente pode não ser observado. IDs locais e remotos são independentes.
- Prazo/cancelamento após o envio preserva o registro do documento já aceito. Cancelar o acompanhamento não cancela automaticamente o documento. Use a fila para cancelar o trabalho.
- Instalação RAW/LPR confere IPv4, número de porta e configuração da porta existente. Não altera uma porta ocupada com configuração diferente. Só confirma instalação após consultar nome, porta e driver da fila.
- O driver da instalação por IP precisa ser escolhido; não há seleção automática por marca ou primeira posição da lista. Conexões compartilhadas continuam recebendo o driver pelo fluxo existente.
- Manutenção verifica cada ação separadamente. Reiniciar o Spooler não altera seu tipo de inicialização. Pausa e offline são ações independentes. A purga global continua explícita e cancela trabalhos de todas as impressoras.
- Diagnóstico JSON, comparação entre host/cliente, resumo e exportação ZIP são coletados sob demanda. Senhas, credenciais e comandos RAW são excluídos dos registros de suporte.

## Cancelar um documento ou limpar uma impressora

1. Abra **Fila e serviços → Atualizar Fila e Status**.
2. Selecione um documento e clique em **Cancelar documento selecionado**.
3. Para limpar uma impressora, escolha-a na lista e clique em **Limpar somente esta impressora**.

A limpeza usa os documentos existentes naquele momento; não cancela documentos que chegarem depois. Outras filas permanecem preservadas. IDs reutilizados por outro documento não são cancelados pela ação individual.

## Descobrir onde ficou o teste

Use **Página de teste** ou marque a opção de teste na conexão. O resultado informa o documento/ID e o estado local. Para uma fila UNC, há uma consulta limitada ao servidor usando a identidade dessa operação. Confirme saída no papel somente quando puder verificar a impressora física.

Em **Relatórios e logs → Resumo da última operação**, consulte o resultado registrado. Se a impressora estiver desconectada, não trate instalação como prova de impressão.

## Comparar os dois computadores

1. No computador que compartilha a impressora, abra **Relatórios e logs → Salvar diagnóstico deste PC**.
2. Transfira esse JSON ao cliente por um meio disponível.
3. No cliente, clique em **Comparar diagnóstico do host** e escolha o JSON.

O comparativo identifica compartilhamentos, presença do mesmo nome de driver, arquitetura, filas UNC por nome/IP, builds completas, políticas pertinentes e consultas indisponíveis. Um relatório antigo recebe aviso. Mesmo nome de driver não prova arquivos iguais ou permissão de impressão. O comparativo não modifica políticas.

## Exportar o atendimento

Em **Relatórios e logs → Exportar atendimento (ZIP)**, escolha onde salvar. O pacote contém o log atual do disco, tentativas estruturadas desta sessão, inventário/eventos e dados dos estados anteriores de políticas relacionados à sessão. Esses estados são dados de auditoria, não scripts de restauração. O ZIP pode conter nomes de computadores, usuários e documentos; compartilhe apenas com quem fará o atendimento.

## Conexão e leveza

Hostname permanece o padrão; IP continua disponível. A sessão atual é tentada primeiro. A opção **Win 11** mantém a conta explícita antes da conexão, com a correção de driver da 1.10.9. Conectar não aplica políticas nem reinicia Spooler automaticamente.

As novas coletas não participam da abertura. Mantidos Windows PowerShell 5.1, UTF-8 com BOM, WinForms e recursos incorporados no EXE, sem motor de navegador ou banco externo.

## Verificação e limites

Verificações automatizadas em PowerShell 5.1 cobrem a suíte anterior e novos cenários de acompanhamento/RAW, cancelamento/prazo, filas isoladas, manutenção, TCP/IP, comparação, exportação e ausência de segredos. As chamadas que alteram impressão/serviços foram substituídas por fixtures; houve diagnóstico real somente de leitura e prévias das interfaces pública e privada.

Não houve novo teste na VM, instalação real de impressora ou envio de página real nesta entrega. Não há garantia de compatibilidade com qualquer driver/build; os testes não substituem validação no equipamento conectado.

Esta entrega implementa as etapas 1 e 2 do plano: C1–C4 e A1–A3. Consolidação das telas, favoritos e demais recursos opcionais continuam para uma etapa posterior.
