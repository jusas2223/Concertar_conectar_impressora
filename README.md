# Arrumar Impressora VG

Assistente portátil para diagnosticar e configurar impressoras no Windows 10 e 11. Esta é a edição preparada para um repositório público, com oito abas e sem integração com sistemas de gestão privados.

Versão atual: **1.10.6**.

A conexão executa uma cascata: conexão nativa, recebimento automático de pacote INF/driver pela rede e alternativa por porta local UNC. Confirma a fila no Windows. A página de teste é opcional e acompanhada pelo JobId; um job pendente não é apresentado como falha de instalação da fila.

No servidor, use **Impressoras locais → Preparar host e driver**. No cliente, selecione a fila e clique em **Conectar impressora**, deixando usuário e senha em branco para usar a sessão atual do Windows. Outra conta é solicitada após recusa de acesso ou quando o compartilhamento de impressão foi confirmado e a cascata não instalou após 709/11b/bcb. Uma conta já confirmada é reutilizada enquanto o aplicativo estiver aberto. O EXE pede elevação antes de coletar as credenciais. Conectar não aplica políticas nem reinicia o Spooler; a preparação é uma ação explícita.

**Impressoras locais → Preparar cliente / restaurar políticas** permite preparar o cliente ou restaurar as políticas de cliente/servidor a partir da primeira cópia válida salva pelo EXE. [Correção das regressões e comparação com 1.9.7](REGRESSAO_1.10.5.md).

Na aba **Impressoras da rede**, escolha **Conectar por → Nome do computador (hostname)**, que é o padrão, ou **Endereço IP**. O caminho escolhido aparece ao lado. A mesma escolha é aplicada à autenticação, à conexão e à porta local.

A abertura não consulta impressoras, trabalhos ou drivers. Essas listas carregam ao entrar nas respectivas abas; os botões Atualizar continuam disponíveis. Os controles usam construção direta do .NET e montagem com layout suspenso. [Medições e limites da otimização](PERFORMANCE.md).

[Documentação completa, parâmetros, políticas e limites](CASCATA_WIN10_WIN11.md).

As demais funções de diagnóstico, busca na rede, filas, instalação por IP, correções guiadas e Área de Trabalho Remota permanecem na interface WinForms. O modo Simulação impede alterações e envio de jobs pelo fluxo da interface.

A busca de rede encerra o indicador, restaura os botões e preserva o resultado da varredura em sucesso, erro ou limite de tempo. Consultas de nome têm prazo e não recorrem a WMI remoto. [Correção da busca na versão 1.10.6](CORRECAO_VARREDURA_1.10.6.md).

Um pacote compatível com a arquitetura/Windows do cliente é necessário. print$ pode conter apenas arquivos de um driver legado sem INF; nesse caso, o EXE do servidor precisa preparar o pacote aplicável. A porta UNC continua sujeita à validação do Windows. A versão não garante compatibilidade com qualquer driver/build, e a conexão MP no Windows 10 ainda aguarda confirmação real.

Logs e relatórios são criados na pasta Logs ao lado do EXE quando gravável, ou em pasta local alternativa. Não publique logs ou credenciais.

## Compilar

Requer Windows com PowerShell 5.1 e .NET Framework 4.x. Na raiz do projeto:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\src\build.ps1
```

O comando gera `Arrumar_impressoraVG.exe` na raiz. O EXE incorpora os scripts necessários; não é preciso distribuir `src` para executá-lo.

## Verificar

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\run.ps1
```

Os testes cobrem sintaxe, conteúdo incorporado ao EXE, descoberta, autenticação, limite de tempo de conexão, instalação por porta local, diagnósticos e planos de correção. Eles não substituem um teste de impressão em uma rede real: instalação de drivers, permissões e acesso à fila dependem dos computadores envolvidos.

## Estrutura

- `src/AssistenteImpressoras.ps1`: interface e fluxos principais.
- `src/Program.cs`: iniciador Windows que incorpora e executa os scripts.
- `src/build.ps1`: compilação do EXE.
- `src/scripts/`: rotinas auxiliares incorporadas ao EXE.
- `Diagnostico_Compartilhamento.ps1`: diagnóstico independente, somente leitura.
- `tests/`: verificações automatizadas.

Esta edição não inclui dados de atendimento, logs, drivers de fabricantes nem arquivos da máquina virtual de testes.

Consulte [Autenticação sob demanda](AUTENTICACAO.md) para o pedido de conta nos botões de conexão, driver e porta local, os testes e os limites da versão 1.10.6.
