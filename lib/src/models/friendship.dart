/// Status of a friendship
enum FriendshipStatus {
  /// Friend request sent, waiting for acceptance
  pending,

  /// Friend request received, waiting for user action
  received,

  /// Friendship established
  accepted,

  /// Friend request declined
  declined,
}

/// Represents a friendship between two users
class Friendship {
  /// The friend's public key in hex format
  final String peerPubkeyHex;

  /// The friend's libp2p multiaddress (if known)
  String? libp2pAddress;

  /// The friend's libp2p host ID (PeerId) for connection
  String? libp2pHostId;

  /// The friend's libp2p addresses for connection
  List<String>? libp2pHostAddrs;

  /// The friend's nickname (if known)
  String? nickname;

  /// The current status of the friendship
  FriendshipStatus status;

  /// When the friendship was created/updated
  DateTime updatedAt;

  /// When the friend request was sent/received
  final DateTime createdAt;

  /// Optional message sent with the friend request
  String? message;

  /// Whether the friend is currently online (via libp2p)
  bool isOnline;

  /// Last time the friend was seen online
  DateTime? lastOnline;

  Friendship({
    required this.peerPubkeyHex,
    this.libp2pAddress,
    this.libp2pHostId,
    this.libp2pHostAddrs,
    this.nickname,
    required this.status,
    DateTime? createdAt,
    DateTime? updatedAt,
    this.message,
    this.isOnline = false,
    this.lastOnline,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  /// Whether this is an established friendship
  bool get isAccepted => status == FriendshipStatus.accepted;

  /// Whether this is a pending friend request we sent
  bool get isPendingOutgoing => status == FriendshipStatus.pending;

  /// Whether this is a pending friend request we received
  bool get isPendingIncoming => status == FriendshipStatus.received;

  /// Display name for the friend
  String get displayName =>
      nickname ?? 'Peer ${peerPubkeyHex.substring(0, 8)}...';

  Map<String, dynamic> toJson() => {
        'peerPubkeyHex': peerPubkeyHex,
        'libp2pAddress': libp2pAddress,
        'libp2pHostId': libp2pHostId,
        'libp2pHostAddrs': libp2pHostAddrs,
        'nickname': nickname,
        'status': status.index,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'message': message,
        'isOnline': isOnline,
        'lastOnline': lastOnline?.toIso8601String(),
      };

  factory Friendship.fromJson(Map<String, dynamic> json) => Friendship(
        peerPubkeyHex: json['peerPubkeyHex'],
        libp2pAddress: json['libp2pAddress'],
        libp2pHostId: json['libp2pHostId'],
        libp2pHostAddrs: json['libp2pHostAddrs'] != null
            ? List<String>.from(json['libp2pHostAddrs'])
            : null,
        nickname: json['nickname'],
        status: FriendshipStatus.values[json['status']],
        createdAt: DateTime.parse(json['createdAt']),
        updatedAt: DateTime.parse(json['updatedAt']),
        message: json['message'],
        isOnline: json['isOnline'] ?? false,
        lastOnline: json['lastOnline'] != null
            ? DateTime.parse(json['lastOnline'])
            : null,
      );

  Friendship copyWith({
    String? libp2pAddress,
    String? libp2pHostId,
    List<String>? libp2pHostAddrs,
    String? nickname,
    FriendshipStatus? status,
    String? message,
    bool? isOnline,
    DateTime? lastOnline,
  }) =>
      Friendship(
        peerPubkeyHex: peerPubkeyHex,
        libp2pAddress: libp2pAddress ?? this.libp2pAddress,
        libp2pHostId: libp2pHostId ?? this.libp2pHostId,
        libp2pHostAddrs: libp2pHostAddrs ?? this.libp2pHostAddrs,
        nickname: nickname ?? this.nickname,
        status: status ?? this.status,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        message: message ?? this.message,
        isOnline: isOnline ?? this.isOnline,
        lastOnline: lastOnline ?? this.lastOnline,
      );
}
