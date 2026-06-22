import React from 'react';

const defaultDesktopUpdateState = {
  status: 'idle' as const,
  currentVersion: '0.0.0',
  latestVersion: '',
  latestBuild: 0,
  releaseChannel: 'stable',
  releaseNotes: null,
  required: false,
  downloadedBytes: 0,
  contentLength: 0,
  error: null,
  checkNow: async () => undefined,
  relaunchToUpdate: async () => undefined,
};

export function DesktopUpdateProvider({ children }: { children: React.ReactNode }) {
  return <>{children}</>;
}

export function useDesktopUpdate() {
  return defaultDesktopUpdateState;
}

export function DesktopUpdateOverlay() {
  return null;
}
