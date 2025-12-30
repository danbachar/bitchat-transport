import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';
import '../models/packet.dart';

/// A cached message waiting for delivery
class CachedMessage {
  final BitchatPacket packet;
  final DateTime cachedAt;
  final Uint8List recipientPubkey;
  int relayCount;
  bool isPriority;
  
  CachedMessage({
    required this.packet,
    required this.recipientPubkey,
    DateTime? cachedAt,
    this.relayCount = 0,
    this.isPriority = false,
  }) : cachedAt = cachedAt ?? DateTime.now();
  
  /// Age of the cached message
  Duration get age => DateTime.now().difference(cachedAt);
}

/// Store-and-forward cache for messages to offline peers.
/// 
/// When a peer is offline, messages destined for them are cached
/// and delivered when they reconnect.
/// 
/// Retention policy (matches Bitchat):
/// - Regular messages: 12 hours
/// - Priority messages (favorite peers): indefinite (until max capacity)
/// - Max cache size: 1000 messages (LRU eviction)
class StoreForwardCache {
  /// Regular message retention time
  static const Duration regularRetention = Duration(hours: 12);
  
  /// Maximum messages to cache per recipient
  static const int maxMessagesPerRecipient = 100;
  
  /// Maximum total cached messages
  static const int maxTotalMessages = 1000;
  
  /// Messages keyed by recipient pubkey (hex string)
  final Map<String, Queue<CachedMessage>> _cache = {};
  
  /// Set of "priority" recipients (messages kept longer)
  final Set<String> _priorityRecipients = {};
  
  /// Total message count
  int _totalCount = 0;
  
  /// Timer for cleanup
  Timer? _cleanupTimer;
  
  /// Callback when messages are ready for delivery
  void Function(Uint8List recipientPubkey, List<BitchatPacket> messages)? 
      onMessagesReady;
  
  StoreForwardCache() {
    _startCleanupTimer();
  }
  
  /// Mark a recipient as priority (e.g., favorite peer)
  void setPriority(Uint8List recipientPubkey, bool isPriority) {
    final key = _pubkeyToHex(recipientPubkey);
    if (isPriority) {
      _priorityRecipients.add(key);
      // Update existing cached messages
      _cache[key]?.forEach((msg) => msg.isPriority = true);
    } else {
      _priorityRecipients.remove(key);
      _cache[key]?.forEach((msg) => msg.isPriority = false);
    }
  }
  
  /// Cache a message for later delivery
  void cache(BitchatPacket packet) {
    if (packet.recipientPubkey == null) {
      // Don't cache broadcasts
      return;
    }
    
    final key = _pubkeyToHex(packet.recipientPubkey!);
    final queue = _cache.putIfAbsent(key, () => Queue<CachedMessage>());
    
    // Check per-recipient limit
    while (queue.length >= maxMessagesPerRecipient) {
      queue.removeFirst();
      _totalCount--;
    }
    
    // Check total limit (LRU eviction)
    while (_totalCount >= maxTotalMessages) {
      _evictOldest();
    }
    
    queue.add(CachedMessage(
      packet: packet,
      recipientPubkey: packet.recipientPubkey!,
      isPriority: _priorityRecipients.contains(key),
    ));
    _totalCount++;
  }
  
  /// Get and remove all cached messages for a recipient
  List<BitchatPacket> retrieve(Uint8List recipientPubkey) {
    final key = _pubkeyToHex(recipientPubkey);
    final queue = _cache.remove(key);
    if (queue == null) return [];
    
    _totalCount -= queue.length;
    return queue.map((m) => m.packet).toList();
  }
  
  /// Check if there are cached messages for a recipient
  bool hasMessages(Uint8List recipientPubkey) {
    final key = _pubkeyToHex(recipientPubkey);
    final queue = _cache[key];
    return queue != null && queue.isNotEmpty;
  }
  
  /// Get count of cached messages for a recipient
  int messageCount(Uint8List recipientPubkey) {
    final key = _pubkeyToHex(recipientPubkey);
    return _cache[key]?.length ?? 0;
  }
  
  /// Total cached messages
  int get totalCount => _totalCount;
  
  /// Number of recipients with cached messages
  int get recipientCount => _cache.length;
  
  /// Evict the oldest non-priority message
  void _evictOldest() {
    CachedMessage? oldest;
    String? oldestKey;
    
    for (final entry in _cache.entries) {
      for (final msg in entry.value) {
        if (msg.isPriority) continue;
        if (oldest == null || msg.cachedAt.isBefore(oldest.cachedAt)) {
          oldest = msg;
          oldestKey = entry.key;
        }
      }
    }
    
    if (oldest != null && oldestKey != null) {
      _cache[oldestKey]!.remove(oldest);
      if (_cache[oldestKey]!.isEmpty) {
        _cache.remove(oldestKey);
      }
      _totalCount--;
    }
  }
  
  /// Remove expired messages
  void _cleanup() {
    final now = DateTime.now();
    final keysToRemove = <String>[];
    
    for (final entry in _cache.entries) {
      entry.value.removeWhere((msg) {
        if (msg.isPriority) return false;
        final expired = now.difference(msg.cachedAt) > regularRetention;
        if (expired) _totalCount--;
        return expired;
      });
      
      if (entry.value.isEmpty) {
        keysToRemove.add(entry.key);
      }
    }
    
    for (final key in keysToRemove) {
      _cache.remove(key);
    }
  }
  
  void _startCleanupTimer() {
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (_) {
      _cleanup();
    });
  }
  
  String _pubkeyToHex(Uint8List pubkey) {
    return pubkey.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
  
  /// Clean up resources
  void dispose() {
    _cleanupTimer?.cancel();
    _cache.clear();
    _totalCount = 0;
  }
}
