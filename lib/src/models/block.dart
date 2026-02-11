import 'dart:convert';
import 'dart:typed_data';

/// Block types for the Bitchat protocol
///
/// Note: FriendAnnounce (0x04) was removed - presence is now handled at
/// the transport layer via unified ANNOUNCE messages.
enum BlockType {
  /// Regular text message
  say(0x01),

  /// Friend request with libp2p address
  friendshipOffer(0x02),

  /// Accept friend request with libp2p address
  friendshipAccept(0x03),

  /// Revoke friendship (unfriend)
  friendshipRevoke(0x05);

  final int value;
  const BlockType(this.value);

  static BlockType fromValue(int value) {
    return BlockType.values.firstWhere(
      (t) => t.value == value,
      orElse: () => throw ArgumentError('Unknown block type: $value'),
    );
  }

  /// Check if value is a valid block type
  static bool isValidType(int value) {
    // Valid types: 0x01 (say), 0x02 (friendshipOffer), 0x03 (friendshipAccept), 0x05 (friendshipRevoke)
    // Note: 0x04 (friendAnnounce) is no longer a valid block type
    return value == 0x01 || value == 0x02 || value == 0x03 || value == 0x05;
  }
}

/// A Block represents a message unit in the Bitchat protocol.
///
/// Block types:
/// - Say: Regular text message
/// - FriendshipOffer: Send friend request with libp2p address
/// - FriendshipAccept: Accept friend request with libp2p address
/// - FriendAnnounce: Announce presence to friends over libp2p
abstract class Block {
  /// The type of this block
  BlockType get type;

  /// Serialize the block to bytes for transmission
  Uint8List serialize();

  /// Deserialize a block from bytes
  static Block deserialize(Uint8List data) {
    if (data.isEmpty) {
      throw FormatException('Block data is empty');
    }

    final blockType = BlockType.fromValue(data[0]);
    final payload = data.sublist(1);

    switch (blockType) {
      case BlockType.say:
        return SayBlock.fromPayload(payload);
      case BlockType.friendshipOffer:
        return FriendshipOfferBlock.fromPayload(payload);
      case BlockType.friendshipAccept:
        return FriendshipAcceptBlock.fromPayload(payload);
      case BlockType.friendshipRevoke:
        return FriendshipRevokeBlock.fromPayload(payload);
    }
  }

  /// Try to deserialize, returns null if data is not a valid block
  /// (e.g., legacy plain text message)
  static Block? tryDeserialize(Uint8List data) {
    try {
      // Check if first byte is a valid block type
      if (data.isEmpty) {
        print('[GEVER]############# 📨 Data is empty!!');

        return null;
      }
      final typeValue = data[0];
      if (!BlockType.isValidType(typeValue)) {
        // Not a block - treat as legacy plain text
        print('[GEVER]############# 📨 Data is not a valid block type: $typeValue');
        return null;
      }
      return deserialize(data);
    } catch (e) {
      print("[GEVER]############# 📨 Failed to deserialize block: $e");
      return null;
    }
  }
}

/// A regular text message block
class SayBlock extends Block {
  @override
  BlockType get type => BlockType.say;

  /// The text content of the message
  final String content;

  SayBlock({required this.content});

  @override
  Uint8List serialize() {
    final contentBytes = utf8.encode(content);
    final data = Uint8List(1 + contentBytes.length);
    data[0] = type.value;
    data.setRange(1, data.length, contentBytes);
    return data;
  }

  factory SayBlock.fromPayload(Uint8List payload) {
    return SayBlock(content: utf8.decode(payload));
  }
}

/// A friendship offer block containing the sender's libp2p host info
class FriendshipOfferBlock extends Block {
  @override
  BlockType get type => BlockType.friendshipOffer;

  /// The sender's libp2p host ID (PeerId)
  final String hostId;

  /// The sender's libp2p addresses (list of multiaddrs)
  final List<String> hostAddrs;

  /// Optional message with the friend request
  final String? message;

  /// Computed full multiaddress string combining first address with host ID
  String get fullAddress => hostAddrs.isNotEmpty ? '${hostAddrs.first}/p2p/$hostId' : '/p2p/$hostId';

  FriendshipOfferBlock({
    required this.hostId,
    required this.hostAddrs,
    this.message,
  });

  @override
  Uint8List serialize() {
    // Format: type (1) + hostId_len (2) + hostId + addrs_count (2) + [addr_len (2) + addr]... + message_len (2) + message
    final hostIdBytes = utf8.encode(hostId);
    final addrsBytes = hostAddrs.map((a) => utf8.encode(a)).toList();
    final messageBytes = message != null ? utf8.encode(message!) : Uint8List(0);

    // Calculate total size
    var totalSize = 1 + 2 + hostIdBytes.length + 2;
    for (final addrBytes in addrsBytes) {
      totalSize += 2 + addrBytes.length;
    }
    totalSize += 2 + messageBytes.length;

    final bytes = Uint8List(totalSize);
    final data = ByteData.view(bytes.buffer);
    var offset = 0;

    data.setUint8(offset++, type.value);
    
    // Host ID
    data.setUint16(offset, hostIdBytes.length, Endian.big);
    offset += 2;
    bytes.setRange(offset, offset + hostIdBytes.length, hostIdBytes);
    offset += hostIdBytes.length;

    // Addresses
    data.setUint16(offset, hostAddrs.length, Endian.big);
    offset += 2;
    for (final addrBytes in addrsBytes) {
      data.setUint16(offset, addrBytes.length, Endian.big);
      offset += 2;
      bytes.setRange(offset, offset + addrBytes.length, addrBytes);
      offset += addrBytes.length;
    }

    // Message
    data.setUint16(offset, messageBytes.length, Endian.big);
    offset += 2;
    if (messageBytes.isNotEmpty) {
      bytes.setRange(offset, offset + messageBytes.length, messageBytes);
    }

    return bytes;
  }

