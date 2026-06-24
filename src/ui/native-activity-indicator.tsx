import { ActivityIndicator, type ActivityIndicatorProps } from 'react-native';

export type VexNativeActivityIndicatorProps = Pick<ActivityIndicatorProps, 'color' | 'size'>;

export function VexNativeActivityIndicator({ color = '#22D3EE', size = 'small' }: VexNativeActivityIndicatorProps) {
  return <ActivityIndicator color={color} size={size} />;
}
