#!/usr/bin/env bash
# One-time additive restore. Only the RFCY HMGWEB snapshot and an isolated test RG are in scope.
set -Eeuo pipefail
umask 077

: "${RFCY_SUBSCRIPTION:?RFCY_SUBSCRIPTION is required}"
az account set --subscription "$RFCY_SUBSCRIPTION"
test "$(az account show --query id -o tsv)" = "$RFCY_SUBSCRIPTION"

SOURCE_RG="HMGWEB_GROUP"
SOURCE_VM="hmgweb"
SOURCE_SNAPSHOT="hmgweb-snap-1791359991"
EXPECTED_SIZE="Standard_B2ls_v2"
LOCATION="westeurope"
TEST_RG="hmgweb-20261007-test-rg"
TEST_VM="hmgweb-20261007-test"
TEST_DISK="hmgweb-20261007-restore-os"
TEST_VNET="hmgweb-20261007-test-vnet"
TEST_SUBNET="test-subnet"
TEST_NSG="hmgweb-20261007-test-nsg"
TEST_NIC="hmgweb-20261007-test-nic"

WORKDIR="$(mktemp -d)"
trap 'rm -rf -- "$WORKDIR"' EXIT

# Read-only preflight: exact source disk, all three snapshots, original VM size, security and OS.
az vm show -g "$SOURCE_RG" -n "$SOURCE_VM" -o json > "$WORKDIR/source-vm.json"
az snapshot list -g "$SOURCE_RG" -o json > "$WORKDIR/source-snapshots.json"
az snapshot show -g "$SOURCE_RG" -n "$SOURCE_SNAPSHOT" -o json > "$WORKDIR/oldest-snapshot.json"
SOURCE_DISK_ID="$(jq -er '.storageProfile.osDisk.managedDisk.id' "$WORKDIR/source-vm.json")"
az disk show --ids "$SOURCE_DISK_ID" -o json > "$WORKDIR/source-disk.json"
python3 - "$WORKDIR/source-vm.json" "$WORKDIR/source-snapshots.json" "$WORKDIR/oldest-snapshot.json" "$WORKDIR/source-disk.json" <<'PY'
import json,sys
vm,snaps,snap,disk=[json.load(open(p,encoding="utf-8")) for p in sys.argv[1:]]
def check(ok,reason):
    if not ok: raise SystemExit("PREFLIGHT_BLOCKED: "+reason)
osdisk=(vm.get("storageProfile") or {}).get("osDisk") or {}
osid=((osdisk.get("managedDisk") or {}).get("id") or "").lower()
check(vm.get("name","").lower()=="hmgweb","wrong VM")
check(vm.get("resourceGroup","").lower()=="hmgweb_group","wrong source RG")
check(vm.get("location","").lower()=="westeurope","wrong region")
check((vm.get("hardwareProfile") or {}).get("vmSize")=="Standard_B2ls_v2","source VM size changed")
check((vm.get("securityProfile") or {}).get("securityType")=="Standard","unexpected source security type")
check(osdisk.get("osType")=="Linux" and bool(osid),"unexpected source OS disk")
check(len((vm.get("storageProfile") or {}).get("dataDisks") or [])==0,"source VM has additional data disks")
check((disk.get("id") or "").lower()==osid,"source disk ID mismatch")
check((disk.get("sku") or {}).get("name")=="StandardSSD_LRS","source disk SKU changed")
check(disk.get("hyperVGeneration")=="V2","source disk generation changed")
matching=[s for s in snaps if (((s.get("creationData") or {}).get("sourceResourceId") or "").lower()==osid)]
check(len(matching)==3,"expected precisely 3 snapshots for the HMGWEB OS disk")
matching.sort(key=lambda s:s.get("timeCreated") or "")
check(matching[0].get("name")=="hmgweb-snap-1791359991","oldest source snapshot changed")
check(matching[0].get("id","").lower()==snap.get("id","").lower(),"snapshot identity mismatch")
check((snap.get("timeCreated") or "").startswith("2026-10-07T07:59:52"),"snapshot age changed")
check(snap.get("provisioningState")=="Succeeded","snapshot incomplete")
check(snap.get("location")=="westeurope" and snap.get("osType")=="Linux","snapshot location/OS mismatch")
check(snap.get("hyperVGeneration")=="V2","snapshot generation mismatch")
snap_size=snap.get("diskSizeGB",snap.get("diskSizeGb"))
disk_size=disk.get("diskSizeGB",disk.get("diskSizeGb"))
check(isinstance(snap_size,int) and snap_size>0,"snapshot capacity not available")
check(isinstance(disk_size,int) and disk_size>0,"source capacity not available")
check(snap_size<=disk_size,"snapshot capacity exceeds current disk capacity")
print("PREFLIGHT_OK: oldest 2026-10-07 snapshot selected, exactly three HMGWEB OS-disk snapshots, Standard_B2ls_v2, Linux V2, West Europe.")
print("SOURCE_SNAPSHOT_SIZE_GB="+str(snap_size))
print("CURRENT_SOURCE_DISK_SIZE_GB="+str(disk_size))
PY

