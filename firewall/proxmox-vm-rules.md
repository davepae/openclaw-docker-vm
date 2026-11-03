# Proxmox VM firewall for the OpenClaw VM

This is the outer layer. It limits the whole VM; the `DOCKER-USER` chains (see
`oc-firewall.sh`) limit the gateway container and the egress proxy inside it.

| Dir | Action | Destination / source | Port | Why |
| --- | --- | --- | --- | --- |
| IN | Accept | from your admin machine (`ADMIN_IP`) | tcp 22 | SSH and the Control UI tunnel |
| IN | Drop | everything else | | policy |
| OUT | Accept | the model server | its port | model requests |
| OUT | Accept | the SearXNG and Firecrawl host(s) | their ports | web search and fetch |
| OUT | Accept | your DNS server(s) | udp/tcp 53 | name resolution |
| OUT | Accept | any | udp 123 | NTP |
| OUT | Drop | 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 | | the rest of the LAN |
| OUT | Accept | any (internet) | tcp 80, 443 | host updates, image pulls, the sandbox proxy's registries |
| OUT | Drop | everything else | | policy |

Containers never get the internet through the last Accept: `DOCKER-USER` drops
it for the gateway network, and the sandbox proxy only forwards HTTPS to its
allowlist.

## Get your rules

The addresses come from `site.env`, so print your rules on the VM:

```bash
./firewall/proxmox-rules.sh
```

The output is a complete `.fw` file, in this shape:

```
[OPTIONS]
enable: 1
policy_in: DROP
policy_out: DROP
dhcp: 1

[RULES]
IN SSH(ACCEPT) -source <ADMIN_IP>
OUT ACCEPT -dest <model server IP> -p tcp -dport <port>
OUT ACCEPT -dest <SearXNG IP> -p tcp -dport <port>
OUT ACCEPT -dest <Firecrawl IP> -p tcp -dport <port>
OUT DNS(ACCEPT) -dest <DNS server>
OUT NTP(ACCEPT)
OUT DROP -dest 10.0.0.0/8
OUT DROP -dest 172.16.0.0/12
OUT DROP -dest 192.168.0.0/16
OUT HTTP(ACCEPT)
OUT HTTPS(ACCEPT)
```

Rules apply top to bottom, so the accepts for your servers come before the
drops for private ranges. If a server's address changes, re-run
`./configure.sh`, `sudo ./firewall/install.sh` and this script, and update the
file on the Proxmox host.

## Apply

1. **Protect your access to Proxmox first.** VM rules only work when the
   datacenter firewall is on, and turning that on applies its Input Policy
   (usually DROP) to the Proxmox host itself. In **Datacenter → Firewall**, add
   accept rules for the Proxmox web UI (tcp 8006) and SSH (tcp 22) from the
   network you manage Proxmox from, before the next step.
2. **Datacenter → Firewall → Options → Firewall: Yes.** Then open the Proxmox
   UI in a new browser tab to confirm you can still get in.
3. Confirm the VM's NIC has **Firewall** ticked (VM → Hardware → Network
   Device).
4. On the Proxmox host (your node → Shell), write the rules to
   `/etc/pve/firewall/<vmid>.fw`, with `<vmid>` the VM's ID from the tree:

   ```bash
   VMID=101    # your VM's ID
   cat > /etc/pve/firewall/${VMID}.fw <<'RULES'
   ...paste the output of ./firewall/proxmox-rules.sh here...
   RULES
   pve-firewall compile >/dev/null && echo "rules OK"
   ```

   `enable: 1` turns the VM's firewall on immediately (VM → Firewall →
   Options shows Firewall: Yes).
5. Keep your current SSH session open and test a new one from the admin
   machine. If it hangs, set VM → Firewall → Options → Firewall to No, fix
   `ADMIN_IP`, and try again. The VM's console in Proxmox always works.

## Notes

- **Admin machine address:** if it comes from DHCP, give it a reservation on
  your router, or SSH stops working when the address changes. `ADMIN_IP` can
  also be a small subnet (no wider than /16).
- **Services on another network segment** (for example a DMZ): the router
  between the segments must allow the VM to reach them; these rules only cover
  the VM itself.
- **`dhcp: 1`** lets the VM renew a DHCP lease through the firewall. It is
  harmless with a static address.
