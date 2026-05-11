# Cloud Providers — VPC / Cloud Firewall Reference

The host nftables ruleset is necessary but not sufficient. Most clouds drop traffic at a network-layer firewall before it reaches your VM. After deploying, the operator must open inbound 443/tcp + 443/udp at the cloud layer.

`infra/cloud-firewall.sh` should print provider-appropriate commands. The deploy script itself does NOT execute these — they require cloud-API auth which is the operator's responsibility (and a privilege boundary we deliberately don't cross).

## GCP (Google Cloud Platform)

GCE has a VPC-level firewall. The default GCP VM service account does **not** have `compute` scope, so gcloud running on the VM cannot create firewall rules. The operator must run gcloud from their own authenticated workstation, or use the Console.

### Console path (no gcloud needed)

1. <https://console.cloud.google.com/networking/firewalls/list>
2. **CREATE FIREWALL RULE**:
   - Name: `allow-vpn-443-tcp`
   - Direction: Ingress
   - Action: Allow
   - Targets: All instances in the network
   - Source IPv4 ranges: `0.0.0.0/0`
   - Protocols and ports: TCP → `443`
3. Repeat for UDP:
   - Name: `allow-vpn-443-udp`
   - Same options, but Protocol = UDP → `443`

### gcloud CLI (operator workstation)

```bash
brew install --cask google-cloud-sdk   # macOS
gcloud auth login
gcloud config set project <your-project-id>

gcloud compute firewall-rules create allow-vpn-443-tcp \
  --direction=INGRESS --action=ALLOW --rules=tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --description='vpn-builder Reality'

gcloud compute firewall-rules create allow-vpn-443-udp \
  --direction=INGRESS --action=ALLOW --rules=udp:443 \
  --source-ranges=0.0.0.0/0 \
  --description='vpn-builder Hysteria2'
```

If using non-default network: add `--network=<vpc-name>`.

### GCE-specific gotchas

- Default rDNS is `*.bc.googleusercontent.com` — don't try to "clean it up", default obscurity is fine.
- ICMP is dropped by default at the VPC firewall — `ping` to the VM fails even when SSH works. Don't conclude unreachability from ICMP.
- GCE service account scopes: default is `compute-rw` only on Compute Engine API explicitly enabled. New e2-class VMs get a constrained set (storage RO, logging, monitoring). Adding compute scope requires stopping the VM and editing service account scope — usually easier to just gcloud from workstation.
- GCE network egress to China region is billed; consider a budget alert if traffic is heavy.

## AWS EC2

EC2 has Security Groups (per-instance) and Network ACLs (per-subnet). Most users only configure Security Groups.

### Console path

1. EC2 → Security Groups → select the SG attached to your VM
2. Edit Inbound Rules → Add Rule:
   - Type: Custom TCP, Port: 443, Source: 0.0.0.0/0, ::/0
   - Type: Custom UDP, Port: 443, Source: 0.0.0.0/0, ::/0
3. Save

### CLI

```bash
aws ec2 authorize-security-group-ingress \
  --group-id <sg-xxxxxxxx> \
  --protocol tcp --port 443 --cidr 0.0.0.0/0

aws ec2 authorize-security-group-ingress \
  --group-id <sg-xxxxxxxx> \
  --protocol udp --port 443 --cidr 0.0.0.0/0
```

### AWS-specific gotchas

- EC2 instance roles can be given `ec2:AuthorizeSecurityGroupIngress` so the VM can self-modify its SG. Possible but adds attack surface (compromised VM = open ports) — generally avoid.
- Default SG may already block traffic; check the rules attached to the SG, not just whether one exists.
- Lightsail uses a simplified firewall UI in the Lightsail console, NOT EC2 Security Groups.

## DigitalOcean

DO Droplets have an optional "Cloud Firewall" (off by default — but if it's on, configure it).

### Web UI

1. Networking → Firewalls → select firewall (or Create)
2. Inbound Rules → New Rule:
   - Type: Custom, Protocol: TCP, Port: 443, Sources: All IPv4 / All IPv6
   - Type: Custom, Protocol: UDP, Port: 443, Sources: All IPv4 / All IPv6
3. Save & Apply

### doctl

```bash
doctl compute firewall add-rules <firewall-id> \
  --inbound-rules "protocol:tcp,ports:443,address:0.0.0.0/0,address:::/0"
doctl compute firewall add-rules <firewall-id> \
  --inbound-rules "protocol:udp,ports:443,address:0.0.0.0/0,address:::/0"
```

### DO-specific gotchas

- If no Cloud Firewall is attached, the host nftables is the only firewall — that's actually fine for vpn-builder (host firewall is properly locked down).
- Reverse DNS can be customized for free, useful if you want to NOT have `*.digitalocean.com` rDNS.

## Vultr

Vultr has "Firewall Groups" (off by default for most instance types).

### Web UI

1. Products → Firewall → select group (or Add)
2. Add IPv4 Rule:
   - Protocol: TCP, Source: 0.0.0.0/0, Port: 443
   - Protocol: UDP, Source: 0.0.0.0/0, Port: 443
3. Same for IPv6
4. Save

### Vultr CLI

```bash
vultr-cli firewall rule create <firewall-group-id> \
  --protocol tcp --port 443 --subnet 0.0.0.0 --size 0
vultr-cli firewall rule create <firewall-group-id> \
  --protocol udp --port 443 --subnet 0.0.0.0 --size 0
```

### Vultr-specific gotchas

- "High Frequency Compute" instances start without any firewall — host nftables is your only line.
- Vultr's "Bare Metal" has IPv6 enabled by default; ensure IPv6 routing rules are set up (or disable IPv6 if you don't need it).

## BandwagonHost / RackNerd / generic VPS

These small VPS providers typically have NO cloud-side firewall. The host nftables is everything.

After deploy:
1. Verify nftables loaded: `nft list ruleset | grep "dport 443"` — both `tcp dport 443` and `udp dport 443` should appear.
2. From another machine: `nc -zv <ip> 443` (TCP) and `nc -zuv <ip> 443` (UDP).
3. If you're on macOS with a TUN-mode local proxy, your `nc` results are useless — every port appears open. Test from another network (phone hotspot) instead.

### Generic VPS gotchas

- KVM vs OpenVZ: nftables only works on KVM. OpenVZ VMs may need iptables — check `uname -r` first; if you see "openvz" or "lxc" or kernel < 4, this skill's nftables-based setup won't work without adaptation.
- IPv6 is often enabled and routable on these providers; nftables ruleset must cover IPv6 ports too (the template does, via `inet filter` table family).

## Bare metal / colocation

You own the box. The host nftables is everything. Probably also configure your router or upstream firewall (DD-WRT, OPNsense, Mikrotik, etc.) to forward 443/tcp and 443/udp to the box. Cover IPv6 too if your ISP provides it.

## Probing whether 443 is open externally

After cloud firewall is configured, verify from a network that is NOT the operator's Mac (because the Mac may have TUN proxies that pollute results):

```bash
# From phone hotspot or a different cloud VM:
nc -zv <server> 443        # TCP
nc -zuv <server> 443       # UDP (requires sending data; some firewalls don't ACK)

# Or use an online port checker:
curl -s https://portchecker.io/  # then manually enter IP+port
```

The most reliable test is the smoke test itself: a real Reality/Hysteria2 handshake either succeeds or it doesn't.
