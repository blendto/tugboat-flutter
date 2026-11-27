import type { TurboModule } from 'react-native';
import { TurboModuleRegistry } from 'react-native';

// Codegen spec. Every method is one call to the same-named `Tugboat` function
// in tugboat-android or the Swift host. Events are built by the shared engine,
// never in JavaScript.
export interface Spec extends TurboModule {
  start(config: Object): void;
  activate(activationRequestId: string): void;
  deactivate(): void;
  stop(): void;
  setScreen(name: string, instanceId: string | null): void;
  setUserId(id: string | null): void;
  setTraits(traits: Object): void;
}

// `get`, not `getEnforcing`: the module does not exist on other platforms.
export default TurboModuleRegistry.get<Spec>('Tugboat');
