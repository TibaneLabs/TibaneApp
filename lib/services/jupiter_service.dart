import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/solana_constants.dart';
import '../models/token_account.dart';
import 'rpc_service.dart';

const _jupiterApi = 'https://api.jup.ag';
const _jupiterApiKey = '88a07ce3-0f5d-44b3-a8d5-8cd2beab86fc';
const _referralAccount = 'BF436HVWSsrdXkYQU3NAg5W4gqPogEKhdVJBQXPkcXLE';
const _referralFee = '50'; // 0.5%

/// Common tokens available as swap targets
class CommonToken {
  final String mint;
  final String symbol;
  final String name;
  final String? imageUrl;

  const CommonToken({
    required this.mint,
    required this.symbol,
    required this.name,
    this.imageUrl,
  });
}

const commonTokens = [
  CommonToken(mint: wsolMint, symbol: 'SOL', name: 'Solana'),
  CommonToken(
    mint: 'EPjFWdd5AufqSSqeM2qN1xzybapC8G4wEGGkZwyTDt1v',
    symbol: 'USDC',
    name: 'USD Coin',
  ),
  CommonToken(
    mint: 'Es9vMFrzaCERmJfrF4H2FYD4KCoNkY11McCe8BenwNYB',
    symbol: 'USDT',
    name: 'Tether USD',
  ),
  CommonToken(
    mint: chiefPussyMint,
    symbol: 'ChiefPussy',
    name: 'Tibane Thecat',
  ),
];

/// A token holding in the user's wallet
class TokenHolding {
  final String mint;
  final String symbol;
  final String name;
  final String? imageUrl;
  final BigInt balance;
  final int decimals;
  final double uiBalance;
  final double? priceUsd;
  final double? valueUsd;

  TokenHolding({
    required this.mint,
    required this.symbol,
    required this.name,
    this.imageUrl,
    required this.balance,
    required this.decimals,
    required this.uiBalance,
    this.priceUsd,
    this.valueUsd,
  });
}

/// Quote from Jupiter Ultra API
class SwapQuote {
  final String inAmount;
  final String outAmount;
  final double outAmountUi;
  final String priceImpactPct;
  final double? inUsdValue;
  final double? outUsdValue;
  final bool gasless;
  final String requestId;
  final String transaction; // base64-encoded unsigned transaction

  SwapQuote({
    required this.inAmount,
    required this.outAmount,
    required this.outAmountUi,
    required this.priceImpactPct,
    this.inUsdValue,
    this.outUsdValue,
    required this.gasless,
    required this.requestId,
    required this.transaction,
  });
}

class JupiterService {
  final _client = http.Client();

  Map<String, String> get _getHeaders => {
    if (_jupiterApiKey.isNotEmpty) 'x-api-key': _jupiterApiKey,
  };

  Map<String, String> get _postHeaders => {
    'Content-Type': 'application/json',
    if (_jupiterApiKey.isNotEmpty) 'x-api-key': _jupiterApiKey,
  };

  /// Fetch all token holdings for a wallet address
  Future<List<TokenHolding>> fetchHoldings(
    String walletAddress, {
    String? excludeMint,
  }) async {
    final rpc = RpcService();
    try {
      // Fetch SPL and Token2022 accounts in parallel
      final results = await Future.wait([
        rpc.getTokenAccountsByOwner(walletAddress),
        rpc.getTokenAccountsByOwner(walletAddress, token2022: true),
        rpc.getBalance(walletAddress),
      ]);

      final splAccounts = results[0] as List<TokenAccount>;
      final t22Accounts = results[1] as List<TokenAccount>;
      final solBalance = results[2] as BigInt;

      // Parse token accounts
      final raw =
          <({String mint, BigInt balance, int decimals, double uiBalance})>[];

      for (final acc in [...splAccounts, ...t22Accounts]) {
        if (acc.amount <= BigInt.zero) continue;
        if (acc.mint == excludeMint) continue;
        final divisor = BigInt.from(10).pow(acc.decimals);
        raw.add((
          mint: acc.mint,
          balance: acc.amount,
          decimals: acc.decimals,
          uiBalance: acc.amount.toDouble() / divisor.toDouble(),
        ));
      }

      // Add native SOL (reserve ~0.01 for fees)
      final usableSol = solBalance > BigInt.from(10000000)
          ? solBalance - BigInt.from(10000000)
          : BigInt.zero;
      if (usableSol > BigInt.zero && excludeMint != wsolMint) {
        raw.add((
          mint: wsolMint,
          balance: usableSol,
          decimals: 9,
          uiBalance: usableSol.toDouble() / 1e9,
        ));
      }

      if (raw.isEmpty) return [];

      // Fetch metadata and prices in parallel
      final mints = raw.map((r) => r.mint).toList();
      final metaFuture = _fetchTokenMetadata(mints, rpc);
      final priceFuture = fetchTokenPrices(mints);
      final results2 = await Future.wait([metaFuture, priceFuture]);

      final metaMap =
          results2[0]
              as Map<String, ({String name, String symbol, String? image})>;
      final priceMap = results2[1] as Map<String, double>;

      final holdings = <TokenHolding>[];
      for (final r in raw) {
        final meta = metaMap[r.mint];
        final price = priceMap[r.mint];
        final valueUsd = price != null ? r.uiBalance * price : null;

        holdings.add(
          TokenHolding(
            mint: r.mint,
            symbol: meta?.symbol ?? shortenAddress(r.mint),
            name: meta?.name ?? r.mint,
            imageUrl: meta?.image,
            balance: r.balance,
            decimals: r.decimals,
            uiBalance: r.uiBalance,
            priceUsd: price,
            valueUsd: valueUsd,
          ),
        );
      }

      // Sort by USD value descending, then by balance
      holdings.sort((a, b) {
        if (a.valueUsd != null && b.valueUsd != null) {
          return b.valueUsd!.compareTo(a.valueUsd!);
        }
        if (a.valueUsd != null) return -1;
        if (b.valueUsd != null) return 1;
        return b.uiBalance.compareTo(a.uiBalance);
      });

      return holdings;
    } finally {
      rpc.dispose();
    }
  }