# Never overwrite/modify an existing group or any production object.
if [[ "$(az group exists -n "$TEST_RG" -o tsv)" != "false" ]]; then
  echo "BLOCKED: intended test RG already exists; refusing to overwrite or duplicate" >&2
  exit 30
fi

echo "CREATE_BEGIN: isolated test infrastructure"
az group create -n "$TEST_RG" -l "$LOCATION" --tags purpose=isolated-snapshot-test origin=rfcy-hmgweb-snapshot-20261007 -o none

# Distinct unpeered VNet, no public IP, and explicit bidirectional deny-all traffic.
# Azure WireServer agent channel 168.63.129.16 is NSG-exempt per Microsoft Learn.
az network nsg create -g "$TEST_RG" -n "$TEST_NSG" -l "$LOCATION" -o none
az network nsg rule create -g "$TEST_RG" --nsg-name "$TEST_NSG" -n deny-all-inbound --priority 100 --direction Inbound --access Deny --protocol '*' --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges '*' -o none
az network nsg rule create -g "$TEST_RG" --nsg-name "$TEST_NSG" -n deny-all-outbound --priority 100 --direction Outbound --access Deny --protocol '*' --source-address-prefixes '*' --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges '*' -o none
az network vnet create -g "$TEST_RG" -n "$TEST_VNET" -l "$LOCATION" --address-prefixes 10.248.247.0/24 --subnet-name "$TEST_SUBNET" --subnet-prefixes 10.248.247.0/27 -o none
az network nic create -g "$TEST_RG" -n "$TEST_NIC" -l "$LOCATION" --vnet-name "$TEST_VNET" --subnet "$TEST_SUBNET" --network-security-group "$TEST_NSG" -o none

SOURCE_SNAPSHOT_ID="$(jq -er '.id' "$WORKDIR/oldest-snapshot.json")"
echo "Creating a separate managed OS disk from the oldest read-only snapshot"
az disk create -g "$TEST_RG" -n "$TEST_DISK" -l "$LOCATION" --source "$SOURCE_SNAPSHOT_ID" --sku StandardSSD_LRS --os-type Linux --tags purpose=isolated-snapshot-test source=hmgweb-20261007 -o none
az disk show -g "$TEST_RG" -n "$TEST_DISK" -o json > "$WORKDIR/restored-disk.json"
python3 - "$WORKDIR/oldest-snapshot.json" "$WORKDIR/restored-disk.json" <<'PY'
import json,sys
s,d=[json.load(open(p,encoding="utf-8")) for p in sys.argv[1:]]
def gb(x):return x.get("diskSizeGB",x.get("diskSizeGb"))
assert gb(s)==gb(d),f"CLONED_DISK_SIZE_MISMATCH snapshot={gb(s)} restored={gb(d)}"
assert d.get("provisioningState")=="Succeeded","CLONED_DISK_NOT_READY"
assert d.get("diskState") in ("Unattached","ReadyToUpload",None), "CLONED_DISK_UNEXPECTED_STATE"
assert d.get("osType")=="Linux","CLONED_DISK_NOT_LINUX"
assert (d.get("sku") or {}).get("name")=="StandardSSD_LRS","CLONED_DISK_SKU_MISMATCH"
print("RESTORED_OS_DISK_VERIFIED_GB="+str(gb(d)))
PY

echo "Creating Linux test VM from specialized cloned OS disk, matching original VM size"
az vm create -g "$TEST_RG" -n "$TEST_VM" -l "$LOCATION" --size "$EXPECTED_SIZE" --attach-os-disk "$TEST_DISK" --os-type Linux --security-type Standard --nics "$TEST_NIC" --tags purpose=isolated-snapshot-test source=hmgweb-20261007 -o none

