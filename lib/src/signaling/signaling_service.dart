import 'dart:async';
import 'dart:typed_data';

import 'package:logger/logger.dart';
import 'package:redux/redux.dart';

import '../store/app_state.dart';
import '../store/peers_state.dart';
import '../store/signaling_actions.dart';
import 'address_table.dart';
import 'signaling_codec.dart';

/// Orchestrates signaling between peers via well-connected friends.
///
/// ## Two roles
///
/// 1. **As a regular agent** (behind NAT):
///    - Queries friends for other peers' addresses (ADDR_QUERY).
///    - Requests hole-punch coordination (PUNCH_REQUEST).
///    - Responds to PUNCH_INITIATE by starting the punch.
///
/// 2. **As a well-connected friend** (globally routable):
///    - Registers friend addresses from ANNOUNCE packets ([processAnnounceFromFriend]).
///    - Maintains an [AddressTable] of friend addresses.
///    - Responds to ADDR_QUERY from friends.
///    - Coordinates hole-punches on PUNCH_REQUEST.
///
/// ## Integration
///
/// The service doesn't send packets directly. Instead, it calls
/// [sendSignaling] which the coordinator provides. This keeps the
/// service transport-agnostic.
class SignalingService {
  final Logger _log = Logger();

  final Store<AppState> store;
  final SignalingCodec codec;

  /// Address table — only meaningful when we are well-connected.
  /// Always allocated so we don't need null checks; just empty when not used.
  final AddressTable addressTable = AddressTable();

  /// Timer for periodic stale-entry cleanup in the address table.
  Timer? _staleCleanupTimer;

  /// Pending address queries: correlate responses back to the requester.
  /// Key: pubkey hex of the target peer we're querying about.
  /// Value: completer that resolves when the first response arrives (or timeout).
  final Map<String, Completer<AddressEntry?>> _pendingQueries = {};

  // ===== Callbacks (set by coordinator) =====

  /// Send a signaling payload wrapped in a BitchatPacket to a specific peer.
  /// The coordinator wraps the payload in a BitchatPacket(type: signaling),
  /// signs it, and sends it via the best available transport.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
      sendSignaling;

  /// Fired when a well-connected friend tells us to start hole-punching.
  /// The coordinator should call HolePunchService.punch() with these params.
  void Function(Uint8List peerPubkey, String ip, int port)? onPunchInitiate;

  /// Fired when a hole-punch completes and we should connect to the peer.
  /// (Triggered by PUNCH_READY from the other side via the friend.)
  void Function(Uint8List peerPubkey)? onPunchReady;

  /// Fired when a well-connected friend reflects our observed public address.
  /// The coordinator should update its public address with this value.
  void Function(String ip, int port)? onAddrReflected;

