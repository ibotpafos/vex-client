export type BootScreenPresentation = {
  durationMs: number;
  initialOpacity: number;
  initialScale: number;
  label: 'VEX';
};

export function bootScreenPresentation(reduceMotion: boolean): BootScreenPresentation {
  return {
    durationMs: reduceMotion ? 0 : 450,
    initialOpacity: reduceMotion ? 1 : 0,
    initialScale: reduceMotion ? 1 : 0.96,
    label: 'VEX',
  };
}
