import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart' show WcSession;
import 'package:provider/provider.dart';

import '../../constants/solana_constants.dart';
import '../../main.dart' show rootNavigatorKey;
import '../../services/wallet/walletconnect_bridge.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/tibane_card.dart';

/// WalletConnect v2 hub. Lets the user start the relay (if not already
/// running), paste a `wc:` URI to pair with a dApp, and view / disconnect
/// active sessions.
class WalletConnectSessionsScreen extends StatefulWidget {
  const WalletConnectSessionsScreen({super.key});

  @override
  State<WalletConnectSessionsScreen> createState() =>
      _WalletConnectSessionsScreenState();
}

class _WalletConnectSessionsScreenState
    extends State<WalletConnectSessionsScreen> {
  WalletConnectBridge? _bridge;
  List<WcSession>? _sessions;
  bool _loading = true;
  bool _starting = false;
  String? _error;
  final _uriCtrl = TextEditingController();
  bool _pairing = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  @override
  void dispose() {
    _bridge?.removeListener(_onBridgeChanged);
    _uriCtrl.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final wallet = context.read<WalletService>();
    try {
      final bridge = await wallet.walletConnect(rootNavigatorKey);
      bridge.addListener(_onBridgeChanged);
      if (!mounted) return;
      setState(() => _bridge = bridge);
      // Auto-start if a project id is configured.
      if (!bridge.isStarted && walletConnectProjectId.isNotEmpty) {
        await _start();
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  void _onBridgeChanged() {
    if (!mounted) return;
    setState(() {});
    _refresh();
  }

  Future<void> _start() async {
    final bridge = _bridge;
    if (bridge == null) return;
    setState(() => _starting = true);
    final ok = await bridge.start(projectId: walletConnectProjectId);
    if (!mounted) return;
    setState(() => _starting = false);
    if (!ok && bridge.error != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(bridge.error!)));
    }
  }

  Future<void> _refresh() async {
    final bridge = _bridge;
    if (bridge == null || !bridge.isStarted) {
      if (!mounted) return;
      setState(() {
        _sessions = const [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    final list = await bridge.sessions();
    if (!mounted) return;
    setState(() {
      _sessions = list;
      _loading = false;
    });
  }

  Future<void> _pasteAndPair() async {
    final data = await Clipboard.getData('text/plain');
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Clipboard is empty')));
      return;
    }
    _uriCtrl.text = text;
    await _pair();
  }

  Future<void> _pair() async {
    final bridge = _bridge;
    final uri = _uriCtrl.text.trim();
    if (bridge == null || uri.isEmpty) return;
    if (!uri.startsWith('wc:')) {
      setState(() => _error = 'URI must start with "wc:"');
      return;
    }
    setState(() {
      _pairing = true;
      _error = null;
    });
    final topic = await bridge.pair(uri);
    if (!mounted) return;
    setState(() {
      _pairing = false;
      if (topic == null) {
        _error = bridge.error ?? 'Pair failed';
      } else {
        _uriCtrl.clear();
      }
    });
    if (topic != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Pairing in progress — wait for the dApp to send a '
            'session proposal',
          ),
        ),
      );
    }
  }

  Future<void> _disconnect(WcSession s) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: TibaneColors.card,
        title: const Text('Disconnect session?'),
        content: Text(
          'Disconnect from "${s.peerName.isNotEmpty ? s.peerName : s.topic}"?',
          style: const TextStyle(color: TibaneColors.textMuted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Disconnect',
              style: TextStyle(color: TibaneColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _bridge?.disconnect(s.topic);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final bridge = _bridge;
    final notConfigured = walletConnectProjectId.isEmpty;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(
        title: const Text('WalletConnect'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
          child: ListView(
            children: [
              if (notConfigured)
                _Banner(
                  icon: Icons.warning_amber_outlined,
                  title: 'No project id configured',
                  body:
                      'Set `walletConnectProjectId` in lib/constants/solana_'
                      'constants.dart to a project id from cloud.walletconnect'
                      '.com to enable pairing.',
                )
              else if (bridge == null)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: CircularProgressIndicator(
                      color: TibaneColors.orange,
                    ),
                  ),
                )
              else if (!bridge.isStarted)
                Column(
                  children: [
                    _Banner(
                      icon: Icons.power_settings_new,
                      title: 'Relay offline',
                      body:
                          bridge.error ??
                          'Start the relay to begin pairing with dApps.',
                    ),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: _starting ? null : _start,
                      style: FilledButton.styleFrom(
                        backgroundColor: TibaneColors.orange,
                        foregroundColor: TibaneColors.black,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                      ),
                      icon: const Icon(Icons.play_arrow),
                      label: Text(_starting ? 'Starting…' : 'Start relay'),
                    ),
                  ],
                )
              else ...[
                _SectionLabel('Pair with a dApp'),
                const SizedBox(height: 8),
                TextField(
                  controller: _uriCtrl,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: 'wc:… URI',
                    suffixIcon: IconButton(
                      tooltip: 'Paste from clipboard',
                      icon: const Icon(Icons.paste, size: 18),
                      onPressed: _pasteAndPair,
                    ),
                  ),
                  style: monoStyle(fontSize: 13),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: _pairing ? null : _pair,
                        style: FilledButton.styleFrom(
                          backgroundColor: TibaneColors.orange,
                          foregroundColor: TibaneColors.black,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: Text(_pairing ? 'Pairing…' : 'Pair'),
                      ),
                    ),
                  ],
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.error),
                  ),
                ],
                const SizedBox(height: 20),
                _SectionLabel('Sessions'),
                const SizedBox(height: 8),
                if (_loading)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: CircularProgressIndicator(
                        color: TibaneColors.orange,
                      ),
                    ),
                  )
                else if ((_sessions ?? const []).isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'No active sessions.',
                      style: TextStyle(color: TibaneColors.textMuted),
                    ),
                  )
                else
                  ...(_sessions!).map(
                    (s) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _SessionRow(
                        session: s,
                        onDisconnect: () => _disconnect(s),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;

  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text.toUpperCase(),
    style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
  );
}

class _Banner extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;

  const _Banner({required this.icon, required this.title, required this.body});

  @override
  Widget build(BuildContext context) => TibaneCard(
    padding: const EdgeInsets.all(14),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: TibaneColors.textMuted, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: TibaneColors.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SessionRow extends StatelessWidget {
  final WcSession session;
  final VoidCallback onDisconnect;

  const _SessionRow({required this.session, required this.onDisconnect});

  @override
  Widget build(BuildContext context) {
    final name = session.peerName.isNotEmpty ? session.peerName : '(unknown)';
    final url = (session.peerMetadata['url'] as String?) ?? '';
    return TibaneCard(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: TibaneColors.orange.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.link, color: TibaneColors.orange, size: 16),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 15,
                  ),
                ),
                if (url.isNotEmpty)
                  Text(
                    url,
                    style: monoStyle(
                      fontSize: 11,
                      color: TibaneColors.textMuted,
                    ),
                  ),
                Text(
                  'state: ${session.state}',
                  style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Disconnect',
            icon: const Icon(Icons.close, size: 18),
            color: TibaneColors.error,
            onPressed: onDisconnect,
          ),
        ],
      ),
    );
  }
}
