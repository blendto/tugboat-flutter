import React from 'react';
import {
  Pressable,
  ScrollView,
  StyleSheet,
  Switch,
  Text,
  TextInput,
  TextInputProps,
  View,
} from 'react-native';

export const colors = {
  primary: '#5b3fd0',
  bg: '#f6f4fb',
  card: '#fff',
  text: '#1d1b20',
  muted: '#6b6775',
  border: '#ddd8e8',
};

export function Page({ children, testID }: { children: React.ReactNode; testID: string }) {
  return (
    <ScrollView testID={testID} style={s.page} contentContainerStyle={s.pageContent}>
      {children}
    </ScrollView>
  );
}

export function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <View style={s.section}>
      <Text style={s.sectionTitle}>{title}</Text>
      {children}
    </View>
  );
}

export function Button({
  label,
  onPress,
  testID,
  kind = 'filled',
  disabled,
}: {
  label: string;
  onPress: () => void;
  testID: string;
  kind?: 'filled' | 'outline';
  disabled?: boolean;
}) {
  return (
    <Pressable
      testID={testID}
      accessibilityRole="button"
      disabled={disabled}
      onPress={onPress}
      style={[s.btn, kind === 'outline' && s.btnOutline, disabled && { opacity: 0.4 }]}>
      <Text style={[s.btnText, kind === 'outline' && { color: colors.primary }]}>{label}</Text>
    </Pressable>
  );
}

export function Row({
  title,
  subtitle,
  onPress,
  testID,
  right,
}: {
  title: string;
  subtitle?: string;
  onPress?: () => void;
  testID: string;
  right?: React.ReactNode;
}) {
  return (
    <Pressable testID={testID} onPress={onPress} style={s.row}>
      <View style={{ flex: 1 }}>
        <Text style={s.rowTitle}>{title}</Text>
        {subtitle ? <Text style={s.muted}>{subtitle}</Text> : null}
      </View>
      {right}
    </Pressable>
  );
}

export function Field(props: TextInputProps & { label: string; testID: string }) {
  const { label, ...rest } = props;
  return (
    <View style={{ marginBottom: 10 }}>
      <Text style={s.muted}>{label}</Text>
      <TextInput {...rest} placeholderTextColor="#aaa" style={s.input} />
    </View>
  );
}

export function SwitchRow({
  title,
  value,
  onChange,
  testID,
}: {
  title: string;
  value: boolean;
  onChange: (v: boolean) => void;
  testID: string;
}) {
  return (
    <View style={s.row}>
      <Text style={[s.rowTitle, { flex: 1 }]}>{title}</Text>
      <Switch testID={testID} value={value} onValueChange={onChange} />
    </View>
  );
}

export function Chip({
  label,
  selected,
  onPress,
  testID,
}: {
  label: string;
  selected: boolean;
  onPress: () => void;
  testID: string;
}) {
  return (
    <Pressable testID={testID} onPress={onPress} style={[s.chip, selected && s.chipOn]}>
      <Text style={{ color: selected ? '#fff' : colors.text }}>{label}</Text>
    </Pressable>
  );
}

export const s = StyleSheet.create({
  page: { flex: 1, backgroundColor: colors.bg },
  pageContent: { padding: 16, gap: 12 },
  section: { backgroundColor: colors.card, borderRadius: 12, padding: 12 },
  sectionTitle: { fontSize: 16, fontWeight: '600', marginBottom: 8, color: colors.text },
  h1: { fontSize: 24, fontWeight: '700', color: colors.text },
  muted: { color: colors.muted, fontSize: 13 },
  body: { color: colors.text, fontSize: 15 },
  btn: { backgroundColor: colors.primary, borderRadius: 24, paddingVertical: 12, paddingHorizontal: 20, alignItems: 'center' },
  btnOutline: { backgroundColor: 'transparent', borderWidth: 1, borderColor: colors.primary },
  btnText: { color: '#fff', fontWeight: '600' },
  row: { flexDirection: 'row', alignItems: 'center', paddingVertical: 10, gap: 8 },
  rowTitle: { fontSize: 15, color: colors.text },
  input: { borderWidth: 1, borderColor: colors.border, borderRadius: 8, paddingHorizontal: 10, paddingVertical: 8, color: colors.text },
  chip: { borderWidth: 1, borderColor: colors.border, borderRadius: 16, paddingHorizontal: 12, paddingVertical: 6, marginRight: 8 },
  chipOn: { backgroundColor: colors.primary, borderColor: colors.primary },
});
