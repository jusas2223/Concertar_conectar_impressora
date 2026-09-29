# Arrumar Impressora VG

Assistente portátil para diagnosticar e configurar impressoras no Windows 10 e 11. Esta é a edição preparada para um repositório público, com oito abas e sem integração com sistemas de gestão privados.

Versão atual: **1.9.6**.

## Funções

- Diagnóstico do computador, do Spooler e das filas instaladas.
- Busca de impressoras compartilhadas na rede e conexão por nome ou IP.
- Instalação por caminho UNC ou por porta TCP/IP, com seleção de driver.
- Diagnóstico de compatibilidade Windows 10 → Windows 11 e alternativa por porta local UNC.
- Diagnóstico da fila remota com indicação de acesso negado, nome do driver remoto quando disponível e presença desse driver no cliente.
- Busca manual com usuário e senha do computador servidor; a senha não é enviada em argumentos de linha de comando. O fluxo de conexão orienta a elevação quando o Windows exige administrador para instalar o driver.
- Conexão RPC com as credenciais informadas na busca manual ou diretamente antes de clicar em **Conectar Impressora Selecionada**. O log indica se a conexão usou a conta do servidor ou a identidade local, sem registrar a senha.
- Análise de filas, trabalhos presos e redirecionamento de impressoras por Área de Trabalho Remota.
- Correções guiadas para erros 0x00000709/0x0000011b e acesso à rede no Windows 11 24H2, com registro das alterações e scripts de restauração.
- Modo Simulação para examinar o fluxo sem aplicar alterações.

## Executar

No Windows, abra `Arrumar_impressoraVG.exe`. Algumas operações exigem privilégios de administrador. As correções de políticas e a limpeza de filas só ocorrem quando o usuário aciona os respectivos botões.

Para uma impressora USB compartilhada por outro PC, confirme que a conta informada na busca manual tem senha e permissão **Imprimir** no servidor. Se o driver não estiver no cliente, use **Instalar via porta local → Instalar driver...** para abrir o instalador oficial assinado do fabricante; o programa verifica depois se o driver apareceu no Windows. A impressora física precisa estar conectada para confirmar a página de teste.

No laboratório Windows 10 → Windows 11, a fila `ArgoxRede` foi registrada após autenticar o processo de impressão e instalar o driver correspondente no cliente. Na fila `MP`, a abertura remota com credenciais funcionou, mas a instalação da fila não terminou: o driver `MP-4200 TH` não está instalado na VM. Nenhum teste enviou uma página física.

Logs e relatórios são criados na pasta `Logs` ao lado do EXE quando há permissão de escrita. Caso contrário, o assistente usa uma pasta local gravável. A pasta `Logs` não deve ser publicada.

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
