# Physical iOS node is read from EPMD, scoped to the project's app

- Date: 2026-09-30
- Status: accepted

## Context

MOB-283, on a physical iPhone SE with WiFi and USB, running `scanner_sample`:

- The LAN scan (`Discovery.IOS.query_ios_epmd`) took the **first** `*_ios`
  name in the phone's EPMD reply, so `mix mob.connect` resolved
  `muster_app_ios@10.0.0.121` — a different Mob app on the same phone.
- `mix mob.connect --device <udid>` took the USB path in `Tunnel.setup/1`,
  which **predicted** `scanner_sample_ios@169.254.1.100` from the ARP
  link-local entry. mob_beam.m names the node after the WiFi IP whenever the
  phone has one, so the app was `scanner_sample_ios@10.0.0.121` and the wait
  timed out.

A third latent defect sat under both: erts' EPMD writes the 4-byte
`NAMES_REQ` header and each name line as separate writes, and the query read
a single `recv`, so it could see the header and nothing else.

## Decision

1. **Project-scoped selection.** `select_ios_node/2` takes the entry that is
   `<app>_ios` (`Device.ios_node_base/0`) or `<app>_ios_<suffix>`
   (`MOB_NODE_SUFFIX`), unsuffixed first. Any `*_ios` is accepted only when no
   Mix project app is known. Another app's node is never this project's device.
2. **Parse every entry, read to close.** `parse_epmd_names/1` returns all
   names; the query reads until EPMD closes the socket, under an overall 2 s
   deadline (a per-read timeout never fires against a peer that trickles).
3. **USB devices resolve from EPMD, anchored on the cable.** The link-local
   IP is the one address known to reach the UDID being connected, so its
   EPMD is the reference. The phone's EPMD binds 0.0.0.0, so it lists the
   node even when the node is named after the WiFi IP — which mob_beam.m
   does whenever WiFi is up. To find that IP, `IOS.resolve_usb_node/1`
   reverse-resolves the link-local IP to the phone's mDNS name
   (`kevins-iphone.local`) and forward-resolves that name's IPv4s, under a 3 s
   overall deadline (each native lookup can take seconds; running out means
   no other addresses, so link-local is used). `choose_usb_node/2` takes one of
   them only if its EPMD lists the same node at the same dist port and it is
   the only one that does; otherwise the link-local IP with the link-local
   EPMD's port. If the link-local EPMD lists nothing, the old link-local
   prediction stands and no other address is taken.

   **This narrows the candidates to addresses registered under the USB
   phone's name; it does not prove identity.** The lookups are not scoped to
   the USB interface, and RFC 6762 §14 allows the same `.local` name on
   different links. Accepted limitation: with two phones sharing a `.local`
   name, one USB-only and one on the LAN running the same app, the LAN phone's
   address can be taken for the USB phone's. Future work: scope both lookups
   to the USB interface (`dns-sd -i <enN>`).

   Rejected: scanning ARP neighbours and taking a sole LAN hit (the first
   version of this change). It pairs the requested UDID with any other phone
   on the LAN running the same app. Matching the dist port does not fix that
   on its own: physical iOS launches set no `MOB_DIST_PORT`, so every phone's
   BEAM listens on mob_beam.m's default 9101 and two phones look identical.
   The port/name match is kept as a consistency check against a stale mDNS
   answer; the candidates come from mDNS.

The dist-port reachability check that rejects phantom hits (an Android phone's
`adb reverse tcp:4369` echoing the Mac's EPMD) is unchanged and still runs on
the selected entry.

## Consequences

- `mix mob.connect` / `mix mob.devices` inside a project no longer list or
  attach to other Mob apps' iOS nodes. Outside a Mix project the old
  first-`*_ios` behaviour is kept, since there is nothing to match against.
- USB resolution costs a reverse + forward mDNS lookup and one EPMD probe per
  phone address (~125 ms end to end here), instead of a probe per ARP neighbour. The
  LAN scan's neighbour list comes from `arp -an`: `arp -a` reverse-resolves
  every entry, which took 15 s on the machine this was found on. The
  link-local lookup in `Tunnel` still uses `arp -a` (unchanged here).
- A phone without mDNS on the link (reverse lookup fails) is resolved at its
  link-local IP only. If it named its node after WiFi, the connect then fails
  on the name mismatch rather than attaching elsewhere — the pre-change
  behaviour.
- Still a prediction when the app is not running at tunnel setup:
  `Connector.connect_all/1` sets up tunnels *before* restarting the app, so a
  cold app on a WiFi-connected phone still gets the link-local name and the
  wait can time out. Resolving after launch (or waiting on candidate names)
  would close that gap; not done here.
- Discovery's LAN scan (`list_physical/0` without USB) still finds this app on
  whichever LAN hosts run it; with one USB phone and one LAN hit it still
  merges them as before. That merge is not identity-checked; unchanged here.
