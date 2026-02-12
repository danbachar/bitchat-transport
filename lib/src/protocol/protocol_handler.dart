import 'dart:convert';
import 'dart:typed_data';
import 'package:bitchat_transport/src/models/identity.dart';
import 'package:bitchat_transport/src/models/packet.dart';

/// Handles Bitchat protocol logic: packet encoding/decoding,
/// ANNOUNCE parsing, MESSAGE handling, etc.
///
/// Pure functions - no state, no I/O, fully testable.
/// Extracted from transport layer to achieve separation of concerns.
class ProtocolHandler {
  final BitchatIdentity identity;
  static const int protocolVersion = 1;

  const ProtocolHandler({required this.identity});

  // ===== Encoding =====

  /// Create ANNOUNCE payload
  ///
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrLen(2) + addr?]
  ///
  /// The address field is only populated when sending to friends.
  /// For non-friends or broadcast, addrLen is 0.
  Uint8List createAnnouncePayload({String? address}) {
    final nicknameBytes = Uint8List.fromList(identity.nickname.codeUnits);
    final addressBytes = address != null ? Uint8List.fromList(address.codeUnits) : Uint8List(0);
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

    // Address length (2 bytes) + address
    final addrLenBytes = ByteData(2);
    addrLenBytes.setUint16(0, addressBytes.length, Endian.big);
    buffer.add(addrLenBytes.buffer.asUint8List());
    if (addressBytes.isNotEmpty) {
      buffer.add(addressBytes);
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
      signature: Uint8List(64), // TODO: Sign packet
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
      signature: Uint8List(64), // TODO: Sign packet
    );
  }

  // ===== Decoding =====

  /// Decode ANNOUNCE payload
  ///
  /// Format: [pubkey(32) + version(2) + nickLen(1) + nick + addrLen(2) + addr?]
  /// Returns: AnnounceData with public key, nickname, version, and optional address
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

    // Address length (2 bytes) + address (optional - may not exist in old payloads)
    String? address;
    if (offset + 2 <= data.length) {
      final addrLength = ByteData.view(data.buffer, data.offsetInBytes + offset, 2)
          .getUint16(0, Endian.big);
      offset += 2;
      if (addrLength > 0 && offset + addrLength <= data.length) {
        address = String.fromCharCodes(data.sublist(offset, offset + addrLength));
      }
    }

    return AnnounceData(
      publicKey: Uint8List.fromList(pubkey),
      nickname: nickname,
      protocolVersion: version,
      libp2pAddress: address,
    );
  }

  /// Decode READ_RECEIPT payload
  String decodeReadReceipt(Uint8List payload) {
    return utf8.decode(payload);
  }

  // ===== Validation (TODO) =====

  /// Verify packet signature
  Future<bool> verifyPacket(BitchatPacket packet) async {
    // TODO: Implement signature verification when encryption is added
    return true;
  }

  /// Sign packet
  Future<void> signPacket(BitchatPacket packet) async {
    // TODO: Implement packet signing when encryption is added
  }
}

/// Decoded ANNOUNCE data
class AnnounceData {
  final Uint8List publicKey;
  final String nickname;
  final int protocolVersion;
  final String? libp2pAddress;

  const AnnounceData({
    required this.publicKey,
    required this.nickname,
    required this.protocolVersion,
    this.libp2pAddress,
  });

  @override
  String toString() => 'AnnounceData($nickname, v$protocolVersion${libp2pAddress != null ? ", addr: $libp2pAddress" : ""})';
}
