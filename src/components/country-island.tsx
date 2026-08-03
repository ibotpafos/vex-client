import React from 'react';
import { View } from 'react-native';
import Svg, { Defs, LinearGradient, Path, Stop } from 'react-native-svg';

const countryPaths: Record<string, string> = {
  DE: 'M36 4 L48 8 L53 18 L50 27 L57 34 L52 43 L55 53 L48 60 L49 72 L41 78 L33 74 L27 79 L20 73 L21 61 L15 53 L19 43 L14 35 L20 26 L18 15 L27 10 Z',
  FI: 'M38 3 L47 9 L45 19 L52 28 L46 39 L49 49 L44 59 L46 72 L39 80 L32 74 L31 63 L24 55 L28 44 L23 34 L29 24 L27 13 Z',
  NL: 'M17 24 L29 17 L42 20 L52 16 L61 25 L58 38 L64 49 L54 58 L41 56 L31 63 L20 55 L22 43 L14 35 Z',
};

export function CountryIsland({ countryCode }: { countryCode?: string }) {
  const path = countryCode ? countryPaths[countryCode.toUpperCase()] : undefined;
  if (!path) return null;

  return (
    <View pointerEvents="none" style={{ height: 82, opacity: 0.95, width: 82 }}>
      <Svg height="82" viewBox="0 0 82 82" width="82">
        <Defs>
          <LinearGradient id="countryIsland" x1="0" x2="1" y1="0" y2="1">
            <Stop offset="0" stopColor="#22D3EE" stopOpacity="0.18" />
            <Stop offset="1" stopColor="#22D3EE" stopOpacity="0.03" />
          </LinearGradient>
        </Defs>
        <Path d={path} fill="url(#countryIsland)" stroke="#67E8F9" strokeOpacity={0.25} strokeWidth={1.4} />
      </Svg>
    </View>
  );
}
