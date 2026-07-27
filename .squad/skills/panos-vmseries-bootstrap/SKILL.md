# SKILL: PAN-OS VM-Series Azure Bootstrap

**Owner:** Alex (Network Eng)  
**Created:** 2026-07-27  
**Applies to:** Palo Alto VM-Series BYOL on Azure (3-NIC topology)

---

## When to Use

Apply this skill when deploying Palo Alto VM-Series firewalls as NVAs in an Azure Virtual WAN or hub-spoke topology where the firewall must:
- Forward traffic from a trust-side subnet to an untrust-side subnet (internet breakout)
- Be configured entirely from day-0 bootstrap (no post-boot manual configuration)
- Answer Azure LB health probes on its data interfaces

---

## Required Files

A VM-Series bootstrap package on Azure requires two files, uploaded to an Azure Storage Account blob container (or a Storage File Share):

```
bootstrap/
  config/
    init-cfg.txt       ← management-plane bootstrap parameters
    bootstrap.xml      ← PAN-OS candidate configuration (day-0)
```

The VM is pointed to the storage account via a custom-data / boot parameter in Bicep.

---

## init-cfg.txt: Key Parameters

```ini
type=dhcp-client            # Azure management NIC gets IP from DHCP
ip-address=                 # leave blank — DHCP fills this
default-gateway=            # leave blank — DHCP fills this
netmask=                    # leave blank — DHCP fills this
hostname=pan-dmz-nva        # human-readable; no functional effect
vm-auth-key=                # leave blank for standalone BYOL (no Panorama)
panorama-server=            # leave blank for standalone
dhcp-send-hostname=yes
dhcp-send-client-id=yes
dhcp-accept-server-hostname=yes
dhcp-accept-server-domain=yes
op-command-modes=mgmt-interface-swap   # CRITICAL for Azure 3-NIC
```

### `op-command-modes=mgmt-interface-swap` — Why It Matters

Azure VMs do not have a dedicated out-of-band management port. Without the swap:
- PAN-OS looks for a dedicated management NIC and cannot reach the management plane
- The firewall boots but is unreachable

With the swap, Azure NIC-to-PAN-OS-interface mapping becomes:
| Azure NIC | PAN-OS interface | Role |
|---|---|---|
| eth0 (1st NIC) | Management plane | Mgmt access (SSH/GUI) |
| eth1 (2nd NIC) | ethernet1/1 | Untrust (internet-facing) |
| eth2 (3rd NIC) | ethernet1/2 | Trust (spoke-facing) |

### Comment Safety

PAN-OS init-cfg.txt parser treats lines beginning with `#` as comments (silently ignored). Safe to include comment headers. Remove if bootstrap fails as first debug step.

---

## bootstrap.xml: PAN-OS 10.1+ Schema

### Root structure

```xml
<config version="10.1.0">
  <devices>
    <entry name="localhost.localdomain">
      <deviceconfig>...</deviceconfig>
      <network>
        <profiles>
          <interface-management-profile>...</interface-management-profile>
        </profiles>
        <interface><ethernet>...</ethernet></interface>
        <virtual-router>...</virtual-router>
      </network>
      <vsys>
        <entry name="vsys1">
          <zone>...</zone>
          <rulebase>
            <nat>...</nat>
            <security>...</security>
          </rulebase>
        </entry>
      </vsys>
    </entry>
  </devices>
</config>
```

### Interface management profile (LB health probe support)

```xml
<network>
  <profiles>
    <interface-management-profile>
      <entry name="allow-ssh-ping">
        <ssh>yes</ssh>
        <ping>yes</ping>
      </entry>
    </interface-management-profile>
  </profiles>
```

**Required** when Azure LBs probe TCP/22 on data interfaces. PAN-OS responds to the TCP/22 probe directly — no SSH daemon on the OS required.

### DHCP-client data interfaces (critical: `create-default-route=no`)

```xml
<interface>
  <ethernet>
    <entry name="ethernet1/1">
      <layer3>
        <interface-management-profile>allow-ssh-ping</interface-management-profile>
        <dhcp-client>
          <enable>yes</enable>
          <create-default-route>no</create-default-route>  <!-- CRITICAL -->
        </dhcp-client>
      </layer3>
    </entry>
  </ethernet>
</interface>
```

**`create-default-route=no` is mandatory.** Without it, Azure DHCP injects a 0.0.0.0/0 route via each data interface's DHCP option 3, conflicting with the static default route.

### Static routes in virtual router

