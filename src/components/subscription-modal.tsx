import React from 'react';
import { Modal } from 'react-native';
import { SubscriptionContent } from './subscription-content';

export interface SubscriptionModalProps {
  visible: boolean;
  onClose: () => void;
}

export function SubscriptionModal({
  visible,
  onClose,
}: SubscriptionModalProps) {
  return (
    <Modal animationType="slide" onRequestClose={onClose} presentationStyle="fullScreen" visible={visible}>
      <SubscriptionContent onClose={onClose} />
    </Modal>
  );
}
