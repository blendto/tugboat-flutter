import React, { useState } from 'react';
import { Modal, Text, ToastAndroid, View } from 'react-native';
import { Sensitive } from '../tugboat';
import { Button, Chip, Field, Page, Row, Section, SwitchRow, s } from '../ui';

const ACTIONS = ['Order history', 'Saved addresses', 'Payment methods', 'Help & support', 'Human verification', 'Sign out'];
const LANGUAGES = ['English', 'Spanish', 'French', 'German'];
const DENSITIES = ['Compact', 'Comfortable', 'Spacious'];

export default function ProfileScreen() {
  const [push, setPush] = useState(true);
  const [digest, setDigest] = useState(false);
  const [dark, setDark] = useState(false);
  const [density, setDensity] = useState('Comfortable');
  const [language, setLanguage] = useState('English');
  const [verify, setVerify] = useState(false);
  return (
    <Page testID="profile-screen">
      <Section title="Demo User">
        <Text style={s.muted}>demo@tugboat.example</Text>
        <Button testID="profile-edit" kind="outline" label="Edit" onPress={() => {}} />
      </Section>
      <Section title="Notifications">
        <SwitchRow testID="profile-push" title="Push notifications" value={push} onChange={setPush} />
        <SwitchRow testID="profile-digest" title="Weekly email digest" value={digest} onChange={setDigest} />
      </Section>
      <Section title="Appearance">
        <SwitchRow testID="profile-dark" title="Dark mode" value={dark} onChange={setDark} />
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
          {DENSITIES.map(d => (
            <Chip key={d} testID={`profile-density-${d.toLowerCase()}`} label={d} selected={density === d} onPress={() => setDensity(d)} />
          ))}
        </View>
      </Section>
      <Section title="Language">
        <View style={{ flexDirection: 'row', flexWrap: 'wrap', gap: 8 }}>
          {LANGUAGES.map(l => (
            <Chip key={l} testID={`profile-language-${l.toLowerCase()}`} label={l} selected={language === l} onPress={() => setLanguage(l)} />
          ))}
        </View>
      </Section>
      <Section title="Account actions">
        {ACTIONS.map(a => (
          <Row
            key={a}
            testID={`profile-action-${a.toLowerCase().replace(/[^a-z]+/g, '-')}`}
            title={a}
            onPress={() => (a === 'Human verification' ? setVerify(true) : ToastAndroid.show(`${a} tapped`, ToastAndroid.SHORT))}
          />
        ))}
      </Section>
      <Modal visible={verify} transparent animationType="fade" onRequestClose={() => setVerify(false)}>
        <View style={{ flex: 1, justifyContent: 'center', padding: 24, backgroundColor: '#0006' }}>
          <View style={{ backgroundColor: '#fff', borderRadius: 12, padding: 16 }}>
            <Text style={s.h1}>Human verification required</Text>
            <Sensitive>
              <Field testID="profile-verify-code" label="One-time verification code" keyboardType="number-pad" />
            </Sensitive>
            <Button testID="profile-verify-complete" label="Complete verification" onPress={() => setVerify(false)} />
          </View>
        </View>
      </Modal>
    </Page>
  );
}
