import 'package:flutter/material.dart';
import 'package:pmkit/pmkit.dart';

import '../navigation.dart';
import '../widgets/demo_widgets.dart';
import 'payment_screen.dart';

class ShippingScreen extends StatefulWidget {
  const ShippingScreen({super.key});

  @override
  State<ShippingScreen> createState() => _ShippingScreenState();
}

class _ShippingScreenState extends State<ShippingScreen> {
  bool _express = false;
  bool _giftWrap = false;
  String _deliveryWindow = 'Standard';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Shipping')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Where should we send your order?',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 20),
          const DemoSection(
            title: 'Contact',
            children: [
              TextField(decoration: InputDecoration(labelText: 'Full name')),
              SizedBox(height: 12),
              TextField(
                keyboardType: TextInputType.emailAddress,
                decoration: InputDecoration(labelText: 'Email'),
              ),
              SizedBox(height: 12),
              TextField(
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(labelText: 'Phone'),
              ),
            ],
          ),
          DemoSection(
            title: 'Address',
            children: [
              const PmkitSensitive(
                child: TextField(
                  decoration: InputDecoration(labelText: 'Street address'),
                ),
              ),
              const SizedBox(height: 12),
              const Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(labelText: 'City'),
                    ),
                  ),
                  SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      decoration: InputDecoration(labelText: 'Postcode'),
                    ),
                  ),
                ],
              ),
            ],
          ),
          DemoSection(
            title: 'Delivery options',
            children: [
              SwitchListTile(
                value: _express,
                onChanged: (value) => setState(() => _express = value),
                title: const Text('Express delivery'),
                subtitle: const Text('Arrives in 1–2 business days (+ \$15)'),
              ),
              SwitchListTile(
                value: _giftWrap,
                onChanged: (value) => setState(() => _giftWrap = value),
                title: const Text('Gift wrap'),
                subtitle: const Text('Include a handwritten note'),
              ),
              const SizedBox(height: 8),
              for (final option in ['Standard', 'Weekend', 'Evening'])
                RadioListTile<String>(
                  value: option,
                  // ignore: deprecated_member_use
                  groupValue: _deliveryWindow,
                  // ignore: deprecated_member_use
                  onChanged: (value) =>
                      setState(() => _deliveryWindow = value!),
                  title: Text('$option delivery'),
                  subtitle: Text(_deliverySubtitle(option)),
                ),
            ],
          ),
          DemoSection(
            title: 'Delivery notes',
            children: [
              for (var i = 0; i < 8; i++)
                ListTile(
                  leading: const Icon(Icons.local_shipping_outlined),
                  title: Text('Shipping detail ${i + 1}'),
                  subtitle: const Text(
                    'Helpful information about your delivery',
                  ),
                  trailing: IconButton(
                    onPressed: () {},
                    icon: const Icon(Icons.info_outline),
                  ),
                ),
            ],
          ),
          FilledButton(
            onPressed: () => pushDemoScreen(
              context,
              routeName: '/payment',
              screen: const PaymentScreen(),
            ),
            child: const Text('Continue to payment'),
          ),
        ],
      ),
    );
  }

  String _deliverySubtitle(String option) {
    switch (option) {
      case 'Standard':
        return '3–5 business days';
      case 'Weekend':
        return 'Saturday delivery';
      case 'Evening':
        return 'After 6 PM';
      default:
        throw StateError('Unknown delivery option: $option');
    }
  }
}
