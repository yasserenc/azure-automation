#!/usr/bin/env bash
# RFCY HMGWEB October 7 restored test VM ONLY. No production resources targeted.
set -Eeuo pipefail
: "$RFCY_SUBSCRIPTION"
az account set --subscription "$RFCY_SUBSCRIPTION"
test "$(az account show --query id -o tsv)" = "$RFCY_SUBSCRIPTION"
RG="hmgweb-20261007-test-rg"
VM="hmgweb-20261007-test"
DISK="hmgweb-20261007-restore-os"
NIC="hmgweb-20261007-test-nic"
NSG="hmgweb-20261007-test-nsg"
VNET="hmgweb-20261007-test-vnet"
PIP="hmgweb-20261007-test-pip"
D="$(mktemp -d)"
trap 'rm -rf "$D"' EXIT

# Resolve exact isolation boundary and fail closed on unexpected topology.
az vm show -g "$RG" -n "$VM" -o json > "$D/vm.json"
az network nic show -g "$RG" -n "$NIC" -o json > "$D/nic.json"
az network nsg rule list -g "$RG" --nsg-name "$NSG" -o json > "$D/rules.json"
az network vnet peering list -g "$RG" --vnet-name "$VNET" -o json > "$D/peerings.json"
az network vnet subnet show -g "$RG" --vnet-name "$VNET" -n test-subnet -o json > "$D/subnet.json"
az network public-ip list -g "$RG" -o json > "$D/ips.json"
python3 - "$D/vm.json" "$D/nic.json" "$D/rules.json" "$D/peerings.json" "$D/subnet.json" "$D/ips.json" <<'PY'
import json,sys
v,n,rs,ps,sub,pips=(json.load(open(p)) for p in sys.argv[1:])
def check(b,why):
    if not b: raise SystemExit("PRECHECK_BLOCKED: "+why)
def endid(x,t):
    return (x or "").lower().endswith("/"+t.lower())
cfg=n.get('ipConfigurations') or []
nis=(v.get('networkProfile') or {}).get('networkInterfaces') or []
os=(v.get('storageProfile') or {}).get('osDisk') or {}
check(v.get("name","").lower()=="hmgweb-20261007-test","target VM")
check(v.get("resourceGroup","").lower()=="hmgweb-20261007-test-rg","target RG")
check(v.get("location")=="westeurope","VM region")
check((v.get("hardwareProfile") or {}).get("vmSize")=="Standard_B2ls_v2","VM size")
check(v.get("provisioningState")=="Succeeded","VM provisioning")
check(os.get("name")=="hmgweb-20261007-restore-os","restored disk")
check(endid((os.get('managedDisk') or {}).get('id'),'hmgweb-20261007-restore-os'),"OS disk ID")
check(n.get("resourceGroup","").lower()=="hmgweb-20261007-test-rg","NIC RG")
check(n.get("location")=="westeurope","NIC region")
check(len(nis)==1 and (nis[0].get('id') or '').lower()==n.get('id','').lower(),"unexpected VM NICs")
check(len(cfg)==1 and cfg[0].get("name")=="ipconfig1","NIC IP config")
check(endid((n.get('networkSecurityGroup') or {}).get('id'),'hmgweb-20261007-test-nsg'),"target NSG not bound")
check(endid((cfg[0].get('subnet') or {}).get('id'),'test-subnet'),"unexpected subnet")
check(not ps,"VNet peered to another network")
check(not sub.get("natGateway") and not sub.get("routeTable"),"unexpected route/NAT")
existing=(cfg[0].get('publicIPAddress') or {}).get('id')
check(not existing or endid(existing,'hmgweb-20261007-test-pip'),"NIC has unexpected public IP")
check(len(pips)<=1 and all(p.get('name')=='hmgweb-20261007-test-pip' for p in pips),"unexpected public IPs in test RG")
byname={r['name']:r for r in rs}
check('deny-all-outbound' in byname,"outbound restriction missing")
out=byname['deny-all-outbound']
check(out.get('priority')==100 and out.get('direction')=='Outbound' and out.get('access')=='Deny',"outbound restriction changed")
check('deny-all-inbound' in byname,"inbound restriction missing")
inn=byname['deny-all-inbound']
check(inn.get('priority') in (100,4096) and inn.get('direction')=='Inbound' and inn.get('access')=='Deny',"inbound restriction changed")
allowed={'deny-all-outbound','deny-all-inbound','allow-ssh-22','allow-http-80','allow-https-443'}
check(set(byname).issubset(allowed),"unexpected NSG rules")
print("EXACT_TARGET_PRECHECK_OK: RFCY restored VM and own NIC/NSG only; outbound blocked; no peering")
PY

POWER="$(az vm get-instance-view -g "$RG" -n "$VM" --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" -o tsv)"
test "$POWER" = "VM running"

# First permit only the specified services within this test NSG.
# With priority 100 deny in place, creating these rules does not yet expose them.
for spec in "allow-ssh-22 200 22" "allow-http-80 210 80" "allow-https-443 220 443"; do
  read -r name priority port <<< "$spec"
  az network nsg rule create -g "$RG" --nsg-name "$NSG" --name "$name" --priority "$priority" --direction Inbound --access Allow --protocol Tcp --source-address-prefixes Internet --source-port-ranges '*' --destination-address-prefixes '*' --destination-port-ranges "$port" -o none
done

