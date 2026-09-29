export type StackAnimation = 'default' | 'none';

export function stackAnimationForPlatform(platform: string): StackAnimation {
  return platform === 'android' ? 'none' : 'default';
}
