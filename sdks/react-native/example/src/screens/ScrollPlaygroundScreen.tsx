import React from 'react';
import { FlatList, ScrollView, Text, View } from 'react-native';
import { Page, Section, colors, s } from '../ui';

const rows = Array.from({ length: 30 }, (_, i) => `Feed row ${i}`);
const cards = Array.from({ length: 12 }, (_, i) => `Card ${i}`);

export default function ScrollPlaygroundScreen() {
  return (
    <Page testID="scroll-screen">
      <Text style={s.muted}>
        Try scrolling each section. Dead swipes on the static block should not scroll anything.
      </Text>
      <Section title="Long vertical feed (nested scroll)">
        <View style={{ height: 220 }}>
          <FlatList testID="scroll-vertical" nestedScrollEnabled data={rows} keyExtractor={r => r} renderItem={({ item }) => <Text style={[s.body, { paddingVertical: 10 }]}>{item}</Text>} />
        </View>
      </Section>
      <Section title="Horizontal carousel">
        <ScrollView testID="scroll-carousel" horizontal showsHorizontalScrollIndicator={false}>
          {cards.map(c => (
            <View key={c} style={{ width: 140, height: 90, marginRight: 8, borderRadius: 12, backgroundColor: colors.primary, justifyContent: 'center', alignItems: 'center' }}>
              <Text style={{ color: '#fff' }}>{c}</Text>
            </View>
          ))}
        </ScrollView>
      </Section>
      <Section title="Static block (dead swipe target)">
        <View testID="scroll-static" style={{ height: 120, borderRadius: 12, backgroundColor: colors.border, justifyContent: 'center', alignItems: 'center' }}>
          <Text style={s.muted}>Swipe here: nothing scrolls</Text>
        </View>
      </Section>
      <Section title="Nested: carousel of vertical lists">
        <ScrollView testID="scroll-nested" horizontal pagingEnabled nestedScrollEnabled>
          {[0, 1, 2].map(p => (
            <View key={p} style={{ width: 280, height: 160, marginRight: 8 }}>
              <ScrollView nestedScrollEnabled testID={`scroll-nested-page-${p}`}>
                {Array.from({ length: 15 }, (_, i) => (
                  <Text key={i} style={[s.body, { paddingVertical: 8 }]}>Page {p} item {i}</Text>
                ))}
              </ScrollView>
            </View>
          ))}
        </ScrollView>
      </Section>
    </Page>
  );
}
