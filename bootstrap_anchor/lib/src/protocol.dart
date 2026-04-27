import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

import 'identity.dart';
import 'packet.dart';

/// Protocol handler for the bootstrap anchor.
///
/// Handles packet signing, verification, and ANNOUNCE encoding/decoding.
/// Wire-compatible with the Flutter client's ProtocolHandler.
class Protocol {
  final AnchorIdentity identity;
  static const int protocolVersion = 2;

  /// Maximum number of candidates encoded in an ANNOUNCE.
  static const int maxCandidates = 255;

  const Protocol({required this.identity});

  // ===== Signing & Verification =====

  /// Sign a packet with our Ed25519 private key.
  Future<void> signPacket(BitchatPacket packet) async {
    final algorithm = Ed25519();
    final signableBytes = packet.getSignableBytes();
    final signature =
        await algorithm.sign(signableBytes, keyPair: identity.keyPair);
    packet.signature = Uint8List.fromList(signature.bytes);
  }

  /// Verify a packet's Ed25519 signature against the sender's public key.
  Future<bool> verifyPacket(BitchatPacket packet) async {
    try {
      final algorithm = Ed25519();
      final signableBytes = packet.getSignableBytes();
      final publicKey = SimplePublicKey(
        packet.senderPubkey,
        type: KeyPairType.ed25519,
      );
      final signature = Signature(
        packet.signature,
        publicKey: publicKey,
      );
      return await algorithm.verify(signableBytes, signature: signature);
    } catch (e) {
      return false;
    }
  }

  // ===== ANNOUNCE =====

  /// Create ANNOUNCE payload.
  ///
  /// Format:
  /// ```
  /// pubkey(32) + version(2) + nickLen(1) + nick
  ///   + count(1) + repeated[ addrLen(2) + addrBytes ]
  /// ```
  Uint8List createAnnouncePayload({List<String> candidates = const []}) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final trimmed = candidates.length > maxCandidates
        ? candidates.sublist(0, maxCandidates)
        : candidates;
    final buffer = BytesBuilder();

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Protocol version (2 bytes, big-endian)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    // Candidate count (1 byte)
    buffer.addByte(trimmed.length);

    for (final candidate in trimmed) {
      final addrBytes = Uint8List.fromList(candidate.codeUnits);
      final addrLenBytes = ByteData(2);
      addrLenBytes.setUint16(0, addrBytes.length, Endian.big);
      buffer.add(addrLenBytes.buffer.asUint8List());
      buffer.add(addrBytes);
    }

    return buffer.toBytes();
  }

  /// Decode ANNOUNCE payload.
  AnnounceData decodeAnnounce(Uint8List data) {
    var offset = 0;

    final pubkey = data.sublist(offset, offset + 32);
    offset += 32;

    final version = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
        .getUint16(0, Endian.big);
    offset += 2;

    final nicknameLength = data[offset];
    offset += 1;
    final nickname =
        String.fromCharCodes(data.sublist(offset, offset + nicknameLength));
    offset += nicknameLength;

    final candidates = <String>[];
    if (offset < data.length) {
      final count = data[offset];
      offset += 1;
      for (var i = 0; i < count; i++) {
        if (offset + 2 > data.length) break;
        final addrLength =
            ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
                .getUint16(0, Endian.big);
        offset += 2;
        if (offset + addrLength > data.length) break;
        if (addrLength > 0) {
          candidates.add(
              String.fromCharCodes(data.sublist(offset, offset + addrLength)));
        }
        offset += addrLength;
      }
    }

    return AnnounceData(
      publicKey: Uint8List.fromList(pubkey),
      nickname: nickname,
      protocolVersion: version,
      candidates: candidates,
    );
  }

  /// Create an ANNOUNCE packet (broadcast).
  BitchatPacket createAnnouncePacket({List<String> candidates = const []}) {
    final payload = createAnnouncePayload(candidates: candidates);
    return BitchatPacket(
      type: PacketType.announce,
      senderPubkey: identity.publicKey,
      recipientPubkey: null, // broadcast
      payload: payload,
      signature: Uint8List(64), // must sign before sending
    );
  }

  /// Create ACK packet.
  BitchatPacket createAckPacket({
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final payload = Uint8List.fromList(messageId.codeUnits);
    return BitchatPacket(
      type: PacketType.ack,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64),
    );
  }

  /// Create a signaling packet targeting a specific peer.
  BitchatPacket createSignalingPacket({
    required Uint8List recipientPubkey,
    required Uint8List signalingPayload,
  }) {
    return BitchatPacket(
      type: PacketType.signaling,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: signalingPayload,
      signature: Uint8List(64),
    );
  }
}

/// Decoded ANNOUNCE data.
class AnnounceData {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final List<String> candidates;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    this.candidates = const [],
  });

  String get pubkeyHex =>
      publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  @override
  String toString() =>
      'AnnounceData($nickname, v$protocolVersion, candidates: $candidates)';
}
