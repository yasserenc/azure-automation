#!/usr/bin/env bash
set -Eeuo pipefail

: "${TARGET:?TARGET is required}"
: "${SUBSCRIPTION_ID:?SUBSCRIPTION_ID is required}"
: "${CREDIT_THRESHOLD_USD:?CREDIT_THRESHOLD_USD is required}"
: "${ENFORCEMENT_ENABLED:?ENFORCEMENT_ENABLED is required}"
: "${RESULTS_FILE:?RESULTS_FILE is required}"

recorded=false

record_result() {
  local status="$1"
  local trigger="$2"
  local note="$3"
  printf '%s\t%s\t%s\t%s\n' "$TARGET" "$status" "$trigger" "$note" >> "$RESULTS_FILE"
  recorded=true
}

on_error() {
  local line="$1"
  local code="$2"
  if [[ "$recorded" != "true" ]]; then
    record_result "error" "unknown" "unexpected-error-line-$line"
  fi
  echo "::error::[$TARGET] grant guard failed at line $line (exit $code)."
  exit "$code"
}
trap 'on_error "$LINENO" "$?"' ERR

fail_account() {
  local note="$1"
  record_result "error" "unknown" "$note"
  echo "::error::[$TARGET] $note"
  exit 0
}

az account get-access-token --query expiresOn -o tsv >/dev/null
az account set --subscription "$SUBSCRIPTION_ID"

billing_property="$(az rest --method get --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/providers/Microsoft.Billing/billingProperty/default?api-version=2024-04-01" --only-show-errors)"

sku="$(jq -r '.properties.skuDescription // empty' <<<"$billing_property")"
agreement="$(jq -r '.properties.billingAccountAgreementType // empty' <<<"$billing_property")"
account_resource_id="$(jq -r '.properties.billingAccountId // empty' <<<"$billing_property")"
profile_resource_id="$(jq -r '.properties.billingProfileId // empty' <<<"$billing_property")"

[[ "$sku" == "Microsoft Azure Plan" ]] || fail_account "unexpected-plan"
[[ "$agreement" == "MicrosoftCustomerAgreement" ]] || fail_account "unexpected-billing-agreement"
[[ -n "$account_resource_id" && -n "$profile_resource_id" ]] || fail_account "billing-profile-not-discovered"

billing_account_id="${account_resource_id##*/billingAccounts/}"
billing_profile_id="${profile_resource_id##*/billingProfiles/}"

credit_json="$(az rest --method get --url "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$billing_account_id/billingProfiles/$billing_profile_id/providers/Microsoft.Consumption/credits/balanceSummary?api-version=2026-06-01" --only-show-errors)"

current_balance="$(jq -r '.properties.balanceSummary.currentBalance.value // empty' <<<"$credit_json")"
estimated_balance="$(jq -r '.properties.balanceSummary.estimatedBalance.value // empty' <<<"$credit_json")"
currency="$(jq -r '.properties.creditCurrency // .properties.balanceSummary.currentBalance.currency // empty' <<<"$credit_json")"

[[ -n "$current_balance" ]] || fail_account "current-credit-balance-missing"
[[ "$currency" == "USD" ]] || fail_account "unexpected-credit-currency"

effective_remaining="$(CURRENT="$current_balance" ESTIMATED="$estimated_balance" python3 -c 'from decimal import Decimal; import os; c=Decimal(os.environ["CURRENT"]); e=Decimal(os.environ.get("ESTIMATED") or os.environ["CURRENT"]); print(min(c,e))')"
trigger="$(EFFECTIVE="$effective_remaining" THRESHOLD="$CREDIT_THRESHOLD_USD" python3 -c 'from decimal import Decimal; import os; print("true" if Decimal(os.environ["EFFECTIVE"]) <= Decimal(os.environ["THRESHOLD"]) else "false")')"

echo "[$TARGET] CREDIT current=$current_balance estimated=${estimated_balance:-n/a} effective=$effective_remaining currency=$currency"

if [[ "$trigger" != "true" ]]; then
  record_result "ok" "false" "above-threshold"
  {
    echo "### $TARGET"
    echo "- Credit API: **PASS**"
    echo "- Threshold reached: **false**"
    echo "- Enforcement enabled: **$ENFORCEMENT_ENABLED**"
    echo "- Result: **no action required**"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

if [[ "$ENFORCEMENT_ENABLED" != "true" ]]; then
  record_result "would-freeze" "true" "validation-only"
  {
    echo "### $TARGET"
    echo "- Credit API: **PASS**"
    echo "- Threshold reached: **true**"
    echo "- Enforcement enabled: **false**"
    echo "- Result: **validation only; compute not changed**"
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
  exit 0
fi

mapfile -t vm_rows < <(az vm list --query '[].[resourceGroup,name]' -o tsv --only-show-errors)
for row in "${vm_rows[@]}"; do
  [[ -z "$row" ]] && continue
  rg="$(cut -f1 <<<"$row")"
  name="$(cut -f2 <<<"$row")"
  echo "[$TARGET] Deallocating VM: $rg/$name"
  az vm deallocate --resource-group "$rg" --name "$name" --only-show-errors
done

mapfile -t vmss_rows < <(az vmss list --query '[].[resourceGroup,name]' -o tsv --only-show-errors)
for row in "${vmss_rows[@]}"; do
  [[ -z "$row" ]] && continue
  rg="$(cut -f1 <<<"$row")"
  name="$(cut -f2 <<<"$row")"
  echo "[$TARGET] Deallocating VMSS: $rg/$name"
  az vmss deallocate --resource-group "$rg" --name "$name" --only-show-errors
done

running_vms="$(az vm list -d --query "[?powerState!='VM deallocated'].{name:name,resourceGroup:resourceGroup,powerState:powerState}" -o json --only-show-errors)"
if [[ "$(jq 'length' <<<"$running_vms")" != "0" ]]; then
  fail_account "standalone-vm-freeze-verification-failed"
fi

for row in "${vmss_rows[@]}"; do
  [[ -z "$row" ]] && continue
  rg="$(cut -f1 <<<"$row")"
  name="$(cut -f2 <<<"$row")"
  instances="$(az vmss list-instances --resource-group "$rg" --name "$name" --expand instanceView -o json --only-show-errors)"
  non_deallocated="$(jq '[.[] | ([.instanceView.statuses[]? | select(.code | startswith("PowerState/")) | .code][0] // "unknown") | select(. != "PowerState/deallocated")] | length' <<<"$instances")"
  if [[ "$non_deallocated" != "0" ]]; then
    fail_account "vmss-freeze-verification-failed"
  fi
done

record_result "emergency-freeze" "true" "compute-deallocated"
{
  echo "### $TARGET"
  echo "- Credit API: **PASS**"
  echo "- Threshold reached: **true**"
  echo "- Enforcement enabled: **true**"
  echo "- Result: **emergency compute freeze completed**"
  echo "- VMs: **deallocated**"
  echo "- VM scale sets: **deallocated (not deleted)**"
  echo ""
} >> "$GITHUB_STEP_SUMMARY"
