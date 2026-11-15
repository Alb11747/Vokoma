using System.Diagnostics;
using Velopack;

// Dart owns policy and signature verification. Never auto-apply an unauthenticated
// package on startup; only the explicit --apply path may invoke the updater.
VelopackApp.Build().SetAutoApplyOnStartup(false).Run();
try {
    if (args.Length == 3 && args[0] == "--apply") {
        var manager = new UpdateManager(args[1]);
        var update = await manager.CheckForUpdatesAsync();
        if (update == null) return;
        await manager.DownloadUpdatesAsync(update);
        // The Flutter process holds the playback gate until it exits.
        try { Process.GetProcessById(int.Parse(args[2])).WaitForExit(); }
        catch (ArgumentException) { /* It already exited. */ }
        manager.ApplyUpdatesAndRestart(update.TargetFullRelease);
        return;
    }
    var player = Process.Start(new ProcessStartInfo(
        Path.Combine(AppContext.BaseDirectory, "vokoma.exe")) { UseShellExecute = false });
    player?.WaitForExit();
} catch (Exception error) {
    // WinExe has no console: retain diagnostics in the user's app data.
    var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Vokoma");
    Directory.CreateDirectory(directory);
    File.WriteAllText(Path.Combine(directory, "updater-error.txt"), error.ToString());
    Environment.ExitCode = 1;
}