```xml
<network>
  <virtual-router>
    <entry name="default">
      <interface>
        <member>ethernet1/1</member>
        <member>ethernet1/2</member>
      </interface>
      <routing-table>
        <ip>
          <static-route>
            <!-- Default route via untrust gateway -->
            <entry name="default-via-untrust">
              <destination>0.0.0.0/0</destination>
              <nexthop><ip-address>10.0.0.33</ip-address></nexthop>
              <interface>ethernet1/1</interface>
              <metric>10</metric>
            </entry>
            <!-- RFC1918 return path via trust gateway -->
            <entry name="rfc1918-10-via-trust">
              <destination>10.0.0.0/8</destination>
              <nexthop><ip-address>10.0.0.65</ip-address></nexthop>
              <interface>ethernet1/2</interface>
              <metric>10</metric>
            </entry>
          </static-route>
        </ip>
      </routing-table>
    </entry>
  </virtual-router>
</network>
```

### Zones (under vsys, NOT under network)

```xml
<vsys>
  <entry name="vsys1">
    <zone>
      <entry name="untrust">
        <network><layer3><member>ethernet1/1</member></layer3></network>
      </entry>
      <entry name="trust">
        <network><layer3><member>ethernet1/2</member></layer3></network>
      </entry>
    </zone>
```

### NAT rule: MASQUERADE equivalent

```xml
<rulebase>
  <nat>
    <rules>
      <entry name="trust-to-untrust-masquerade">
        <from><member>trust</member></from>
        <to><member>untrust</member></to>
        <source><member>any</member></source>
        <destination><member>any</member></destination>
        <service>any</service>  <!-- plain text, NOT member list -->
        <source-translation>
          <dynamic-ip-and-port>
            <interface-address>
              <interface>ethernet1/1</interface>
            </interface-address>
          </dynamic-ip-and-port>
        </source-translation>
      </entry>
    </rules>
  </nat>
```

**`<service>any</service>`** — In NAT rules the service element is plain text. Do NOT use `<member>` here (unlike security rules).

### Security rule

```xml
  <security>
    <rules>
      <entry name="permit-trust-to-untrust">
        <from><member>trust</member></from>
        <to><member>untrust</member></to>
        <source><member>any</member></source>
        <destination><member>any</member></destination>
        <source-user><member>any</member></source-user>
        <category><member>any</member></category>
        <application><member>any</member></application>
        <service><member>any</member></service>  <!-- member list here -->
        <hip-profiles><member>any</member></hip-profiles>
        <action>allow</action>
        <log-end>yes</log-end>
      </entry>
    </rules>
  </security>
```

### Non-SYN TCP (required for ILB HA-ports)

```xml
<deviceconfig>
  <setting>
    <session>
      <tcp>
        <non-syn-tcp>yes</non-syn-tcp>
      </tcp>
    </session>
  </setting>
</deviceconfig>
```

Azure ILB HA-ports mode may forward mid-flow TCP connections after failover. Without this, PAN-OS drops non-SYN packets for sessions not in the session table.

---

## BYOL Eval Period

VM-Series BYOL on Azure operates in full-feature eval mode for approximately 30 days after first boot with no license applied. During eval:
- Full dataplane is active: L3 forwarding, NAT, security policy all work
- Threat prevention and URL filtering work at basic level

For routing/NVA labs this is sufficient. Apply a real license before production use.

---

## Gotchas and Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Omit `op-command-modes=mgmt-interface-swap` | VM boots but management plane unreachable | Add to init-cfg.txt |
| Set `create-default-route` to yes (or omit) | Routing loops / wrong default route | Set `<create-default-route>no</create-default-route>` on both interfaces |
| Use `<member>any</member>` for NAT service | XML parse error at bootstrap | Use plain `<service>any</service>` in NAT rules |
| Omit management profile on data interfaces | LB health probes fail (TCP/22 timeout) | Add `allow-ssh-ping` profile to ethernet1/1 and ethernet1/2 |
| Omit `non-syn-tcp=yes` | TCP sessions break after ILB failover | Add to `deviceconfig/setting/session/tcp` |
| Wrong zone location in XML | Zones not recognized | Zones go under `vsys/entry/zone`, NOT under `network/` |

---

## Validation

After deploy, run:
```bash
./nva-spoke-internet-paloalto/scripts/validate-flow.sh
# or
.\nva-spoke-internet-paloalto\scripts\validate-flow.ps1
```

Phase 3 (data-plane curl) is the authoritative pass/fail. Phase 4 emits WARN with manual PAN-OS CLI commands for session/NAT evidence.

---

## References

- Bootstrap overview: https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall
- Bootstrap config files (init-cfg.txt schema): https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/bootstrap-configuration-files
- Create bootstrap files: https://docs.paloaltonetworks.com/vm-series/getting-started/bootstrap-the-vm-series-firewall/create-bootstrap-configuration-files
- PAN-OS CLI cheat sheet: https://docs.paloaltonetworks.com/pan-os/11-1/pan-os-cli-quick-start/use-the-cli/cli-cheat-sheets
