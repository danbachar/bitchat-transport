import 'dart:io';
import 'dart:typed_data';

import 'address_table.dart';
import 'peer_table.dart';
import 'protocol.dart';
import 'signaling_codec.dart';

/// Handles all signaling logic for the rendezvous agent.
///
/// The rendezvous agent is a public service — it accepts cold-call
/// connections from any agent and coordinates hole-punches between
/// agents that can prove they are friends via friendship attestations.
///
/// Authorization model (spec §7.1):
/// - Has no friends list and does not participate in the social graph.
/// - Accepts cold-call connections from any agent.
/// - Verifies friendship proofs to confirm the requesting agents are friends.
/// - Observes connecting agents' addresses via the source IP:port.
/// - Coordinates UDP hole-punches by relaying addresses.
///
/// Currently: The server registers any peer that sends a valid ANNOUNCE
/// and coordinates punches between registered peers. Friendship proof
/// verification is a TODO — for now, any registered peer can request
/// signaling for any other registered peer. This is safe for a private
/// deployment but must be tightened before federation.
///
/// Responsibilities:
/// - Maintains peer-table state from peer ANNOUNCE packets.
/// - Responds to ADDR_QUERY from registered peers.
/// - Coordinates hole-punches between registered peers on PUNCH_REQUEST.
/// - Reflects observed addresses back via ADDR_REFLECT.
/// - Forwards PUNCH_READY between counterparts.
class SignalingHandler {
  final Protocol protocol;
  final PeerTable peerTable;
  final AddressTable addressTable;
  final SignalingCodec codec;

  /// When coordinating a punch, remember the counterpart for PUNCH_READY forwarding.
  final Map<String, Uint8List> _pendingPunchCounterparts = {};

  /// Recently-coordinated punch sessions, keyed by canonical (sorted) pubkey
  /// pair. Lets us drop duplicate PUNCH_REQUEST messages that arrive when
  /// both peers initiate simultaneously — the first request already told both
  /// sides to punch, so re-sending PUNCH_INITIATE just causes redundant punch
  /// rounds and "Unmatched punch ready" noise.
  final Map<String, DateTime> _recentPunchCoordinations = {};

  /// Window during which a repeated coordination request for the same
  /// unordered pair is dropped. Short enough to recover from a real retry
  /// after genuine failure, long enough to absorb a simultaneous initiate.
  static const _punchCoordinationCooldown = Duration(seconds: 15);

  /// Callback to send a signed signaling packet to a peer.
  Future<bool> Function(Uint8List recipientPubkey, Uint8List signalingPayload)?
      sendSignaling;

  SignalingHandler({
    required this.protocol,
    required this.peerTable,
    required this.addressTable,
    this.codec = const SignalingCodec(),
  });

