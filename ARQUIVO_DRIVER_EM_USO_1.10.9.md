# Registro de driver e arquivo em uso — 1.10.9

A instalação do pacote legado podia forçar a cópia de todos os arquivos (`APD_COPY_ALL_FILES`), incluindo arquivos idênticos já em uso pelo Spooler ou por um aplicativo. O modo de cópia foi alterado para `APD_COPY_NEW_FILES | APD_COPY_FROM_DIRECTORY`. A [documentação da Microsoft](https://learn.microsoft.com/en-us/windows/win32/printdocs/addprinterdriverex) distingue a cópia forçada de todos os arquivos da cópia de arquivos mais novos.

Arquivos locais do fabricante com SHA-256 idêntico são reutilizados antes do registro. Um driver existente só é aceito se nome, arquitetura, Tipo 3, arquivos e vínculos do cadastro corresponderem ao pacote. Depois da chamada de instalação, há confirmação por esses mesmos critérios; retorno nativo de sucesso sozinho não basta.

Erros locais 32/33 permitem até três chamadas de registro, com esperas de 300 e 600 ms. Outros erros interrompem a instalação. O prazo externo do worker permanece. Se o bloqueio persistir, o resultado preserva código, driver, tentativas e caminhos enviados ao registro. Não identifica um processo ou arquivo específico como culpado sem evidência.

Falha local de arquivo em uso não provoca consulta de nome de compartilhamento nem pedido de outra senha. O nome do driver não é apagado pela cascata ao ocorrer uma falha de transferência. O log inclui a política de cópia e a quantidade de chamadas.

O cabeçalho de log da 1.10.8 ainda declarava 1.10.7; foi corrigido. O teste de empacotamento agora exige que a versão no cabeçalho corresponda à versão do executável.

## Uso

Abra o EXE 1.10.9 e repita a tentativa usando a caixa Win 11. Não é necessário preparar novamente um pacote válido já publicado no host. Se o código 32/33 persistir, feche aplicativos e janelas de impressão que possam estar usando o driver. A ação explícita de reiniciar o Spooler continua em Fila e serviços; a conexão não reinicia o serviço automaticamente.

O recebimento e a autenticação de rede são etapas diferentes do registro local do driver. A correção não comprova instalação ou impressão física em um cliente real até a tentativa ser validada.

## Testes

O teste `verify-driver-file-in-use.ps1` executa o código real de construção da chamada C# com a API de impressão substituída por um stub. Verifica flags 0x18, arquivo idêntico reutilizado, driver já confirmado, erros transitórios 32/33, bloqueio persistente, outro erro sem repetição e rejeição de cadastro/arquivos incorretos após retorno de sucesso. Nenhum driver real é instalado pelo teste.
