import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:remote_pi_identity/remote_pi_identity.dart';

void main() {
  runApp(const ExampleApp());
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'remote_pi_identity demo',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final OwnerIdentityStore _store = MethodChannelOwnerIdentityStore();
  final _ed25519 = Ed25519();

  OwnerIdentity? _identity;
  bool? _syncAvailable;
  String? _error;
  String _lastEvent = '—';

  @override
  void initState() {
    super.initState();
    _refreshSync();
    _loadFromStore();
    _store.watch().listen(
      (id) {
        if (!mounted) return;
        setState(() {
          _identity = id;
          _lastEvent =
              'watch() emitted at ${DateTime.now().toIso8601String()}';
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _error = 'watch error: $e');
      },
    );
  }

  Future<void> _refreshSync() async {
    try {
      final ok = await _store.isSyncAvailable();
      if (!mounted) return;
      setState(() => _syncAvailable = ok);
    } on IdentityStoreError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'isSyncAvailable: $e');
    }
  }

  Future<void> _loadFromStore() async {
    try {
      final id = await _store.load();
      if (!mounted) return;
      setState(() {
        _identity = id;
        _error = null;
      });
    } on IdentityStoreError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'load: $e');
    }
  }

  Future<void> _generate() async {
    try {
      final keypair = await _ed25519.newKeyPair();
      final pub = await keypair.extractPublicKey();
      final pkBytes = Uint8List.fromList(pub.bytes);
      final skSeed = await keypair.extractPrivateKeyBytes();
      final skBytes = Uint8List.fromList(skSeed);
      final identity = OwnerIdentity(ownerPk: pkBytes, ownerSk: skBytes);
      await _store.save(identity);
      if (!mounted) return;
      setState(() {
        _identity = identity;
        _error = null;
      });
    } on IdentityStoreError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'save: $e');
    }
  }

  Future<void> _delete() async {
    try {
      await _store.delete();
      if (!mounted) return;
      setState(() => _identity = null);
    } on IdentityStoreError catch (e) {
      if (!mounted) return;
      setState(() => _error = 'delete: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final id = _identity;
    return Scaffold(
      appBar: AppBar(title: const Text('Owner identity demo')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: ListView(
          children: [
            _StatusBlock(syncAvailable: _syncAvailable, lastEvent: _lastEvent),
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: _generate,
                  icon: const Icon(Icons.vpn_key),
                  label: const Text('Generate identity'),
                ),
                OutlinedButton.icon(
                  onPressed: _loadFromStore,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Load'),
                ),
                OutlinedButton.icon(
                  onPressed: id == null ? null : _delete,
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('Delete'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (_error != null)
              Card(
                color: Theme.of(context).colorScheme.errorContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              ),
            if (_error != null) const SizedBox(height: 16),
            _IdentityBlock(identity: id),
          ],
        ),
      ),
    );
  }
}

class _StatusBlock extends StatelessWidget {
  final bool? syncAvailable;
  final String lastEvent;
  const _StatusBlock({required this.syncAvailable, required this.lastEvent});

  @override
  Widget build(BuildContext context) {
    final color = syncAvailable == null
        ? Colors.grey
        : (syncAvailable! ? Colors.green : Colors.orange);
    final label = syncAvailable == null
        ? 'checking…'
        : (syncAvailable! ? 'yes' : 'no');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.cloud_sync, color: color),
                const SizedBox(width: 8),
                Text('Sync available: $label'),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              lastEvent,
              style: const TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}

class _IdentityBlock extends StatelessWidget {
  final OwnerIdentity? identity;
  const _IdentityBlock({required this.identity});

  @override
  Widget build(BuildContext context) {
    final id = identity;
    if (id == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(12),
          child: Text('No identity stored. Tap "Generate identity".'),
        ),
      );
    }
    final pkB64 = base64.encode(id.ownerPk);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Owner public key',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 4),
            SelectableText(pkB64, style: const TextStyle(fontSize: 11)),
            const SizedBox(height: 12),
            const Text(
              'Plugin scope is Owner-key sync only — paired peers, mesh '
              'state, and revocation propagation live elsewhere.',
              style: TextStyle(fontSize: 11, color: Colors.black54),
            ),
          ],
        ),
      ),
    );
  }
}