  /// Process an ANNOUNCE received over UDP from a peer.
  ///
  /// Records the peer as verified and reflects its observed address back.
  /// Address-table entries are not touched here — they are owned by the
  /// anchor's live-connection tracking (`_trackPeerConnection` /
  /// peer-disconnect handlers) so they always match the actual live session
  /// and never flip-flop to stale observations (raw packets, zombie sockets).
  ///
  /// TODO: Signaling currently models a single address per peer per family.
  /// We pick the first globally-routable candidate as the canonical address
  /// for the peer record, but ADDR_QUERY / PUNCH_INITIATE should ultimately
  /// surface the full candidate list. Tracked alongside the multi-candidate
  /// migration in the main client.
  void processAnnounce(
    AnnounceData data, {
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = data.pubkeyHex;

    // Register the peer as verified (they sent a valid signed ANNOUNCE)
    peerTable.addVerified(senderHex, nickname: data.nickname);

    // Pick the highest-priority globally-routable candidate as the address
    // we record for this peer.
    String? canonicalAddress;
    for (final addr in data.candidates) {
      if (_isGloballyRoutableAddrString(addr)) {
        canonicalAddress = addr;
        break;
      }
    }

    peerTable.upsert(
      publicKey: data.publicKey,
      nickname: data.nickname,
      pubkeyHex: senderHex,
      udpAddress: canonicalAddress,
    );

    // Reflect observed address back to the peer
    if (observedIp != null && observedPort != null) {
      final reflect = AddrReflectMessage(ip: observedIp, port: observedPort);
      sendSignaling?.call(data.publicKey, codec.encode(reflect));
    }
  }

  /// Whether [addrString] parses as a globally-routable IPv4 or IPv6 address.
  /// Mirrors the client-side classification (without pulling the full
  /// address_utils package into the anchor codebase).
  static bool _isGloballyRoutableAddrString(String addrString) {
    if (addrString.isEmpty) return false;
    String ipPart;
    if (addrString.startsWith('[')) {
      final close = addrString.indexOf(']');
      if (close < 0) return false;
      ipPart = addrString.substring(1, close);
    } else {
      final lastColon = addrString.lastIndexOf(':');
      if (lastColon < 0) return false;
      ipPart = addrString.substring(0, lastColon);
      if (ipPart.contains(':')) return false;
    }
    final ip = InternetAddress.tryParse(ipPart);
    if (ip == null) return false;
    if (ip.isLoopback) return false;
    if (ip.type == InternetAddressType.IPv6) {
      if (ip.isLinkLocal) return false;
      final bytes = ip.rawAddress;
      if (bytes.length != 16) return false;
      if (bytes.every((b) => b == 0)) return false;
      if ((bytes[0] & 0xFE) == 0xFC) return false; // ULA
      if (bytes[0] == 0xFF) return false; // multicast
      return true;
    }
    if (ip.type == InternetAddressType.IPv4) {
      final bytes = ip.rawAddress;
      if (bytes.length != 4) return false;
      final a = bytes[0];
      final b = bytes[1];
      if (a == 0 || a == 10 || a == 127) return false;
      if (a == 100 && b >= 64 && b <= 127) return false; // CGNAT
      if (a == 169 && b == 254) return false; // link-local
      if (a == 172 && b >= 16 && b <= 31) return false;
      if (a == 192 && b == 168) return false;
      if (a >= 224) return false;
      return true;
    }
    return false;
  }

  /// Process an incoming signaling packet.
  void processSignaling(
    Uint8List senderPubkey,
    Uint8List payload, {
    String? observedIp,
    int? observedPort,
  }) {
    final senderHex = _pubkeyToHex(senderPubkey);
    final requesterFamily = _familyForIp(observedIp);

    SignalingMessage msg;
    try {
      msg = codec.decode(payload);
    } catch (e) {
      _log(
          'Failed to decode signaling from ${senderHex.substring(0, 8)}...: $e');
      return;
    }

    final senderName = peerTable.lookupVerified(senderHex)?.nickname ??
        senderHex.substring(0, 8);
    _log('Signaling from $senderName: ${msg.runtimeType}');

    switch (msg) {
      case AddrQueryMessage():
        _handleAddrQuery(
          senderPubkey,
          msg,
          requesterFamily: requesterFamily,
        );
      case AddrResponseMessage():
        _log('Ignoring AddrResponse (server does not query)');
      case PunchRequestMessage():
        _handlePunchRequest(
          senderPubkey,
          senderHex,
          msg,
          requesterFamily: requesterFamily,
        );
      case PunchInitiateMessage():
        _log('Ignoring PunchInitiate (server is well-connected)');
      case PunchReadyMessage():
        _handlePunchReady(senderPubkey, msg);
      case AddrReflectMessage():
        _log('Ignoring AddrReflect (server knows its own address)');
    }
  }

  void _handleAddrQuery(
    Uint8List senderPubkey,
    AddrQueryMessage msg, {
    InternetAddressType? requesterFamily,
  }) {
    final requesterHex = _pubkeyToHex(senderPubkey);
    final targetHex = _pubkeyToHex(msg.targetPubkey);

    // TODO: Verify friendship proof — for now, any registered peer can query.
    // In the spec model, the querier should present a friendship attestation
    // for the target peer.

    final entry = addressTable.lookup(targetHex, family: requesterFamily);
    final response = AddrResponseMessage(
      targetPubkey: msg.targetPubkey,
      ip: entry?.ip,
      port: entry?.port,
    );
    final responsePayload = codec.encode(response);
    sendSignaling?.call(senderPubkey, responsePayload);

    _log('Addr query for ${targetHex.substring(0, 8)}... from '
        '${requesterHex.substring(0, 8)}...: '
        '${entry != null ? "${entry.ip}:${entry.port}" : "not found"}'
        '${requesterFamily != null ? " for ${_familyLabel(requesterFamily)} requester" : ""} '
        '(reply payload=${responsePayload.length}B)');
  }

  void _handlePunchRequest(
    Uint8List requesterPubkey,
    String requesterHex,
    PunchRequestMessage msg, {
    InternetAddressType? requesterFamily,
  }) {
    final targetHex = _pubkeyToHex(msg.targetPubkey);

    // TODO: Verify friendship proof — for now, any registered peer can
    // request a punch to any other registered peer.

    // Deduplicate coordination: if we've already coordinated a punch between
    // this unordered pair in the last few seconds, the other side already got
    // its PUNCH_INITIATE — re-sending just causes redundant punch rounds.
    final sessionKey = _punchSessionKey(requesterHex, targetHex);
    final lastCoordinated = _recentPunchCoordinations[sessionKey];
    final now = DateTime.now();
    if (lastCoordinated != null &&
        now.difference(lastCoordinated) < _punchCoordinationCooldown) {
      _log('Dropping duplicate punch request ${requesterHex.substring(0, 8)}...'
          ' ↔ ${targetHex.substring(0, 8)}... — already coordinated '
          '${now.difference(lastCoordinated).inMilliseconds}ms ago');
      return;
    }

    final requesterAddr =
        addressTable.lookup(requesterHex, family: requesterFamily) ??
            addressTable.lookup(requesterHex);
    final targetAddr = addressTable.lookup(targetHex, family: requesterFamily);

    if (requesterAddr == null) {
      _log('Punch request from ${requesterHex.substring(0, 8)}... '
          'but they have no registered address');
      return;
    }
    if (targetAddr == null) {
      final fallbackTarget = addressTable.lookup(targetHex);
      if (fallbackTarget != null &&
          requesterFamily != null &&
          fallbackTarget.family != requesterFamily) {
        _log('Punch request for ${targetHex.substring(0, 8)}... '
            'cannot be coordinated across families '
            '(${_familyLabel(requesterFamily)} requester, '
            '${_familyLabel(fallbackTarget.family)} target)');
        return;
      }
      _log('Punch request for ${targetHex.substring(0, 8)}... '
          'but they have no registered address');
      return;
    }

    final requesterName = peerTable.lookupVerified(requesterHex)?.nickname ??
        requesterHex.substring(0, 8);
    final targetName = peerTable.lookupVerified(targetHex)?.nickname ??
        targetHex.substring(0, 8);

    _log('Coordinating hole-punch: '
        '$requesterName(${requesterAddr.ip}:${requesterAddr.port}) <-> '
        '$targetName(${targetAddr.ip}:${targetAddr.port})');

    _recentPunchCoordinations[sessionKey] = now;
    _pruneRecentPunchCoordinations(now);

    // Remember counterparts for PUNCH_READY forwarding
    _pendingPunchCounterparts[requesterHex] = msg.targetPubkey;
    _pendingPunchCounterparts[targetHex] = requesterPubkey;

    // Tell requester to punch toward target
    final initiateToRequester = PunchInitiateMessage(
      peerPubkey: msg.targetPubkey,
      ip: targetAddr.ip,
      port: targetAddr.port,
    );
    sendSignaling?.call(requesterPubkey, codec.encode(initiateToRequester));

    // Tell target to punch toward requester
    final initiateToTarget = PunchInitiateMessage(
      peerPubkey: requesterPubkey,
      ip: requesterAddr.ip,
      port: requesterAddr.port,
    );
    sendSignaling?.call(msg.targetPubkey, codec.encode(initiateToTarget));
  }

  void _handlePunchReady(Uint8List senderPubkey, PunchReadyMessage msg) {
    final senderHex = _pubkeyToHex(senderPubkey);

    final counterpart = _pendingPunchCounterparts.remove(senderHex);
    if (counterpart != null) {
      final counterpartHex = _pubkeyToHex(counterpart);
      _log('Forwarding punch ready from ${senderHex.substring(0, 8)}... '
          'to ${counterpartHex.substring(0, 8)}...');
      sendSignaling?.call(counterpart, codec.encode(msg));
      return;
    }

    _log('Unmatched punch ready from ${senderHex.substring(0, 8)}... '
        'for ${_pubkeyToHex(msg.peerPubkey).substring(0, 8)}...');
  }

  // ===== Helpers =====

  /// Canonical (order-independent) key for a punch session between two peers.
  /// A request from A for B and a request from B for A produce the same key.
  static String _punchSessionKey(String a, String b) =>
      a.compareTo(b) <= 0 ? '$a|$b' : '$b|$a';

  void _pruneRecentPunchCoordinations(DateTime now) {
    _recentPunchCoordinations.removeWhere(
      (_, ts) => now.difference(ts) >= _punchCoordinationCooldown,
    );
  }

  static String _pubkeyToHex(Uint8List pubkey) =>
      pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static InternetAddressType? _familyForIp(String? ip) =>
      ip == null ? null : InternetAddress.tryParse(ip)?.type;

  static String _familyLabel(InternetAddressType family) =>
      family == InternetAddressType.IPv6 ? 'IPv6' : 'IPv4';

  void _log(String message) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    print('[$ts] $message');
  }
}