# Move the explicit deny behind the three allow rules; all other inbound remains blocked.
az network nsg rule update -g "$RG" --nsg-name "$NSG" -n deny-all-inbound --priority 4096 -o none

if ! az network public-ip show -g "$RG" -n "$PIP" >/dev/null 2>&1; then
  az network public-ip create -g "$RG" -n "$PIP" -l westeurope --sku Standard --allocation-method Static --version IPv4 --tags purpose=hmgweb-20261007-test-only -o none
fi
az network public-ip show -g "$RG" -n "$PIP" -o json > "$D/pip.json"
python3 - "$D/pip.json" <<'PY'
import json,sys
p=json.load(open(sys.argv[1]))
assert p.get('location')=='westeurope'
assert (p.get('sku') or {}).get('name')=='Standard'
assert p.get('publicIPAllocationMethod')=='Static'
assert p.get('publicIPAddressVersion')=='IPv4'
assert (p.get('ipConfiguration') or {}).get('id') in (None,'')
print("STANDARD_STATIC_PUBLIC_IP_READY")
PY

# Attach this IP ONLY to the already verified sole test NIC configuration.
az network nic ip-config update -g "$RG" --nic-name "$NIC" -n ipconfig1 --public-ip-address "$PIP" -o none

az network public-ip show -g "$RG" -n "$PIP" -o json > "$D/pip-attached.json"
az network nic show -g "$RG" -n "$NIC" -o json > "$D/nic-attached.json"
az network nsg rule list -g "$RG" --nsg-name "$NSG" -o json > "$D/rules-after.json"
python3 - "$D/pip-attached.json" "$D/nic-attached.json" "$D/rules-after.json" <<'PY'
import json,sys,ipaddress
p,n,r=(json.load(open(x)) for x in sys.argv[1:])
cfg=(n.get('ipConfigurations') or [])[0]
assert (cfg.get('publicIPAddress') or {}).get('id','').lower()==p.get('id','').lower(),"PIP not attached to target NIC"
assert (p.get('ipConfiguration') or {}).get('id','').lower()==cfg.get('id','').lower(),"PIP association incorrect"
ip=ipaddress.ip_address(p.get('ipAddress'))
assert ip.version==4 and ip.is_global,"unexpected public IPv4 allocation"
rule={x['name']:x for x in r}
for name,prio,port in [('allow-ssh-22',200,22),('allow-http-80',210,80),('allow-https-443',220,443)]:
    o=rule[name]
    assert o['priority']==prio and o['direction']=='Inbound' and o['access']=='Allow' and o['protocol']=='Tcp'
    assert (o.get('destinationPortRange') or '')==str(port)
    assert (o.get('sourceAddressPrefix') or '')=='Internet'
assert rule['deny-all-inbound']['priority']==4096 and rule['deny-all-inbound']['access']=='Deny'
assert rule['deny-all-outbound']['priority']==100 and rule['deny-all-outbound']['access']=='Deny'
print("AZURE_NETWORK_VERIFIED: PIP associated with exact test NIC, only 22/80/443 opened, all other inbound denied, outbound remains denied")
print("PUBLIC_IPV4="+str(ip))
PY

IP="$(jq -er '.ipAddress' "$D/pip-attached.json")"
echo "PUBLIC_IPV4=$IP"

# Probe from the Internet-side GitHub Actions runner; verify TCP, not merely Azure ACLs.
python3 - "$IP" <<'PY'
import socket,sys,time
ip=sys.argv[1]
for port in (22,80,443):
    error=None
    for attempt in range(4):
        try:
            with socket.create_connection((ip,port),timeout=7) as s:
                if port==22:
                    s.settimeout(5)
                    banner=s.recv(90).decode('ascii','replace')
                    if not banner.startswith('SSH-'): raise RuntimeError('SSH banner absent')
            print('EXTERNAL_TCP_OK='+str(port))
            error=None
            break
        except (OSError,RuntimeError) as e:
            error=e
            if attempt<3: time.sleep(6)
    if error is not None:
        raise SystemExit('EXTERNAL_TCP_FAILED_'+str(port)+': '+str(error))
PY

HTTP_CODE="$(curl --noproxy '*' --connect-timeout 6 --max-time 15 -sS -o /dev/null -w '%{http_code}' -H 'Host: ulfah.org' "http://$IP/" || true)"
echo "EXTERNAL_HTTP_STATUS=$HTTP_CODE"
if [[ "$HTTP_CODE" == "000" || -z "$HTTP_CODE" ]]; then
  echo "EXTERNAL_HTTP_REQUEST_FAILED"; exit 41
fi

# HTTPS strict trust check (no -k and no weakening TLS verification).
if HTTPS_CODE="$(curl --noproxy '*' --connect-timeout 6 --max-time 15 -sS -o /dev/null -w '%{http_code}' --resolve "ulfah.org:443:$IP" https://ulfah.org/ 2>"$D/https-error")"; then
  echo "EXTERNAL_HTTPS_VERIFIED_CODE=$HTTPS_CODE"
else
  echo "HTTPS_CERT_OR_APPLICATION_CHECK_NOT_PASSED: TLS chain, hostname, service or application needs separate verification"
  sed -E 's/(https?:\/\/)[^ ]+/\1[redacted]/g' "$D/https-error" | tail -n 3
fi
echo "PUBLIC_WEB_ACCESS_CONFIGURED: VM=$VM ip=$IP ports=22,80,443 source=Internet outbound=deny-all"
