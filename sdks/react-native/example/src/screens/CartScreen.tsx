import React, { useState } from 'react';
import { Text, ToastAndroid, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { RootStackParams } from '../../App';
import { useCart } from '../data';
import { Button, Field, Page, Section, s } from '../ui';

export default function CartScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParams>>();
  const cart = useCart();
  const [promo, setPromo] = useState('');
  const entries = Object.entries(cart.items);
  const tax = 12;
  return (
    <Page testID="cart-screen">
      <Section title={`Items (${cart.count})`}>
        {entries.length === 0 ? <Text testID="cart-empty" style={s.muted}>Your cart is empty</Text> : null}
        {entries.map(([name, qty]) => {
          const id = name.replace(/\s+/g, '-').toLowerCase();
          return (
            <View key={name} style={s.row}>
              <Text style={[s.rowTitle, { flex: 1 }]}>{name}</Text>
              <Button testID={`cart-minus-${id}`} kind="outline" label="−" onPress={() => cart.setQty(name, qty - 1)} />
              <Text testID={`cart-qty-${id}`} style={s.body}>{qty}</Text>
              <Button testID={`cart-plus-${id}`} kind="outline" label="+" onPress={() => cart.setQty(name, qty + 1)} />
            </View>
          );
        })}
        <Button testID="cart-clear" kind="outline" label="Clear" onPress={cart.clear} />
      </Section>
      <Section title="Promo code">
        <Field testID="cart-promo-input" label="Enter code" placeholder="SAVE10" autoCapitalize="characters" value={promo} onChangeText={setPromo} />
        <Button testID="cart-promo-apply" label="Apply" kind="outline" onPress={() => ToastAndroid.show('Promo code applied', ToastAndroid.SHORT)} />
      </Section>
      <Section title="Order summary">
        <Text style={s.body}>Subtotal: ${cart.subtotal}</Text>
        <Text style={s.body}>Shipping: Calculated next</Text>
        <Text style={s.body}>Tax: ${tax}</Text>
        <Text testID="cart-total" style={[s.body, { fontWeight: '700' }]}>Total: ${cart.subtotal + tax}</Text>
      </Section>
      <Button testID="cart-continue-shipping" label="Continue to shipping" disabled={cart.count === 0} onPress={() => nav.navigate('Shipping')} />
      <Button testID="cart-continue-shopping" kind="outline" label="Continue shopping" onPress={() => nav.navigate('Tabs', { screen: 'Catalog' } as never)} />
    </Page>
  );
}
