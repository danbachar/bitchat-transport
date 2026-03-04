import 'dart:typed_data';
import 'package:logger/logger.dart';
import 'package:redux/redux.dart';
import '../mesh/bloom_filter.dart';
import '../models/identity.dart';
import '../models/packet.dart';
import '../models/peer.dart';
import '../protocol/fragment_handler.dart';
import '../protocol/protocol_handler.dart';
import '../store/app_state.dart';
import '../store/peers_actions.dart';
import '../store/peers_state.dart';

/// Routes incoming packets from all transports to the appropriate handlers.
///
/// Responsibilities:
/// - Signature verification (drops invalid packets)
/// - Packet deduplication (via BloomFilter)
/// - ANNOUNCE decoding and Redux dispatch
/// - MESSAGE targeting (is-for-us check)
/// - Fragment reassembly delegation
/// - Callback dispatch to application layer
///
/// All transports feed into [processPacket] — one entry point, one format.
class MessageRouter {
  final Logger _log = Logger();

  final BitchatIdentity identity;
  final Store<AppState> store;
  final ProtocolHandler protocolHandler;
  final FragmentHandler fragmentHandler;
  final BloomFilter _seenPackets = BloomFilter();

  /// Called when a message is received
  void Function(String id, Uint8List senderPubkey, Uint8List payload)?
      onMessageReceived;

  /// Called when an ACK is received (delivery confirmation)
  void Function(String messageId)? onAckReceived;

  /// Called when a read receipt is received
  void Function(String messageId)? onReadReceiptReceived;

  /// Called when a peer ANNOUNCE is processed (new or updated peer)
  void Function(AnnounceData data, PeerTransport transport,
      {bool isNew, bool irohAddressChanged})? onPeerAnnounced;

  /// Called when a message needs an ACK sent back to the sender
  void Function(PeerTransport transport, String peerId, String messageId)?
      onAckRequested;

  /// Convenience accessor for peers state
  PeersState get _peersState => store.state.peers;

  MessageRouter({
    required this.identity,
    required this.store,
    required this.protocolHandler,
    required this.fragmentHandler,
  });

  // ===== Unified Packet Processing =====