az vm show -g "$TEST_RG" -n "$TEST_VM" -o json > "$WORKDIR/test-vm.json"
az disk show -g "$TEST_RG" -n "$TEST_DISK" -o json > "$WORKDIR/test-disk.json"
az network nic show -g "$TEST_RG" -n "$TEST_NIC" -o json > "$WORKDIR/test-nic.json"
az network nsg rule list -g "$TEST_RG" --nsg-name "$TEST_NSG" -o json > "$WORKDIR/test-nsg-rules.json"
az network vnet peering list -g "$TEST_RG" --vnet-name "$TEST_VNET" -o json > "$WORKDIR/test-peerings.json"
az network vnet subnet show -g "$TEST_RG" --vnet-name "$TEST_VNET" -n "$TEST_SUBNET" -o json > "$WORKDIR/test-subnet.json"
az network public-ip list -g "$TEST_RG" -o json > "$WORKDIR/test-public-ips.json"
python3 - "$WORKDIR/test-vm.json" "$WORKDIR/test-disk.json" "$WORKDIR/test-nic.json" "$WORKDIR/test-nsg-rules.json" "$WORKDIR/test-peerings.json" "$WORKDIR/test-subnet.json" "$WORKDIR/test-public-ips.json" <<'PY'
import json,sys
vm,disk,nic,rules,peerings,subnet,pips=[json.load(open(p,encoding="utf-8")) for p in sys.argv[1:]]
def check(ok,msg):
    if not ok: raise SystemExit("POSTCONDITION_FAILED: "+msg)
vm_os=((vm.get("storageProfile") or {}).get("osDisk") or {})
vm_nics=((vm.get("networkProfile") or {}).get("networkInterfaces") or [])
nsg_id=((nic.get("networkSecurityGroup") or {}).get("id") or "").lower()
check((vm.get("hardwareProfile") or {}).get("vmSize")=="Standard_B2ls_v2","VM size differs from original")
check(vm.get("location")=="westeurope","VM region mismatch")
check(vm_os.get("osType")=="Linux","VM OS type mismatch")
check(((vm_os.get("managedDisk") or {}).get("id") or "").lower()==disk.get("id","").lower(),"VM attached wrong disk")
check(len(vm_nics)==1 and vm_nics[0].get("id","").lower()==nic.get("id","").lower(),"VM NIC mismatch")
check(not any(conf.get("publicIPAddress") for conf in nic.get("ipConfigurations") or []),"VM has public IP")
check(nsg_id.endswith("/networksecuritygroups/hmgweb-20261007-test-nsg"),"isolation NSG not bound to NIC")
check(vm.get("provisioningState")=="Succeeded","VM provisioning not complete")
check((vm.get("securityProfile") or {}).get("securityType")=="Standard","VM security mode changed")
check(not peerings,"VNet has peering")
check(not pips,"Unexpected public IP resources")
check(not subnet.get("natGateway") and not subnet.get("routeTable"),"Unexpected NAT or route table")
for name,direction in [("deny-all-inbound","Inbound"),("deny-all-outbound","Outbound")]:
    candidates=[r for r in rules if r.get("name")==name]
    check(len(candidates)==1, "missing "+name)
    r=candidates[0]
    check(r.get("direction")==direction and r.get("access")=="Deny" and r.get("priority")==100,"invalid "+name)
print("CONTROL_PLANE_VERIFIED: Standard_B2ls_v2 VM; cloned OS disk; private NIC; deny-all NSG; unpeered VNet; no NAT, route table or public IP.")
PY

POWER="$(az vm get-instance-view -g "$TEST_RG" -n "$TEST_VM" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)"
echo "VM_POWER_STATE=$POWER"
[[ "$POWER" == "VM running" ]] || { echo "VM not running" >&2; exit 41; }

# Read-only guest verification through Azure guest agent, without SSH/public IP.
az vm run-command invoke -g "$TEST_RG" -n "$TEST_VM" --command-id RunShellScript \
  --scripts 'set -eu; test "$(uname -s)" = Linux; test -d /www/wwwroot; echo RESTORED_GUEST_BOOT_OK; echo OS=$(sed -n "s/^PRETTY_NAME=//p" /etc/os-release | head -n 1); echo ROOT=$(findmnt -n -o SOURCE / | head -n 1)' \
  --query 'value[0].message' -o tsv

echo "RESTORE_VERIFIED: VM=$TEST_VM RG=$TEST_RG REGION=$LOCATION SIZE=$EXPECTED_SIZE SNAPSHOT=$SOURCE_SNAPSHOT PUBLIC_IP=none OUTBOUND=denied"
