// Manual install, foreground resume and permission return share one attempt.
export function createAndroidUpdateInstallGate() {
  let running = false;
  return {
    isRunning: () => running,
    async run(install: () => Promise<void>): Promise<boolean> {
      if (running) return false;
      running = true;
      try {
        await install();
        return true;
      } finally {
        running = false;
      }
    },
  };
}
