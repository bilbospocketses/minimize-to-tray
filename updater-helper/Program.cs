// updater-helper: Velopack update bridge for the AHK-based minimize-to-tray app.
//
// CLI:
//   updater-helper.exe check    -> prints "<version>" on stdout if an update is available, else nothing.
//                                  Always exits 0 (a non-zero exit would surface to the AHK script as a "broken
//                                  helper", which is worse UX than "no update detected").
//   updater-helper.exe update   -> downloads + applies + restarts the parent app. Does not return on success
//                                  (ApplyUpdatesAndRestart relaunches the main exe and exits this helper).
//                                  Exits 1 on failure with error info on stderr.
//
// The AHK script (minimize-to-tray.ahk) invokes this via WScript.Shell.Exec on startup ("check"),
// and on user-click of the pulsing blue dot in the About dialog ("update").

using System;
using System.Threading.Tasks;
using Velopack;
using Velopack.Sources;

namespace MinimizeToTray.UpdaterHelper;

internal static class Program
{
    private const string RepoUrl = "https://github.com/bilbospocketses/minimize-to-tray";

    private static async Task<int> Main(string[] args)
    {
        // Required Velopack initialization hook. Processes any Velopack lifecycle args
        // (e.g. install/uninstall/firstrun) and returns immediately when none are present.
        VelopackApp.Build().Run();

        if (args.Length == 0)
        {
            Console.Error.WriteLine("Usage: updater-helper.exe <check|update>");
            return 2;
        }

        var source = new GithubSource(RepoUrl, accessToken: null, prerelease: false);
        var manager = new UpdateManager(source);

        return args[0].ToLowerInvariant() switch
        {
            "check"  => await DoCheckAsync(manager),
            "update" => await DoUpdateAsync(manager),
            _        => UnknownCommand(args[0]),
        };
    }

    private static async Task<int> DoCheckAsync(UpdateManager manager)
    {
        try
        {
            var info = await manager.CheckForUpdatesAsync();
            if (info is not null)
            {
                // stdout: the new version string only. AHK script trims and compares to APP_VERSION.
                Console.WriteLine(info.TargetFullRelease.Version);
            }
            return 0;
        }
        catch (Exception ex)
        {
            // Don't surface as a script-visible error - the user just sees "no update detected".
            // Diagnostics go to stderr for log scraping if needed.
            Console.Error.WriteLine($"check failed: {ex.Message}");
            return 0;
        }
    }

    private static async Task<int> DoUpdateAsync(UpdateManager manager)
    {
        try
        {
            var info = await manager.CheckForUpdatesAsync();
            if (info is null)
            {
                Console.Error.WriteLine("update: no newer release found");
                return 0;
            }
            await manager.DownloadUpdatesAsync(info);
            manager.ApplyUpdatesAndRestart(info);
            // Unreachable: ApplyUpdatesAndRestart replaces our process.
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"update failed: {ex.Message}");
            return 1;
        }
    }

    private static int UnknownCommand(string cmd)
    {
        Console.Error.WriteLine($"Unknown command: {cmd}");
        Console.Error.WriteLine("Usage: updater-helper.exe <check|update>");
        return 2;
    }
}
