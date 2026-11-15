namespace Vokoma;

// Applying successfully exits the launcher through Velopack. Every returning
// failure path must leave the player usable, including an empty update feed.
public static class ApplyRecovery
{
    public static async Task Run(Func<Task<Action?>> prepare, Action waitForPlayer,
        Action<string> reportError, Action restartPlayer)
    {
        try {
            var apply = await prepare() ?? throw new InvalidOperationException("No applicable Windows update was found.");
            waitForPlayer();
            apply();
            throw new InvalidOperationException("The Windows updater returned without restarting the app.");
        } catch (Exception error) {
            try { reportError(error.ToString()); }
            finally {
                try { waitForPlayer(); }
                finally { restartPlayer(); }
            }
        }
    }
}
