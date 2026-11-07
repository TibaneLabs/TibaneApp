import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/libwallet_request_bridge.dart';

class _Backend extends LibwalletBackend {
  @override
  bool get hasWallet => true;
  @override
  String get publicKey => '0x0000000000000000000000000000000000000001';
}

class _Client implements LibwalletClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  testWidgets('EVM hex is correctly decoded for transaction review', (
    tester,
  ) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (ctx) {
            context = ctx;
            return const Scaffold();
          },
        ),
      ),
    );
    final backend = _Backend();
    addTearDown(backend.dispose);
    final bridge = LibwalletRequestBridge(
      client: _Client(),
      backend: backend,
      contextProvider: () => context,
    );
    final request = PendingRequest.fromJson({
      'Id': 'offline-audit',
      'Type': 'transaction_sign',
      'Status': 'pending',
      'Host': 'https://offline.invalid',
      'Value': {'chain': 'evm', 'raw': '0x00'},
    });
    final handling = bridge.handle(request);
    await tester.pumpAndSettle();
    expect(decodeTransactionPayload('evm', '0x00'), [0]);
    await tester.tap(find.byType(ExpansionTile));
    await tester.pumpAndSettle();
    expect(find.text('1 bytes\n00'), findsOneWidget);
    // Cancel the fixture; no request can be approved or signed.
    await tester.tap(find.byType(OutlinedButton));
    await tester.pumpAndSettle();
    await handling;
  });
}
