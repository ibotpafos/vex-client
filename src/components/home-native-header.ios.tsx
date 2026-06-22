import { Host, HStack, RNHostView, Spacer, Text, VStack } from '@expo/ui/swift-ui';
import { background, clipShape, font, foregroundStyle, frame, glassEffect, padding } from '@expo/ui/swift-ui/modifiers';
import React, { type ReactElement } from 'react';
import { Image, StyleSheet, View, type ImageSourcePropType } from 'react-native';

type HomeNativeHeaderProps = {
  logoSource: ImageSourcePropType;
  planLabel: string | null;
  showPlan: boolean;
  actions: ReactElement;
};

export function HomeNativeHeader({ logoSource, planLabel, showPlan, actions }: HomeNativeHeaderProps) {
  return (
    <Host matchContents={{ vertical: true }} colorScheme="dark" style={styles.host}>
      <HStack
        alignment="center"
        spacing={12}
        modifiers={[
          padding({ horizontal: 4, vertical: 4 }),
          frame({ maxWidth: 430, minHeight: 66 }),
          glassEffect({
            glass: { variant: 'regular', interactive: true, tint: '#0B2024' },
            shape: 'roundedRectangle',
            cornerRadius: 24,
          }),
        ]}
      >
        <RNHostView matchContents>
          <View style={styles.logoShell}>
            <Image source={logoSource} resizeMode="contain" style={styles.logo} />
          </View>
        </RNHostView>
        <VStack alignment="leading" spacing={4}>
          <Text
            modifiers={[
              font({ size: 34, weight: 'black', design: 'rounded' }),
              foregroundStyle('#F4FCFD'),
            ]}
          >
            VEX
          </Text>
          {showPlan && planLabel ? (
            <Text
              modifiers={[
                font({ size: 13, weight: 'bold', design: 'rounded' }),
                foregroundStyle('#8BF2FF'),
                padding({ horizontal: 12, vertical: 5 }),
                background('#183B40'),
                clipShape('capsule'),
              ]}
            >
              {planLabel}
            </Text>
          ) : null}
        </VStack>
        <Spacer />
        <RNHostView matchContents>{actions}</RNHostView>
      </HStack>
    </Host>
  );
}

const styles = StyleSheet.create({
  host: {
    width: '100%',
  },
  logoShell: {
    alignItems: 'center',
    height: 70,
    justifyContent: 'center',
    width: 76,
  },
  logo: {
    height: 64,
    width: 64,
  },
});
