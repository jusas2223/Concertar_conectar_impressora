# Abertura — versão 1.10.3

## Alterações

- A janela abre sem enumerar impressoras, jobs, drivers ou fazer varredura de rede.
- Impressoras locais e drivers para instalação por IP carregam na primeira visita à aba. Os botões Atualizar continuam executando uma consulta nova. Falha no carregamento permite nova tentativa.
- As abas de serviços e sessão remota consultam os dados quando selecionadas. A edição privada carrega seus dados específicos quando a respectiva aba é aberta.
- Construção direta dos controles WinForms e dos objetos de desenho por construtores do .NET, em vez de centenas de chamadas a New-Object. Layout do formulário suspenso durante a montagem e retomado antes da exibição.
- Executar o EXE a partir de pasta de rede usa logs locais, evitando testar escrita SMB durante a abertura. Caminho: %LOCALAPPDATA%\AssistenteImpressoras\Logs, com alternativa em %TEMP%.
- Tempo de inicialização do script registrado no log como Interface pronta em ... ms. Esse tempo começa depois que o PowerShell começou a executar o script.

## Medição local

Comparação da edição privada anterior (1.10.2) com a otimizada, no mesmo PC com Windows 11, usando subprocessos de Windows PowerShell 5.1. Duas execuções por versão, formulário completo e interface real, com janela transparente e fechamento automático no primeiro tick do loop de mensagens. O teste anterior inclui as consultas originais na abertura. Apenas consultas de leitura e logs temporários; nenhuma instalação de impressora ou alteração de configuração.

| Medida | Anterior, média | Otimizada, média |
|---|---:|---:|
| Início do script até loop de mensagens responsivo | 2.587 ms | 786 ms |
| Processo do teste, incluindo iniciar PowerShell e fechar janela | 4.066 ms | 2.163 ms |

Redução observada: aproximadamente 70% na inicialização do script/interface e 47% no teste completo. A edição pública otimizada também foi executada: 620 ms até loop responsivo e 1.785 ms no teste completo, em uma amostra.

Essas medições não incluem aceitar UAC, extrair recursos pelo launcher nem abrir o EXE pela rede. Não representam garantia de tempo nos PCs dos clientes. CPU, disco, antivírus, carregamento inicial do .NET/PowerShell e permissões podem alterar o resultado. O EXE continua sendo um iniciador .NET de Windows PowerShell 5.1; a arquitetura dos workers permanece a mesma.

A suíte de 17 scripts passou. verify-startup.ps1 verifica ausência de consultas antes da janela pronta, carregamento por aba, prevenção de repetição/reentrância e recuperação de falha. A otimização de abertura não comprova resolução do problema de conexão MP em um cliente real.