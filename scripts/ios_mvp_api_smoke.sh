#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-https://vpn.example.com}"
EMAIL="${EMAIL:-ios-mvp-$(date +%s)@example.com}"
PASSWORD="${PASSWORD:-Password123!}"

json_get() {
  ruby -rjson -e "puts JSON.parse(STDIN.read).dig(*ARGV)" "$@"
}

echo "Registering $EMAIL"
auth_json="$(curl -fsS --max-time 15 \
  -H "Content-Type: application/json" \
  -d "{\"email\":\"$EMAIL\",\"password\":\"$PASSWORD\"}" \
  "$BASE_URL/v1/auth/register")"
token="$(printf '%s' "$auth_json" | json_get session access_token)"

echo "Loading plans"
plans_json="$(curl -fsS --max-time 15 "$BASE_URL/v1/billing/plans")"
plan_id="$(printf '%s' "$plans_json" | ruby -rjson -e 'puts JSON.parse(STDIN.read).first.fetch("id")')"

echo "Activating access through checkout session: $plan_id"
curl -fsS --max-time 15 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $token" \
  -H "Idempotency-Key: ios-smoke-checkout-$(date +%s)" \
  -d "{\"plan_id\":\"$plan_id\",\"provider\":\"manual\"}" \
  "$BASE_URL/v1/billing/checkout-session" >/dev/null

entitlement_json="$(curl -fsS --max-time 15 \
  -H "Authorization: Bearer $token" \
  "$BASE_URL/v1/billing/entitlement")"
active="$(printf '%s' "$entitlement_json" | json_get active)"
if [[ "$active" != "true" ]]; then
  echo "Expected active entitlement, got: $entitlement_json" >&2
  exit 1
fi

echo "Creating iPhone device"
device_json="$(curl -fsS --max-time 15 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $token" \
  -H "Idempotency-Key: ios-smoke-device-$(date +%s)" \
  -d '{"name":"iPhone","location":"de"}' \
  "$BASE_URL/v1/devices")"
device_id="$(printf '%s' "$device_json" | json_get device id)"

echo "Preparing WireGuard config"
config_token_json="$(curl -fsS --max-time 15 \
  -X POST \
  -H "Authorization: Bearer $token" \
  "$BASE_URL/v1/devices/$device_id/config-token")"
config_token="$(printf '%s' "$config_token_json" | json_get token)"

config="$(curl -fsS --max-time 15 \
  -H "Authorization: Bearer $token" \
  "$BASE_URL/v1/devices/$device_id/config?format=conf&token=$config_token")"
if ! printf '%s' "$config" | grep -q "PrivateKey"; then
  echo "WireGuard config is missing PrivateKey" >&2
  exit 1
fi

diagnostics_json="$(curl -fsS --max-time 15 \
  -H "Authorization: Bearer $token" \
  "$BASE_URL/v1/devices/$device_id/diagnostics")"
status="$(printf '%s' "$diagnostics_json" | json_get status)"

echo "MVP API smoke test passed"
echo "Email: $EMAIL"
echo "Device: $device_id"
echo "Diagnostics: $status"
