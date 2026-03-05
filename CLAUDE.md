# Claude Instructions for Bitchat Transport

## Critical: always be precise, critical, but helpful.

## CRITICAL: NO Legacy or Compatibility Code — EVER

**IMPORTANT**: NEVER write backward-compatible code, migration shims, or compatibility layers. This applies to ALL code changes including protocol changes, API changes, data format changes, and refactors.

- ❌ **NO** `// Legacy - kept for compatibility` comments
- ❌ **NO** keeping both old and new implementations
- ❌ **NO** backward-compatible encoding/decoding (e.g., "old receivers will still parse this")
- ❌ **NO** migration paths or version-gated behavior
- ❌ **NO** fallback logic for old formats or protocols
- ✅ **DO** fully replace old code with new implementation
- ✅ **DO** remove unused imports and dead code
- ✅ **DO** update all call sites when changing APIs
- ✅ **DO** change protocols/formats cleanly without worrying about old versions
- ❌ **NO** `PeerStore` - use Redux store (`AppState.peers`) only

---

## Peer Relay / Friend Forwarding

**IMPORTANT**: SGN supports **peer-to-peer message forwarding** through trusted intermediate peers.

If a peer cannot reach the recipient directly (neither via BLE nor libp2p), it MAY forward the message through a connected peer that **can** reach the recipient.

### How It Works

1. **Peer A** wants to send to **Peer B** but has no direct route (no BLE range, no libp2p connection)
2. **Peer C** is connected to both A and B (via any transport combination: BLE, libp2p, or mixed)
3. A sends the message to C with B's public key as the intended recipient
4. C forwards the message to B on A's behalf

### Rules

- ✅ **DO** forward messages through connected peers when the recipient is not directly reachable
- ✅ **DO** use end-to-end encryption — relay peers MUST NOT be able to read forwarded message content
- ✅ **DO** support mixed-transport forwarding (e.g., A→C via BLE, C→B via libp2p)
- ✅ **DO** limit hop count (max 1 relay hop to keep it simple)
- ✅ **DO** let any peer act as a relay — no special server role required
- ❌ **NO** multi-hop chains (A→C→D→B) — only single-hop relay (A→C→B)
- ❌ **NO** queuing at the relay peer — relay is real-time only; if C cannot reach B right now, the forward fails
- ❌ **NO** automatic retry at the relay peer

---

## Fair Message Delivery (Local Queuing)

**IMPORTANT**: SGN guarantees **fair message delivery** as required by the madGLP runtime. Every message passed to `send()` is eventually delivered, assuming the recipient eventually becomes reachable.

### How It Works

- The **sender** queues messages locally when the recipient is temporarily unreachable
- When the recipient becomes reachable again (via any transport), queued messages are delivered
- Messages are delivered as complete, atomic units (reassembled if fragmented)
- The networking layer provides encryption and integrity checks

### Sender-Side Queuing vs Relay Queuing

- ✅ **DO** queue messages at the **sender** when the destination is unreachable
- ✅ **DO** deliver queued messages when the peer reconnects (via BLE, libp2p, or relay)
- ✅ **DO** preserve message ordering per destination
- ❌ **NO** queuing at relay peers — relay forwarding is real-time only
- ❌ **NO** unbounded queue growth — apply reasonable limits (e.g., max queue size, TTL)

### Why This Matters

The madGLP runtime assumes fair message delivery: every `send()` eventually succeeds if the recipient eventually becomes reachable. Without local queuing, madGLP's correctness guarantees break — global link assignments could be lost during transient disconnections.

---

## BLE Service UUID Architecture

**IMPORTANT**: Each SGN device advertises a BLE GATT service UUID with a **fixed Grassroots prefix** and an **agent-specific suffix** derived from its public key.

### UUID Structure

The 128-bit (16-byte) service UUID has two parts:
1. **Fixed 8-byte Grassroots prefix**: Common to all SGN agents. Enables efficient scan filtering — scanners can filter by prefix to find only SGN devices without connecting to every BLE device.
2. **8-byte agent suffix**: Derived from the agent's Ed25519 public key (first 8 bytes of SHA-256 hash of the public key). Enables recognition of a specific agent before connection, by anyone who knows that agent's public key.

### How It Works

1. **Advertising (Peripheral Mode)**:
   - Each device advertises with UUID = `grassroots_prefix | sha256(publicKey)[0:8]`
   - The prefix enables scan-time filtering; the suffix enables pre-connection identification

