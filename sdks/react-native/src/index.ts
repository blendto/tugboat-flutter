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
        console.warn(`[Tugboat] ${name}: only Android is supported; ignored.`);
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

/** The focused route path (`Main/Feed`) and its leaf route key, from a React Navigation state. */
function focusedRoute(state: any): { name: string; key: string } | null {
  const names: string[] = [];
  let key = '';
  while (state && Array.isArray(state.routes) && state.routes.length > 0) {
    const route = state.routes[Math.min(state.index ?? 0, state.routes.length - 1)];
    names.push(String(route.name));
    key = String(route.key ?? route.name);
    state = route.state;
  }
  return names.length > 0 ? { name: names.join('/'), key } : null;
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
  /**
   * Names the current screen (a custom navigator). A new `instanceId` is a push, one
   * already seen is a pop back to it. `instanceId` defaults to `name`.
   */
  setScreen(name: string, instanceId?: string): void {
    call('setScreen', () => NativeTugboat!.setScreen(name, instanceId ?? null));
  },
  /**
   * React Navigation: one `route_change` per navigation, named by the focused route
   * path. Pass the ref given to `NavigationContainer`. Returns a function that stops
   * tracking. Never throws.
   */
  trackNavigation(navigationRef: any): () => void {
    let last = '';
    const report = () => {
      try {
        const focused = focusedRoute(navigationRef?.getRootState?.());
        if (focused == null) return;
        const id = `${focused.name}\u0000${focused.key}`;
        if (id === last) return;
        Tugboat.setScreen(focused.name, focused.key);
        last = id;
      } catch (e) {
        console.warn('[Tugboat] trackNavigation failed', e);
      }
    };
    try {
      const subs = [navigationRef.addListener('state', report), navigationRef.addListener('ready', report)];
      if (navigationRef.isReady?.()) report(); // called after the container is ready
      return () => subs.forEach((unsubscribe: () => void) => unsubscribe());
    } catch (e) {
      console.warn('[Tugboat] trackNavigation failed', e);
      return () => {};
    }
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
