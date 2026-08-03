import React from 'react';
import Svg, { Defs, LinearGradient, Path, Stop } from 'react-native-svg';

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
      .map((ring) => `M ${ring.map(([x, y]) => `${x * 82} ${y * 82}`).join(' L ')} Z`)
      .join(' ');
  }, [countryCode]);

  if (!path) return null;

  return (
    <Svg height={82} viewBox="0 0 82 82" width={82}>
      <Defs>
        <LinearGradient id="countryIsland" x1="0" x2="1" y1="1" y2="0">
          <Stop offset="0" stopColor="#22D3EE" stopOpacity={0.3} />
          <Stop offset="1" stopColor="#B9FBFF" />
        </LinearGradient>
      </Defs>
      <Path d={path} fill="url(#countryIsland)" fillOpacity={selected ? 0.085 : 0.048} fillRule="evenodd" />
      <Path d={path} fill="none" stroke="#B9FBFF" strokeOpacity={selected ? 0.18 : 0.1} strokeWidth={0.6} />
    </Svg>
  );
});