2. **Scanning (Central Mode)**:
   - Devices scan for devices whose service UUID matches the Grassroots prefix
   - This filters out non-SGN devices (headphones, etc.) at scan time — no need to connect and disconnect
   - Known friends can be recognized by their suffix before connection

3. **Connection & ANNOUNCE Exchange**:
   - After BLE connection, exchange ANNOUNCE packets
   - ANNOUNCE contains: full 32-byte public key, nickname, IP addresses (for libp2p transport)
   - No Bluetooth bonding/pairing required — application-level encryption (Noise XX with Ed25519 keys) is used instead
   - Receiving device verifies identity and stores the mapping: `BLE_Device_ID → PublicKey`

4. **Identity Mapping**:
   - BLE layer knows devices by MAC address / device ID
   - Application layer knows peers by Ed25519 public key
   - SGN maintains the mapping between these identities

### DO NOT:
- ❌ Use a fully random UUID with no shared prefix
- ❌ Connect to every BLE device to check if it's an SGN peer
- ❌ Assume UUID uniqueness means peer uniqueness (verify via ANNOUNCE)

### DO:
- ✅ Use fixed Grassroots prefix + public-key-derived suffix
- ✅ Filter scans by Grassroots prefix to find SGN devices
- ✅ Exchange ANNOUNCE packets after BLE connection
- ✅ Maintain BLE Device ID ↔ Public Key mapping

---

## IP Transport (LibP2P: UDX/TCP + Noise XX)

**IMPORTANT**: The IP transport uses **libp2p** with **UDX** (primary, reliable multiplexed streams over UDP) and **TCP** (fallback). All connections are secured with **Noise XX** (Curve25519 DH, ChaCha20-Poly1305, SHA-256) for mutual authentication and forward secrecy.

### Identity

Each agent's **Ed25519 public key IS the transport identity**. The same key is used for:
- BLE advertising (UUID suffix)
- LibP2P Noise XX authentication
- Message addressing (`send(pubKey, payload)`)
- madGLP agent identity

LibP2P generates a `PeerId` from the Ed25519 key, but the SGN public key remains the canonical identity. The runtime maintains the bidirectional mapping `PeerId ↔ SGN PublicKey`.

### Routable Friends (Friends with Public IPs)

A **routable friend** is an ordinary SGN agent that currently has a **globally routable IP address** (typically PuIv6, but also PuIv4). It is not a server — it is a regular friend running the same app, who happens to be directly reachable from the Internet right now.

Any friend with a globally routable address can be a routable friend. This includes:
- **Smartphones on carriers that assign public IPv6** (increasingly common)
- **Devices on networks with public IPv4** (less common for mobile)
- **Dedicated always-on servers** (for reliability, but not required)

Routable friends perform **signaling** in addition to the relay role any friend can play:
1. **Address registration**: NATed friends connect via libp2p and report their current public IP:port
2. **Address notification**: When agent A wants to reach agent B, the routable friend provides A with B's registered address (and vice versa)
3. **Hole-punch coordination**: Instructs both agents to begin simultaneous UDP sends to each other's addresses, enabling NAT traversal

**Key properties**:
- **Federated**: Any friend with a public IP is a routable friend. Befriend multiple for redundancy. No single point of failure.
- **Dual role**: A routable friend does both signaling (hole-punch coordination) AND message relay (forwarding encrypted payloads). These are complementary — signaling establishes direct connections, relay provides fallback.
- **Just a friend**: No special server role in the protocol. The signaling logic is built into every peer; it activates when the peer detects it has a routable address.
- **Symmetric NAT fallback**: When hole-punching fails (symmetric NAT ↔ symmetric NAT), the routable friend falls back to **message relay** through the social graph.

### NAT Traversal via UDP Hole-Punching

Most mobile devices are behind NAT. UDP hole-punching enables two NATed agents to establish a direct connection, coordinated by their mutual routable friend:

1. Agent A and agent B both maintain a libp2p connection to routable friend S and have registered their public IP:port with S
2. A requests a connection to B through S
3. S sends B's public IP:port to A and A's public IP:port to B
4. A sends a UDP packet to B's address — this opens a mapping in A's NAT
5. B sends a UDP packet to A's address — this opens a mapping in B's NAT
6. Subsequent packets flow directly between A and B through the opened NAT mappings

