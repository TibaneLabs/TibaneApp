import 'package:flutter/material.dart';

import 'dapp_browser_view.dart';

/// Browse tab. Pure webview — no wallet gates. Browsing is read-only and
/// must not require the user to unlock anything; the wallet only comes
/// into play when a destination actually requests a signature, at which
/// point the request bridge prompts for unlock just-in-time.
class DAppBrowserScreen extends StatelessWidget {
  const DAppBrowserScreen({super.key});

  @override
  Widget build(BuildContext context) => const DAppBrowserView();
}
