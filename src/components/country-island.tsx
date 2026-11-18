import React from 'react';
import Svg, { Path } from 'react-native-svg';
import { vexTheme } from '@/ui/vex-theme';

type CountrySilhouette = {
  rings: number[][][];
};

type CountrySilhouetteCatalog = {
  countries: Record<string, CountrySilhouette>;
};

// This is the same Natural Earth geometry resource rendered by VEX Native on macOS.
// Keeping one source of truth prevents the Android card from degrading into a generic icon.
const silhouetteCatalog = require('../../macos-native/Sources/VEXNativeMac/Resources/country-silhouettes.json') as CountrySilhouetteCatalog;

export const CountryIsland = React.memo(function CountryIsland({
  countryCode,
  selected,
}: {
  countryCode?: string;
  selected: boolean;
}) {
  const path = React.useMemo(() => {
    const normalizedCode = countryCode?.trim().toUpperCase();
    const silhouette = normalizedCode ? silhouetteCatalog.countries[normalizedCode] : undefined;
    if (!silhouette) return null;

    return silhouette.rings
      .filter((ring) => ring.length >= 3)
      .map((ring) => `M ${ring.map(([x, y]) => `${x * 80} ${y * 80}`).join(' L ')} Z`)
      .join(' ');
  }, [countryCode]);

  if (!path) return null;

  return (
    <Svg height={80} viewBox="0 0 80 80" width={80}>
      <Path d={path} fill={vexTheme.colors.textMuted} fillOpacity={selected ? 0.085 : 0.048} fillRule="evenodd" />
      <Path d={path} fill="none" stroke={vexTheme.colors.textMuted} strokeOpacity={selected ? 0.18 : 0.1} strokeWidth={0.6} />
    </Svg>
  );
});
