import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';
import 'package:tibaneapp/constants/solana_constants.dart';
import 'package:tibaneapp/l10n/gen/app_localizations.dart';
import 'package:tibaneapp/models/staking_pool.dart';
import 'package:tibaneapp/screens/staking/staking_pools_screen.dart';
import 'package:tibaneapp/services/chiefstaker_api.dart';
import 'package:tibaneapp/services/rpc_service.dart';
import 'package:tibaneapp/services/solana_common.dart';
import 'package:tibaneapp/services/staking_positions.dart';
import 'package:tibaneapp/services/uk_compliance_service.dart';
import 'package:tibaneapp/services/wallet_service.dart';
import 'package:tibaneapp/theme/tibane_theme.dart';

String _key(int value) =>
    base58Encode(Uint8List.fromList(List.filled(32, value)));

final _owner = _key(1);
final _poolAddress = _key(2);

StakingPool _pool() => StakingPool(
  address: _poolAddress,
  mint: wsolMint,
  tokenVault: _key(3),
  authority: _key(4),
  totalStaked: BigInt.from(1000000),
  sumStakeExp: BigInt.zero,
  tauSeconds: BigInt.from(100),
  baseTime: BigInt.zero,
  accRewardPerWeightedShare: BigInt.from(1000000000) * BigInt.from(1000000000),
  lastUpdateTime: BigInt.zero,
  bump: 0,
  lastSyncedLamports: BigInt.zero,
  minStakeAmount: BigInt.zero,
  lockDurationSeconds: BigInt.zero,
  unstakeCooldownSeconds: BigInt.zero,
  initialBaseTime: BigInt.zero,
);

UserStake _stake(String owner) => UserStake(
  owner: owner,
  pool: _poolAddress,
  amount: BigInt.from(1000000),
  stakeTime: BigInt.zero,
  expStartFactor: BigInt.zero,
  rewardDebt: BigInt.zero,
  bump: 0,
  unstakeRequestAmount: BigInt.zero,
  unstakeRequestTime: BigInt.zero,
  lastStakeTime: BigInt.zero,
  baseTimeSnapshot: BigInt.zero,
  totalRewardsClaimed: BigInt.zero,
  claimedRewardsWad: BigInt.zero,
);

class _Directory extends ChiefStakerApi {
  _Directory() : super.real();

  @override
  Future<List<StakingPool>> listPools({int perPage = 100}) async => [
    _pool()
      ..tokenName = 'Fixture staking token'
      ..tokenSymbol = 'FIX',
  ];
}

class _Rpc extends RpcService {
  _Rpc() : super.real();
  final owners = <String>[];
  SolanaSignatureStatus status = SolanaSignatureStatus.confirmed;

  @override
  Future<List<UserStake>> getUserStakes(String owner) async {
    owners.add(owner);
    return owner == _owner ? [_stake(owner)] : [];
  }

  @override
  Future<StakingPool?> getStakingPool(String address) async => _pool();
  @override
  Future<String> getLatestBlockhash() async => _key(5);
  @override
  Future<Map<String, dynamic>> simulateTransaction(Uint8List txBytes) async => {
    'err': null,
  };
  @override
  Future<List<SolanaSignatureStatus>> getSignatureStatuses(
    List<String> signatures,
  ) async => [status];
}

class _Wallet extends WalletService {
  String owner = _owner;
  final sent = <Uint8List>[];
  @override
  String? get publicKey => owner;
  @override
  bool get isConnected => true;
  @override
  WalletKind get kind => WalletKind.mwa;
  @override
  void notifyTxCommitted() {}
  @override
  Future<List<String?>> signAndSendTransactions(List<Uint8List> txs) async {
    sent.addAll(txs);
    return ['fixture-signature'];
  }

