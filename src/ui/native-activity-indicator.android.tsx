import { ActivityIndicator, type ActivityIndicatorProps } from 'react-native';

export type VexNativeActivityIndicatorProps = Pick<ActivityIndicatorProps, 'color' | 'size'>;

export function VexNativeActivityIndicator({ color = '#43D9E7', size = 'small' }: VexNativeActivityIndicatorProps) {
  return <ActivityIndicator color={color} size={size} />;
}
