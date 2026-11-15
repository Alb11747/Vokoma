import 'package:flutter/material.dart';

import 'release.dart';
import 'update_service.dart';

class UpdateScreen extends StatelessWidget {
  const UpdateScreen({super.key});
  @override
  Widget build(BuildContext context) {
    final service = UpdateService.instance;
    return ListenableBuilder(
      listenable: service,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('About / updates')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Vokoma ${service.currentVersion}'),
            DropdownButton<UpdateChannel>(
              value: service.channel,
              items: [
                for (final channel in UpdateChannel.values) DropdownMenuItem(value: channel, child: Text(channel.name)),
              ],
              onChanged: (value) async {
                if (value != null) await service.configure(value, service.policy);
              },
            ),
            DropdownButton<InstallPolicy>(
              value: service.policy,
              items: const [
                DropdownMenuItem(value: InstallPolicy.restart, child: Text('Install on next restart')),
                DropdownMenuItem(value: InstallPolicy.idle, child: Text('Install when idle, never during playback')),
              ],
              onChanged: (value) async {
                if (value != null) await service.configure(service.channel, value);
              },
            ),
            Text('Last check: ${service.lastCheck?.toLocal() ?? 'Never'}'),
            Text(service.status),
            OutlinedButton(onPressed: service.check, child: const Text('Check now')),
          ],
        ),
      ),
    );
  }
}
