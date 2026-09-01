import 'package:flutter/material.dart';
import 'package:tugboat/tugboat.dart';

import '../widgets/demo_widgets.dart';

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  String _method = 'card';
  bool _saveCard = true;
  bool _billingSameAsShipping = true;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            'Almost there',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            'Your payment details are protected and are never recorded.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          DemoSection(
            title: 'Payment method',
            children: [
              for (final option in [
                ('card', Icons.credit_card, 'Credit or debit card'),
                ('paypal', Icons.account_balance_wallet_outlined, 'PayPal'),
                ('apple', Icons.phone_iphone, 'Apple Pay'),
              ])
                Card(
                  margin: const EdgeInsets.only(bottom: 8),
                  child: RadioListTile<String>(
                    value: option.$1,
                    // ignore: deprecated_member_use
                    groupValue: _method,
                    // ignore: deprecated_member_use
                    onChanged: (value) => setState(() => _method = value!),
                    title: Text(option.$3),
                    secondary: Icon(option.$2),
                  ),
                ),
            ],
          ),
          if (_method == 'card') ...[
            DemoSection(
              title: 'Card details',
              children: [
                const TugboatSensitive(
                  child: TextField(
                    decoration: InputDecoration(
                      labelText: 'Card number',
                      hintText: '4242 4242 4242 4242',
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                const Row(
                  children: [
                    Expanded(
                      child: TugboatSensitive(
                        child: TextField(
                          decoration: InputDecoration(labelText: 'Expiry'),
                        ),
                      ),
                    ),
                    SizedBox(width: 12),
                    Expanded(
                      child: TugboatSensitive(
                        child: TextField(
                          decoration: InputDecoration(labelText: 'CVC'),
                        ),
                      ),
                    ),
                  ],
                ),
                CheckboxListTile(
                  value: _saveCard,
                  onChanged: (value) =>
                      setState(() => _saveCard = value ?? true),
                  title: const Text('Save card for next time'),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
            ),
          ],
          DemoSection(
            title: 'Billing',
            children: [
              SwitchListTile(
                value: _billingSameAsShipping,
                onChanged: (value) =>
                    setState(() => _billingSameAsShipping = value),
                title: const Text('Same as shipping address'),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton.icon(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                icon: const Icon(Icons.check_circle_outline, size: 48),
                title: const Text('Order complete'),
                content: const Text(
                  'Thanks for testing the Tugboat journey replay. Your session captured '
                  'every tap, scroll, and screen transition.',
                ),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      Navigator.popUntil(context, (route) => route.isFirst);
                    },
                    child: const Text('Back to home'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.lock_outline),
            label: const Text('Pay \$244'),
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Back to shipping'),
          ),
        ],
      ),
    );
  }
}
