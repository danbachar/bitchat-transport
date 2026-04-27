import 'dart:io';
import 'dart:typed_data';

import 'package:bootstrap_anchor/src/address_table.dart';
import 'package:bootstrap_anchor/src/identity.dart';
import 'package:bootstrap_anchor/src/peer_table.dart';
import 'package:bootstrap_anchor/src/protocol.dart';
import 'package:bootstrap_anchor/src/signaling_codec.dart';
import 'package:bootstrap_anchor/src/signaling_handler.dart';
import 'package:test/test.dart';

Future<Protocol> _createProtocol() async {
  final identity = await AnchorIdentity.generate(nickname: 'anchor');
  return Protocol(identity: identity);
}

Uint8List _pubkey(int seed) =>
    Uint8List.fromList(List<int>.generate(32, (i) => (seed + i) & 0xff));

String _hex(Uint8List bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

class _SentSignal {
  final Uint8List recipient;
  final SignalingMessage message;

  const _SentSignal(this.recipient, this.message);
}

void main() {
  group('AddressTable', () {
    test('stores separate IPv4 and IPv6 entries per pubkey', () {
      final table = AddressTable();
      final pubkeyHex = _hex(_pubkey(1));

      table.register(pubkeyHex, '2001:db8::20', 9000);
      table.register(pubkeyHex, '203.0.113.20', 9001);

      final ipv6Entry = table.lookup(
        pubkeyHex,
        family: InternetAddressType.IPv6,
      );
      final ipv4Entry = table.lookup(
        pubkeyHex,
        family: InternetAddressType.IPv4,
      );

      expect(ipv6Entry, isNotNull);
      expect(ipv6Entry!.ip, equals('2001:db8::20'));
      expect(ipv6Entry.port, equals(9000));
      expect(ipv4Entry, isNotNull);
      expect(ipv4Entry!.ip, equals('203.0.113.20'));
      expect(ipv4Entry.port, equals(9001));
      expect(table.length, equals(2));
    });

    test('removeStale preserves protected pubkeys', () {
      final table = AddressTable();
      final livePubkeyHex = _hex(_pubkey(1));
      final stalePubkeyHex = _hex(_pubkey(2));

      table.register(livePubkeyHex, '2001:db8::20', 9000);
      table.register(stalePubkeyHex, '2001:db8::21', 9001);

      table.removeStale(
        Duration.zero,
        protectedPubkeys: {livePubkeyHex},
      );

      expect(table.lookup(livePubkeyHex), isNotNull);
      expect(table.lookup(stalePubkeyHex), isNull);
      expect(table.length, equals(1));
    });
  });

  group('SignalingHandler', () {
    late AddressTable addressTable;
    late PeerTable peerTable;
    late SignalingCodec codec;
    late SignalingHandler handler;
    late List<_SentSignal> sentSignals;
    late Uint8List requesterPubkey;
    late Uint8List targetPubkey;

    setUp(() async {
      addressTable = AddressTable();
      peerTable = PeerTable();
      codec = const SignalingCodec();
      requesterPubkey = _pubkey(1);
      targetPubkey = _pubkey(2);
      handler = SignalingHandler(
        protocol: await _createProtocol(),
        peerTable: peerTable,
        addressTable: addressTable,
        codec: codec,
      );
      sentSignals = <_SentSignal>[];
      handler.sendSignaling = (recipientPubkey, payload) async {
        sentSignals.add(_SentSignal(recipientPubkey, codec.decode(payload)));
        return true;
      };

      peerTable.addVerified(_hex(requesterPubkey), nickname: 'requester');
      peerTable.addVerified(_hex(targetPubkey), nickname: 'target');
    });

    test('processAnnounce reflects the observed address back', () {
      // The signaling handler no longer writes address-table entries itself —
      // those are owned by the anchor server's live-connection tracking.
      // processAnnounce is now only responsible for peer-table bookkeeping
      // and sending an AddrReflect to the peer.
      final announce = AnnounceData(
        publicKey: requesterPubkey,
        nickname: 'requester',
        protocolVersion: 2,
        candidates: const ['[2001:db8::99]:7000'],
      );

      handler.processAnnounce(
        announce,
        observedIp: '2001:db8::10',
        observedPort: 7001,
      );

      expect(
        addressTable.lookup(_hex(requesterPubkey)),
        isNull,
        reason: 'processAnnounce must not touch the address table',
      );

      expect(sentSignals, hasLength(1));
      expect(sentSignals.single.recipient, equals(requesterPubkey));
      final reflect = sentSignals.single.message as AddrReflectMessage;
      expect(reflect.ip, equals('2001:db8::10'));
      expect(reflect.port, equals(7001));
    });

    test('addr query responds with an address matching requester family', () {
      final targetHex = _hex(targetPubkey);
      addressTable.register(targetHex, '2001:db8::20', 9000);
      addressTable.register(targetHex, '203.0.113.20', 9001);

      handler.processSignaling(
        requesterPubkey,
        codec.encode(AddrQueryMessage(targetPubkey: targetPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );

      expect(sentSignals, hasLength(1));
      expect(sentSignals.single.recipient, equals(requesterPubkey));
      final ipv4Response = sentSignals.single.message as AddrResponseMessage;
      expect(ipv4Response.ip, equals('203.0.113.20'));
      expect(ipv4Response.port, equals(9001));

      sentSignals.clear();

      handler.processSignaling(
        requesterPubkey,
        codec.encode(AddrQueryMessage(targetPubkey: targetPubkey)),
        observedIp: '2001:db8::10',
        observedPort: 7000,
      );

      expect(sentSignals, hasLength(1));
      expect(sentSignals.single.recipient, equals(requesterPubkey));
      final ipv6Response = sentSignals.single.message as AddrResponseMessage;
      expect(ipv6Response.ip, equals('2001:db8::20'));
      expect(ipv6Response.port, equals(9000));
    });

    test('punch request only coordinates peers on the same family', () {
      final requesterHex = _hex(requesterPubkey);
      final targetHex = _hex(targetPubkey);

      addressTable.register(requesterHex, '198.51.100.10', 7000);
      addressTable.register(targetHex, '2001:db8::20', 9000);

      handler.processSignaling(
        requesterPubkey,
        codec.encode(PunchRequestMessage(targetPubkey: targetPubkey)),
        observedIp: '198.51.100.10',
        observedPort: 7000,
      );

      expect(sentSignals, isEmpty);
    });
  });
}
