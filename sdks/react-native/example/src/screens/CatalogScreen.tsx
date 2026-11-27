import React, { useState } from 'react';
import { FlatList, ScrollView, Text, TextInput, ToastAndroid, View } from 'react-native';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import type { RootStackParams } from '../../App';
import { CATEGORIES, PRODUCTS, useCart } from '../data';
import { Button, Chip, Row, colors, s } from '../ui';

const TABS = ['Featured', 'New', 'Popular'];

export default function CatalogScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStackParams>>();
  const cart = useCart();
  const [tab, setTab] = useState('Featured');
  const [query, setQuery] = useState('');
  const [category, setCategory] = useState('All');
  const [grid, setGrid] = useState(false);

  const shown = PRODUCTS.filter(
    p =>
      (category === 'All' || p.category === category) &&
      p.name.toLowerCase().includes(query.toLowerCase()),
  );
  // The tabs only reorder the list; enough to produce visible UI changes.
  const ordered = tab === 'Popular' ? [...shown].reverse() : tab === 'New' ? [...shown].sort((a, b) => a.price - b.price) : shown;

  return (
    <View style={s.page} testID="catalog-screen">
      <View style={{ flexDirection: 'row', padding: 12 }}>
        {TABS.map(t => (
          <Chip key={t} testID={`catalog-tab-${t.toLowerCase()}`} label={t} selected={tab === t} onPress={() => setTab(t)} />
        ))}
      </View>
      <TextInput testID="catalog-search" value={query} onChangeText={setQuery} placeholder="Search products" placeholderTextColor="#aaa" style={[s.input, { marginHorizontal: 12, backgroundColor: '#fff' }]} />
      <ScrollView horizontal showsHorizontalScrollIndicator={false} style={{ flexGrow: 0, padding: 12 }}>
        {CATEGORIES.map(c => (
          <Chip key={c} testID={`catalog-chip-${c.toLowerCase()}`} label={c} selected={category === c} onPress={() => setCategory(c)} />
        ))}
      </ScrollView>
      <View style={{ flexDirection: 'row', alignItems: 'center', paddingHorizontal: 12 }}>
        <Text style={[s.muted, { flex: 1 }]}>{ordered.length} items</Text>
        <Button testID="catalog-toggle-view" kind="outline" label={grid ? 'List view' : 'Grid view'} onPress={() => setGrid(g => !g)} />
      </View>
      <FlatList
        key={grid ? 'grid' : 'list'}
        testID="catalog-list"
        data={ordered}
        numColumns={grid ? 2 : 1}
        keyExtractor={p => p.name}
        contentContainerStyle={{ padding: 12, gap: 8 }}
        columnWrapperStyle={grid ? { gap: 8 } : undefined}
        ListEmptyComponent={<Text testID="catalog-empty" style={s.muted}>No products match your filters</Text>}
        renderItem={({ item }) => {
          const id = item.name.replace(/\s+/g, '-').toLowerCase();
          return (
            <View style={{ flex: 1, backgroundColor: colors.card, borderRadius: 12, paddingHorizontal: 12 }}>
              <Row
                testID={`product-${id}`}
                title={item.name}
                subtitle={`${item.category} · In stock`}
                right={
                  <>
                    <Text style={s.body}>${item.price}</Text>
                    <Button
                      testID={`product-add-${id}`}
                      label="Add"
                      kind="outline"
                      onPress={() => {
                        cart.add(item.name);
                        ToastAndroid.show(`Added ${item.name} to cart`, ToastAndroid.SHORT);
                      }}
                    />
                  </>
                }
              />
            </View>
          );
        }}
      />
      <View style={{ padding: 12 }}>
        <Button testID="catalog-view-cart" label={`View cart (${cart.count} items)`} onPress={() => nav.navigate('Cart')} />
      </View>
    </View>
  );
}
