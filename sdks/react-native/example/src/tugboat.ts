import { Platform } from 'react-native';
import { Tugboat } from '@tugboat-ai/react-native';

/**
 * Starts the SDK once. The collector is the local capture collector:
 * `python3 tool/dev/capture-collector/capture_collector.py --port 3000 --out <dir>`
 * and `adb reverse tcp:3000 tcp:3000` on Android. The iOS simulator shares the Mac's
 * network; `127.0.0.1`, not `localhost`, which can resolve to another process on IPv6.
 */
const COLLECTOR_URL = Platform.OS === 'ios' ? 'http://127.0.0.1:3000' : 'http://localhost:3000';

export function init(): void {
  Tugboat.start({
    collector: { baseUrl: COLLECTOR_URL, apiKey: 'rn-example' },
    app: { name: 'Tugboat RN Example' },
    enabled: true,
  });
}

/** Wrap anything that must never be recorded (card fields, OTP codes, ...). */
export const Sensitive = Tugboat.Sensitive;
