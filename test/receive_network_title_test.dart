import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:libwallet/libwallet.dart' as lw;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/screens/wallet/receive_screen.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/unified_account.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

lw.Network _network(String chain, String name, lw.NetworkType type) =>
    lw.Network(
      id: 'network-$chain',
      type: type,
      chainId: chain,
      name: name,
      rpc: '',
      currencySymbol: '',
      currencyDecimals: 9,
      blockExplorer: '',
      testNet: false,
      priority: 0,
      created: DateTime.utc(2026),
      updated: DateTime.utc(2026),
    );

String _address(String chain) => 'public-$chain-receive-address-for-testing';

class _Accounts implements lw.AccountApi {
  _Accounts(this.network, this.requests);
  final lw.Network network;
  final List<String?> requests;

  @override
  Future<lw.NextAddress> nextAddress(
    String id, {
    bool change = false,
    String? network,
  }) async {
    requests.add(network);
    return lw.NextAddress(
      address: _address(this.network.chainId),
      path: 'm/0/0',
      index: 0,
      chain: 'receive',
    );
  }

  @override
  Future<lw.AddressFormatsResult> addressFormats(
    String id, {
    String? network,
  }) async {
    requests.add(network);
    return lw.AddressFormatsResult(
      chainId: this.network.chainId,
      formats: [
        lw.AddressFormat(
          kind: 'p2pkh',
          name: 'Default',
          address: _address(this.network.chainId),
          path: 'm/0/0',
          isDefault: true,
        ),
      ],
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements lw.LibwalletClient {
  _Client(this.accounts);
  @override
  final lw.AccountApi accounts;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.network);
  final lw.Network? network;
  final addressRequests = <String?>[];

  @override
  lw.Network? get currentNetwork => network;
  @override
  Future<lw.Network?> refreshCurrentNetwork() async => network;
  @override
  Future<lw.LibwalletClient> ensureClient() async =>
      _Client(_Accounts(network!, addressRequests));
}

class _Service extends WalletService {
  _Service(this.backend, this.account);
  final _Backend backend;
  final UnifiedAccount account;
  @override
  LibwalletBackend get libwallet => backend;
  @override
  UnifiedAccount get currentAccount => account;
  @override
  String get publicKey => account.address;
  @override
  void dispose() {
    backend.dispose();
    super.dispose();
  }
}

Future<_Service> _pump(
  WidgetTester tester,
  lw.Network? network, {
  String language = 'en',
  Size size = const Size(393, 852),
  UnifiedAccount? account,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final service = _Service(
    _Backend(network),
    account ??
        UnifiedAccount(
          backend: AccountBackend.inapp,
          chain: network!.type == lw.NetworkType.evm
              ? 'ethereum'
              : network.chainId,
          address: _address(network.chainId),
          label: 'Account',
          accountId: 'account',
          walletId: 'wallet',
          networkId: network.id,
        ),
  );
  addTearDown(service.dispose);
  await tester.pumpWidget(
    ChangeNotifierProvider<WalletService>.value(
      value: service,
      child: MaterialApp(
        locale: Locale(language),
        theme: TibaneTheme.darkTheme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const ReceiveScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return service;
}

void _expectTitleAboveQr(WidgetTester tester, String name) {
  final title = find.byKey(const ValueKey('receive-network-title'));
  final text = tester.widget<Text>(title);
  expect(text.data, name);
  expect(text.style!.color, TibaneColors.orange);
  expect(text.style!.fontWeight, FontWeight.w600);
  expect(
    tester.getBottomLeft(title).dy,
    lessThan(tester.getTopLeft(find.byType(QrImageView)).dy),
  );
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);
  final networks = [
    _network('solana', 'Solana', lw.NetworkType.solana),
    _network('1', 'Ethereum', lw.NetworkType.evm),
    _network('137', 'Polygon', lw.NetworkType.evm),
    _network('tron', 'Tron', lw.NetworkType.tron),
    for (final chain in kBitcoinFamilyChainOrder)
      _network(chain, chainLabel(chain), lw.NetworkType.bitcoin),
  ];

  for (final network in networks) {
    for (final language in ['en', 'pt', 'fr', 'ja']) {
      testWidgets('${network.name} title above its QR in $language', (
        tester,
      ) async {
        final service = await _pump(tester, network, language: language);
        _expectTitleAboveQr(tester, network.name);
        expect(find.text(service.publicKey), findsWidgets);
        if (network.type == lw.NetworkType.bitcoin) {
          expect(service.backend.addressRequests, [network.id, network.id]);
        }
      });
    }
    testWidgets('${network.name} fits a compact screen', (tester) async {
      await _pump(tester, network, size: const Size(320, 568));
      _expectTitleAboveQr(tester, network.name);
    });
  }

  testWidgets('external Solana does not inherit a cached Ethereum title', (
    tester,
  ) async {
    await _pump(
      tester,
      _network('1', 'Ethereum', lw.NetworkType.evm),
      account: const UnifiedAccount(
        backend: AccountBackend.mwa,
        chain: 'solana',
        address: 'public-external-solana-address',
        label: 'External',
      ),
    );
    _expectTitleAboveQr(tester, 'Solana');
  });

  testWidgets('uses the account chain when network metadata is unavailable', (
    tester,
  ) async {
    await _pump(
      tester,
      null,
      account: const UnifiedAccount(
        backend: AccountBackend.inapp,
        chain: 'ethereum',
        address: '0xPublicTestAddress',
        label: 'Ethereum account',
        accountId: 'account',
        walletId: 'wallet',
      ),
    );
    _expectTitleAboveQr(tester, 'Ethereum');
  });
}
