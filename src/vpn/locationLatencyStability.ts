const latencyBucketMs = 10;
const latencyChangeThresholdMs = 20;

export function stabilizedLocationLatency(
  previous: number | null | undefined,
  measurement: number | null | undefined,
): number | null {
  const previousLatency = typeof previous === 'number' && Number.isFinite(previous)
    ? Math.max(0, previous)
    : null;
  if (typeof measurement !== 'number' || !Number.isFinite(measurement)) {
    return previousLatency;
  }

  const roundedMeasurement = Math.max(
    0,
    Math.round(measurement / latencyBucketMs) * latencyBucketMs,
  );
  if (previousLatency === null) {
    return roundedMeasurement;
  }
  return Math.abs(roundedMeasurement - previousLatency) >= latencyChangeThresholdMs
    ? roundedMeasurement
    : previousLatency;
}
