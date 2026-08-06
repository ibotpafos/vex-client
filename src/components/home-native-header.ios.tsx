import { Host, HStack, RNHostView, Spacer, Text } from '@expo/ui/swift-ui';
import { font, foregroundStyle, frame, glassEffect, padding } from '@expo/ui/swift-ui/modifiers';
import { type ReactElement } from 'react';
import { StyleSheet } from 'react-native';

type HomeNativeHeaderProps = {
  actions: ReactElement;
};

export function HomeNativeHeader({ actions }: HomeNativeHeaderProps) {
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
        <HStack alignment="center" spacing={8}>
          <Text
            modifiers={[
              font({ size: 28, weight: 'black', design: 'rounded' }),
              foregroundStyle('#F4FCFD'),
            ]}
          >
            VEX
          </Text>
          <Text modifiers={[font({ size: 22, weight: 'black' }), foregroundStyle('#43D9E7')]}>•</Text>
        </HStack>
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
});