  SignalingService({
    required this.store,
    this.codec = const SignalingCodec(),
  }) {
    // Clean up stale address table entries every 60 seconds.
    _staleCleanupTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => addressTable.removeStale(const Duration(minutes: 5)),
    );
  }

  // ===== Outgoing API (called by coordinator) =====

  /// Query well-connected friends for a peer's address.
  ///
  /// Sends ADDR_QUERY to all well-connected friends in parallel.
  /// Returns the first response, or null after [timeout].
  Future<AddressEntry?> queryPeerAddress(
    Uint8List targetPubkey, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    // Exclude the target from the friends list — can't ask a peer to
    // look up its own address or coordinate a punch to itself.
    final friends = store.state.peers.wellConnectedFriends
        .where((f) => _pubkeyToHex(f.publicKey) != targetHex)
        .toList();

    if (friends.isEmpty) {
      _log.w('No well-connected friends to query (excluding target)');
      return null;
    }

    // If there's already a pending query for this target, return the same future.
    if (_pendingQueries.containsKey(targetHex)) {
      return _pendingQueries[targetHex]!.future;
    }

    final completer = Completer<AddressEntry?>();
    _pendingQueries[targetHex] = completer;

    _log.i('Querying ${friends.length} friends for address of ${targetHex.substring(0, 8)}...');

    final msg = AddrQueryMessage(targetPubkey: targetPubkey);
    final payload = codec.encode(msg);

    // Send to all friends in parallel — first response wins.
    for (final friend in friends) {
      sendSignaling?.call(friend.publicKey, payload);
    }

    // Timeout — resolve with null if no response.
    final timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _log.w('Address query timed out for ${targetHex.substring(0, 8)}...');
        completer.complete(null);
      }
    });

    final result = await completer.future;
    timer.cancel();
    _pendingQueries.remove(targetHex);
    return result;
  }

  /// Request hole-punch coordination through a well-connected friend.
  ///
  /// Sends PUNCH_REQUEST to the first reachable well-connected friend.
  /// The friend will send PUNCH_INITIATE to both us and the target.
  Future<void> requestHolePunch(Uint8List targetPubkey) async {
    final targetHex = _pubkeyToHex(targetPubkey);

    // Exclude the target from the friends list — can't ask a peer to
    // coordinate a hole-punch to itself.
    final friends = store.state.peers.wellConnectedFriends
        .where((f) => _pubkeyToHex(f.publicKey) != targetHex)
        .toList();
    if (friends.isEmpty) {
      _log.w('No well-connected friends to coordinate hole-punch (excluding target)');
      return;
    }
    _log.i('Requesting hole-punch to ${targetHex.substring(0, 8)}... via well-connected friend');

    store.dispatch(HolePunchStartedAction(targetHex));

    final msg = PunchRequestMessage(targetPubkey: targetPubkey);
    final payload = codec.encode(msg);

    // Try each friend until one accepts.
    for (final friend in friends) {
      final sent = await sendSignaling?.call(friend.publicKey, payload);
      if (sent == true) {
        _log.d('Punch request sent via ${friend.displayName}');
        return;
      }
    }

    _log.w('Failed to send punch request to any well-connected friend');
    store.dispatch(HolePunchFailedAction(targetHex, 'No reachable friend'));
  }

  /// Notify a well-connected friend that our NAT is open (punch sent).
  Future<void> sendPunchReady(
    Uint8List friendPubkey,
    Uint8List peerPubkey,
  ) async {
    final msg = PunchReadyMessage(peerPubkey: peerPubkey);
    final payload = codec.encode(msg);
    await sendSignaling?.call(friendPubkey, payload);
  }

  // ===== Incoming processing (called by MessageRouter via coordinator) =====

  /// Process an incoming signaling packet.
  ///
  /// [senderPubkey] is the authenticated sender from the outer BitchatPacket.
  /// [payload] is the raw signaling payload (type byte + message data).
  void processSignaling(
    Uint8List senderPubkey,
    Uint8List payload,
  ) {
    // Only process signaling from friends — drop signaling from strangers.
    final senderHex = _pubkeyToHex(senderPubkey);
    final senderPeer = store.state.peers.getPeerByPubkeyHex(senderHex);
    if (senderPeer == null || !senderPeer.isFriend) {
      _log.w('Dropping signaling from non-friend ${senderHex.substring(0, 8)}...');
      return;
    }

    SignalingMessage msg;
    try {
      msg = codec.decode(payload);
    } catch (e) {
      _log.w('Failed to decode signaling message: $e');
      return;
    }

    _log.d('Received signaling from ${senderPeer.displayName}: $msg');

    switch (msg) {
      case AddrQueryMessage():
        _handleAddrQuery(senderPubkey, msg);
      case AddrResponseMessage():
        _handleAddrResponse(msg);
      case PunchRequestMessage():
        _handlePunchRequest(senderPubkey, senderHex, msg);
      case PunchInitiateMessage():
        _handlePunchInitiate(msg);
      case PunchReadyMessage():
        _handlePunchReady(msg);
      case AddrReflectMessage():
        _handleAddrReflect(msg);
    }
  }

  // ===== Incoming handlers =====

  /// Process an ANNOUNCE received over UDP from a friend.
  ///
  /// Called by the coordinator when we are well-connected and receive an
  /// ANNOUNCE over UDP from a friend. Registers the friend's address in our
  /// address table (so other friends can query for it) and reflects the
  /// observed address back if it differs from the claimed address.
  ///
  /// [senderPubkey] is the authenticated sender from the outer BitchatPacket.
  /// [claimedAddress] is the address from the ANNOUNCE payload (ip:port string).
  /// [observedIp] and [observedPort] are the sender's address as seen on the
  /// UDX connection — the NAT-translated public address.
  void processAnnounceFromFriend(
    Uint8List senderPubkey, {
    String? claimedAddress,
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = _pubkeyToHex(senderPubkey);

    // Parse claimed address from ANNOUNCE payload
    String? claimedIp;
    int? claimedPort;
    if (claimedAddress != null && claimedAddress.isNotEmpty) {
      // Parse ip:port or [ip]:port format
      final parts = _parseAddress(claimedAddress);
      if (parts != null) {
        claimedIp = parts.ip;
        claimedPort = parts.port;
      }
    }

    // Use the observed address (from the UDX connection) when available.
    // This is the real NAT-translated address — the claimed address may
    // have an incorrect port (cone NAT port assumption).
    final effectiveIp = observedIp ?? claimedIp;
    final effectivePort = observedPort ?? claimedPort;

    if (effectiveIp == null || effectivePort == null) return;

    if (observedIp != null && observedPort != null &&
        claimedIp != null && claimedPort != null) {
      if (claimedIp != observedIp || claimedPort != observedPort) {
        _log.i('Address mismatch for ${senderHex.substring(0, 8)}...: '
            'claimed $claimedIp:$claimedPort, observed $observedIp:$observedPort — using observed');
      }
    }

    _log.i('Address registered via ANNOUNCE: ${senderHex.substring(0, 8)}... → $effectiveIp:$effectivePort');
    addressTable.register(senderHex, effectiveIp, effectivePort);

    // Reflect the observed address back to the sender so they can learn
    // their true external address (especially the correct NAT port).
    if (observedIp != null && observedPort != null) {
      final reflect = AddrReflectMessage(ip: observedIp, port: observedPort);
      sendSignaling?.call(senderPubkey, codec.encode(reflect));
    }
  }

  /// Parse an address string in "[ip]:port" or "ip:port" format.
  static ({String ip, int port})? _parseAddress(String addr) {
    String ipStr;
    String portStr;

    if (addr.startsWith('[')) {
      final closeBracket = addr.indexOf(']');
      if (closeBracket < 0) return null;
      ipStr = addr.substring(1, closeBracket);
      final afterBracket = addr.substring(closeBracket + 1);
      if (!afterBracket.startsWith(':')) return null;
      portStr = afterBracket.substring(1);
    } else {
      final lastColon = addr.lastIndexOf(':');
      if (lastColon < 0) return null;
      ipStr = addr.substring(0, lastColon);
      portStr = addr.substring(lastColon + 1);
      if (ipStr.contains(':')) return null;
    }

    final port = int.tryParse(portStr);
    if (port == null) return null;

    return (ip: ipStr, port: port);
  }

  /// Handle ADDR_QUERY: friend asking us for another peer's address.
  ///
  /// Only responds if we're well-connected and have the entry.
  void _handleAddrQuery(Uint8List senderPubkey, AddrQueryMessage msg) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);
    final entry = addressTable.lookup(targetHex);

    // Always respond — even "not found" — so the querier doesn't hang.
    final response = AddrResponseMessage(
      targetPubkey: msg.targetPubkey,
      ip: entry?.ip,
      port: entry?.port,
    );
    final payload = codec.encode(response);
    sendSignaling?.call(senderPubkey, payload);

    _log.d('Responded to addr query for ${targetHex.substring(0, 8)}...: '
        '${entry != null ? "${entry.ip}:${entry.port}" : "not found"}');
  }

  /// Handle ADDR_RESPONSE: a friend responding to our address query.
  void _handleAddrResponse(AddrResponseMessage msg) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);
    final completer = _pendingQueries[targetHex];

    if (completer == null || completer.isCompleted) {
      _log.d('Ignoring unexpected addr response for ${targetHex.substring(0, 8)}...');
      return;
    }

    if (msg.found) {
      _log.i('Got address for ${targetHex.substring(0, 8)}...: ${msg.ip}:${msg.port}');
      completer.complete(AddressEntry(
        ip: msg.ip!,
        port: msg.port!,
        registeredAt: DateTime.now(),
      ));
    } else {
      // Don't complete yet — maybe another friend has the answer.
      _log.d('Friend reports no address for ${targetHex.substring(0, 8)}...');
    }
  }

  /// Handle PUNCH_REQUEST: friend asking us to coordinate a hole-punch.
  ///
  /// We only process this if we're well-connected. Both the requester and the
  /// target must be friends with registered addresses.
  void _handlePunchRequest(
    Uint8List requesterPubkey,
    String requesterHex,
    PunchRequestMessage msg,
  ) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);

    // Both requester and target must be our friends. We only coordinate
    // hole-punches between peers we trust.
    final targetPeer = store.state.peers.getPeerByPubkeyHex(targetHex);
    if (targetPeer == null || !targetPeer.isFriend) {
      _log.w('Punch request for non-friend target ${targetHex.substring(0, 8)}..., ignoring');
      return;
    }

    // Both must have registered addresses.
    final requesterAddr = addressTable.lookup(requesterHex);
    final targetAddr = addressTable.lookup(targetHex);

    if (requesterAddr == null) {
      _log.w('Punch request from ${requesterHex.substring(0, 8)}... but they have no registered address');
      return;
    }
    if (targetAddr == null) {
      _log.w('Punch request for ${targetHex.substring(0, 8)}... but they have no registered address');
      return;
    }

    _log.i('Coordinating hole-punch: '
        '${requesterHex.substring(0, 8)}...(${requesterAddr.ip}:${requesterAddr.port}) ↔ '
        '${targetHex.substring(0, 8)}...(${targetAddr.ip}:${targetAddr.port})');

    // Tell requester to punch toward target.
    final initiateToRequester = PunchInitiateMessage(
      peerPubkey: msg.targetPubkey,
      ip: targetAddr.ip,
      port: targetAddr.port,
    );
    sendSignaling?.call(requesterPubkey, codec.encode(initiateToRequester));

    // Tell target to punch toward requester.
    final initiateToTarget = PunchInitiateMessage(
      peerPubkey: requesterPubkey,
      ip: requesterAddr.ip,
      port: requesterAddr.port,
    );
    sendSignaling?.call(msg.targetPubkey, codec.encode(initiateToTarget));
  }

  /// Handle PUNCH_INITIATE: a well-connected friend telling us to start punching.
  void _handlePunchInitiate(PunchInitiateMessage msg) {
    _log.i('Punch initiate: punch toward '
        '${_pubkeyToHex(msg.peerPubkey).substring(0, 8)}... at ${msg.ip}:${msg.port}');
    onPunchInitiate?.call(msg.peerPubkey, msg.ip, msg.port);
  }

  /// Handle PUNCH_READY: the other peer (via friend) says their NAT is open.
  void _handlePunchReady(PunchReadyMessage msg) {
    _log.i('Punch ready from ${_pubkeyToHex(msg.peerPubkey).substring(0, 8)}...');
    onPunchReady?.call(msg.peerPubkey);
  }

  /// Handle ADDR_REFLECT: a well-connected friend telling us our observed address.
  ///
  /// This is the STUN-equivalent for Bitchat. The friend saw our real
  /// NAT-translated address on the incoming UDP connection and is reflecting
  /// it back. We update our public address with this value — it has the
  /// correct external port, unlike our local-port-based guess.
  void _handleAddrReflect(AddrReflectMessage msg) {
    _log.i('Address reflected by friend: ${msg.ip}:${msg.port}');
    onAddrReflected?.call(msg.ip, msg.port);
  }

  // ===== Lifecycle =====

  void dispose() {
    _staleCleanupTimer?.cancel();
    _staleCleanupTimer = null;

    // Complete any pending queries with null.
    for (final completer in _pendingQueries.values) {
      if (!completer.isCompleted) completer.complete(null);
    }
    _pendingQueries.clear();

    addressTable.clear();
  }

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