  /// Process an incoming packet from any transport.
  ///
  /// All packets are signature-verified before processing.
  /// Invalid signatures are dropped immediately.
  /// ANNOUNCE packets bypass deduplication (always processed).
  Future<void> processPacket(
    BitchatPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    String? irohNodeIdHex,
    int rssi = -100,
  }) async {
    // Verify signature — drop invalid packets
    final isValid = await protocolHandler.verifyPacket(packet);
    if (!isValid) {
      _log.w('Dropping packet with invalid signature (type: ${packet.type})');
      return;
    }

    // ANNOUNCE always processed (peer may have updated info)
    if (packet.type == PacketType.announce) {
      _handleAnnounce(
        packet,
        transport: transport,
        bleDeviceId: bleDeviceId,
        irohNodeIdHex: irohNodeIdHex,
        rssi: rssi,
      );
      return;
    }

    // Dedup for non-ANNOUNCE packets
    if (_seenPackets.checkAndAdd(packet.packetId)) {
      return;
    }

    switch (packet.type) {
      case PacketType.announce:
        return; // Already handled above
      case PacketType.message:
        _handleMessage(packet, transport: transport, irohNodeIdHex: irohNodeIdHex);
      case PacketType.fragmentStart:
      case PacketType.fragmentContinue:
      case PacketType.fragmentEnd:
        _handleFragment(packet);
      case PacketType.ack:
        _handleAck(packet);
      case PacketType.nack:
        break;
      case PacketType.readReceipt:
        _handleReadReceipt(packet);
    }
  }

  // ===== Handlers =====

  void _handleAnnounce(
    BitchatPacket packet, {
    required PeerTransport transport,
    String? bleDeviceId,
    String? irohNodeIdHex,
    int rssi = -100,
  }) {
    final data = protocolHandler.decodeAnnounce(packet.payload);
    final pubkey = data.publicKey;

    int effectiveRssi = rssi;

    // BLE-specific: lookup RSSI from discovered peers
    if (transport == PeerTransport.bleDirect) {
      DiscoveredPeerState? discoveredPeer;
      if (bleDeviceId != null) {
        discoveredPeer = _peersState.getDiscoveredBlePeer(bleDeviceId);
      }
      if (discoveredPeer == null) {
        final theirServiceUuid = _deriveServiceUuidFromPubkey(pubkey);
        discoveredPeer =
            _peersState.findDiscoveredBlePeerByServiceUuid(theirServiceUuid);
      }
      if (discoveredPeer != null) {
        effectiveRssi = discoveredPeer.rssi;
      }
    }

    final existingPeer = _peersState.getPeerByPubkey(pubkey);
    final isNew = existingPeer == null;

    // Parse iroh addresses from ANNOUNCE
    final irohAddresses = data.irohAddresses;

    // Detect if iroh addresses changed (for reconnection logic)
    final previousRelayUrl = existingPeer?.irohRelayUrl;
    final newRelayUrl = _extractRelayUrl(irohAddresses);
    final irohAddressChanged = previousRelayUrl != null && newRelayUrl != previousRelayUrl;

    // Extract relay URL and direct addresses from the address list
    String? relayUrl;
    final directAddresses = <String>[];
    for (final addr in irohAddresses) {
      if (addr.startsWith('https://') || addr.startsWith('http://')) {
        relayUrl = addr;
      } else {
        directAddresses.add(addr);
      }
    }

    store.dispatch(PeerAnnounceReceivedAction(
      publicKey: pubkey,
      nickname: data.nickname,
      protocolVersion: data.protocolVersion,
      rssi: effectiveRssi,
      transport: transport,
      bleDeviceId: bleDeviceId,
      irohRelayUrl: relayUrl,
      irohDirectAddresses: directAddresses,
    ));

    if (bleDeviceId != null) {
      store.dispatch(
          AssociateBleDeviceAction(publicKey: pubkey, deviceId: bleDeviceId));
    }

    _log.i(
        'Peer ${isNew ? "connected" : "updated"}: ${data.nickname} via ${transport.name}'
        '${irohAddresses.isNotEmpty ? ", ${irohAddresses.length} iroh addrs" : ""}');
    if (irohAddresses.isNotEmpty) {
      _log.d('  ANNOUNCE addresses: ${irohAddresses.join(", ")}');
    }

    onPeerAnnounced?.call(data, transport,
        isNew: isNew, irohAddressChanged: irohAddressChanged);
  }

  /// Extract relay URL from a list of addresses (first https:// URL)
  String? _extractRelayUrl(List<String> addresses) {
    for (final addr in addresses) {
      if (addr.startsWith('https://') || addr.startsWith('http://')) {
        return addr;
      }
    }
    return null;
  }

  void _handleMessage(
    BitchatPacket packet, {
    required PeerTransport transport,
    String? irohNodeIdHex,
  }) {
    if (!_isForUs(packet)) return;
    onMessageReceived?.call(
        packet.packetId, packet.senderPubkey, packet.payload);
    // Send ACK back for iroh (delivery confirmation)
    if (transport == PeerTransport.iroh && irohNodeIdHex != null) {
      onAckRequested?.call(transport, irohNodeIdHex, packet.packetId);
    }
  }

  void _handleFragment(BitchatPacket packet) {
    final reassembled = fragmentHandler.processFragment(packet);
    if (reassembled != null) {
      onMessageReceived?.call(
          packet.packetId, packet.senderPubkey, reassembled);
    }
  }

  void _handleAck(BitchatPacket packet) {
    if (packet.payload.isEmpty) return;
    final messageId = String.fromCharCodes(packet.payload);
    onAckReceived?.call(messageId);
  }

  void _handleReadReceipt(BitchatPacket packet) {
    if (packet.payload.isEmpty) return;
    final messageId = String.fromCharCodes(packet.payload);
    onReadReceiptReceived?.call(messageId);
  }

  // ===== Helpers =====

  bool _isForUs(BitchatPacket packet) {
    if (packet.isBroadcast) return true;
    return _pubkeysEqual(packet.recipientPubkey!, identity.publicKey);
  }

  static bool _pubkeysEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Derive BLE Service UUID from a public key (last 16 bytes as UUID).
  static String _deriveServiceUuidFromPubkey(Uint8List pubkey) {
    final uuidBytes = pubkey.sublist(16, 32);
    final hex =
        uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
        '${hex.substring(8, 12)}-'
        '${hex.substring(12, 16)}-'
        '${hex.substring(16, 20)}-'
        '${hex.substring(20, 32)}';
  }

  // ===== Deduplication API =====

  /// Mark a packet ID as seen (e.g., for outgoing packets)
  void markSeen(String packetId) {
    _seenPackets.add(packetId);
  }

  /// Check if a packet ID has been seen before
  bool isDuplicate(String packetId) {
    return _seenPackets.mightContain(packetId);
  }

  // ===== Lifecycle =====

  /// Clean up resources
  void dispose() {
    _seenPackets.clear();
  }
}
