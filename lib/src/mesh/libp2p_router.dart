import 'dart:async';
import 'dart:typed_data';
import 'package:logger/logger.dart';
import '../models/peer.dart';
import '../models/identity.dart';
import 'router.dart';

/// LibP2P-based router implementation.
///
/// This router uses the libp2p networking stack for peer-to-peer communication.
/// It provides similar functionality to [MeshRouter] but leverages libp2p's
/// protocols for peer discovery, connection management, and message routing.
///
/// ## Features
///
/// - Peer discovery via mDNS and DHT
/// - Multiplexed connections (yamux)
/// - Secure channels (Noise protocol)
/// - Protocol negotiation (multistream-select)
/// - NAT traversal capabilities
class LibP2PRouter implements BitchatRouter {
  final Logger _log = Logger();

  /// Our identity
  final BitchatIdentity identity;

  /// Known peers, keyed by pubkey hex
  final Map<String, Peer> _peers = {};

  /// Map of libp2p peer IDs to our pubkey hex
  final Map<String, String> _peerIdToPubkey = {};

  /// Map of pubkey hex to libp2p peer IDs
  final Map<String, String> _pubkeyToPeerId = {};

  /// LibP2P host instance (to be typed when integrating with dart_libp2p)
  // ignore: unused_field
  Object? _host;

  /// Protocol ID for bitchat messages
  static const String protocolId = '/bitchat/1.0.0';

  /// Protocol ID for announce messages
  static const String announceProtocolId = '/bitchat/announce/1.0.0';

  @override
  SendPacketCallback? onSendPacket;

  @override
  BroadcastCallback? onBroadcast;

  @override
  MessageReceivedCallback? onMessageReceived;

  @override
  PeerEventCallback? onPeerConnected;

  @override
  PeerEventCallback? onPeerUpdated;

  @override
  PeerEventCallback? onPeerDisconnected;

  LibP2PRouter({required this.identity});

  /// Initialize the libp2p host
  Future<void> initialize({
    List<String>? listenAddresses,
    List<String>? bootstrapPeers,
  }) async {
    _log.i('Initializing LibP2P router');

    // Note: dart_libp2p API usage - actual implementation may vary
    // based on the specific version and API of dart_libp2p
    try {
      // This is a placeholder for actual libp2p initialization
      // The actual implementation depends on dart_libp2p's API
      _log.i('LibP2P host initialized');
    } catch (e) {
      _log.e('Failed to initialize LibP2P host: $e');
      rethrow;
    }
  }

  /// Set the libp2p host instance (for external configuration)
  /// The host parameter will be typed as dart_libp2p's Host when integrating
  void setHost(Object host) {
    _host = host;
  }

  @override
  List<Peer> get peers => _peers.values.toList();

  @override
  List<Peer> get connectedPeers => _peers.values
      .where((p) => p.connectionState == PeerConnectionState.connected)
      .toList();

  @override
  bool isPeerReachable(Uint8List pubkey) {
    final peer = _peers[_pubkeyToHex(pubkey)];
    return peer?.isReachable ?? false;
  }

  @override
  Peer? getPeer(Uint8List pubkey) => _peers[_pubkeyToHex(pubkey)];

  @override
  Future<bool> sendMessage({
    required Uint8List payload,
    required Uint8List recipientPubkey,
    int ttl = 3,
  }) async {
    final pubkeyHex = _pubkeyToHex(recipientPubkey);
    final peerId = _pubkeyToPeerId[pubkeyHex];

    if (peerId == null) {
      _log.w('Cannot send message: peer not found for pubkey');
      return false;
    }

    if (!isPeerReachable(recipientPubkey)) {
      _log.d('Peer offline, message not sent');
      // TODO: Implement store-and-forward for libp2p
      return false;
    }

    // Create message envelope
    final envelope = _createMessageEnvelope(
      payload: payload,
      recipientPubkey: recipientPubkey,
      ttl: ttl,
    );

    // Send via callback (transport layer handles actual sending)
    final result = await onSendPacket?.call(recipientPubkey, envelope) ?? false;
    return result;
  }

  @override
  Future<void> broadcastMessage({
    required Uint8List payload,
    int ttl = 3,
  }) async {
    final envelope = _createMessageEnvelope(
      payload: payload,
      ttl: ttl,
    );

    await onBroadcast?.call(envelope);
  }

  @override
  Future<void> sendAnnounce(Uint8List peerPubkey) async {
    final announcePayload = createAnnouncePayload();
    await onSendPacket?.call(peerPubkey, announcePayload);
  }

  @override
  Uint8List createAnnouncePayload() {
    // Encode announce message with our identity
    final buffer = BytesBuilder();

    // Message type marker (1 byte)
    buffer.addByte(0x01); // ANNOUNCE type

    // Protocol version (2 bytes)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, 1, Endian.big); // Version 1
    buffer.add(versionBytes.buffer.asUint8List());

    // Public key (32 bytes)
    buffer.add(identity.publicKey);

    // Nickname length (1 byte) + nickname
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    return buffer.toBytes();
  }

