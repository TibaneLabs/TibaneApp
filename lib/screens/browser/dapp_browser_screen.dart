import 'package:flutter/material.dart';

import 'dapp_browser_view.dart';

/// Browse tab. Pure webview — no wallet gates. Browsing is read-only and
/// must not require the user to unlock anything; the wallet only comes
/// into play when a destination actually requests a signature, at which
/// point the request bridge prompts for unlock just-in-time.
class DAppBrowserScreen extends StatelessWidget {
  /// Whether the Browse tab is the currently-selected tab. When false the
  /// underlying [WebViewWidget] is detached so its native RenderThread stops
  /// compositing off-screen; the [WebViewController] and the loaded page
  /// survive (they're owned by the view's State), so returning re-attaches the
  /// live page instantly.
  final bool active;

  const DAppBrowserScreen({super.key, this.active = true});

  @override
  Widget build(BuildContext context) => DAppBrowserView(active: active);
}
