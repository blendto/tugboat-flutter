import type { ViewProps } from 'react-native';
import { codegenNativeComponent } from 'react-native';

export interface NativeProps extends ViewProps {}

// A plain view whose Android view calls `tugboatSensitive()`: screenshots mask
// it and everything below it.
export default codegenNativeComponent<NativeProps>('TugboatSensitiveView');
