import 'package:flutter/material.dart';

import '../navigation.dart';
import 'cart_screen.dart';

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});

  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;
  final _searchController = TextEditingController();
  String _selectedCategory = 'All';
  bool _gridView = false;

  static const _categories = ['All', 'Bags', 'Accessories', 'Travel', 'Sale'];
  static const _products = [
    ('Canvas Weekender', '\$84', 'Bags'),
    ('Travel Pouch', '\$28', 'Accessories'),
    ('Leather Tote', '\$120', 'Bags'),
    ('Packable Duffel', '\$65', 'Travel'),
    ('Passport Wallet', '\$34', 'Accessories'),
    ('Weekend Backpack', '\$98', 'Bags'),
    ('Cable Organizer', '\$18', 'Accessories'),
    ('Carry-on Spinner', '\$189', 'Travel'),
    ('Outlet Sale Bundle', '\$49', 'Sale'),
    ('Mini Crossbody', '\$56', 'Bags'),
  ];

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<(String, String, String)> get _filteredProducts {
    final query = _searchController.text.toLowerCase();
    return _products.where((product) {
      final matchesCategory =
          _selectedCategory == 'All' || product.$3 == _selectedCategory;
      final matchesQuery =
          query.isEmpty || product.$1.toLowerCase().contains(query);
      return matchesCategory && matchesQuery;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Catalog'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: 'Featured'),
            Tab(text: 'New'),
            Tab(text: 'Popular'),
          ],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: TextField(
              controller: _searchController,
              onChanged: (_) => setState(() {}),
              decoration: InputDecoration(
                hintText: 'Search products',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchController.text.isEmpty
                    ? null
                    : IconButton(
                        onPressed: () {
                          _searchController.clear();
                          setState(() {});
                        },
                        icon: const Icon(Icons.clear),
                      ),
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final category = _categories[index];
                return FilterChip(
                  label: Text(category),
                  selected: _selectedCategory == category,
                  onSelected: (_) =>
                      setState(() => _selectedCategory = category),
                );
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Text('${_filteredProducts.length} items'),
                const Spacer(),
                IconButton(
                  tooltip: 'List view',
                  onPressed: () => setState(() => _gridView = false),
                  icon: Icon(
                    Icons.view_list,
                    color: !_gridView
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
                IconButton(
                  tooltip: 'Grid view',
                  onPressed: () => setState(() => _gridView = true),
                  icon: Icon(
                    Icons.grid_view,
                    color: _gridView
                        ? Theme.of(context).colorScheme.primary
                        : null,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: List.generate(3, (_) => _buildProductList()),
            ),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton.icon(
            onPressed: () => pushDemoScreen(
              context,
              routeName: '/cart',
              screen: const CartScreen(),
            ),
            icon: const Icon(Icons.shopping_cart_outlined),
            label: const Text('View cart (3 items)'),
          ),
        ),
      ),
    );
  }

  Widget _buildProductList() {
    final products = _filteredProducts;
    if (products.isEmpty) {
      return const Center(child: Text('No products match your filters'));
    }

    if (_gridView) {
      return GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 0.78,
        ),
        itemCount: products.length,
        itemBuilder: (context, index) =>
            _ProductGridCard(product: products[index]),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: products.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) =>
          _ProductListTile(product: products[index]),
    );
  }
}

class _ProductListTile extends StatelessWidget {
  const _ProductListTile({required this.product});

  final (String, String, String) product;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(child: Text(product.$1.characters.first)),
        title: Text(product.$1),
        subtitle: Text('${product.$3} · In stock'),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              product.$2,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            TextButton(
              onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Added ${product.$1} to cart')),
              ),
              child: const Text('Add'),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }
}

class _ProductGridCard extends StatelessWidget {
  const _ProductGridCard({required this.product});

  final (String, String, String) product;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  Icons.shopping_bag_outlined,
                  size: 40,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(product.$1, maxLines: 2, overflow: TextOverflow.ellipsis),
            Text(product.$3, style: Theme.of(context).textTheme.bodySmall),
            const Spacer(),
            Row(
              children: [
                Text(
                  product.$2,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                IconButton.filledTonal(
                  onPressed: () {},
                  icon: const Icon(Icons.add, size: 18),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
