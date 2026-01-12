import 'dart:convert';
import 'dart:typed_data';

/// Block types for the Bitchat protocol
enum BlockType {
  /// Regular text message
  say(0x01),

  /// Friend request with libp2p address
  friendshipOffer(0x02),

  /// Accept friend request with libp2p address
  friendshipAccept(0x03),

  /// Announce presence to friends over libp2p
  friendAnnounce(0x04),

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
    return value >= 0x01 && value <= 0x05;
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
      case BlockType.friendAnnounce:
        return FriendAnnounceBlock.fromPayload(payload);
      case BlockType.friendshipRevoke:
        return FriendshipRevokeBlock.fromPayload(payload);
    }
  }

  /// Try to deserialize, returns null if data is not a valid block
  /// (e.g., legacy plain text message)
  static Block? tryDeserialize(Uint8List data) {
    try {
      // Check if first byte is a valid block type
      if (data.isEmpty) return null;
      final typeValue = data[0];
      if (!BlockType.isValidType(typeValue)) {
        // Not a block - treat as legacy plain text
        return null;
      }
      return deserialize(data);
    } catch (e) {
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

/// A friendship offer block containing the sender's libp2p address
class FriendshipOfferBlock extends Block {
  @override
  BlockType get type => BlockType.friendshipOffer;

  /// The sender's libp2p multiaddress
  final String libp2pAddress;

  /// Optional message with the friend request
  final String? message;

  FriendshipOfferBlock({
    required this.libp2pAddress,
    this.message,
  });

  @override
  Uint8List serialize() {
    // Format: type (1) + address_len (2) + address + message_len (2) + message
    final addressBytes = utf8.encode(libp2pAddress);
    final messageBytes = message != null ? utf8.encode(message!) : Uint8List(0);

    final data =
        ByteData(1 + 2 + addressBytes.length + 2 + messageBytes.length);
    var offset = 0;

    data.setUint8(offset++, type.value);
    data.setUint16(offset, addressBytes.length, Endian.big);
    offset += 2;

    final bytes = data.buffer.asUint8List();
    bytes.setRange(offset, offset + addressBytes.length, addressBytes);
    offset += addressBytes.length;

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

    final addressLen = data.getUint16(offset, Endian.big);
    offset += 2;

    final addressBytes = payload.sublist(offset, offset + addressLen);
    final address = utf8.decode(addressBytes);
    offset += addressLen;

    final messageLen = data.getUint16(offset, Endian.big);
    offset += 2;

    String? message;
    if (messageLen > 0) {
      final messageBytes = payload.sublist(offset, offset + messageLen);
      message = utf8.decode(messageBytes);
    }

    return FriendshipOfferBlock(
      libp2pAddress: address,
      message: message,
    );
  }
}

/// A friendship accept block containing the accepter's libp2p address
class FriendshipAcceptBlock extends Block {
  @override
  BlockType get type => BlockType.friendshipAccept;

  /// The accepter's libp2p multiaddress
  final String libp2pAddress;

  FriendshipAcceptBlock({required this.libp2pAddress});

  @override
  Uint8List serialize() {
    final addressBytes = utf8.encode(libp2pAddress);
    final data = Uint8List(1 + 2 + addressBytes.length);
    final byteData = ByteData.view(data.buffer);

    data[0] = type.value;
    byteData.setUint16(1, addressBytes.length, Endian.big);
    data.setRange(3, 3 + addressBytes.length, addressBytes);

    return data;
  }

  factory FriendshipAcceptBlock.fromPayload(Uint8List payload) {
    final data = ByteData.view(payload.buffer, payload.offsetInBytes);
    final addressLen = data.getUint16(0, Endian.big);
    final addressBytes = payload.sublist(2, 2 + addressLen);
    return FriendshipAcceptBlock(libp2pAddress: utf8.decode(addressBytes));
  }
}

/// A friend announce block for presence over libp2p
class FriendAnnounceBlock extends Block {
  @override
  BlockType get type => BlockType.friendAnnounce;

  /// The sender's libp2p multiaddress
  final String libp2pAddress;

  /// The sender's nickname
  final String nickname;

  /// Whether the sender is coming online or going offline
  final bool isOnline;

  FriendAnnounceBlock({
    required this.libp2pAddress,
    required this.nickname,
    this.isOnline = true,
  });

  @override
  Uint8List serialize() {
    final addressBytes = utf8.encode(libp2pAddress);
    final nicknameBytes = utf8.encode(nickname);

    final data =
        ByteData(1 + 1 + 2 + addressBytes.length + 2 + nicknameBytes.length);
    var offset = 0;

    data.setUint8(offset++, type.value);
    data.setUint8(offset++, isOnline ? 1 : 0);
    data.setUint16(offset, addressBytes.length, Endian.big);
    offset += 2;

    final bytes = data.buffer.asUint8List();
    bytes.setRange(offset, offset + addressBytes.length, addressBytes);
    offset += addressBytes.length;

    data.setUint16(offset, nicknameBytes.length, Endian.big);
    offset += 2;

    bytes.setRange(offset, offset + nicknameBytes.length, nicknameBytes);

    return bytes;
  }

  factory FriendAnnounceBlock.fromPayload(Uint8List payload) {
    final data = ByteData.view(payload.buffer, payload.offsetInBytes);
    var offset = 0;

    final isOnline = data.getUint8(offset++) == 1;
    final addressLen = data.getUint16(offset, Endian.big);
    offset += 2;

    final addressBytes = payload.sublist(offset, offset + addressLen);
    final address = utf8.decode(addressBytes);
    offset += addressLen;

    final nicknameLen = data.getUint16(offset, Endian.big);
    offset += 2;

    final nicknameBytes = payload.sublist(offset, offset + nicknameLen);
    final nickname = utf8.decode(nicknameBytes);

    return FriendAnnounceBlock(
      libp2pAddress: address,
      nickname: nickname,
      isOnline: isOnline,
    );
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
