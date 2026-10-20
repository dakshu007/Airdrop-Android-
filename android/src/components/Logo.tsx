import React from 'react';
import Svg, { Defs, Path, RadialGradient, Stop } from 'react-native-svg';

/** The CrossDrop drop mark. Decorative. */
export function Logo({ size = 30 }: { size?: number }) {
  return (
    <Svg width={size} height={size} viewBox="0 0 30 30" accessible={false}>
      <Defs>
        <RadialGradient id="logoGrad" cx="0.62" cy="0.7" r="0.7">
          <Stop offset="0" stopColor="#E9FFC8" />
          <Stop offset="0.45" stopColor="#5ED48A" />
          <Stop offset="1" stopColor="#128C55" />
        </RadialGradient>
      </Defs>
      <Path
        d="M15 2.5C15 2.5 5.5 12.6 5.5 18.6a9.5 9.5 0 0 0 19 0C24.5 12.6 15 2.5 15 2.5z"
        fill="url(#logoGrad)"
      />
    </Svg>
  );
}
