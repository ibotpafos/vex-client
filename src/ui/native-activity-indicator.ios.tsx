import { Host, ProgressView } from '@expo/ui/swift-ui';
import { controlSize, frame, tint } from '@expo/ui/swift-ui/modifiers';
import type { ActivityIndicatorProps } from 'react-native';

export type VexNativeActivityIndicatorProps = Pick<ActivityIndicatorProps, 'color' | 'size'>;

function indicatorSize(size: VexNativeActivityIndicatorProps['size']) {
  return size === 'large' ? 40 : 22;
}

export function VexNativeActivityIndicator({ color = '#22D3EE', size = 'small' }: VexNativeActivityIndicatorProps) {
  const resolvedSize = indicatorSize(size);

  return (
    <Host matchContents colorScheme="dark">
      <ProgressView
        modifiers={[
          tint(color),
          controlSize(size === 'large' ? 'large' : 'regular'),
          frame({ width: resolvedSize, height: resolvedSize }),
        ]}
      />
    </Host>
  );
}
