import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:libwallet/libwallet.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../l10n/l10n.dart';
import '../../services/browser_preferences.dart';
import '../../services/uk_compliance_service.dart';
import '../../services/wallet/libwallet_request_bridge.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';

const _kBridge = 'libwalletBridge';
// UK users get a neutral search engine regardless of the user's
// configured start page — see UkComplianceService.
const _kHomeUk = 'https://duckduckgo.com';

class DAppBrowserView extends StatefulWidget {
  /// Whether the Browse tab is currently active. When false the [WebViewWidget]
  /// is swapped for a placeholder so the platform view is detached and the
  /// webview's RenderThread stops compositing off-screen. The controller and
  /// the loaded page live in State, so they survive the detach.
  final bool active;

  const DAppBrowserView({super.key, this.active = true});

  @override
  State<DAppBrowserView> createState() => _DAppBrowserViewState();
}

class _DAppBrowserViewState extends State<DAppBrowserView> {
  late final WebViewController _webview;
  final _urlCtrl = TextEditingController();

  LibwalletClient? _client;
  LibwalletRequestBridge? _bridge;
  StreamSubscription? _jsEventsSub;
  StreamSubscription? _pendingSub;

  String? _iconDataUrl;
  String _currentUrl = '';
  String _pageTitle = '';
  bool _loading = true;
  bool _canGoBack = false;
  bool _canGoForward = false;
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
      ..setNavigationDelegate(
        NavigationDelegate(
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
            final canFwd = await _webview.canGoForward();
            final title = await _webview.getTitle();
            if (!mounted) return;
            setState(() {
              _loading = false;
              _canGoBack = canBack;
              _canGoForward = canFwd;
              _pageTitle = title ?? '';
            });
            await _injectProvider(url);
          },
        ),
      );
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final wallet = context.read<WalletService>();
    final client = await wallet.libwallet.ensureClient();
    final iconData = await rootBundle.load('assets/app_icon.png');
    final iconB64 = base64Encode(iconData.buffer.asUint8List());

    final home = _resolveStartPage();

    if (!mounted) return;
    setState(() {
      _client = client;
      _iconDataUrl = 'data:image/png;base64,$iconB64';
      _ready = true;
      _currentUrl = home;
      _urlCtrl.text = home;
    });

    _bridge = LibwalletRequestBridge(
      client: client,
      backend: wallet.libwallet,
      contextProvider: () => context,
      onTxCommitted: wallet.notifyTxCommitted,
    );
    _jsEventsSub = client.jsEvents.listen(_onJsEvent);
    _pendingSub = client.pendingRequests.listen((req) => _bridge?.handle(req));

    await _webview.loadRequest(Uri.parse(home));
  }

  /// Resolved start page for the current session. UK users always go
  /// to a neutral search engine for FCA compliance, regardless of
  /// their configured preference.
  String _resolveStartPage() {
    final uk = context.read<UkComplianceService>();
    if (uk.isUk) return _kHomeUk;
    final prefs = context.read<BrowserPreferences>();
    final s = prefs.startPage.trim();
    return s.isEmpty ? kDefaultBrowserStartPage : s;
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
    if (uri.scheme == 'http' ||
        uri.scheme == 'https' ||
        uri.scheme == 'about') {
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
        query: {'method': req['method'], 'params': req['params']},
      );
      payload = jsonEncode({'result': result});
    } on LibwalletException catch (e) {
      payload = jsonEncode({
        'error': {'code': int.tryParse(e.code) ?? -32000, 'message': e.message},
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
    final target = _urlCtrl.text.trim();
    if (target.isEmpty) return;
    final uri = _resolveBarInput(target);
    if (uri == null) return;
    await _webview.loadRequest(uri);
  }

  /// Decide whether bar input is a URL or a search query. Chrome's rule
  /// of thumb: any whitespace → search; a token with at least one dot →
  /// hostname; everything else → search. Search routes to DuckDuckGo
  /// (https://duckduckgo.com/?q=...).
  Uri? _resolveBarInput(String raw) {
    // Explicit scheme — use as-is.
    if (raw.contains('://')) return Uri.tryParse(raw);
    // Whitespace = search query.
    final hasWhitespace = raw.contains(RegExp(r'\s'));
    if (!hasWhitespace) {
      // Looks like a host if it has a dot and no obvious "you mean a
      // sentence" punctuation. Allow localhost / IPv4 / TLDs.
      final looksLikeHost =
          raw.contains('.') ||
          raw.startsWith('localhost') ||
          raw.startsWith('127.0.0.1');
      if (looksLikeHost) {
        return Uri.tryParse('https://$raw');
      }
    }
    // Otherwise search.
    final q = Uri.encodeQueryComponent(raw);
    return Uri.parse('https://duckduckgo.com/?q=$q');
  }

  @override
  Widget build(BuildContext context) {
    // Watch BrowserPreferences so the star icon updates the moment a
    // favorite is added or removed from the current page.
    final prefs = context.watch<BrowserPreferences>();
    final isFav = _currentUrl.isNotEmpty && prefs.isFavorite(_currentUrl);

    return Column(
      children: [
        Container(
          color: TibaneColors.dark,
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: context.l10n.actionBack,
                icon: const Icon(Icons.arrow_back, size: 20),
                onPressed: _canGoBack ? () => _webview.goBack() : null,
                color: TibaneColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: context.l10n.browserForward,
                icon: const Icon(Icons.arrow_forward, size: 20),
                onPressed:
                    _canGoForward ? () => _webview.goForward() : null,
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
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(8),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: TibaneColors.textDim,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 14,
                    ),
                    suffixIcon: IconButton(
                      tooltip: isFav
                          ? context.l10n.browserRemoveFromFavorites
                          : context.l10n.browserAddToFavorites,
                      icon: Icon(
                        isFav ? Icons.star : Icons.star_border,
                        size: 18,
                        color: isFav
                            ? TibaneColors.orange
                            : TibaneColors.textDim,
                      ),
                      onPressed: _currentUrl.isEmpty
                          ? null
                          : () => prefs.toggleFavorite(
                                url: _currentUrl,
                                title: _pageTitle,
                              ),
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 28,
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: context.l10n.browserFavorites,
                icon: const Icon(Icons.bookmarks_outlined, size: 20),
                onPressed: _openFavorites,
                color: TibaneColors.textMuted,
                visualDensity: VisualDensity.compact,
              ),
              IconButton(
                tooltip: _loading ? context.l10n.actionCancel : context.l10n.actionRefresh,
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
          child: !_ready
              ? const Center(child: CircularProgressIndicator())
              : widget.active
                  ? WebViewWidget(controller: _webview)
                  // Off-screen: drop the platform view so the native webview's
                  // RenderThread stops compositing. The controller + page state
                  // are retained, so switching back re-attaches the live page.
                  : const ColoredBox(color: TibaneColors.black),
        ),
      ],
    );
  }

  Future<void> _openFavorites() async {
    final picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: TibaneColors.dark,
      isScrollControlled: true,
      builder: (ctx) => _FavoritesSheet(
        startPage: _resolveStartPage(),
      ),
    );
    if (picked == null) return;
    final uri = Uri.tryParse(picked);
    if (uri == null) return;
    await _webview.loadRequest(uri);
  }
}

