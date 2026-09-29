import 'package:flutter/material.dart';
import 'package:app_settings/app_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'permission_service.dart';

class PermissionsOnboardingScreen extends StatefulWidget {
  final VoidCallback onComplete;
  const PermissionsOnboardingScreen({super.key, required this.onComplete});

  @override
  State<PermissionsOnboardingScreen> createState() =>
      _PermissionsOnboardingScreenState();
}

class _PermissionsOnboardingScreenState
    extends State<PermissionsOnboardingScreen> {
  Map<String, bool> _statuses = {
    'notifications': false,
    'microphone': false,
    'alarms': false,
  };
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final s = await PermissionService.checkAll();
    setState(() {
      _statuses = s;
      _loading = false;
    });
  }

  Future<void> _markSeenAndContinue() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('permissions_seen', true);
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allGranted = _statuses.values.every((v) => v);

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 16),
              Icon(Icons.eco, size: 48, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text('App Permissions',
                  style: theme.textTheme.headlineMedium
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(
                'Trini Agri Assistant needs a few permissions to send you '
                'schedule reminders and accept voice input.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 32),
              if (_loading)
                const Center(child: CircularProgressIndicator())
              else ...[
                _PermissionTile(
                  icon: Icons.notifications_active,
                  title: 'Notifications & Reminders',
                  subtitle: 'Receive alerts for watering, fertilising, '
                      'and other scheduled tasks.',
                  granted: _statuses['notifications'] ?? false,
                  onRequest: () async {
                    await PermissionService.requestNotifications();
                    await _refresh();
                  },
                  onOpenSettings: () async {
                    await AppSettings.openAppSettings(
                        type: AppSettingsType.notification);
                    await _refresh();
                  },
                ),
                const SizedBox(height: 16),
                _PermissionTile(
                  icon: Icons.alarm,
                  title: 'Exact Alarms',
                  subtitle:
                      'Required for precise schedule notifications on Android 12+.',
                  granted: _statuses['alarms'] ?? false,
                  onRequest: () async {
                    await PermissionService.requestNotifications();
                    await _refresh();
                  },
                  onOpenSettings: () async {
                    await AppSettings.openAppSettings(
                        type: AppSettingsType.alarm);
                    await _refresh();
                  },
                ),
                const SizedBox(height: 16),
                _PermissionTile(
                  icon: Icons.mic,
                  title: 'Microphone',
                  subtitle:
                      'Used for voice-entry of yield logs. Optional if you prefer typing.',
                  granted: _statuses['microphone'] ?? false,
                  onRequest: () async {
                    await PermissionService.requestMicrophone();
                    await _refresh();
                  },
                  onOpenSettings: () async {
                    await AppSettings.openAppSettings(
                        type: AppSettingsType.settings);
                    await _refresh();
                  },
                ),
              ],
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _markSeenAndContinue,
                  style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16)),
                  child: Text(allGranted ? 'Get Started' : 'Continue Anyway'),
                ),
              ),
              if (!allGranted) ...[
                const SizedBox(height: 8),
                Center(
                  child: Text(
                    'You can change permissions later in Settings.',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Colors.grey),
                  ),
                ),
              ]
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Reusable tile ────────────────────────────────────────────────────────────

class _PermissionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool granted;
  final VoidCallback onRequest;
  final VoidCallback onOpenSettings;

  const _PermissionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.granted,
    required this.onRequest,
    required this.onOpenSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: granted
              ? Colors.green.shade300
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon,
                size: 32,
                color: granted ? Colors.green : theme.colorScheme.primary),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(title,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(width: 8),
                      if (granted)
                        const Icon(Icons.check_circle,
                            size: 16, color: Colors.green),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(subtitle, style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (!granted)
              TextButton(
                onPressed: onRequest,
                child: const Text('Enable'),
              ),
            if (granted)
              TextButton(
                onPressed: onOpenSettings,
                child: const Text('Settings'),
              ),
          ],
        ),
      ),
    );
  }
}