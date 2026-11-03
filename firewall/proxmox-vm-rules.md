# Proxmox VM firewall for `openclaw` (172.16.1.230)

This is the outer layer. It limits the whole VM; `DOCKER-USER` (see
`oc-firewall.sh`) limits the gateway container inside it.

| Dir | Action | Destination / source | Port | Why |
| --- | --- | --- | --- | --- |
| IN | Accept | from 172.16.1.175 (MacBook) | tcp 22 | SSH and the Control UI tunnel |
| IN | Drop | everything else | | policy |
| OUT | Accept | 172.16.1.67 (llm) | tcp 8080 | Strata |
| OUT | Accept | 172.16.3.100 (intelnuc6) | tcp 8080, 3002 | SearXNG, Firecrawl |
| OUT | Accept | 172.16.1.2 (pfSense) | udp/tcp 53 | DNS |
| OUT | Accept | any | udp 123 | NTP |
| OUT | Drop | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 | | rest of the LAN and DMZ |
| OUT | Accept | any (internet) | tcp 80, 443 | host apt updates and Docker image pulls |
| OUT | Drop | everything else | | policy |

Containers never get the internet through the last Accept: `DOCKER-USER`
drops it for `oc-gw` before the packet leaves the VM.

## Apply

1. **Datacenter → Firewall → Options → Firewall: Yes.** VM rules do nothing
   until this is on. Before turning it on, check **Datacenter → Firewall →
   Options → Input Policy**: Proxmox auto-allows its web UI (8006) and SSH
   from the host's local network, but if you have changed that or manage
   Proxmox from another subnet, add an accept rule first so you don't lock
   yourself out.
2. Confirm the VM's NIC has **Firewall** ticked (Hardware → Network Device).
3. On the Proxmox host, write the rules below to
   `/etc/pve/firewall/<vmid>.fw` (replace `<vmid>` with the VM's ID), or
   enter them in **VM → Firewall** in the same order. Proxmox applies them
   top to bottom.
4. **VM → Firewall → Options → Firewall: Yes.**
5. Keep your current SSH session open and test a new one from the MacBook.

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP
dhcp: 1

[RULES]
IN SSH(ACCEPT) -source 172.16.1.175
OUT ACCEPT -dest 172.16.1.67 -p tcp -dport 8080
OUT ACCEPT -dest 172.16.3.100 -p tcp -dport 8080,3002
OUT DNS(ACCEPT) -dest 172.16.1.2
OUT NTP(ACCEPT)
OUT DROP -dest 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16
OUT HTTP(ACCEPT)
OUT HTTPS(ACCEPT)
```

## Notes

- **MacBook IP:** if 172.16.1.175 comes from DHCP, give it a reservation in
  Kea on pfSense, or you'll be locked out of SSH when it changes. The Proxmox
  console still works if that happens.
- **intelnuc6 is on the DMZ.** The VM is on the LAN, and pfSense's default LAN
  rule allows LAN to DMZ, so no pfSense change should be needed. If the
  SearXNG or Firecrawl checks fail, look at the pfSense LAN rules first.
- **`dhcp: 1`** lets the VM renew a DHCP lease through the firewall. Harmless
  with a static address.
