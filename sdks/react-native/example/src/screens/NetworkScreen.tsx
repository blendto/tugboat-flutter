import React, { useState } from 'react';
import { Text, View } from 'react-native';
import { Button, Field, Page, Section, s } from '../ui';

// Default is a public echo service. Point it at a local capture server
// (e.g. http://10.0.2.2:8080 from an emulator) to inspect requests.
const DEFAULT_BASE_URL = 'https://httpbin.org';
const FAILING_URL = 'https://does-not-exist.invalid/ping';

type Result = { id: string; label: string; outcome: string };
type Call = { id: string; label: string; client: 'fetch' | 'xhr'; method: 'GET' | 'POST'; url: (b: string) => string };

const CALLS: Call[] = [
  { id: 'fetch-get', label: 'fetch GET', client: 'fetch', method: 'GET', url: b => `${b}/get?source=fetch` },
  { id: 'fetch-post', label: 'fetch POST', client: 'fetch', method: 'POST', url: b => `${b}/post` },
  { id: 'fetch-404', label: 'fetch 404', client: 'fetch', method: 'GET', url: b => `${b}/status/404` },
  { id: 'fetch-500', label: 'fetch 500', client: 'fetch', method: 'GET', url: b => `${b}/status/500` },
  { id: 'fetch-fail', label: 'fetch failing host', client: 'fetch', method: 'GET', url: () => FAILING_URL },
  { id: 'xhr-get', label: 'XHR GET', client: 'xhr', method: 'GET', url: b => `${b}/get?source=xhr` },
  { id: 'xhr-post', label: 'XHR POST', client: 'xhr', method: 'POST', url: b => `${b}/post` },
  { id: 'xhr-404', label: 'XHR 404', client: 'xhr', method: 'GET', url: b => `${b}/status/404` },
  { id: 'xhr-500', label: 'XHR 500', client: 'xhr', method: 'GET', url: b => `${b}/status/500` },
  { id: 'xhr-fail', label: 'XHR failing host', client: 'xhr', method: 'GET', url: () => FAILING_URL },
];

const body = JSON.stringify({ hello: 'tugboat', sentAt: 'now' });

async function viaFetch(method: string, url: string): Promise<string> {
  try {
    const res = await fetch(url, method === 'POST' ? { method, headers: { 'Content-Type': 'application/json' }, body } : { method });
    await res.text();
    return `HTTP ${res.status}`;
  } catch (e) {
    return `error: ${(e as Error).message}`;
  }
}

function viaXhr(method: string, url: string): Promise<string> {
  return new Promise(resolve => {
    const xhr = new XMLHttpRequest();
    xhr.open(method, url);
    if (method === 'POST') {
      xhr.setRequestHeader('Content-Type', 'application/json');
    }
    xhr.onload = () => resolve(`HTTP ${xhr.status}`);
    xhr.onerror = () => resolve('error: network failure');
    xhr.ontimeout = () => resolve('error: timeout');
    xhr.timeout = 15000;
    xhr.send(method === 'POST' ? body : undefined);
  });
}

export default function NetworkScreen() {
  const [base, setBase] = useState(DEFAULT_BASE_URL);
  const [results, setResults] = useState<Result[]>([]);

  const run = async (c: Call) => {
    const outcome = await (c.client === 'fetch' ? viaFetch : viaXhr)(c.method, c.url(base));
    setResults(prev => [{ id: `${c.id}-${prev.length}`, label: c.label, outcome }, ...prev]);
  };

  return (
    <Page testID="network-screen">
      <Section title="Base URL">
        <Field testID="network-base-url" label="Echo service" value={base} onChangeText={setBase} autoCapitalize="none" autoCorrect={false} />
      </Section>
      <Section title="Requests">
        <View style={{ gap: 8 }}>
          {CALLS.map(c => (
            <Button key={c.id} testID={`network-${c.id}`} kind="outline" label={c.label} onPress={() => run(c)} />
          ))}
          <Button testID="network-run-all" label="Run all" onPress={() => CALLS.forEach(run)} />
        </View>
      </Section>
      <Section title="Results">
        {results.length === 0 ? <Text style={s.muted}>No requests yet</Text> : null}
        {results.map(r => (
          <Text key={r.id} testID={`network-result-${r.id}`} style={s.body}>
            {r.label}: {r.outcome}
          </Text>
        ))}
        <Button testID="network-clear" kind="outline" label="Clear" onPress={() => setResults([])} />
      </Section>
    </Page>
  );
}