  factory FriendshipOfferBlock.fromPayload(Uint8List payload) {
    final data = ByteData.view(payload.buffer, payload.offsetInBytes);
    var offset = 0;

    // Host ID
    final hostIdLen = data.getUint16(offset, Endian.big);
    offset += 2;
    final hostId = utf8.decode(payload.sublist(offset, offset + hostIdLen));
    offset += hostIdLen;

    // Addresses
    final addrsCount = data.getUint16(offset, Endian.big);
    offset += 2;
    final hostAddrs = <String>[];
    for (var i = 0; i < addrsCount; i++) {
      final addrLen = data.getUint16(offset, Endian.big);
      offset += 2;
      hostAddrs.add(utf8.decode(payload.sublist(offset, offset + addrLen)));
      offset += addrLen;
    }

    // Message
    final messageLen = data.getUint16(offset, Endian.big);
    offset += 2;
    String? message;
    if (messageLen > 0) {
      message = utf8.decode(payload.sublist(offset, offset + messageLen));
    }

    return FriendshipOfferBlock(
      hostId: hostId,
      hostAddrs: hostAddrs,
      message: message,
    );
  }
}

/// A friendship accept block containing the accepter's libp2p host info
class FriendshipAcceptBlock extends Block {
  @override
  BlockType get type => BlockType.friendshipAccept;

  /// The accepter's libp2p host ID (PeerId)
  final String hostId;

  /// The accepter's libp2p addresses (list of multiaddrs)
  final List<String> hostAddrs;

  /// Computed full multiaddress string combining first address with host ID
  String get fullAddress => hostAddrs.isNotEmpty ? '${hostAddrs.first}/p2p/$hostId' : '/p2p/$hostId';

  FriendshipAcceptBlock({
    required this.hostId,
    required this.hostAddrs,
  });

  @override
  Uint8List serialize() {
    // Format: type (1) + hostId_len (2) + hostId + addrs_count (2) + [addr_len (2) + addr]...
    final hostIdBytes = utf8.encode(hostId);
    final addrsBytes = hostAddrs.map((a) => utf8.encode(a)).toList();

    // Calculate total size
    var totalSize = 1 + 2 + hostIdBytes.length + 2;
    for (final addrBytes in addrsBytes) {
      totalSize += 2 + addrBytes.length;
    }

    final bytes = Uint8List(totalSize);
    final data = ByteData.view(bytes.buffer);
    var offset = 0;

    data.setUint8(offset++, type.value);
    
    // Host ID
    data.setUint16(offset, hostIdBytes.length, Endian.big);
    offset += 2;
    bytes.setRange(offset, offset + hostIdBytes.length, hostIdBytes);
    offset += hostIdBytes.length;

    // Addresses
    data.setUint16(offset, hostAddrs.length, Endian.big);
    offset += 2;
    for (final addrBytes in addrsBytes) {
      data.setUint16(offset, addrBytes.length, Endian.big);
      offset += 2;
      bytes.setRange(offset, offset + addrBytes.length, addrBytes);
      offset += addrBytes.length;
    }

    return bytes;
  }

  factory FriendshipAcceptBlock.fromPayload(Uint8List payload) {
    try {
      final data = ByteData.view(payload.buffer, payload.offsetInBytes);
      var offset = 0;

      // Host ID
      final hostIdLen = data.getUint16(offset, Endian.big);
      offset += 2;
      print('🤝 FriendshipAcceptBlock.fromPayload: hostIdLen=$hostIdLen, payload.length=${payload.length}');
      final hostId = utf8.decode(payload.sublist(offset, offset + hostIdLen));
      offset += hostIdLen;
      print('🤝 FriendshipAcceptBlock.fromPayload: hostId=$hostId');

      // Addresses
      final addrsCount = data.getUint16(offset, Endian.big);
      offset += 2;
      print('🤝 FriendshipAcceptBlock.fromPayload: addrsCount=$addrsCount');
      final hostAddrs = <String>[];
      for (var i = 0; i < addrsCount; i++) {
        final addrLen = data.getUint16(offset, Endian.big);
        offset += 2;
        final addr = utf8.decode(payload.sublist(offset, offset + addrLen));
        hostAddrs.add(addr);
        offset += addrLen;
        print('🤝 FriendshipAcceptBlock.fromPayload: addr[$i]=$addr');
      }

      print('🤝 FriendshipAcceptBlock.fromPayload: SUCCESS');
      return FriendshipAcceptBlock(
        hostId: hostId,
        hostAddrs: hostAddrs,
      );
    } catch (e, stack) {
      print('🤝 FriendshipAcceptBlock.fromPayload: FAILED - $e');
      print('🤝 Stack: $stack');
      rethrow;
    }
  }
}

/// A friendship revoke block (unfriend notification)
/// 
/// This is sent when a user unfriends someone. The recipient should:
/// 1. Remove the sender from their friend list
/// 2. Delete any stored addresses for the sender
/// 
/// The message is intentionally minimal to not reveal the reason.
class FriendshipRevokeBlock extends Block {
  @override
  BlockType get type => BlockType.friendshipRevoke;

  FriendshipRevokeBlock();

  @override
  Uint8List serialize() {
    // Just the type byte - no additional data needed
    return Uint8List.fromList([type.value]);
  }

  factory FriendshipRevokeBlock.fromPayload(Uint8List payload) {
    // No payload to parse
    return FriendshipRevokeBlock();
  }
}
