using System.Diagnostics;
using Velopack;
using Vokoma;

VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
void StartPlayer() {
    var player = Process.Start(new ProcessStartInfo(
        Path.Combine(AppContext.BaseDirectory, "vokoma.exe")) { UseShellExecute = false });
    player?.WaitForExit();
}
void ReportError(string error) {
    var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Vokoma");
    Directory.CreateDirectory(directory);
    File.WriteAllText(Path.Combine(directory, "updater-error.txt"), error);
}
try {
    if (args.Length == 3 && args[0] == "--apply") {
        void WaitForPlayer() {
            try { Process.GetProcessById(int.Parse(args[2])).WaitForExit(); }
            catch (ArgumentException) { /* The old player already exited. */ }
        }
        await ApplyRecovery.Run(async () => {
            var manager = new UpdateManager(args[1]);
            var update = await manager.CheckForUpdatesAsync();
            if (update == null) return null;
            await manager.DownloadUpdatesAsync(update);
            return () => manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
        }, WaitForPlayer, ReportError, StartPlayer);
    } else {
        StartPlayer();
    }
} catch (Exception error) {
    ReportError(error.ToString());
    Environment.ExitCode = 1;
}
