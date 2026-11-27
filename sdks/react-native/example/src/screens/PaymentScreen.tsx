import React, { useState } from 'react';
import { Alert, Text, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { RootStackParams } from '../../App';
import { Sensitive } from '../tugboat';
import { Button, Chip, Field, Page, Section, SwitchRow, s } from '../ui';

const METHODS: [string, string][] = [
  ['card', 'Credit or debit card'],
  ['paypal', 'PayPal'],
  ['apple', 'Apple Pay'],
];

export default function PaymentScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParams>>();
  const [method, setMethod] = useState('card');
  const [save, setSave] = useState(false);
  const [same, setSame] = useState(true);
  return (
    <Page testID="payment-screen">
      <Text style={s.h1}>Almost there</Text>
      <Text style={s.muted}>Your payment details are protected and are never recorded.</Text>
      <Section title="Payment method">
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
          {METHODS.map(([id, label]) => (
            <Chip key={id} testID={`payment-method-${id}`} label={label} selected={method === id} onPress={() => setMethod(id)} />
          ))}
        </View>
      </Section>
      {method === 'card' ? (
        <Section title="Card details">
          {/* TODO(@tugboat/react-native): Sensitive masks this subtree once the SDK is wired in. */}
          <Sensitive>
            <Field testID="payment-card-number" label="Card number" placeholder="4242 4242 4242 4242" keyboardType="number-pad" secureTextEntry={false} />
            <View style={{ flexDirection: 'row', gap: 12 }}>
              <View style={{ flex: 1 }}><Field testID="payment-expiry" label="Expiry" placeholder="MM/YY" keyboardType="number-pad" /></View>
              <View style={{ flex: 1 }}><Field testID="payment-cvc" label="CVC" keyboardType="number-pad" secureTextEntry /></View>
            </View>
          </Sensitive>
          <SwitchRow testID="payment-save-card" title="Save card for next time" value={save} onChange={setSave} />
        </Section>
      ) : null}
      <Section title="Billing">
        <SwitchRow testID="payment-same-address" title="Same as shipping address" value={same} onChange={setSame} />
      </Section>
      <Button
        testID="payment-pay"
        label="Pay $244"
        onPress={() =>
          Alert.alert('Order complete', 'Thanks for testing the Tugboat journey replay.', [
            { text: 'Back to home', onPress: () => nav.popTo('Tabs') },
          ])
        }
      />
      <Button testID="payment-back" kind="outline" label="Back to shipping" onPress={() => nav.goBack()} />
    </Page>
  );
}
