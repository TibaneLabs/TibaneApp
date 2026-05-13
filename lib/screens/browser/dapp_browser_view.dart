import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../services/wallet/libwallet_request_bridge.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

const _kBridge = 'libwalletBridge';
const _kHome = 'https://jup.ag';

class DAppBrowserView extends StatefulWidget {
  const DAppBrowserView({super.key});

  @override
  State<DAppBrowserView> createState() => _DAppBrowserViewState();
}

class _DAppBrowserViewState extends State<DAppBrowserView> {
  late final WebViewController _webview;
  final _urlCtrl = TextEditingController(text: _kHome);

  LibwalletClient? _client;
  LibwalletRequestBridge? _bridge;
  StreamSubscription? _jsEventsSub;
  StreamSubscription? _pendingSub;

  String? _iconDataUrl;
  String _currentUrl = _kHome;
  bool _loading = true;
  bool _canGoBack = false;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _webview = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(TibaneColors.black)
      ..addJavaScriptChannel(_kBridge, onMessageReceived: _onRpc)
      ..setOnConsoleMessage((m) {
        // Surfaces both page console output and any errors thrown by the
        // injected provider script so we can see why a dApp didn't pick
        // up the wallet.
        debugPrint('[webview console] ${m.level.name}: ${m.message}');
      })
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: _onNavigationRequest,
        onPageStarted: (url) {
          if (!mounted) return;
          setState(() {
            _loading = true;
            _currentUrl = url;
            _urlCtrl.text = url;
          });
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          final canBack = await _webview.canGoBack();
          if (!mounted) return;
          setState(() {
            _loading = false;
            _canGoBack = canBack;
          });
          await _injectProvider(url);
        },
      ));
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final wallet = context.read<WalletService>();
    final client = await wallet.libwallet.ensureClient();
    final iconData = await rootBundle.load('assets/app_icon.png');
    final iconB64 = base64Encode(iconData.buffer.asUint8List());

    if (!mounted) return;
    setState(() {
      _client = client;
      _iconDataUrl = 'data:image/png;base64,$iconB64';
      _ready = true;
    });

    _bridge = LibwalletRequestBridge(
      client: client,
      backend: wallet.libwallet,
      contextProvider: () => context,
    );
    _jsEventsSub = client.jsEvents.listen(_onJsEvent);
    _pendingSub = client.pendingRequests.listen((req) => _bridge?.handle(req));

    await _webview.loadRequest(Uri.parse(_kHome));
  }

  @override
  void dispose() {
    _jsEventsSub?.cancel();
    _pendingSub?.cancel();
    _urlCtrl.dispose();
    super.dispose();
  }

  // --- webview navigation ---

  Future<NavigationDecision> _onNavigationRequest(NavigationRequest req) async {
    final uri = Uri.tryParse(req.url);
    if (uri == null) return NavigationDecision.prevent;
    if (uri.scheme == 'http' || uri.scheme == 'https' || uri.scheme == 'about') {
      return NavigationDecision.navigate;
    }
    // mailto, tel, solana:, wallet:, intent:, ... → external
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
    return NavigationDecision.prevent;
  }

  Future<void> _onRpc(JavaScriptMessage msg) async {
    if (_client == null) return;
    final url = _currentUrl;
    Map<String, dynamic> req;
    try {
      req = jsonDecode(msg.message) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('bridge decode failed: $e');
      return;
    }
    final id = req['id'];
    String payload;
    try {
      final result = await _client!.web3.request(
        url: url,
        query: {
          'method': req['method'],
          'params': req['params'],
        },
      );
      payload = jsonEncode({'result': result});
    } on LibwalletException catch (e) {
      payload = jsonEncode({
        'error': {
          'code': int.tryParse(e.code) ?? -32000,
          'message': e.message,
        },
      });
    } catch (e) {
      payload = jsonEncode({
        'error': {'code': -32000, 'message': e.toString()},
      });
    }
    if (!mounted) return;
    await _webview.runJavaScript(
      '__libwalletResolve($id, ${jsonEncode(payload)})',
    );
  }

  void _onJsEvent(JsEvent event) {
    final name = jsonEncode(event.jsEventName);
    final data = jsonEncode(event.data);
    _webview.runJavaScript('__libwalletEvent($name, $data)');
  }

  Future<void> _injectProvider(String host) async {
    if (!_ready || _client == null) {
      debugPrint('skip injection: ready=$_ready client=${_client != null}');
      return;
    }
    try {
      final js = await _client!.web3.injectionScript(
        name: 'Tibane',
        rdns: 'net.tibane.tibaneapp',
        uuid: _freshUuid(),
        icon: _iconDataUrl!,
        bridge: _kBridge,
        host: host,
      );
      await _webview.runJavaScript(js);
      // Probe the provider state from the page side so we can confirm the
      // script actually ran (not just that we sent it).
      await _webview.runJavaScript(
        "console.log('[tibane] provider installed: solana=' + (typeof window.solana !== 'undefined') + ', ethereum=' + (typeof window.ethereum !== 'undefined'));",
      );
    } catch (e) {
      debugPrint('injection failed: $e');
    }
  }

  /// EIP-6963 scopes `uuid` to the page lifetime — fresh v4 per injection.
  /// dApps key the wallet across page loads on `rdns`, which is stable.
  static String _freshUuid() {
    final rng = Random.secure();
    final b = List<int>.generate(16, (_) => rng.nextInt(256));
    b[6] = (b[6] & 0x0f) | 0x40;
    b[8] = (b[8] & 0x3f) | 0x80;
    String h(int i) => b[i].toRadixString(16).padLeft(2, '0');
    return '${h(0)}${h(1)}${h(2)}${h(3)}-${h(4)}${h(5)}-${h(6)}${h(7)}-'
        '${h(8)}${h(9)}-${h(10)}${h(11)}${h(12)}${h(13)}${h(14)}${h(15)}';
  }

  // --- UI ---

  Future<void> _go() async {
    var target = _urlCtrl.text.trim();
    if (target.isEmpty) return;
    if (!target.contains('://')) target = 'https://$target';
    final uri = Uri.tryParse(target);
    if (uri == null) return;
    await _webview.loadRequest(uri);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          color: TibaneColors.dark,
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: _canGoBack ? () => _webview.goBack() : null,
                color: TibaneColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
              Expanded(
                child: TextField(
                  controller: _urlCtrl,
                  textInputAction: TextInputAction.go,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  onSubmitted: (_) => _go(),
                  style: monoStyle(fontSize: 12),
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    fillColor: TibaneColors.darker,
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.lock_outline,
                        size: 14, color: TibaneColors.textDim),
                    prefixIconConstraints:
                        const BoxConstraints(minWidth: 28, minHeight: 14),
                  ),
                ),
              ),
              IconButton(
                icon: Icon(_loading ? Icons.close : Icons.refresh, size: 20),
                onPressed: () => _loading ? null : _webview.reload(),
                color: TibaneColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2),
        Expanded(
          child: _ready
              ? WebViewWidget(controller: _webview)
              : const Center(child: CircularProgressIndicator()),
        ),
      ],
    );
  }
}
