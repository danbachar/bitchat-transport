import 'dart:convert';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';

/// Handles Bitchat protocol logic: packet encoding/decoding,
/// ANNOUNCE parsing, MESSAGE handling, etc.
///
/// Pure functions - no state, no I/O, fully testable.
/// Extracted from transport layer to achieve separation of concerns.
class ProtocolHandler {
  final BitchatIdentity identity;
  static const int protocolVersion = 2;

  /// Maximum number of candidates we'll encode in an ANNOUNCE.
  /// 1-byte length field caps it at 255; we won't reasonably advertise that
  /// many addresses, but encoders trim to this limit defensively.
  static const int maxCandidates = 255;

  const ProtocolHandler({required this.identity});

  // ===== Encoding =====

  /// Create ANNOUNCE payload.
  ///
  /// Format:
  /// ```
  /// pubkey(32) + version(2) + nickLen(1) + nick
  ///   + count(1) + repeated[ addrLen(2) + addrBytes ]
  /// ```
  ///
  /// The candidates list carries every address we want peers to consider,
  /// in the order we want them tried. Sending an empty list (count 0) is
  /// valid — used for BLE announcements to non-friends (privacy).
  Uint8List createAnnouncePayload({List<String> candidates = const []}) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final trimmed = candidates.length > maxCandidates
        ? candidates.sublist(0, maxCandidates)
        : candidates;
    final buffer = BytesBuilder();

    // Pubkey (32 bytes)
    buffer.add(identity.publicKey);

    // Protocol version (2 bytes)
    final versionBytes = ByteData(2);
    versionBytes.setUint16(0, protocolVersion, Endian.big);
    buffer.add(versionBytes.buffer.asUint8List());

    // Nickname length (1 byte) + nickname
    buffer.addByte(nicknameBytes.length);
    buffer.add(nicknameBytes);

    // Candidate count (1 byte)
    buffer.addByte(trimmed.length);

    // Candidates
    for (final candidate in trimmed) {
      final addrBytes = Uint8List.fromList(candidate.codeUnits);
      final addrLenBytes = ByteData(2);
      addrLenBytes.setUint16(0, addrBytes.length, Endian.big);
      buffer.add(addrLenBytes.buffer.asUint8List());
      buffer.add(addrBytes);
    }

    return buffer.toBytes();
  }

  /// Create MESSAGE packet
  BitchatPacket createMessagePacket({
    required Uint8List payload,
    Uint8List? recipientPubkey,
  }) {
    return BitchatPacket(
      type: PacketType.message,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Caller must sign before sending
    );
  }

  /// Create READ_RECEIPT packet
  BitchatPacket createReadReceiptPacket({
    required String messageId,
    required Uint8List recipientPubkey,
  }) {
    final payload = utf8.encode(messageId);
    return BitchatPacket(
      type: PacketType.readReceipt,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Caller must sign before sending
    );
  }

  // ===== Decoding =====

  /// Decode ANNOUNCE payload.
  ///
  /// Format:
  /// ```
  /// pubkey(32) + version(2) + nickLen(1) + nick
  ///   + count(1) + repeated[ addrLen(2) + addrBytes ]
  /// ```
  AnnounceData decodeAnnounce(Uint8List data) {
    var offset = 0;

    // Pubkey (32 bytes)
    final pubkey = data.sublist(offset, offset + 32);
    offset += 32;

    // Version (2 bytes)
    final version = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
        .getUint16(0, Endian.big);
    offset += 2;

    // Nickname length (1 byte) + nickname
    final nicknameLength = data[offset];
    offset += 1;
    final nickname = String.fromCharCodes(data.sublist(offset, offset + nicknameLength));
    offset += nicknameLength;

    // Candidate count (1 byte) + repeated candidates
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

  /// Decode READ_RECEIPT payload
  String decodeReadReceipt(Uint8List payload) {
    return utf8.decode(payload);
  }

  /// Create ACK packet (for delivery confirmation)
  BitchatPacket createAckPacket({
    required String messageId,
    Uint8List? recipientPubkey,
  }) {
    final payload = utf8.encode(messageId);
    return BitchatPacket(
      type: PacketType.ack,
      senderPubkey: identity.publicKey,
      recipientPubkey: recipientPubkey,
      payload: payload,
      signature: Uint8List(64), // Caller must sign before sending
    );
  }

  // ===== Signing & Verification =====

  /// Sign a packet with the identity's Ed25519 private key.
  ///
  /// Mutates [packet.signature] in place.
  Future<void> signPacket(BitchatPacket packet) async {
    final algorithm = Ed25519();
    final signableBytes = packet.getSignableBytes();
    final signature = await algorithm.sign(signableBytes, keyPair: identity.keyPair);
    packet.signature = Uint8List.fromList(signature.bytes);
  }

  /// Verify a packet's Ed25519 signature against the sender's public key.
  ///
  /// Returns true if the signature is valid.
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
}

/// Decoded ANNOUNCE data.
///
/// [candidates] is the list of `ip:port` strings the sender wants peers to
/// try, in the order the sender prefers. The receiver classifies each
/// address (link-local vs LAN vs global, v4 vs v6) and picks one according
/// to its own priority policy.
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

  @override
  String toString() =>
      'AnnounceData($nickname, v$protocolVersion, candidates: $candidates)';
}
