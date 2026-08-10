// Vento launcher: elevates via manifest, then runs app.ps1 hidden.
// Build: build\build-exe.ps1
using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Windows.Forms;

[assembly: AssemblyTitle("Vento")]
[assembly: AssemblyProduct("Vento")]
[assembly: AssemblyDescription("Lightweight fan monitoring & control")]
[assembly: AssemblyCompany("Blakfy")]
[assembly: AssemblyCopyright("MIT License")]
[assembly: AssemblyVersion("1.3.0.0")]
[assembly: AssemblyFileVersion("1.3.0.0")]

static class Program
{
    [STAThread]
    static void Main()
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "app.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("app.ps1 was not found next to Vento.exe.", "Vento",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
            return;
        }
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File \"" + script + "\"",
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = dir
        };
        try { Process.Start(psi); }
        catch (Exception ex)
        {
            MessageBox.Show("Could not start Vento: " + ex.Message, "Vento",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }
}
