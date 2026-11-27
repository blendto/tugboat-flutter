import React, { useState } from 'react';
import { Alert, Modal, Text, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { RootStackParams } from '../../App';
import { Button, Page, Row, Section, s } from '../ui';

export default function HomeScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParams>>();
  const [sheet, setSheet] = useState(false);
  return (
    <Page testID="home-screen">
      <Text style={s.h1}>Explore every screen</Text>
      <Text style={s.muted}>
        Tap around, scroll lists, toggle switches, and navigate between screens.
      </Text>
      <Section title="Screens">
        <Row testID="home-catalog" title="Product catalog" subtitle="Search, filters, chips, and product cards" onPress={() => nav.navigate('Tabs', { screen: 'Catalog' } as never)} />
        <Row testID="home-cart" title="Shopping cart" subtitle="Quantity steppers, promo codes, checkout" onPress={() => nav.navigate('Cart')} />
        <Row testID="home-browse" title="Long browse feed" subtitle="Scroll-heavy list for replay testing" onPress={() => nav.navigate('Browse')} />
        <Row testID="home-scroll" title="Scroll playground" subtitle="Vertical list, horizontal carousel, nested scroll" onPress={() => nav.navigate('ScrollPlayground')} />
        <Row testID="home-network" title="Network" subtitle="fetch and XMLHttpRequest: GET, POST, 4xx, 5xx, failures" onPress={() => nav.navigate('Network')} />
      </Section>
      <Section title="Dialogs & sheets">
        <View style={{ flexDirection: 'row', gap: 12 }}>
          <Button testID="home-show-dialog" label="Show dialog" kind="outline" onPress={() => Alert.alert('Welcome', 'This dialog is captured as part of your replay session.', [{ text: 'Got it' }])} />
          <Button testID="home-show-sheet" label="Bottom sheet" kind="outline" onPress={() => setSheet(true)} />
        </View>
      </Section>
      <Button testID="home-shop-now" label="Shop now" onPress={() => nav.navigate('Tabs', { screen: 'Catalog' } as never)} />
      <Modal visible={sheet} transparent animationType="slide" onRequestClose={() => setSheet(false)}>
        <View style={{ flex: 1, justifyContent: 'flex-end', backgroundColor: '#0006' }}>
          <View style={{ backgroundColor: '#fff', padding: 16, borderTopLeftRadius: 16, borderTopRightRadius: 16 }}>
            <Text style={s.h1}>Quick actions</Text>
            <Row testID="sheet-share" title="Share session" onPress={() => setSheet(false)} />
            <Row testID="sheet-copy" title="Copy export path" onPress={() => setSheet(false)} />
            <Row testID="sheet-help" title="Help" onPress={() => setSheet(false)} />
            <Button testID="sheet-close" label="Close" onPress={() => setSheet(false)} />
          </View>
        </View>
      </Modal>
    </Page>
  );
}
