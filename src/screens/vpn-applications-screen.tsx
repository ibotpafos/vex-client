import { router } from "expo-router";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Platform } from "react-native";
import { UniversalVpnApplicationsContent } from "@/components/universal-vpn-applications-content";
import { playErrorHaptic, playSelectionHaptic } from "@/native/haptics";
import { getInstalledVpnApplications, type InstalledVpnApplication } from "@/native/vexVpn";
import {
  getVpnApplicationSelection,
  setSelectedVpnApplications,
  setVpnApplicationRoutingMode,
  type VpnApplicationRoutingMode,
} from "@/settings/vpnPreferences";
import { useToast } from "@/ui/toast";

export default function VpnApplicationsScreen() {
  const { showToast } = useToast();
  const [applications, setApplications] = useState<InstalledVpnApplication[]>([]);
  const [selectedPackages, setSelectedPackages] = useState<Set<string>>(new Set());
  const [mode, setMode] = useState<VpnApplicationRoutingMode>("all");
  const [query, setQuery] = useState("");
  const [loading, setLoading] = useState(true);
  const saveQueue = useRef<Promise<unknown>>(Promise.resolve());

  const queueSave = useCallback((operation: () => Promise<unknown>) => {
    saveQueue.current = saveQueue.current.then(operation).catch(() => {
      playErrorHaptic();
      showToast({ duration: "long", message: "Не удалось сохранить выбор приложений.", variant: "error" });
    });
  }, [showToast]);

  useEffect(() => {
    let mounted = true;
    if (Platform.OS !== "android") {
      setLoading(false);
      return () => undefined;
    }
    Promise.all([getInstalledVpnApplications(), getVpnApplicationSelection()])
      .then(([installed, selection]) => {
        if (!mounted) return;
        const installedPackages = new Set(installed.map((item) => item.packageName));
        const selected = selection.packageNames.filter((packageName) => installedPackages.has(packageName));
        setApplications(installed);
        setSelectedPackages(new Set(selected));
        setMode(selection.mode === "selected" && selected.length > 0 ? "selected" : "all");
        if (selected.length !== selection.packageNames.length) queueSave(() => setSelectedVpnApplications(selected));
      })
      .catch(() => {
        if (!mounted) return;
        playErrorHaptic();
        showToast({ duration: "long", message: "Не удалось загрузить список приложений.", variant: "error" });
      })
      .finally(() => { if (mounted) setLoading(false); });
    return () => { mounted = false; };
  }, [queueSave, showToast]);

  const filteredApplications = useMemo(() => {
    const normalizedQuery = query.trim().toLocaleLowerCase();
    if (!normalizedQuery) return applications;
    return applications.filter((application) =>
      application.label.toLocaleLowerCase().includes(normalizedQuery)
      || application.packageName.toLocaleLowerCase().includes(normalizedQuery));
  }, [applications, query]);

  const selectMode = useCallback((nextMode: VpnApplicationRoutingMode) => {
    if (nextMode === "selected" && selectedPackages.size === 0) {
      showToast({ message: "Сначала выберите хотя бы одно приложение.", variant: "warning" });
      return;
    }
    playSelectionHaptic();
    setMode(nextMode);
    queueSave(() => setVpnApplicationRoutingMode(nextMode));
  }, [queueSave, selectedPackages.size, showToast]);

  const toggleApplication = useCallback((packageName: string) => {
    playSelectionHaptic();
    setSelectedPackages((current) => {
      const next = new Set(current);
      if (next.has(packageName)) next.delete(packageName);
      else next.add(packageName);
      const packageNames = [...next];
      queueSave(() => setSelectedVpnApplications(packageNames));
      const nextMode: VpnApplicationRoutingMode = packageNames.length > 0 ? "selected" : "all";
      setMode(nextMode);
      queueSave(() => setVpnApplicationRoutingMode(nextMode));
      return next;
    });
  }, [queueSave]);

  return (
    <UniversalVpnApplicationsContent
      applications={filteredApplications}
      loading={loading}
      mode={mode}
      onBack={() => router.back()}
      onModeChange={selectMode}
      onQueryChange={setQuery}
      onToggleApplication={toggleApplication}
      selectedPackages={selectedPackages}
    />
  );
}
