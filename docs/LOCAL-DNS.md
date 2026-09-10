# + local DNS (.lan domains)

> Return to [Setup Guide](SETUP.md)

Access services without remembering port numbers: `http://sonarr.lan` instead of `http://NAS_IP:8989`.

This works by giving Traefik its own IP address on your home network. When you type `sonarr.lan`, Pi-hole's DNS points it to Traefik, which routes you to the right service.

**Step 1: Configure macvlan settings in .env**

These are already in `.env` (from `.env.example`). Edit the values for your network:

```bash
TRAEFIK_LAN_IP=192.168.1.11    # Unused IP in your LAN range
LAN_INTERFACE=eth0            # Network interface (check with: ip link show)
LAN_SUBNET=192.168.1.0/24       # Your LAN subnet
LAN_GATEWAY=192.168.1.1         # Your router IP
```

**Step 2: Reserve the IP in your router**

The container uses a static IP with a fake MAC address (`TRAEFIK_LAN_MAC` in `.env`, default `02:42:c0:a8:01:0b`). Your router doesn't know about it, so add a DHCP reservation to prevent it assigning that IP to another device.

<details>
<summary>Router-specific instructions</summary>

- **MikroTik:** `/ip dhcp-server lease add address=192.168.1.11 mac-address=02:42:c0:a8:01:0b comment="Traefik macvlan" server=dhcp1`
- **UniFi:** Settings → Networks → DHCP → Static IP → Add `02:42:c0:a8:01:0b` → your `TRAEFIK_LAN_IP`
- **pfSense/OPNsense:** Services → DHCP → Static Mappings → Add
- **TP-Link:** Advanced → Network → DHCP Server → Address Reservation → Add
- **Netgear:** Advanced → Setup → LAN Setup → Address Reservation → Add
- **ASUS:** LAN → DHCP Server → Manual Assignment → Add
- **Linksys:** Connectivity → Local Network → DHCP Reservations
- **Other routers:** Look for "DHCP Reservation" or "Address Reservation"

</details>

**Step 3: Create Traefik config and deploy**

> **Important:** You MUST create `traefik.yml` before deploying. If Docker can't find the file, it creates a directory instead, and Traefik fails to start.

```bash
cd $NAS_STACK_DIR

# Create Traefik config from example
cp traefik/traefik.yml.example traefik/traefik.yml

# Deploy Traefik
docker compose -f docker-compose.traefik.yml up -d
```

**Step 4: Configure DNS**
```bash
# Copy example and replace placeholder with your Traefik IP
mkdir -p pihole/dnsmasq.d
sed "s/TRAEFIK_LAN_IP/192.168.1.11/g" pihole/dnsmasq.d/02-local-dns.conf.example > pihole/dnsmasq.d/02-local-dns.conf
chmod 644 pihole/dnsmasq.d/02-local-dns.conf

# Restart Pi-hole to apply changes
docker compose -f docker-compose.arr-stack.yml restart pihole
```

> **⚠️ Important:** Stack `.lan` domains are managed in `02-local-dns.conf`. If you add your own domains (e.g., homeassistant.lan), use either the CLI or Pi-hole web UI — but never define the same domain in both places, as they can conflict and cause unpredictable DNS resolution.

**Step 5: Set router DNS**

Configure your router's DHCP to advertise your NAS IP as DNS server. All devices will then use Pi-hole for DNS.

> **Note:** Due to a macvlan limitation, `.lan` domains don't work from the NAS itself (e.g., via SSH). They work from all other devices.

See [REFERENCE.md](REFERENCE.md#service-access) for the full list of `.lan` URLs.

### Which resolver actually serves each VLAN (read off the router, 2026-09-10)

Every DHCP pool that hands out a resolver names the **NAS Pi-hole**, and nothing else does:

| Pool | `dhcp_option 6` |
|---|---|
| `lan` | `192.168.110.246` |
| `vlan10` | `192.168.110.246` |
| `vlan20` | `192.168.110.246` |
| `vlan30` | `192.168.110.246` |

Check it from a host with router access — this repo's design makes pi1 the only one:
`ssh arr-stack-router 'uci show dhcp | grep dhcp_option'`.

Two consequences worth keeping:

- **The NAS Pi-hole is a single point of failure for the entire house.** That is what makes `scripts/boot-compose-up.service` load-bearing rather than a nicety — see [Docker: Ports Not Published After Reboot](TROUBLESHOOTING.md#docker-ports-not-published-after-reboot-containers-running-nothing-listening).
- **The `pi2-dns` stack (Pi-hole + dnscrypt-proxy on the Pi 3) is a standby, not a peer** — it serves no DHCP client. It was **stopped and retired on 2026-09-10**: containers stopped (not removed), and pi2's checkout returned to `main` so no unmerged branch code stays live. To bring it back deliberately:

  ```bash
  ssh pi@pi2 'cd /home/pi/arr-stack && git fetch origin feat/pi1-pi2-split && \
      git checkout feat/pi1-pi2-split && \
      docker compose -f docker-compose.pi2-dns.yml up -d'
  ```

  It remains a usable fallback if the NAS is ever down: repoint `dhcp_option 6` at `192.168.120.241`. That is a router edit, not a code change.

**Upstream is encrypted.** The NAS Pi-hole forwards to `dnscrypt-proxy` at `172.20.0.6#5053` (set 2026-09-10, which is what `scripts/configure-apps.sh` has always prescribed), rather than sending plaintext to `8.8.8.8`. Verify with `docker exec pihole pihole-FTL --config dns.upstreams`.

---

## ✅ + local DNS Complete!

**Congratulations!** You now have:
- Pretty `.lan` URLs for all services
- Ad-blocking via Pi-hole
- No ports to remember

**What's next?**
- **Stop here** if local access is all you need
- **Continue to [+ remote access](REMOTE-ACCESS.md)** to watch from anywhere

**Other docs:** [Upgrading](UPGRADING.md) · [Home Assistant Integration](HOME-ASSISTANT.md) · [Quick Reference](REFERENCE.md)

Issues? [Report on GitHub](https://github.com/leonardoazeredo/ultimate-arr-stack/issues) or [chat on Reddit](https://www.reddit.com/user/Jeff46K4/).