  /// Fetch metadata for tokens via Helius DAS
  Future<Map<String, ({String name, String symbol, String? image})>>
  _fetchTokenMetadata(List<String> mints, RpcService rpc) async {
    final map = <String, ({String name, String symbol, String? image})>{};
    // Handle SOL specially
    map[wsolMint] = (name: 'Solana', symbol: 'SOL', image: null);

    final nonSolMints = mints.where((m) => m != wsolMint).toList();
    if (nonSolMints.isEmpty) return map;

    try {
      final metaBatch = await rpc.getAssetBatch(nonSolMints);
      for (final entry in metaBatch.entries) {
        map[entry.key] = (
          name: entry.value.name ?? entry.key,
          symbol: entry.value.symbol ?? shortenAddress(entry.key),
          image: entry.value.imageUrl,
        );
      }
    } catch (e) {
      debugPrint('fetchTokenMetadata error: $e');
    }
    return map;
  }

  /// Fetch token prices from Jupiter Price API
  Future<Map<String, double>> fetchTokenPrices(List<String> mints) async {
    final map = <String, double>{};
    if (mints.isEmpty) return map;

    // Batch in groups of 50
    for (var i = 0; i < mints.length; i += 50) {
      final batch = mints.sublist(i, (i + 50).clamp(0, mints.length));
      try {
        final ids = batch.join(',');
        final response = await _client.get(
          Uri.parse('$_jupiterApi/price/v3?ids=$ids'),
          headers: _getHeaders,
        );
        if (response.statusCode != 200) continue;
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        for (final entry in json.entries) {
          if (entry.value is Map<String, dynamic>) {
            final price = (entry.value as Map<String, dynamic>)['usdPrice'];
            if (price is num) {
              map[entry.key] = price.toDouble();
            }
          }
        }
      } catch (e) {
        debugPrint('fetchTokenPrices error: $e');
      }
    }
    return map;
  }

  /// Fetch a quote from Jupiter Ultra API
  Future<SwapQuote> fetchQuote({
    required String inputMint,
    required String outputMint,
    required BigInt amount,
    required String taker,
    required int outputDecimals,
  }) async {
    final params = {
      'inputMint': inputMint,
      'outputMint': outputMint,
      'amount': amount.toString(),
      'taker': taker,
      'referralAccount': _referralAccount,
      'referralFee': _referralFee,
    };

    final uri = Uri.parse(
      '$_jupiterApi/ultra/v1/order',
    ).replace(queryParameters: params);
    final response = await _client.get(uri, headers: _getHeaders);

    if (response.statusCode != 200) {
      throw Exception(
        response.body.isNotEmpty ? response.body : 'Failed to get quote',
      );
    }

    final data = jsonDecode(response.body) as Map<String, dynamic>;

    if (data['transaction'] == null) {
      throw Exception(
        data['error'] as String? ?? 'No route found for this swap',
      );
    }

    final outAmount = BigInt.parse(data['outAmount'] as String);
    final outUi =
        outAmount.toDouble() / BigInt.from(10).pow(outputDecimals).toDouble();

    return SwapQuote(
      inAmount: data['inAmount'] as String,
      outAmount: data['outAmount'] as String,
      outAmountUi: outUi,
      priceImpactPct: (data['priceImpactPct'] as String?) ?? '0',
      inUsdValue: data['inUsdValue'] is num
          ? (data['inUsdValue'] as num).toDouble()
          : null,
      outUsdValue: data['outUsdValue'] is num
          ? (data['outUsdValue'] as num).toDouble()
          : null,
      gasless: data['gasless'] == true,
      requestId: data['requestId'] as String,
      transaction: data['transaction'] as String,
    );
  }

  /// Execute a signed swap via Jupiter Ultra API
  Future<String> executeSwap({
    required String signedTransactionBase64,
    required String requestId,
  }) async {
    final response = await _client.post(
      Uri.parse('$_jupiterApi/ultra/v1/execute'),
      headers: _postHeaders,
      body: jsonEncode({
        'signedTransaction': signedTransactionBase64,
        'requestId': requestId,
      }),
    );

    final result = jsonDecode(response.body) as Map<String, dynamic>;

    if (result['status'] == 'Success' && result['signature'] != null) {
      return result['signature'] as String;
    }

    throw Exception(
      result['error'] as String? ??
          result['message'] as String? ??
          'Swap failed: ${result['status'] ?? 'unknown'}',
    );
  }

  void dispose() {
    _client.close();
  }
}
