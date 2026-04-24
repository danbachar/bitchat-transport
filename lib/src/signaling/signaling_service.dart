import 'dart:async';
import 'dart:io';

import 'package:redux/redux.dart';
import 'package:flutter/foundation.dart';

import '../store/app_state.dart';
import '../store/signaling_actions.dart';
import '../transport/address_utils.dart';
import 'address_table.dart';
import 'signaling_codec.dart';

/// A positive address response from a specific well-connected friend.
class AddressQueryCandidate {
  final Uint8List responderPubkey;
  final AddressEntry entry;

  const AddressQueryCandidate({
    required this.responderPubkey,
    required this.entry,
  });
}

class _PendingAddressQuery {
  final Completer<AddressEntry?> firstMatch = Completer<AddressEntry?>();
  final Completer<List<AddressQueryCandidate>> candidates =
      Completer<List<AddressQueryCandidate>>();
  final List<AddressQueryCandidate> positiveResponses = [];
  final Set<String> pendingResponderHexes;
  final Set<String> respondedHexes = {};
  Timer? timeoutTimer;

  _PendingAddressQuery(this.pendingResponderHexes);
}

/// Orchestrates signaling between peers via trusted facilitators.
///
/// ## Two roles
///
/// 1. **As a regular agent** (behind NAT):
///    - Queries trusted facilitators for other peers' addresses (ADDR_QUERY).
///    - Requests hole-punch coordination (PUNCH_REQUEST).
///    - Can directly ask a reachable friend to start punching toward us.
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
  final Store<AppState> store;
  final SignalingCodec codec;

  /// Address table — only meaningful when we are well-connected.
  /// Always allocated so we don't need null checks; just empty when not used.
  final AddressTable addressTable = AddressTable();

  /// Timer for periodic stale-entry cleanup in the address table.
  Timer? _staleCleanupTimer;

  /// Pending address queries: correlate responses back to the requester.
  /// Key: pubkey hex of the target peer we're querying about.
  final Map<String, _PendingAddressQuery> _pendingQueries = {};

  /// When we coordinate a punch, remember the counterpart for each participant
  /// so a later PUNCH_READY can be forwarded to the other side.
  final Map<String, Uint8List> _pendingPunchCounterparts = {};

  // ===== Callbacks (set by coordinator) =====

  /// Send a signaling payload wrapped in a BitchatPacket to a specific peer.
  /// The coordinator wraps the payload in a BitchatPacket(type: signaling),
  /// signs it, and sends it via the best available transport.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
  sendSignaling;

  /// Send a signaling payload only over an already-live direct control path.
  /// Used for peer-to-peer punch coordination where falling back to UDP would
  /// re-enter the very path we are trying to establish.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
  sendDirectSignaling;

  /// Fired when a well-connected friend or direct peer tells us to start
  /// hole-punching. [readyRecipientPubkey] is where we should send PUNCH_READY
  /// after finishing our local punch. It is either the facilitator or the peer.
  void Function(
    Uint8List peerPubkey,
    String ip,
    int port,
    Uint8List readyRecipientPubkey,
  )?
  onPunchInitiate;

  /// Fired when a hole-punch completes and we should connect to the peer.
  /// (Triggered by PUNCH_READY from the other side via the friend.)
  void Function(Uint8List peerPubkey)? onPunchReady;

  /// Fired when a well-connected friend reflects our observed public address.
  /// The coordinator should update its public address with this value.
  void Function(String ip, int port)? onAddrReflected;

  SignalingService({required this.store, this.codec = const SignalingCodec()}) {
    // Clean up stale address table entries every 60 seconds.
    _staleCleanupTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => addressTable.removeStale(const Duration(minutes: 5)),
    );
  }

  // ===== Outgoing API (called by coordinator) =====

  /// Query trusted facilitators for a peer's address.
  ///
  /// Sends ADDR_QUERY to all trusted facilitators in parallel.
  /// Returns the first response, or null after [timeout].
  Future<AddressEntry?> queryPeerAddress(
    Uint8List targetPubkey, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final query = _ensurePendingAddressQuery(
      targetPubkey,
      targetHex,
      timeout: timeout,
    );
    return query?.firstMatch.future ?? Future.value(null);
  }

  /// Query trusted facilitators and collect every facilitator that can
  /// currently resolve the target's address.
  Future<List<AddressQueryCandidate>> queryPeerAddressCandidates(
    Uint8List targetPubkey, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final query = _ensurePendingAddressQuery(
      targetPubkey,
      targetHex,
      timeout: timeout,
    );
    return query?.candidates.future ?? Future.value(const []);
  }

  /// Request hole-punch coordination through a trusted facilitator.
  ///
  /// Sends PUNCH_REQUEST to the first reachable facilitator.
  /// The facilitator will send PUNCH_INITIATE to both us and the target.
  Future<void> requestHolePunch(Uint8List targetPubkey) async {
    final targetHex = _pubkeyToHex(targetPubkey);

    final facilitators = _trustedFacilitatorPubkeys(
      excludePubkeyHex: targetHex,
    );
    if (facilitators.isEmpty) {
      debugPrint(
        'No trusted facilitators available to coordinate '
        'hole-punch (excluding target)',
      );
      return;
    }
    debugPrint(
      'Requesting hole-punch to ${targetHex.substring(0, 8)}... via '
      '${facilitators.length} trusted facilitator(s)',
    );

    store.dispatch(HolePunchStartedAction(targetHex));

    // Try each facilitator until one accepts.
    for (final facilitator in facilitators) {
      final sent = await requestHolePunchViaFriend(targetPubkey, facilitator);
      if (sent == true) {
        debugPrint(
          'Punch request sent via '
          '${_pubkeyToHex(facilitator).substring(0, 8)}...',
        );
        return;
      }
    }

    debugPrint('Failed to send punch request to any trusted facilitator');
    store.dispatch(
      HolePunchFailedAction(targetHex, 'No reachable facilitator'),
    );
  }

  /// Ask a specific well-connected friend to coordinate a hole-punch.
  Future<bool> requestHolePunchViaFriend(
    Uint8List targetPubkey,
    Uint8List facilitatorPubkey,
  ) async {
    final msg = PunchRequestMessage(targetPubkey: targetPubkey);
    final payload = codec.encode(msg);
    return await sendSignaling?.call(facilitatorPubkey, payload) ?? false;
  }

  /// Directly ask a friend to start punching toward our advertised address.
  ///
  /// This is used when the target peer is already reachable over another
  /// transport such as BLE. Instead of relying on a third relay, we send
  /// PUNCH_INITIATE straight to the target and then start punching locally.
  Future<bool> requestDirectPunch(
    Uint8List targetPubkey, {
    required Uint8List requesterPubkey,
    required String requesterIp,
    required int requesterPort,
    bool requireDirectTransport = false,
  }) async {
    final targetHex = _pubkeyToHex(targetPubkey);
    final targetPeer = store.state.peers.getPeerByPubkeyHex(targetHex);
    if (targetPeer == null || !targetPeer.isFriend) {
      debugPrint(
        'Cannot request direct punch from non-friend ${targetHex.substring(0, 8)}...',
      );
      return false;
    }

    final msg = PunchInitiateMessage(
      peerPubkey: requesterPubkey,
      ip: requesterIp,
      port: requesterPort,
    );
    final payload = codec.encode(msg);
    final sendFn = requireDirectTransport ? sendDirectSignaling : sendSignaling;
    final sent = await sendFn?.call(targetPubkey, payload) ?? false;

    if (sent) {
      debugPrint(
        'Direct punch request sent to ${targetHex.substring(0, 8)}... '
        'for $requesterIp:$requesterPort',
      );
    } else {
      debugPrint(
        'Failed to send direct punch request to ${targetHex.substring(0, 8)}...',
      );
    }

    return sent;
  }

  /// Notify the facilitator or peer that our local punch completed.
  Future<bool> sendPunchReady(
    Uint8List recipientPubkey,
    Uint8List readyPeerPubkey, {
    bool requireDirectTransport = false,
  }) async {
    final msg = PunchReadyMessage(peerPubkey: readyPeerPubkey);
    final payload = codec.encode(msg);
    final sendFn = requireDirectTransport ? sendDirectSignaling : sendSignaling;
    return await sendFn?.call(recipientPubkey, payload) ?? false;
  }

  static Uint8List _hexToBytes(String hex) {
    final bytes = <int>[];
    for (var i = 0; i < hex.length; i += 2) {
      bytes.add(int.parse(hex.substring(i, i + 2), radix: 16));
    }
    return Uint8List.fromList(bytes);
  }

  // ===== Incoming processing (called by MessageRouter via coordinator) =====

  /// Process an incoming signaling packet.
  ///
  /// [senderPubkey] is the authenticated sender from the outer BitchatPacket.
  /// [payload] is the raw signaling payload (type byte + message data).
  void processSignaling(Uint8List senderPubkey, Uint8List payload) {
    final senderHex = _pubkeyToHex(senderPubkey);
    final senderPeer = store.state.peers.getPeerByPubkeyHex(senderHex);
    if (!_isTrustedSignalingSender(senderHex)) {
      debugPrint(
        'Dropping signaling from untrusted sender '
        '${senderHex.substring(0, 8)}...',
      );
      return;
    }

    SignalingMessage msg;
    try {
      msg = codec.decode(payload);
    } catch (e) {
      debugPrint('Failed to decode signaling message: $e');
      return;
    }

    final senderLabel =
        senderPeer?.displayName ??
        'facilitator ${senderHex.substring(0, 8)}...';
    debugPrint('Received signaling from $senderLabel: $msg');

    switch (msg) {
      case AddrQueryMessage():
        _handleAddrQuery(senderPubkey, msg);
      case AddrResponseMessage():
        _handleAddrResponse(senderPubkey, msg);
      case PunchRequestMessage():
        _handlePunchRequest(senderPubkey, senderHex, msg);
      case PunchInitiateMessage():
        _handlePunchInitiate(senderPubkey, msg);
      case PunchReadyMessage():
        _handlePunchReady(senderPubkey, msg);
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

    if (observedIp != null &&
        observedPort != null &&
        claimedIp != null &&
        claimedPort != null) {
      if (claimedIp != observedIp || claimedPort != observedPort) {
        debugPrint(
          'Address mismatch for ${senderHex.substring(0, 8)}...: '
          'claimed $claimedIp:$claimedPort, observed $observedIp:$observedPort — using observed',
        );
      }
    }

    if (InternetAddress.tryParse(effectiveIp) == null) {
      debugPrint(
        'Ignoring malformed friend address for '
        '${senderHex.substring(0, 8)}...: $effectiveIp:$effectivePort',
      );
    } else {
      debugPrint(
        'Address registered via ANNOUNCE: ${senderHex.substring(0, 8)}... → $effectiveIp:$effectivePort',
      );
      addressTable.register(senderHex, effectiveIp, effectivePort);
    }

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
    final entry = _lookupReachableFriendAddress(targetHex);

    // Always respond — even "not found" — so the querier doesn't hang.
    final response = AddrResponseMessage(
      targetPubkey: msg.targetPubkey,
      ip: entry?.ip,
      port: entry?.port,
    );
    final payload = codec.encode(response);
    sendSignaling?.call(senderPubkey, payload);

    debugPrint(
      'Responded to addr query for ${targetHex.substring(0, 8)}...: '
      '${entry != null ? "${entry.ip}:${entry.port}" : "not found"}',
    );
  }

  /// Handle ADDR_RESPONSE: a friend responding to our address query.
  void _handleAddrResponse(Uint8List senderPubkey, AddrResponseMessage msg) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);
    final query = _pendingQueries[targetHex];

    if (query == null) {
      debugPrint(
        'Ignoring unexpected addr response for ${targetHex.substring(0, 8)}...',
      );
      return;
    }

    final senderHex = _pubkeyToHex(senderPubkey);
    if (!query.respondedHexes.add(senderHex)) {
      return;
    }

    query.pendingResponderHexes.remove(senderHex);

    if (msg.found) {
      if (InternetAddress.tryParse(msg.ip!) == null) {
        debugPrint(
          'Ignoring malformed addr response for '
          '${targetHex.substring(0, 8)}...: ${msg.ip}:${msg.port}. '
          'The IP could not be parsed.',
        );
      } else {
        final entry = AddressEntry(
          ip: msg.ip!,
          port: msg.port!,
          registeredAt: DateTime.now(),
        );
        query.positiveResponses.add(
          AddressQueryCandidate(responderPubkey: senderPubkey, entry: entry),
        );
        if (!query.firstMatch.isCompleted) {
          debugPrint(
            'Got address for ${targetHex.substring(0, 8)}...: ${msg.ip}:${msg.port}',
          );
          query.firstMatch.complete(entry);
        }
      }
    } else {
      // Don't complete yet — maybe another friend has the answer.
      debugPrint(
        'Friend reports no address for ${targetHex.substring(0, 8)}...',
      );
    }

    if (query.pendingResponderHexes.isEmpty) {
      _completePendingAddressQuery(targetHex);
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
      debugPrint(
        'Punch request for non-friend target ${targetHex.substring(0, 8)}..., ignoring',
      );
      return;
    }

    // Both must have registered addresses.
    final requesterAddr = _lookupReachableFriendAddress(requesterHex);
    final targetAddr = _lookupReachableFriendAddress(targetHex);

    if (requesterAddr == null) {
      debugPrint(
        'Punch request from ${requesterHex.substring(0, 8)}... but they have no registered address',
      );
      return;
    }
    if (targetAddr == null) {
      debugPrint(
        'Punch request for ${targetHex.substring(0, 8)}... but they have no registered address',
      );
      return;
    }

    debugPrint(
      'Coordinating hole-punch: '
      '${requesterHex.substring(0, 8)}...(${requesterAddr.ip}:${requesterAddr.port}) ↔ '
      '${targetHex.substring(0, 8)}...(${targetAddr.ip}:${targetAddr.port})',
    );

    _pendingPunchCounterparts[requesterHex] = msg.targetPubkey;
    _pendingPunchCounterparts[targetHex] = requesterPubkey;

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
  void _handlePunchInitiate(Uint8List senderPubkey, PunchInitiateMessage msg) {
    debugPrint(
      'Punch initiate: punch toward '
      '${_pubkeyToHex(msg.peerPubkey).substring(0, 8)}... at ${msg.ip}:${msg.port}',
    );
    onPunchInitiate?.call(msg.peerPubkey, msg.ip, msg.port, senderPubkey);
  }

  /// Handle PUNCH_READY: the other peer (via friend) says their NAT is open.
  void _handlePunchReady(Uint8List senderPubkey, PunchReadyMessage msg) {
    final senderHex = _pubkeyToHex(senderPubkey);
    final readyHex = _pubkeyToHex(msg.peerPubkey);

    // If we coordinated a punch between two peers (as a well-connected friend),
    // forward the readiness notification to the counterpart.
    final counterpart = _pendingPunchCounterparts.remove(senderHex);
    if (counterpart != null) {
      final counterpartHex = _pubkeyToHex(counterpart);
      debugPrint(
        'Forwarding punch ready from ${senderHex.substring(0, 8)}... '
        'to ${counterpartHex.substring(0, 8)}...',
      );
      unawaited(sendSignaling?.call(counterpart, codec.encode(msg)));
      return;
    }

    debugPrint('Punch ready from ${readyHex.substring(0, 8)}...');
    onPunchReady?.call(msg.peerPubkey);
  }

  /// Handle ADDR_REFLECT: a well-connected friend telling us our observed address.
  ///
  /// This is the STUN-equivalent for Bitchat. The friend saw our real
  /// NAT-translated address on the incoming UDP connection and is reflecting
  /// it back. We update our public address with this value — it has the
  /// correct external port, unlike our local-port-based guess.
  void _handleAddrReflect(AddrReflectMessage msg) {
    debugPrint('Address reflected by friend: ${msg.ip}:${msg.port}');
    onAddrReflected?.call(msg.ip, msg.port);
  }

  // ===== Lifecycle =====

  void dispose() {
    _staleCleanupTimer?.cancel();
    _staleCleanupTimer = null;

    // Complete any pending queries with null.
    for (final query in _pendingQueries.values) {
      query.timeoutTimer?.cancel();
      if (!query.firstMatch.isCompleted) {
        query.firstMatch.complete(null);
      }
      if (!query.candidates.isCompleted) {
        query.candidates.complete(
          List<AddressQueryCandidate>.unmodifiable(query.positiveResponses),
        );
      }
    }
    _pendingQueries.clear();
    _pendingPunchCounterparts.clear();

    addressTable.clear();
  }

  // ===== Helpers =====

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// Look up a friend's address, preferring the signaling address table.
  ///
  /// The address table is intentionally volatile and can drift during BLE/UDP
  /// handoffs or after app restarts. When it misses, fall back to the trusted
  /// peer state in Redux so signaling can still answer queries and coordinate
  /// punches using the same udpAddress the rest of the app already relies on.
  AddressEntry? _lookupReachableFriendAddress(String pubkeyHex) {
    final tableEntry = addressTable.lookup(pubkeyHex);
    if (tableEntry != null) {
      if (InternetAddress.tryParse(tableEntry.ip) == null) {
        debugPrint(
          'Ignoring malformed address table entry for '
          '${pubkeyHex.substring(0, 8)}...: ${tableEntry.ip}:${tableEntry.port}',
        );
        return null;
      }
      return tableEntry;
    }

    final peer = store.state.peers.getPeerByPubkeyHex(pubkeyHex);
    if (peer == null || !peer.isFriend) return null;

    final udpAddress = peer.udpAddress;
    if (udpAddress == null || udpAddress.isEmpty) return null;

    final parsed = parseAddressString(udpAddress);
    if (parsed == null) return null;

    debugPrint(
      'Address table miss for ${pubkeyHex.substring(0, 8)}...; '
      'falling back to peer state ${parsed.toAddressString()}',
    );

    return AddressEntry(
      ip: parsed.ip.address,
      port: parsed.port,
      registeredAt: DateTime.now(),
    );
  }

  _PendingAddressQuery? _ensurePendingAddressQuery(
    Uint8List targetPubkey,
    String targetHex, {
    required Duration timeout,
  }) {
    final existing = _pendingQueries[targetHex];
    if (existing != null) return existing;

    final facilitators = _trustedFacilitatorPubkeys(
      excludePubkeyHex: targetHex,
    );
    if (facilitators.isEmpty) {
      debugPrint('No trusted facilitators to query (excluding target)');
      return null;
    }

    final query = _PendingAddressQuery(facilitators.map(_pubkeyToHex).toSet());
    _pendingQueries[targetHex] = query;

    debugPrint(
      'Querying ${facilitators.length} trusted facilitator(s) for address '
      'of ${targetHex.substring(0, 8)}...',
    );

    final msg = AddrQueryMessage(targetPubkey: targetPubkey);
    final payload = codec.encode(msg);
    for (final facilitator in facilitators) {
      final facilitatorHex = _pubkeyToHex(facilitator);
      unawaited(
        _sendAddressQueryToFacilitator(
          targetHex: targetHex,
          facilitatorPubkey: facilitator,
          facilitatorHex: facilitatorHex,
          payload: payload,
        ),
      );
    }

    query.timeoutTimer = Timer(timeout, () {
      if (!query.firstMatch.isCompleted) {
        debugPrint(
          'Address query timed out for ${targetHex.substring(0, 8)}...',
        );
      }
      _completePendingAddressQuery(targetHex);
    });

    return query;
  }

  Future<void> _sendAddressQueryToFacilitator({
    required String targetHex,
    required Uint8List facilitatorPubkey,
    required String facilitatorHex,
    required Uint8List payload,
  }) async {
    bool sent = false;
    try {
      sent = await sendSignaling?.call(facilitatorPubkey, payload) ?? false;
    } catch (e) {
      debugPrint(
        'Address query send failed via '
        '${facilitatorHex.substring(0, 8)}...: $e',
      );
    }

    if (sent) return;

    final query = _pendingQueries[targetHex];
    if (query == null) return;
    if (!query.respondedHexes.add(facilitatorHex)) return;

    query.pendingResponderHexes.remove(facilitatorHex);
    debugPrint(
      'Address query could not reach facilitator '
      '${facilitatorHex.substring(0, 8)}... for '
      '${targetHex.substring(0, 8)}...',
    );

    if (query.pendingResponderHexes.isEmpty) {
      _completePendingAddressQuery(targetHex);
    }
  }

  void _completePendingAddressQuery(String targetHex) {
    final query = _pendingQueries.remove(targetHex);
    if (query == null) return;

    query.timeoutTimer?.cancel();
    query.timeoutTimer = null;

    if (!query.firstMatch.isCompleted) {
      query.firstMatch.complete(null);
    }
    if (!query.candidates.isCompleted) {
      query.candidates.complete(
        List<AddressQueryCandidate>.unmodifiable(query.positiveResponses),
      );
    }
  }

  bool _isTrustedSignalingSender(String senderHex) {
    final senderPeer = store.state.peers.getPeerByPubkeyHex(senderHex);
    if (senderPeer != null && senderPeer.isFriend) {
      return true;
    }

    for (final server in store.state.settings.configuredRendezvousServers) {
      if (server.pubkeyHex.isNotEmpty &&
          server.pubkeyHex.toLowerCase() == senderHex) {
        return true;
      }
    }

    return false;
  }

  List<Uint8List> _trustedFacilitatorPubkeys({String? excludePubkeyHex}) {
    final facilitators = <String, Uint8List>{};

    for (final friend in store.state.peers.wellConnectedFriends) {
      final friendHex = _pubkeyToHex(friend.publicKey);
      if (friendHex == excludePubkeyHex) continue;
      facilitators[friendHex] = friend.publicKey;
    }

    for (final server in store.state.settings.configuredRendezvousServers) {
      final normalizedHex = server.pubkeyHex.toLowerCase();
      if (normalizedHex.isEmpty || normalizedHex == excludePubkeyHex) {
        continue;
      }

      try {
        facilitators.putIfAbsent(
          normalizedHex,
          () => _hexToBytes(normalizedHex),
        );
      } catch (e) {
        debugPrint('Ignoring invalid rendezvous pubkey in settings: $e');
      }
    }

    return facilitators.values.toList(growable: false);
  }
}