This works for cone NAT (full-cone, restricted-cone, port-restricted cone). For symmetric NAT, hole-punching may fail, and the routable friend falls back to message relay.

### Smartphones as Routable Friends

Many mobile carriers assign globally routable IPv6 addresses to smartphones. A phone with PuIv6:
- **IS directly reachable** — can receive incoming UDP packets
- **CAN coordinate hole-punching** — both NATed friends connect to it, it exchanges their addresses
- **Less reliable than a dedicated server** — goes offline, changes carriers, battery constraints
- **Mitigated by redundancy** — befriend multiple routable friends

This is the grassroots model: no dedicated infrastructure required. Peers with public IPs naturally emerge as signaling nodes.

### Peer Discovery

LibP2P does NOT discover peers autonomously (DHT is disabled). Discovery happens via:
1. **BLE ANNOUNCE packets** — include the sender's IP addresses
2. **mDNS** — automatic discovery on the same LAN (no BLE required)
3. **Out-of-band exchange** — QR code, link sharing
4. After discovery, the app calls `send(pubKey, payload)` — the networking layer routes via the best available transport

### DO NOT:
- ❌ Require a centralized bootstrap server (use federated routable friends)
- ❌ Assume libp2p has built-in peer discovery (DHT is disabled)
- ❌ Use libp2p Circuit Relay as the primary NAT traversal (use routable-friend-coordinated hole-punching)

### DO:
- ✅ Use Ed25519 public key as the canonical identity (libp2p PeerId derived from it)
- ✅ Use Noise XX pattern for mutual authentication and forward secrecy
- ✅ Use routable friends (peers with public IPs) for signaling and hole-punch coordination
- ✅ Befriend multiple routable friends for redundancy
- ✅ Use BLE ANNOUNCE and mDNS for peer discovery

---

## Transport Layer Settings

### Transport Priority
When sending a message, transports are tried in this order:
1. **Bluetooth (BLE)** — preferred; faster, no Internet needed, works for nearby peers
2. **LibP2P (Internet)** — fallback; UDX/TCP, works globally but requires Internet
3. **Peer relay (forwarding)** — last resort; forward through a connected peer that can reach the recipient

### Disabling Transports
- When Bluetooth is disabled: stop advertising, stop scanning, no BLE communication
- When libp2p is disabled: stop libp2p endpoint, no Internet communication
- At least one transport should remain enabled for the app to function

### Per-Peer Addresses
Each peer can have both a BLE address and a libp2p connection:
- `PeerState.bleDeviceId` - BLE device ID (MAC on Android, UUID on iOS)
- `PeerState.libp2pConnected` - whether libp2p connection is active
- `PeerState.ipAddresses` - peer's known IP addresses (from ANNOUNCE or GLP server)
- Messages route through the best available transport based on peer availability

---

## Redux Architecture for Peers

All peer state is managed through Redux:

### State Structure
- `AppState.peers` → `PeersState`
  - `discoveredBlePeers: Map<String, DiscoveredPeerState>` - Pre-ANNOUNCE BLE devices
  - `peers: Map<String, PeerState>` - Post-ANNOUNCE identified peers

### Key Actions
- `BleDeviceDiscoveredAction` - BLE scan found a device
- `BleDeviceConnectedAction` / `BleDeviceDisconnectedAction` - Connection state
- `PeerAnnounceReceivedAction` - ANNOUNCE packet received (peer identified)
- `PeerRssiUpdatedAction` - Signal strength updated
- `StaleDiscoveredBlePeersRemovedAction` / `StalePeersRemovedAction` - Cleanup

### UI Pattern
```dart
// Read peers from Redux store
Map<String, Peer> get _peers {
  return {
    for (var p in appStore.state.peers.connectedPeers)
      p.pubkeyHex: _peerStateToLegacy(p)
  };
}

// Subscribe to store changes
appStore.onChange.listen((_) => setState(() {}));
```

## Code References

- Service UUID derivation: `lib/src/models/identity.dart` → `bleServiceUuid` getter
- Peripheral advertising: `lib/src/ble/ble_peripheral_service.dart` → `startAdvertising()`
- Central scanning: `lib/src/ble/ble_central_service.dart` → `startScan()` and `_onScanResults()`
- ANNOUNCE handling: `lib/src/routing/message_router.dart` → `_handleAnnounce()`
- Redux store: `lib/src/store/` → `peers_state.dart`, `peers_actions.dart`, `peers_reducer.dart`
