import React, { useState } from 'react';
import { Text, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { RootStackParams } from '../../App';
import { Button, Chip, Field, Page, Section, SwitchRow, s } from '../ui';

const WINDOWS: [string, string][] = [
  ['Standard', '3–5 business days'],
  ['Weekend', 'Saturday delivery'],
  ['Evening', 'After 6 PM'],
];

export default function ShippingScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParams>>();
  const [express, setExpress] = useState(false);
  const [gift, setGift] = useState(false);
  const [window, setWindow] = useState('Standard');
  return (
    <Page testID="shipping-screen">
      <Text style={s.h1}>Where should we send your order?</Text>
      <Section title="Contact">
        <Field testID="shipping-name" label="Full name" autoComplete="name" />
        <Field testID="shipping-email" label="Email" keyboardType="email-address" autoCapitalize="none" />
        <Field testID="shipping-phone" label="Phone" keyboardType="phone-pad" />
      </Section>
      <Section title="Address">
        <Field testID="shipping-street" label="Street address" />
        <View style={{ flexDirection: 'row', gap: 12 }}>
          <View style={{ flex: 1 }}><Field testID="shipping-city" label="City" /></View>
          <View style={{ flex: 1 }}><Field testID="shipping-postcode" label="Postcode" /></View>
        </View>
      </Section>
      <Section title="Delivery options">
        <SwitchRow testID="shipping-express" title="Express delivery (+$15)" value={express} onChange={setExpress} />
        <SwitchRow testID="shipping-gift" title="Gift wrap" value={gift} onChange={setGift} />
        <View style={{ flexDirection: 'row', marginTop: 8 }}>
          {WINDOWS.map(([w]) => (
            <Chip key={w} testID={`shipping-window-${w.toLowerCase()}`} label={w} selected={window === w} onPress={() => setWindow(w)} />
          ))}
        </View>
        <Text testID="shipping-window-detail" style={s.muted}>{WINDOWS.find(([w]) => w === window)?.[1]}</Text>
      </Section>
      <Button testID="shipping-continue" label="Continue to payment" onPress={() => nav.navigate('Payment')} />
    </Page>
  );
}
