import 'package:flutter/material.dart';

import '../navigation.dart';
import '../widgets/demo_widgets.dart';
import 'catalog_screen.dart';
import 'shipping_screen.dart';

class CartScreen extends StatefulWidget {
  const CartScreen({super.key});

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final _promoController = TextEditingController();
  final _quantities = <String, int>{
    'Canvas Weekender': 1,
    'Travel Pouch': 2,
    'Leather Tote': 1,
  };

  @override
  void dispose() {
    _promoController.dispose();
    super.dispose();
  }

  int get _itemCount => _quantities.values.fold(0, (sum, qty) => sum + qty);

  double get _subtotal {
    const prices = {
      'Canvas Weekender': 84.0,
      'Travel Pouch': 28.0,
      'Leather Tote': 120.0,
    };
    return _quantities.entries.fold(0, (sum, entry) {
      return sum + (prices[entry.key] ?? 0) * entry.value;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Your cart'),
        actions: [
          Semantics(
            child: TextButton(
              onPressed: () => setState(_quantities.clear),
              child: const Text('Clear'),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          DemoSection(
            title: 'Items ($_itemCount)',
            children: [
              for (final entry in _quantities.entries)
                Card(
                  margin: const EdgeInsets.only(bottom: 10),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Row(
                      children: [
                        CircleAvatar(child: Text(entry.key.characters.first)),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.key,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const Text('In stock · Free returns'),
                            ],
                          ),
                        ),
                        _QuantityStepper(
                          value: entry.value,
                          onChanged: (value) => setState(() {
                            if (value <= 0) {
                              _quantities.remove(entry.key);
                            } else {
                              _quantities[entry.key] = value;
                            }
                          }),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          DemoSection(
            title: 'Promo code',
            children: [
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _promoController,
                      decoration: const InputDecoration(
                        labelText: 'Enter code',
                        hintText: 'SAVE10',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Promo code applied')),
                    ),
                    child: const Text('Apply'),
                  ),
                ],
              ),
            ],
          ),
          DemoSection(
            title: 'Order summary',
            children: [
              _SummaryRow(
                label: 'Subtotal',
                value: '\$${_subtotal.toStringAsFixed(0)}',
              ),
              const _SummaryRow(label: 'Shipping', value: 'Calculated next'),
              const _SummaryRow(label: 'Tax', value: '\$12'),
              const Divider(height: 32),
              _SummaryRow(
                label: 'Total',
                value: '\$${(_subtotal + 12).toStringAsFixed(0)}',
                bold: true,
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _quantities.isEmpty
                ? null
                : () => pushDemoScreen(
                    context,
                    routeName: '/shipping',
                    screen: const ShippingScreen(),
                  ),
            child: const Text('Continue to shipping'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => pushDemoScreen(
              context,
              routeName: '/catalog',
              screen: const CatalogScreen(),
            ),
            child: const Text('Continue shopping'),
          ),
        ],
      ),
    );
  }
}

class _QuantityStepper extends StatelessWidget {
  const _QuantityStepper({required this.value, required this.onChanged});

  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton.outlined(
          onPressed: () => onChanged(value - 1),
          icon: const Icon(Icons.remove),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text('$value', style: Theme.of(context).textTheme.titleMedium),
        ),
        IconButton.filledTonal(
          onPressed: () => onChanged(value + 1),
          icon: const Icon(Icons.add),
        ),
      ],
    );
  }
}

class _SummaryRow extends StatelessWidget {
  const _SummaryRow({
    required this.label,
    required this.value,
    this.bold = false,
  });

  final String label;
  final String value;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = bold
        ? Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)
        : Theme.of(context).textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Text(label, style: style),
          const Spacer(),
          Text(value, style: style),
        ],
      ),
    );
  }
}
