import 'package:flutter/material.dart';

import '../navigation.dart';
import '../widgets/demo_widgets.dart';
import 'browse_screen.dart';
import 'cart_screen.dart';
import 'catalog_screen.dart';
import 'profile_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Tugboat Replay Demo'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => _showSnack(context, 'No new notifications'),
            icon: const Badge(
              label: Text('3'),
              child: Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            tooltip: 'Profile',
            onPressed: () => pushDemoScreen(
              context,
              routeName: '/profile',
              screen: const ProfileScreen(),
            ),
            icon: const Icon(Icons.person_outline),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Explore every screen',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          Text(
            'Tap around, scroll lists, toggle switches, and navigate between screens. '
            'Tugboat captures screenshots and raw interaction events.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          const DemoSection(
            title: 'Quick stats',
            children: [
              Row(
                children: [
                  Expanded(
                    child: DemoStatCard(
                      label: 'Sessions',
                      value: '12',
                      icon: Icons.play_circle_outline,
                      color: Colors.deepPurple,
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: DemoStatCard(
                      label: 'Events',
                      value: '847',
                      icon: Icons.touch_app_outlined,
                      color: Colors.teal,
                    ),
                  ),
                ],
              ),
            ],
          ),
          DemoSection(
            title: 'Quick actions',
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: null,
                    icon: const Icon(Icons.fiber_manual_record),
                    label: const Text('Recording'),
                  ),
                ],
              ),
            ],
          ),
          DemoSection(
            title: 'Screens',
            children: [
              DemoNavTile(
                title: 'Product catalog',
                subtitle: 'Search, filters, chips, and product cards',
                icon: Icons.storefront_outlined,
                onTap: () => pushDemoScreen(
                  context,
                  routeName: '/catalog',
                  screen: const CatalogScreen(),
                ),
              ),
              DemoNavTile(
                title: 'Shopping cart',
                subtitle: 'Quantity steppers, promo codes, checkout',
                icon: Icons.shopping_cart_outlined,
                onTap: () => pushDemoScreen(
                  context,
                  routeName: '/cart',
                  screen: const CartScreen(),
                ),
              ),
              DemoNavTile(
                title: 'Long browse feed',
                subtitle: 'Scroll-heavy list for replay testing',
                icon: Icons.view_list_outlined,
                onTap: () => pushDemoScreen(
                  context,
                  routeName: '/browse',
                  screen: const BrowseScreen(),
                ),
              ),
              DemoNavTile(
                title: 'Profile & settings',
                subtitle: 'Switches, sliders, and preference chips',
                icon: Icons.tune_outlined,
                onTap: () => pushDemoScreen(
                  context,
                  routeName: '/profile',
                  screen: const ProfileScreen(),
                ),
              ),
            ],
          ),
          DemoSection(
            title: 'Dialogs & sheets',
            children: [
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Welcome'),
                          content: const Text(
                            'This dialog is captured as part of your replay session.',
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Got it'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Show dialog'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: FilledButton.tonal(
                      onPressed: () => showModalBottomSheet<void>(
                        context: context,
                        showDragHandle: true,
                        builder: (_) => Padding(
                          padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(
                                'Quick actions',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const SizedBox(height: 16),
                              ListTile(
                                leading: const Icon(Icons.share_outlined),
                                title: const Text('Share session'),
                                onTap: () => Navigator.pop(context),
                              ),
                              ListTile(
                                leading: const Icon(Icons.copy_outlined),
                                title: const Text('Copy export path'),
                                onTap: () => Navigator.pop(context),
                              ),
                              ListTile(
                                leading: const Icon(Icons.help_outline),
                                title: const Text('Help'),
                                onTap: () => Navigator.pop(context),
                              ),
                            ],
                          ),
                        ),
                      ),
                      child: const Text('Bottom sheet'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => pushDemoScreen(
          context,
          routeName: '/catalog',
          screen: const CatalogScreen(),
        ),
        icon: const Icon(Icons.add_shopping_cart),
        label: const Text('Shop now'),
      ),
    );
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}
