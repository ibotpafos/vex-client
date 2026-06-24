import { StatusBar } from "expo-status-bar";
import { SubscriptionContent } from "@/components/subscription-content";

export default function SubscriptionRoute() {
  return (
    <>
      <StatusBar style="light" />
      <SubscriptionContent />
    </>
  );
}
