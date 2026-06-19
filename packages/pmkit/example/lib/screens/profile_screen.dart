import 'package:flutter/material.dart';
import 'package:pmkit/pmkit.dart';

import '../widgets/demo_widgets.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  bool _pushEnabled = true;
  bool _emailDigest = false;
  bool _darkMode = false;
  double _notificationVolume = 0.6;
  String _language = 'English';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Profile & settings')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 32,
                    backgroundColor: Theme.of(
                      context,
                    ).colorScheme.primaryContainer,
                    child: Icon(
                      Icons.person,
                      size: 32,
                      color: Theme.of(context).colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Demo User',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        Text(
                          'demo@pmkit.example',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                              ),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton(onPressed: () {}, child: const Text('Edit')),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          DemoSection(
            title: 'Notifications',
            children: [
              SwitchListTile(
                value: _pushEnabled,
                onChanged: (value) => setState(() => _pushEnabled = value),
                title: const Text('Push notifications'),
                subtitle: const Text('Order updates and promotions'),
              ),
              SwitchListTile(
                value: _emailDigest,
                onChanged: (value) => setState(() => _emailDigest = value),
                title: const Text('Weekly email digest'),
              ),
              ListTile(
                title: const Text('Alert volume'),
                subtitle: Slider(
                  value: _notificationVolume,
                  onChanged: (value) =>
                      setState(() => _notificationVolume = value),
                ),
              ),
            ],
          ),
          DemoSection(
            title: 'Appearance',
            children: [
              SwitchListTile(
                value: _darkMode,
                onChanged: (value) => setState(() => _darkMode = value),
                title: const Text('Dark mode'),
                secondary: const Icon(Icons.dark_mode_outlined),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('Compact'),
                    selected: false,
                    onSelected: (_) {},
                  ),
                  ChoiceChip(
                    label: const Text('Comfortable'),
                    selected: true,
                    onSelected: (_) {},
                  ),
                  ChoiceChip(
                    label: const Text('Spacious'),
                    selected: false,
                    onSelected: (_) {},
                  ),
                ],
              ),
            ],
          ),
          DemoSection(
            title: 'Language',
            children: [
              DropdownButtonFormField<String>(
                initialValue: _language,
                decoration: const InputDecoration(
                  labelText: 'Preferred language',
                  border: OutlineInputBorder(),
                ),
                items: const [
                  DropdownMenuItem(value: 'English', child: Text('English')),
                  DropdownMenuItem(value: 'Spanish', child: Text('Spanish')),
                  DropdownMenuItem(value: 'French', child: Text('French')),
                  DropdownMenuItem(value: 'German', child: Text('German')),
                ],
                onChanged: (value) =>
                    setState(() => _language = value ?? 'English'),
              ),
            ],
          ),
          DemoSection(
            title: 'Account actions',
            children: [
              for (final action in [
                (Icons.history, 'Order history'),
                (Icons.location_on_outlined, 'Saved addresses'),
                (Icons.payment_outlined, 'Payment methods'),
                (Icons.help_outline, 'Help & support'),
                (Icons.verified_user_outlined, 'Human verification'),
                (Icons.logout, 'Sign out'),
              ])
                ListTile(
                  leading: Icon(action.$1),
                  title: Text(action.$2),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    if (action.$2 == 'Human verification') {
                      showDialog<void>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Human verification required'),
                          content: const PmkitSensitive(
                            child: TextField(
                              decoration: InputDecoration(
                                labelText: 'One-time verification code',
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Complete verification'),
                            ),
                          ],
                        ),
                      );
                      return;
                    }
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('${action.$2} tapped')),
                    );
                  },
                ),
            ],
          ),
        ],
      ),
    );
  }
}
