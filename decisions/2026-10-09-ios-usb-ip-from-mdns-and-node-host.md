# A wired iPhone's USB address comes from its mDNS name; the relaunch names the node host

- Date: 2026-10-09
- Status: accepted
- Linear: MOB-428

## Context

mob_ci's `deploy:ios_device` cell installed on Kevin's wired iPhone SE
(iOS 26.5.2, Mac mini on macOS 27.0.1) and then failed P2 with `device usb
ip: no device USB IP in ARP`. The same happened by hand (`mix mob.deploy
--native --ios --device <udid>`, then the Connector), so it was mob_dev, not
the lane.

1. `MobDev.Tunnel` found the phone's USB link-local address by parsing `arp
   -a`. On macOS 27.0.1, `arp -a`/`arp -an` run from the BEAM (or from
   Python) print nothing and exit 0, while the same command from a shell —
   local or over ssh — lists the phone (`169.254.1.100 on en11`). `netstat
   -rn` from the BEAM likewise omits the link-layer entries. TCP to the
   phone's EPMD at that address works from the BEAM, and so does mDNS
   resolution (`:inet.getaddrs(~c"Kevins-iPhone.local", :inet)` →
   `169.254.1.100`, `192.168.0.185`). The table read is filtered for the
   process, not the network blocked; that this is macOS's privacy filtering
   of neighbour entries for non-shell parents is inferred, not documented.
2. With the address found, the connect still timed out: the phone named its
   node after its WiFi address (`192.168.0.185`, read from the app's
   `mob_diag_host_ip.txt`), a network the Mac can't route to.

The 2026-09-30 decision (`ios-physical-node-from-epmd`) already noted (2) as
a gap for a cold app on a WiFi phone.

## Decision

1. **The USB address comes from the phone's own name.** `devicectl list
   devices --json-output` lists, per UDID, `connectionProperties.
   localHostnames` such as `Kevins-iPhone.coredevice.local`. The phone
   answers mDNS as the same label under `.local` with its link-local and
   WiFi addresses; `IOS.usb_link_local_ip/2` resolves those names (skipping
   the UDID and CoreDevice-identifier labels, which only resolve to the IPv6
   tunnel) under one 3 s deadline and takes the `169.254.*` one. This is
   anchored on the UDID being connected, which the ARP scan (first resolved
   `169.254.*` entry of any device, possibly the Mac's own) never was. ARP
   stays as the fallback for a devicectl without hostnames.
2. **The relaunch tells the app which host to take.** `Connector` relaunches
   a physical iPhone with `DEVICECTL_CHILD_MOB_NODE_HOST=<host_ip>`, the
   address `Tunnel.setup/1` resolved and the node name it then waits for.
   mob 0.9.16's `mob_beam.m` takes it when it is one of the phone's own
   IPv4s (`decisions/2026-10-09-ios-node-host-override.md` in mob).
   `physical_launch_env/1` drops anything that isn't an IPv4 literal.

Rejected: mapping the WiFi-named node to the link-local address on the Mac
(the host is an IP literal, so no resolver applies; a custom
`epmd_module` would have to be set before distribution starts in every
caller); routing the WiFi address over the USB interface (needs root).

## Consequences

- `mix mob.connect`, `mix mob.selftest` and mob_ci reach a wired iPhone
  whatever network its WiFi is on (verified on the iPhone SE above:
  `mob428_ios@169.254.1.100` connected).
- A node launched by the Connector over USB is named after the cable's
  address, so it is unreachable once the cable is pulled; the next connect
  relaunches it.
- `Discovery.IOS`'s LAN scan (`lan_ips/0`, `arp -an`) has the same blind
  spot on macOS 27: from the BEAM it finds no neighbours, so WiFi-only
  phones are not discovered by scanning. Not changed here; the USB path and
  devicectl enrichment cover wired phones.
