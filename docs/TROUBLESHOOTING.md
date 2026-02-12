# Troubleshooting

## SABnzbd: Stuck Unpack Loop

**Symptom:** Radarr shows "Downloading" at 100% with 0 B file size. SABnzbd UI is unresponsive or Save fails. Logs show `Unpacked files []` repeatedly.

**Cause:** NZB had obfuscated filenames + par2 files but no RARs. The unpacker finds nothing to extract and retries on every SABnzbd restart, creating a new `_UNPACK_*` directory each time. Each copy is 20-50+ GB — this can silently eat TBs of disk space. The stuck post-processing loop also locks up SABnzbd's API and UI.

**Diagnose:**
```bash
# _UNPACK_ buildup = stuck unpack loop
ls -d /volume1/Media/downloads/_UNPACK_* | wc -l
du -shc /volume1/Media/downloads/_UNPACK_*

# Confirm in SABnzbd logs
docker logs sabnzbd --tail 200 2>&1 | grep "Unpacked files"
# "Unpacked files []" = nothing to unpack, stuck
```

**Fix:**
```bash
# 1. Stop SABnzbd (API will be unresponsive, must use docker stop)
docker stop sabnzbd

# 2. Delete the postproc queue to clear the stuck job
#    (The history API delete is NOT enough — the postproc queue is separate
#    and will re-trigger the loop on every restart)
sudo rm /volume1/@docker/volumes/arr-stack_sabnzbd-config/_data/admin/postproc2.sab

# 3. Delete all failed _UNPACK_ attempts to reclaim disk space
rm -rf /volume1/Media/downloads/_UNPACK_<release_name>*

# 4. Move the actual file (in incomplete/) to the movie folder
mkdir -p "/volume1/Media/movies/MovieName (Year)"
mv "/volume1/Media/downloads/incomplete/<release>/obfuscated.mkv" \
   "/volume1/Media/movies/MovieName (Year)/MovieName (Year).mkv"
rm -rf "/volume1/Media/downloads/incomplete/<release>"

# 5. Start SABnzbd back up
docker start sabnzbd

# 6. Remove from Radarr queue (get queue ID from queue API)
docker exec radarr curl -s -X DELETE \
  "http://localhost:7878/api/v3/queue/ID?removeFromClient=false&blocklist=false&apikey=KEY"

# 7. Tell Radarr to pick up the file
docker exec radarr curl -s -X POST "http://localhost:7878/api/v3/command" \
  -H "Content-Type: application/json" -H "X-Api-Key: KEY" \
  -d '{"name":"RefreshMovie","movieIds":[MOVIE_ID]}'
```

**Prevention:** No SABnzbd setting fully prevents this. Monitor disk usage (Beszel/duc) and investigate if a movie stays at "Downloading 100%" for more than 30 minutes.

## Pi-hole: Doesn't Start After Reboot

**Symptom:** After every NAS reboot, Pi-hole stays in `Exited (128)` state. All other containers start fine. Your network loses DNS resolution until you manually `docker start pihole`.

**Cause:** Pi-hole binds to `${NAS_IP}:53` (it can't use `0.0.0.0:53` because most NAS OS's run dnsmasq on `127.0.0.1:53`). If `NAS_IP` is assigned via DHCP, Docker starts before the DHCP handshake completes — the IP doesn't exist yet, the port bind fails with exit 128, and Docker's restart policy does not retry start failures (only process exits).

**Diagnose:**
```bash
# Check if Pi-hole is stopped
docker ps -a --filter name=pihole
# Look for: Exited (128)

# Check the error
docker inspect pihole --format "{{.State.Error}}"
# Look for: "listen tcp4 <IP>:53: bind: cannot assign requested address"

# Confirm your IP is from DHCP
ip addr show eth0 | grep inet
# "dynamic" = DHCP (the problem). No "dynamic" = static (correct).
```

**Fix:** Configure a static IP on the NAS itself (not just a DHCP reservation on your router):
```bash
# Back up current config
sudo cp /etc/network/interfaces.d/ifcfg-eth0 /etc/network/interfaces.d/ifcfg-eth0.bak

# Edit to static (replace IP, gateway, netmask with YOUR network values)
sudo tee /etc/network/interfaces.d/ifcfg-eth0 << 'EOF'
auto eth0
iface eth0 inet static
    address 192.168.1.100
    netmask 255.255.255.0
    gateway 192.168.1.1
    dns-nameservers 1.1.1.1 8.8.8.8
iface eth0 inet6 dhcp
EOF

# Reboot and verify
sudo reboot
# After reboot: ip addr show eth0 should show NO "dynamic" flag
# docker ps should show pihole Up
```

**Why DHCP reservation isn't enough:** A DHCP reservation on your router guarantees the same IP every time, but the NAS still *obtains* it via DHCP at boot. The DHCP handshake takes a few seconds — by which time Docker has already tried and failed to start Pi-hole. A static IP is configured directly on the NAS, so it's available the moment the interface comes up — no router involved, no delay.

**Keep the DHCP reservation too:** After switching to a static IP, keep the reservation on your router. The static IP means the NAS claims it instantly at boot; the reservation means the router won't hand out that same IP to another device via DHCP. Both together prevent IP conflicts.

## Jellyfin: Video Stutters/Freezes Every Few Minutes

**Symptom:** Playing large video files (especially 4K remuxes, 50-100+ GB) causes playback to freeze for a few seconds every 2-3 minutes, then resume. Happens on both Jellyfin apps and Kodi with Jellyfin plugin. Jellyfin dashboard may show "Direct Play" (no transcoding).

**Cause:** UGOS default RAID5 read-ahead is 384 KB — far too small for streaming large files. This forces the kernel to issue many small IO requests to spinning HDDs, each triggering a disk seek (5-10ms). At high bitrates (60+ Mbps for 4K remuxes), the IO queue backs up, disk utilization hits 90%+, and the stream buffer empties causing the stall.

**Diagnose:**
```bash
# Check current read-ahead (384 = too low for streaming)
cat /sys/block/md1/queue/read_ahead_kb
cat /sys/block/dm-0/queue/read_ahead_kb

# Check stripe cache (256 = default, too low)
cat /sys/block/md1/md/stripe_cache_size

# Monitor disk IO during playback (look for high %util and w_await)
iostat -x 1 5 | grep -E "Device|dm-0"
```

**Fix:** Increase read-ahead and stripe cache to allow larger sequential reads:
```bash
# Apply immediately (requires root)
sudo bash -c '
echo 4096 > /sys/block/md1/queue/read_ahead_kb
echo 4096 > /sys/block/dm-0/queue/read_ahead_kb
echo 4096 > /sys/block/md1/md/stripe_cache_size
'
```

**Make permanent:** Add a `@reboot` cron job for root (**not** `/etc/rc.local` — UGOS overwrites it on firmware updates):
```bash
# Add to root crontab (sleep 30 lets RAID finish initialising)
sudo crontab -e
# Add this line:
@reboot sleep 30 && echo 4096 > /sys/block/md1/queue/read_ahead_kb && echo 4096 > /sys/block/dm-0/queue/read_ahead_kb && echo 4096 > /sys/block/md1/md/stripe_cache_size
```

> **Warning:** Do NOT use `/etc/rc.local` for custom tuning on UGOS — firmware updates silently overwrite it. Use root crontab `@reboot` instead.

**Result:** Disk utilization drops from ~96% to ~8-15% during 4K playback. Read latency drops from 20ms to 3-7ms. Stalls eliminated.

**Note:** SSD caching will **not** help with video streaming — it only accelerates frequently re-read data, and video playback is sequential read-once.