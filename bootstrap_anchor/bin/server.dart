import 'dart:io';
import 'package:bootstrap_anchor/bootstrap_anchor.dart';
import 'package:args/args.dart';

void main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('identity',
        abbr: 'i',
        defaultsTo: 'identity.json',
        help: 'Path to identity file (created on first run)')
    ..addOption('ipv6-port',
        abbr: 'p', defaultsTo: '9516', help: 'IPv6 UDP port. Defaults to 9516.')
    ..addOption('port', hide: true, help: 'Deprecated alias for --ipv6-port')
    ..addOption('nickname',
        abbr: 'n',
        defaultsTo: 'rendezvous',
        help: 'Server nickname for ANNOUNCE')
    ..addOption('announce-interval',
        defaultsTo: '30', help: 'ANNOUNCE interval in seconds')
    ..addOption('family',
        defaultsTo: 'dual',
        allowed: ['auto', 'dual', 'ipv6', 'ipv4'],
        help: 'UDP listener mode (dual binds IPv6 and IPv4 on separate ports)')
    ..addOption('ipv4-port',
        defaultsTo: '9514', help: 'IPv4 UDP port. Defaults to 9514.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    print('Error: $e\n');
    print('GLP Rendezvous Server\n');
    print(parser.usage);
    exit(1);
  }

  if (results['help'] as bool) {
    print('GLP Rendezvous Server');
    print('');
    print('A lightweight agent that coordinates hole-punching between peers.');
    print('It has its own independent identity and serves any pair of agents');
    print('that can prove they are friends via friendship attestations.');
    print('');
    print('Usage:');
    print('  bootstrap_anchor [options]');
    print('');
    print(parser.usage);
    print('');
    print('On first run, an Ed25519 keypair is generated and saved to the');
    print('identity file. Share the public key with agents that should use');
    print('this server as a rendezvous point.');
    exit(0);
  }

  final identityPath = results['identity'] as String;
  final legacyIpv6Port = results['port'] as String?;
  final ipv6Port = int.parse(
    legacyIpv6Port ?? (results['ipv6-port'] as String),
  );
  final nickname = results['nickname'] as String;
  final announceInterval = int.parse(results['announce-interval'] as String);
  final bindMode = switch (results['family'] as String) {
    'dual' => AnchorBindMode.dual,
    'ipv6' => AnchorBindMode.ipv6,
    'ipv4' => AnchorBindMode.ipv4,
    _ => AnchorBindMode.auto,
  };
  final ipv4Port = int.parse(results['ipv4-port'] as String);

  final server = AnchorServer(
    ipv6Port: ipv6Port,
    ipv4Port: ipv4Port,
    nickname: nickname,
    identityPath: identityPath,
    announceIntervalSeconds: announceInterval,
    bindMode: bindMode,
  );

  // Graceful shutdown
  ProcessSignal.sigint.watch().listen((_) async {
    print('\nShutting down...');
    await server.stop();
    exit(0);
  });
  ProcessSignal.sigterm.watch().listen((_) async {
    print('\nShutting down...');
    await server.stop();
    exit(0);
  });

  await server.start();
}
