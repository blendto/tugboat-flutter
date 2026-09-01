import 'package:flutter/material.dart';

class BrowseScreen extends StatefulWidget {
  const BrowseScreen({super.key});

  @override
  State<BrowseScreen> createState() => _BrowseScreenState();
}

class _BrowseScreenState extends State<BrowseScreen> {
  final _expanded = <int>{};

  static const _items = [
    'Morning commute essentials',
    'Weekend getaway packing list',
    'Office organization tips',
    'Travel gear under \$50',
    'Best sellers this month',
    'Customer favorites',
    'New arrivals',
    'Limited time offers',
    'Gift ideas for travelers',
    'How to pack a carry-on',
    'Waterproof bags guide',
    'Leather care basics',
    'Sustainable materials',
    'Behind the scenes',
    'Store locator',
    'Size guide',
    'Return policy FAQ',
    'Shipping times by region',
    'Loyalty program perks',
    'Refer a friend',
    'Seasonal collections',
    'Collaboration drops',
    'Outlet finds',
    'Staff picks',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Browse feed'),
        actions: [
          IconButton(
            onPressed: () => setState(_expanded.clear),
            icon: const Icon(Icons.unfold_less),
            tooltip: 'Collapse all',
          ),
          IconButton(
            onPressed: () => setState(
              () => _expanded.addAll(List.generate(_items.length, (i) => i)),
            ),
            icon: const Icon(Icons.unfold_more),
            tooltip: 'Expand all',
          ),
        ],
      ),
      body: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: _items.length,
        itemBuilder: (context, index) {
          final expanded = _expanded.contains(index);
          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Column(
              children: [
                ListTile(
                  leading: CircleAvatar(child: Text('${index + 1}')),
                  title: Text(_items[index]),
                  subtitle: Text(
                    'Tap to ${expanded ? 'collapse' : 'expand'} details',
                  ),
                  trailing: Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                  ),
                  onTap: () => setState(() {
                    if (expanded) {
                      _expanded.remove(index);
                    } else {
                      _expanded.add(index);
                    }
                  }),
                ),
                if (expanded)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Lorem ipsum dolor sit amet, consectetur adipiscing elit. '
                          'Scroll through this feed to generate scroll_start and scroll_end events.',
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            OutlinedButton(
                              onPressed: () {},
                              child: const Text('Learn more'),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () {},
                              child: const Text('Share'),
                            ),
                            const Spacer(),
                            IconButton.filledTonal(
                              onPressed: () {},
                              icon: const Icon(Icons.favorite_border),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