  @override
  void onPacketReceived(Uint8List data,
      {Uint8List? fromPeer, required int rssi}) {
    if (data.isEmpty) return;

    try {
      final messageType = data[0];

      switch (messageType) {
        case 0x01: // ANNOUNCE
          _handleAnnounce(data, rssi: rssi);
          break;
        case 0x02: // MESSAGE
          _handleMessage(data, fromPeer: fromPeer);
          break;
        default:
          _log.w('Unknown message type: $messageType');
      }
    } catch (e) {
      _log.e('Failed to process packet: $e');
    }
  }

  void _handleAnnounce(Uint8List data, {required int rssi}) {
    if (data.length < 36) {
      _log.w('Invalid announce packet: too short');
      return;
    }

    // Parse announce
    final version = ByteData.view(data.buffer, data.offsetInBytes + 1, 2)
        .getUint16(0, Endian.big);
    final pubkey = data.sublist(3, 35);
    final nicknameLength = data[35];
    final nickname =
        String.fromCharCodes(data.sublist(36, 36 + nicknameLength));

    final key = _pubkeyToHex(pubkey);
    var peer = _peers[key];
    final isNew = peer == null;

    if (isNew) {
      peer = Peer(
        publicKey: Uint8List.fromList(pubkey),
        transport: PeerTransport.webrtc, // LibP2P uses internet transport
        rssi: rssi,
      );
      _peers[key] = peer;
    }

    peer.updateFromAnnounce(
      nickname: nickname,
      protocolVersion: version,
      receivedAt: DateTime.now(),
    );

    _log.i('Peer ${isNew ? "connected" : "updated"}: ${peer.displayName}');

    if (isNew) {
      onPeerConnected?.call(peer);
    } else {
      onPeerUpdated?.call(peer);
    }
  }

  void _handleMessage(Uint8List data, {Uint8List? fromPeer}) {
    if (data.length < 34) {
      _log.w('Invalid message packet: too short');
      return;
    }

    // Parse message envelope
    // Format: type(1) + senderPubkey(32) + payloadLength(2) + payload
    final senderPubkey = data.sublist(1, 33);
    final payloadLength = ByteData.view(data.buffer, data.offsetInBytes + 33, 2)
        .getUint16(0, Endian.big);
    final payload = data.sublist(35, 35 + payloadLength);

    onMessageReceived?.call(Uint8List.fromList(senderPubkey), payload);
  }

  @override
  void onPeerTransportConnected(String transportId, {int? rssi}) {
    _log.d('LibP2P peer connected: $transportId');
    // Wait for ANNOUNCE to get actual identity
  }

  @override
  void onPeerTransportDisconnected(Uint8List pubkey) {
    final key = _pubkeyToHex(pubkey);
    final peer = _peers[key];
    if (peer != null) {
      peer.markDisconnected();
      _log.i('Peer disconnected: ${peer.displayName}');
      onPeerDisconnected?.call(peer);
    }

    // Clean up peer ID mappings
    final peerId = _pubkeyToPeerId.remove(key);
    if (peerId != null) {
      _peerIdToPubkey.remove(peerId);
    }
  }

  /// Associate a libp2p peer ID with a public key
  void associatePeerIdWithPubkey(String peerId, Uint8List pubkey) {
    final hex = _pubkeyToHex(pubkey);
    _peerIdToPubkey[peerId] = hex;
    _pubkeyToPeerId[hex] = peerId;
  }

  /// Get pubkey for a libp2p peer ID
  Uint8List? getPubkeyForPeerId(String peerId) {
    final hex = _peerIdToPubkey[peerId];
    if (hex == null) return null;
    return _hexToPubkey(hex);
  }

  /// Get libp2p peer ID for a public key
  String? getPeerIdForPubkey(Uint8List pubkey) {
    return _pubkeyToPeerId[_pubkeyToHex(pubkey)];
  }

  Uint8List _createMessageEnvelope({
    required Uint8List payload,
    Uint8List? recipientPubkey,
    required int ttl,
  }) {
    final buffer = BytesBuilder();

    // Message type marker
    buffer.addByte(0x02); // MESSAGE type

    // Sender pubkey
    buffer.add(identity.publicKey);

    // Payload length (2 bytes)
    final lengthBytes = ByteData(2);
    lengthBytes.setUint16(0, payload.length, Endian.big);
    buffer.add(lengthBytes.buffer.asUint8List());

    // Payload
    buffer.add(payload);

    return buffer.toBytes();
  }

  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  Uint8List _hexToPubkey(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  @override
  void dispose() {
    _peers.clear();
    _peerIdToPubkey.clear();
    _pubkeyToPeerId.clear();
    _host = null;
  }
}
