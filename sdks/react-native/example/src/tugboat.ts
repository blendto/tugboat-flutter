import { Tugboat } from '@tugboat/react-native';

/**
 * Starts the SDK once. The collector is the local capture collector:
 * `python3 tool/dev/capture-collector/capture_collector.py --port 3000 --out <dir>`
 * and `adb reverse tcp:3000 tcp:3000`.
 */
export function init(): void {
  Tugboat.start({
    collector: { baseUrl: 'http://localhost:3000', apiKey: 'rn-example' },
    app: { name: 'Tugboat RN Example' },
    enabled: true,
  });
}

/** Wrap anything that must never be recorded (card fields, OTP codes, ...). */
export const Sensitive = Tugboat.Sensitive;