  void select(String value) {
    owner = value;
    notifyListeners();
  }
}

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  test(
    'queries stakes by owner without a data size filter and validates ownership',
    () async {
      Map<String, Object> row(
        String owner, {
        String program = chiefStakerProgramId,
      }) {
        final bytes = Uint8List(153)
          ..setAll(0, userStakeDiscriminator)
          ..setAll(8, base58Decode(owner))
          ..setAll(40, base58Decode(_poolAddress));
        return {
          'account': {
            'owner': program,
            'data': [base64Encode(bytes), 'base64'],
          },
        };
      }

      final rpc = RpcService.real(
        client: MockClient((request) async {
          final payload = jsonDecode(request.body);
          expect(payload['method'], 'getProgramAccounts');
          final params = payload['params'] as List;
          expect(params.first, chiefStakerProgramId);
          expect(params.last['filters'], [
            {
              'memcmp': {
                'offset': 0,
                'bytes': base58Encode(userStakeDiscriminator),
              },
            },
            {
              'memcmp': {'offset': 8, 'bytes': _owner},
            },
          ]);
          return http.Response(
            jsonEncode({
              'result': [
                row(_owner),
                row(_key(9)),
                row(_owner, program: systemProgramId),
              ],
            }),
            200,
          );
        }),
      );
      addTearDown(rpc.dispose);
      final stakes = await rpc.getUserStakes(_owner);
      expect(stakes.single.owner, _owner);
      expect(stakes.single.pool, _poolAddress);
    },
  );

  test('maximum bulk claim fits a single legacy transaction', () {
    Uint8List build(int count) => buildStakingClaim(
      owner: _owner,
      blockhash: _key(93),
      pools: List.generate(count, (i) => _key(i + 11)),
    );
    expect(build(maxClaimsPerTransaction).length, lessThanOrEqualTo(1232));
    expect(() => build(maxClaimsPerTransaction + 1), throwsArgumentError);
  });

  testWidgets(
    'opens My staked, reviews claim and refreshes on account changes',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final wallet = _Wallet();
      final compliance = UkComplianceService();
      final rpc = _Rpc();
      RpcService.testInstance = rpc;
      ChiefStakerApi.testInstance = _Directory();
      addTearDown(() {
        RpcService.testInstance = null;
        ChiefStakerApi.testInstance = null;
        wallet.dispose();
        compliance.dispose();
      });
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<WalletService>.value(value: wallet),
            ChangeNotifierProvider<UkComplianceService>.value(
              value: compliance,
            ),
          ],
          child: MaterialApp(
            theme: TibaneTheme.darkTheme,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: StakingPoolsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Age'), findsNothing);
      expect(find.text('Name'), findsNothing);
      expect(find.text('Total'), findsOneWidget);
      expect(find.text('Total Staked'), findsNothing);
      for (final label in ['Members', 'MCap', 'Total', 'My staked']) {
        final text = find.text(label);
        final background = find
            .ancestor(of: text, matching: find.byType(Material))
            .first;
        expect(tester.getSize(background).height, closeTo(36.8, 0.01));
        expect(
          tester.widget<Text>(text).style?.fontSize,
          closeTo(11 * 1.15 * 1.25, 0.01),
        );
      }
      Color? myStakedColor() {
        final pill = find.descendant(
          of: find.byType(StakingPoolsScreen, skipOffstage: false),
          matching: find.text('My staked', skipOffstage: false),
          skipOffstage: false,
        );
        return tester.widget<Text>(pill).style?.color;
      }

      expect(myStakedColor(), TibaneColors.textMuted);
      await tester.tap(find.text('My staked'));
      await tester.pumpAndSettle();
      expect(myStakedColor(), TibaneColors.orange);
      expect(find.text('Staked: 1 FIX'), findsOneWidget);
      expect(find.text('0.001 SOL'), findsOneWidget);
      await tester.tap(find.text('Claim All'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Review claim'), findsOneWidget);
      expect(wallet.sent, isEmpty);
      await tester.tap(find.text('Confirm'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(wallet.sent, hasLength(1));
      expect(find.text('Rewards claimed.'), findsOneWidget);

      wallet.select(_key(9));
      await tester.pumpAndSettle();
      expect(find.text('Fixture staking token'), findsNothing);
      expect(
        find.text('You don’t have any staking positions on this account.'),
        findsOneWidget,
      );
      expect(rpc.owners.last, _key(9));
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(myStakedColor(), TibaneColors.textMuted);
      expect(tester.takeException(), isNull);
    },
  );
}
