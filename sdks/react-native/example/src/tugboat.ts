// Placeholder for the Tugboat SDK. The @tugboat/react-native PR replaces this file.
import React from 'react';

/** No-op until the SDK exists. Called once at app start. */
export function init(): void {}

/**
 * Wrap anything that must never be recorded (card fields, OTP codes, ...).
 * TODO(@tugboat/react-native): mark `children` as sensitive so the native
 * capture masks the whole subtree. Today it renders children unchanged.
 */
export function Sensitive({ children }: { children: React.ReactNode }) {
  return React.createElement(React.Fragment, null, children);
}