/// Bottom-sheet list of favorites + a pinned "Start page" entry at the
/// top so the user can always jump back to their configured home in
/// one tap. Returns the URL the user picked (or null on dismiss).
class _FavoritesSheet extends StatelessWidget {
  final String startPage;

  const _FavoritesSheet({required this.startPage});

  @override
  Widget build(BuildContext context) {
    final prefs = context.watch<BrowserPreferences>();
    final favs = prefs.favorites;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: TibaneColors.textDim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(
                context.l10n.browserFavorites,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 8),
            _FavoriteTile(
              icon: Icons.home_outlined,
              title: context.l10n.browserStartPage,
              subtitle: startPage,
              onTap: () => Navigator.of(context).pop(startPage),
            ),
            if (favs.isNotEmpty) ...[
              const Divider(color: TibaneColors.dark, height: 16),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: favs.length,
                  itemBuilder: (_, i) {
                    final f = favs[i];
                    return _FavoriteTile(
                      icon: Icons.star,
                      iconColor: TibaneColors.orange,
                      title: f.title.isEmpty ? f.url : f.title,
                      subtitle: f.url,
                      onTap: () => Navigator.of(context).pop(f.url),
                      onDelete: () => prefs.removeFavoriteByUrl(f.url),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FavoriteTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _FavoriteTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.iconColor,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
        child: Row(
          children: [
            Icon(icon, size: 20, color: iconColor ?? TibaneColors.textMuted),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: TibaneColors.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            if (onDelete != null)
              IconButton(
                tooltip: context.l10n.actionRemove,
                icon: const Icon(Icons.close, size: 18),
                onPressed: onDelete,
                color: TibaneColors.textDim,
                visualDensity: VisualDensity.compact,
              ),
          ],
        ),
      ),
    );
  }
}
