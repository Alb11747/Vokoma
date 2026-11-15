using Vokoma;

foreach (var scenario in new[] { "empty feed", "check failure", "download failure", "apply failure", "unexpected return" }) {
    var events = new List<string>();
    await ApplyRecovery.Run(() => {
        if (scenario == "empty feed") return Task.FromResult<Action?>(null);
        if (scenario == "check failure" || scenario == "download failure") throw new IOException(scenario);
        return Task.FromResult<Action?>(() => {
            events.Add("apply");
            if (scenario == "apply failure") throw new IOException(scenario);
        });
    }, () => events.Add("wait"), error => {
        if (string.IsNullOrWhiteSpace(error)) throw new Exception("Missing diagnostic");
        events.Add("error");
    }, () => events.Add("restart"));
    if (events.Last() != "restart" || events.Count(e => e == "restart") != 1 ||
        events[^2] != "wait" || !events.Contains("error")) throw new Exception($"Recovery failed: {scenario}");
    Console.WriteLine($"Passed: {scenario}");
}
