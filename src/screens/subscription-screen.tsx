import { StatusBar } from "expo-status-bar";
import { SubscriptionContent } from "@/components/subscription-content";
import { VexScreen } from '@/ui/vex-ui';

export default function SubscriptionRoute() {
  return (
    <>
      <StatusBar style="light" />
      <VexScreen>
        <SubscriptionContent />
      </VexScreen>
    </>
  );
}
