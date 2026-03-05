# Claude Instructions for Bitchat Transport

## Critical: always be precise, critical, but helpful.

## NO Legacy or Compatibility Code

NEVER write backward-compatible code, migration shims, or compatibility layers. Fully replace old code. Remove dead code. Update all call sites. No `PeerStore` — use Redux store (`AppState.peers`) only.

---

## Peer Relay / Friend Forwarding

SGN supports **single-hop peer-to-peer message forwarding** through trusted intermediate peers.

If Peer A can't reach Peer B directly (BLE or iroh), it forwards through Peer C who is connected to both. Mixed-transport forwarding is supported (e.g., A→C via BLE, C→B via iroh). End-to-end encryption required — relay peers MUST NOT read content. Any peer can relay; no special server role.

- **Max 1 relay hop** (A→C→B only, no A→C→D→B)
- **Real-time only** — no store-and-forward, no queuing at relay peers
- **No automatic retry** — if relay can't reach recipient now, forward fails immediately
- `send()` returns `false` if no path exists (direct or relayed)

---

## BLE Service UUID Architecture

Each device advertises a **unique** service UUID = `last_128_bits(Ed25519_publicKey)`.

**Flow**: Scan broadly for all devices → Connect → GATT service discovery → Check for Bitchat characteristic (`0000ff01-0000-1000-8000-00805f9b34fb`) → If absent, disconnect (not a peer) → If present, exchange ANNOUNCE packets (full pubkey, nickname, signature) → Verify signature → Store `BLE_Device_ID ↔ PublicKey` mapping.

- Scan ALL devices (no UUID filtering during scan)
- Cannot know if a device is a Bitchat peer until AFTER service discovery
- Verify identity via ANNOUNCE, not UUID alone

---

## Redux Architecture for Peers

All peer state via Redux (`AppState.peers` → `PeersState`):
- `discoveredBlePeers: Map<String, DiscoveredPeerState>` — pre-ANNOUNCE BLE devices
- `peers: Map<String, PeerState>` — post-ANNOUNCE identified peers

**Actions**: `BleDeviceDiscoveredAction`, `BleDeviceConnectedAction`, `BleDeviceDisconnectedAction`, `PeerAnnounceReceivedAction`, `PeerRssiUpdatedAction`, `StaleDiscoveredBlePeersRemovedAction`, `StalePeersRemovedAction`

---

## Transport Layer

**Priority**: BLE (preferred) → iroh (fallback) → Peer relay (last resort)

**Per-peer state**: `PeerState.bleDeviceId`, `PeerState.irohConnected`, `PeerState.irohRelayUrl`, `PeerState.irohDirectAddresses`. Messages route through best available transport.

**Disabling**: When BLE disabled — stop advertising/scanning. When iroh disabled — stop endpoint. At least one transport must remain enabled.

---

## Iroh Connection

Iroh (iroh.computer) uses QUIC/UDP. No DHT, no bootstrap nodes.

- **Identity = NodeId**: Ed25519 public key IS the iroh NodeId
- **Relay servers** provide NAT traversal only (not message relaying); iroh auto-migrates to direct connections via hole-punching
- **No built-in peer discovery**: Discovery happens via BLE ANNOUNCE (includes iroh relay URL + direct addresses) or out-of-band (QR code, manual)
- Connect via `connectToNode(nodeIdHex, relayUrl, directAddresses)`
- Use default relay servers (`IrohConfig.defaultRelayUrls`)

---

## Code References

- Service UUID: `lib/src/models/identity.dart` → `bleServiceUuid`
- BLE peripheral: `lib/src/ble/ble_peripheral_service.dart` → `startAdvertising()`
- BLE central: `lib/src/ble/ble_central_service.dart` → `startScan()`, `_onScanResults()`
- ANNOUNCE: `lib/src/transport/ble_transport_service.dart` → `_handleAnnounce()`
- Redux store: `lib/src/store/` → `peers_state.dart`, `peers_actions.dart`, `peers_reducer.dart`

---

## Future Work: Geographic-Optimized Multi-Hop Routing (Geo-AODV)

The current single-hop relay constraint exists because naive multi-hop requires expensive flooding-based route discovery (standard AODV broadcasts RREQ to all peers). In a mobile BLE mesh with volatile topology, this is wasteful and slow.

**Geohash-guided AODV** can make multi-hop viable by constraining route discovery spatially:

### Concept

1. **Geohash in ANNOUNCE**: Each peer includes a truncated geohash (e.g., 5-6 chars, ~5km² precision) in its ANNOUNCE packet. Peers maintain a `nodeId → geohash` mapping for all known peers.
2. **Directional RREQ**: When A needs to route to B and knows B's approximate geohash, A's RREQ is tagged with B's geohash. Intermediate peers only re-broadcast the RREQ if their own geohash is geographically "closer" to the destination's geohash (or within a configurable angular cone). This prunes the flood dramatically.
3. **Geohash ring expansion**: If directional RREQ fails (no peers in the cone), expand the search radius by reducing geohash precision (fewer chars = larger area) and retry — analogous to expanding ring search in standard AODV, but spatially informed.
4. **Route maintenance**: Standard AODV RERR (route error) messages when a hop breaks. Geo-awareness helps pick alternate next-hops that are still in the right direction.

### Why Geohash?

- **Hierarchical**: Truncating characters naturally widens the area — no complex distance math
- **Prefix-matching**: Two peers sharing a geohash prefix are spatially close — fast comparison
- **Privacy-preserving**: 5-char geohash (~5km²) reveals neighborhood, not exact location; can be further truncated or randomized with a per-session offset
- **Compact**: 5-6 ASCII chars in an ANNOUNCE packet — negligible overhead

### Tradeoffs vs. Current Single-Hop

| | Single-hop (current) | Geo-AODV (future) |
|---|---|---|
| Complexity | Trivial | Moderate (RREQ/RREP/RERR state machines) |
| Reach | 2 BLE hops max | Unbounded (with TTL cap) |
| Latency | Low | Additive per hop |
| Privacy | 1 relay sees metadata | N relays see metadata; geohash reveals approximate location |
| Use case | Friends nearby | Dense mesh (protests, festivals, disasters) |

### Open Questions

- **Location permission**: Mobile OS requires explicit user consent for location; geohash is opt-in
- **TTL cap**: Practical limit likely 3-4 hops before latency and reliability degrade
- **Hybrid**: Geo-AODV for BLE mesh, iroh for long-range — geo-routing only makes sense for the physical-proximity transport
- **Spoofing**: A peer could lie about its geohash to attract or deflect traffic; mitigations include cross-referencing BLE RSSI or requiring signed geohash attestations from multiple neighbors
