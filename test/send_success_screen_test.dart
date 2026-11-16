import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' show Network, NetworkType;
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/send_screen.dart';
import 'package:tibaneapp/services/rpc_service.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

const _from = 'CBcWENrpEfVBcU9gu5b5mdSBsfyzkV8UyPXenSniWS3o';
const _to = '9Geyod8NY1iizHWuyghULybsk4WzE3B3PdBToQQmWPXs';

class _ConfirmationRpc extends RpcService {
  _ConfirmationRpc() : super.real();

  SolanaSignatureStatus status = SolanaSignatureStatus.pending;
  int checks = 0;
  bool closed = false;
  bool unavailable = false;

  @override
  Future<List<SolanaSignatureStatus>> getSignatureStatuses(
    List<String> signatures,
  ) async {
    expect(signatures, ['1234567890abcdefghij']);
    checks++;
    if (unavailable) throw StateError('RPC unavailable');
    return [status];
  }

  @override
  void dispose() {
    closed = true;
    super.dispose();
  }
}

Future<void> _pump(
  WidgetTester tester, {
  String language = 'en',
  Size size = const Size(393, 852),
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      locale: Locale(language),
      theme: TibaneTheme.darkTheme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: SendSuccessScreen(
        symbol: 'SOL',
        fromAddress: _from,
        toAddress: _to,
        txHash: '1234567890abcdefghij',
        net: Network(
          id: 'solana',
          type: NetworkType.solana,
          chainId: 'mainnet',
          name: 'Solana',
          rpc: '',
          currencySymbol: 'SOL',
          currencyDecimals: 9,
          blockExplorer: '',
          testNet: false,
          priority: 0,
          created: DateTime.utc(2026),
          updated: DateTime.utc(2026),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  late _ConfirmationRpc rpc;
  setUp(() {
    rpc = _ConfirmationRpc();
    RpcService.testInstance = rpc;
  });
  tearDown(() => RpcService.testInstance = null);

  testWidgets('submitted send becomes successful after ModChain confirms', (
    tester,
  ) async {
    rpc.unavailable = true;
    await _pump(tester);
    expect(find.text('Transaction submitted'), findsOneWidget);
    rpc.unavailable = false;
    rpc.status = SolanaSignatureStatus.confirmed;
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('Send successful'), findsOneWidget);
    expect(find.text('Transaction submitted'), findsNothing);
    expect(rpc.closed, isTrue);
  });

  testWidgets('on-chain execution error never shows send success', (
    tester,
  ) async {
    rpc.status = SolanaSignatureStatus.failed;
    await _pump(tester);
    expect(find.text('Send failed'), findsOneWidget);
    expect(find.text('Send successful'), findsNothing);
    expect(rpc.closed, isTrue);
  });

  testWidgets('timeout keeps the send submitted and stops checking', (
    tester,
  ) async {
    await _pump(tester);
    await tester.pump(const Duration(seconds: 25));
    expect(find.text('Transaction submitted'), findsOneWidget);
    expect(rpc.closed, isTrue);
    final checks = rpc.checks;
    await tester.pump(const Duration(seconds: 1));
    expect(rpc.checks, checks);
  });

  for (final language in ['en', 'pt', 'fr', 'ja']) {
    for (final size in [const Size(375, 667), const Size(393, 852)]) {
      testWidgets('compact send success in $language at $size', (tester) async {
        await _pump(tester, language: language, size: size);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(SendSuccessScreen)),
        );
        expect(
          tester
              .widget<Text>(find.text(l10n.transactionSubmittedTitle))
              .style!
              .fontSize,
          closeTo(28.6, 0.001),
        );
        for (final label in [l10n.labelFrom, l10n.labelTo]) {
          expect(
            tester.widget<Text>(find.text(label)).style!.fontSize,
            closeTo(13.2, 0.001),
          );
        }
        expect(find.byIcon(Icons.north_east), findsNothing);
        expect(find.text(l10n.transactionSubmittedBody), findsOneWidget);
        expect(find.text(l10n.sendSuccessTitle), findsNothing);
        expect(find.byIcon(Icons.south_west), findsNothing);
        expect(find.byIcon(Icons.ios_share), findsNothing);
        expect(find.text(l10n.sendShareReceipt), findsNothing);
        expect(find.text('CBcWE...iWS3o'), findsOneWidget);
        expect(find.text('9Geyo...mWPXs'), findsOneWidget);
        expect(find.text(_from), findsNothing);
        expect(find.text(_to), findsNothing);
        final explorer = find.text(l10n.viewOnExplorerNamed('Solscan'));
        await tester.ensureVisible(explorer);
        await tester.pumpAndSettle();
        expect(explorer, findsOneWidget);
        expect(find.text(l10n.backToHome), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  testWidgets('shortened addresses still copy their complete value', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add(call.arguments['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await _pump(tester, size: const Size(393, 1200));
    await tester.tap(find.text(abbreviateAccountAddress(_from)));
    await tester.pump();
    await tester.tap(find.text(abbreviateAccountAddress(_to)));
    await tester.pump();
    expect(copied, [_from, _to]);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    expect(rpc.closed, isTrue);
  });
}
