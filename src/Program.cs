using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;
using System.Windows.Forms;

[assembly: AssemblyTitle("Arrumar Impressora VG")]
[assembly: AssemblyDescription("Diagnostico e configuracao de impressoras")]
[assembly: AssemblyProduct("Arrumar Impressora VG")]
[assembly: AssemblyVersion("1.10.1.0")]
[assembly: AssemblyFileVersion("1.10.1.0")]

namespace AssistenteImpressorasLauncher
{
    internal static class Program
    {
        private const string ResourceName = "AssistenteImpressoras.AssistenteImpressoras.ps1";
        private const string PrinterFixResource = "AssistenteImpressoras.CORRIGIR-ERRO-IMPRESSORA.ps1";
        private const string PrinterRestoreResource = "AssistenteImpressoras.RESTAURAR-ERRO-IMPRESSORA.ps1";
        private const string NetworkFixResource = "AssistenteImpressoras.CORRIGIR-ACESSO-REDE-24H2.ps1";
        private const string NetworkRestoreResource = "AssistenteImpressoras.RESTAURAR-ACESSO-REDE.ps1";
        private const string LocalPortResource = "AssistenteImpressoras.INSTALAR-PORTA-LOCAL.ps1";
        private const string InterfaceResource = "AssistenteImpressoras.INTERFACE.ps1";
        private const string ServerDriverResource = "AssistenteImpressoras.DRIVER-DO-SERVIDOR.ps1";
        private const string ConnectionResource = "AssistenteImpressoras.CONECTAR-IMPRESSORA.ps1";
        private const string CompatibilityDiagnosisResource = "AssistenteImpressoras.Diagnostico_Compartilhamento.ps1";

        [STAThread]
        private static int Main(string[] args)
        {
            var principal = new System.Security.Principal.WindowsPrincipal(System.Security.Principal.WindowsIdentity.GetCurrent());
            if (!principal.IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator))
            {
                try
                {
                    var elevated = new ProcessStartInfo(Assembly.GetExecutingAssembly().Location);
                    elevated.UseShellExecute = true;
                    elevated.Verb = "runas";
                    Process.Start(elevated);
                    return 0;
                }
                catch (System.ComponentModel.Win32Exception) { return 1223; }
            }
            string workDirectory = null;
            try
            {
                workDirectory = Path.Combine(Path.GetTempPath(),
                    "AssistenteImpressoras_" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(workDirectory);
                string scriptPath = ExtractResource(ResourceName, workDirectory, "AssistenteImpressoras.ps1");
                string printerFixPath = ExtractResource(PrinterFixResource, workDirectory, "CORRIGIR-ERRO-IMPRESSORA.ps1");
                ExtractResource(PrinterRestoreResource, workDirectory, "RESTAURAR-ERRO-IMPRESSORA.ps1");
                string networkFixPath = ExtractResource(NetworkFixResource, workDirectory, "CORRIGIR-ACESSO-REDE-24H2.ps1");
                ExtractResource(NetworkRestoreResource, workDirectory, "RESTAURAR-ACESSO-REDE.ps1");
                string localPortPath = ExtractResource(LocalPortResource, workDirectory, "INSTALAR-PORTA-LOCAL.ps1");
                string connectionPath = ExtractResource(ConnectionResource, workDirectory, "CONECTAR-IMPRESSORA.ps1");
                ExtractResource(ServerDriverResource, workDirectory, "DRIVER-DO-SERVIDOR.ps1");
                ExtractResource("AssistenteImpressoras.IMPRESSAO-COMUM.ps1", workDirectory, "IMPRESSAO-COMUM.ps1");
                ExtractResource(InterfaceResource, workDirectory, "INTERFACE.ps1");
                string compatibilityDiagnosisPath = ExtractResource(CompatibilityDiagnosisResource, workDirectory, "Diagnostico_Compartilhamento.ps1");

                string appDirectory = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
                string launcherPath = Assembly.GetExecutingAssembly().Location;
                string arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File " +
                    Quote(scriptPath) + " -AppDirectory " + Quote(appDirectory) +
                    " -LauncherPath " + Quote(launcherPath) +
                    " -PrinterFixPath " + Quote(printerFixPath) +
                    " -NetworkFixPath " + Quote(networkFixPath) +
                    " -LocalPortInstallPath " + Quote(localPortPath) +
                    " -PrinterConnectionPath " + Quote(connectionPath) +
                    " -CompatibilityDiagnosisPath " + Quote(compatibilityDiagnosisPath);
                ProcessStartInfo start = new ProcessStartInfo("powershell.exe", arguments);
                start.UseShellExecute = false;
                start.CreateNoWindow = true;
                using (Process process = Process.Start(start))
                {
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            catch (Exception ex)
            {
                MessageBox.Show("Erro ao executar o assistente:\n\n" + ex.Message,
                    "Erro", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
            finally
            {
                if (workDirectory != null && Directory.Exists(workDirectory))
                {
                    try
                    {
                        foreach (string file in Directory.GetFiles(workDirectory)) File.Delete(file);
                        Directory.Delete(workDirectory);
                    }
                    catch { /* Arquivos em uso permanecem na pasta temporaria ate a proxima limpeza do Windows. */ }
                }
            }
        }

        private static string ExtractResource(string resourceName, string directory, string fileName)
        {
            using (Stream resource = Assembly.GetExecutingAssembly().GetManifestResourceStream(resourceName))
            {
                if (resource == null) throw new InvalidOperationException("Recurso interno ausente: " + fileName);
                string path = Path.Combine(directory, fileName);
                using (FileStream output = File.Create(path)) resource.CopyTo(output);
                return path;
            }
        }

        private static string Quote(string text)
        {
            StringBuilder result = new StringBuilder("\"");
            int slashes = 0;
            foreach (char character in text)
            {
                if (character == '\\') { slashes++; }
                else if (character == '"')
                {
                    result.Append('\\', slashes * 2 + 1);
                    result.Append('"');
                    slashes = 0;
                }
                else
                {
                    result.Append('\\', slashes);
                    result.Append(character);
                    slashes = 0;
                }
            }
            result.Append('\\', slashes * 2);
            result.Append('"');
            return result.ToString();
        }
    }
}
