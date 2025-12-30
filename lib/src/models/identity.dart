import 'dart:typed_data';

/// Identity provided by GSG layer to Bitchat transport.
/// 
/// GSG is responsible for:
/// - Generating and persisting the Ed25519 keypair
/// - Passing it to Bitchat at initialization
/// 
/// Bitchat uses this for:
/// - Deriving BLE Service UUID (last 128 bits of pubkey)
/// - Signing packets
/// - Peer identification via ANNOUNCE
class BitchatIdentity {
  /// Ed25519 public key (32 bytes)
  final Uint8List publicKey;
  
  /// Ed25519 private key (64 bytes - seed + public key)
  /// This is kept private and used only for signing
  final Uint8List privateKey;
  
  /// Optional human-readable nickname for ANNOUNCE
  final String? nickname;
  
  BitchatIdentity({
    required this.publicKey,
    required this.privateKey,
    this.nickname,
  }) {
    if (publicKey.length != 32) {
      throw ArgumentError('Public key must be 32 bytes (Ed25519)');
    }
    if (privateKey.length != 64) {
      throw ArgumentError('Private key must be 64 bytes (Ed25519 seed + pubkey)');
    }
  }
  
  /// Derive BLE Service UUID from public key.
  /// Uses the last 128 bits (16 bytes) of the public key.
  String get bleServiceUuid {
    // Take last 16 bytes of the 32-byte public key
    final uuidBytes = publicKey.sublist(16, 32);
    
    // Format as UUID string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    final hex = uuidBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-'
           '${hex.substring(8, 12)}-'
           '${hex.substring(12, 16)}-'
           '${hex.substring(16, 20)}-'
           '${hex.substring(20, 32)}';
  }
  
  /// Get fingerprint (first 8 bytes of SHA-256 hash of public key) for display
  /// Full verification uses the complete public key
  String get shortFingerprint {
    // TODO: Implement SHA-256 hash and take first 8 bytes
    // For now, use first 8 bytes of pubkey as placeholder
    return publicKey.sublist(0, 8)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(':')
        .toUpperCase();
  }
  
  @override
  String toString() => 'BitchatIdentity(${nickname ?? shortFingerprint})';
}
