import React, { useState } from 'react';
import { FlatList, Text, View } from 'react-native';
import { Button, Row, colors, s } from '../ui';

const ITEMS = [
  'Morning commute essentials', 'Weekend getaway packing list', 'Office organization tips',
  'Travel gear under $50', 'Best sellers this month', 'Customer favorites', 'New arrivals',
  'Limited time offers', 'Gift ideas for travelers', 'How to pack a carry-on',
  'Waterproof bags guide', 'Leather care basics', 'Sustainable materials', 'Behind the scenes',
  'Store locator', 'Size guide', 'Return policy FAQ', 'Shipping times by region',
  'Loyalty program perks', 'Refer a friend', 'Seasonal collections', 'Collaboration drops',
  'Outlet finds', 'Staff picks',
];

export default function BrowseScreen() {
  const [open, setOpen] = useState<Set<number>>(new Set());
  const toggle = (i: number) =>
    setOpen(prev => {
      const next = new Set(prev);
      if (next.has(i)) {
        next.delete(i);
      } else {
        next.add(i);
      }
      return next;
    });
  return (
    <View style={s.page} testID="browse-screen">
      <View style={{ flexDirection: 'row', gap: 8, padding: 12 }}>
        <Button testID="browse-collapse-all" kind="outline" label="Collapse all" onPress={() => setOpen(new Set())} />
        <Button testID="browse-expand-all" kind="outline" label="Expand all" onPress={() => setOpen(new Set(ITEMS.map((_, i) => i)))} />
      </View>
      <FlatList
        testID="browse-list"
        data={ITEMS}
        keyExtractor={t => t}
        contentContainerStyle={{ paddingHorizontal: 12, gap: 8 }}
        renderItem={({ item, index }) => (
          <View style={{ backgroundColor: colors.card, borderRadius: 12, paddingHorizontal: 12 }}>
            <Row
              testID={`browse-item-${index}`}
              title={`${index + 1}. ${item}`}
              subtitle={`Tap to ${open.has(index) ? 'collapse' : 'expand'} details`}
              onPress={() => toggle(index)}
            />
            {open.has(index) ? (
              <View style={{ paddingBottom: 12 }}>
                <Text style={s.muted}>
                  Lorem ipsum dolor sit amet, consectetur adipiscing elit. Scroll through this feed to generate scroll events.
                </Text>
                <View style={{ flexDirection: 'row', gap: 8, marginTop: 8 }}>
                  <Button testID={`browse-learn-${index}`} kind="outline" label="Learn more" onPress={() => {}} />
                  <Button testID={`browse-share-${index}`} kind="outline" label="Share" onPress={() => {}} />
                </View>
              </View>
            ) : null}
          </View>
        )}
      />
    </View>
  );
}
