import React from 'react';
import { Platform } from 'react-native';
import type { ViewProps } from 'react-native';
import NativeTugboat from './NativeTugboat';

export interface TugboatConfig {
  collector: { baseUrl: string; apiKey: string };
  app: {
    name: string;
    /** Default: the app's package info. */
    version?: string;
    buildNumber?: string;
    appId?: string;
    installationId?: string;
  };
  /** Default false: dormant until `activate()`. */
  enabled?: boolean;
  /** Only `'allTextAndMedia'` exists; any other string becomes it. */
  maskLevel?: 'allTextAndMedia';
  captureFocusChanges?: boolean;
  captureSystemInput?: boolean;
  captureDiagnostics?: boolean;
  durableOutbox?: boolean;
  /** Default true. */
  captureNetwork?: boolean;
  /** Record only calls to these hosts. Empty (default): every host. */
  networkAllowHosts?: string[];
}

let warned = false;

// Nothing here throws into the app. On iOS every call is a no-op with one warning.
function call(name: string, run: () => void): void {
  try {
    if (Platform.OS !== 'android' || NativeTugboat == null) {
      if (!warned) {
        warned = true;
        console.warn(`[Tugboat] ${name}: only Android is supported in 0.0.1; ignored.`);
      }
      return;
    }
    run();
  } catch (e) {
    console.warn(`[Tugboat] ${name} failed`, e);
  }
}

/**
 * Wrap anything that must never be recorded (card fields, OTP codes, ...). The
 * native capture masks this view and everything below it.
 */
function Sensitive(props: ViewProps) {
  if (Platform.OS !== 'android') {
    return React.createElement(React.Fragment, null, props.children);
  }
  const Native = require('./TugboatSensitiveViewNativeComponent').default;
  return React.createElement(Native, { ...props, collapsable: false });
}

export const Tugboat = {
  start(config: TugboatConfig): void {
    call('start', () => NativeTugboat!.start({ ...config }));
  },
  activate(activationRequestId: string): void {
    call('activate', () => NativeTugboat!.activate(activationRequestId));
  },
  deactivate(): void {
    call('deactivate', () => NativeTugboat!.deactivate());
  },
  stop(): void {
    call('stop', () => NativeTugboat!.stop());
  },
  setUserId(id: string | null): void {
    call('setUserId', () => NativeTugboat!.setUserId(id));
  },
  setTraits(traits: Record<string, unknown>): void {
    call('setTraits', () => NativeTugboat!.setTraits({ ...traits }));
  },
  Sensitive,
};

export default Tugboat;
