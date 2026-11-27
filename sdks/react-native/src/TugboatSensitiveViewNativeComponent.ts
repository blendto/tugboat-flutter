import type { ViewProps } from 'react-native';
import { codegenNativeComponent } from 'react-native';

export interface NativeProps extends ViewProps {}

// A plain view that marks itself sensitive (`tugboatSensitive()` on Android,
// `TugboatAdapters.markSensitive` on iOS): screenshots mask it and everything
// below it.
export default codegenNativeComponent<NativeProps>('TugboatSensitiveView');
