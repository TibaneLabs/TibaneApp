import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../constants/solana_constants.dart';
import '../models/staking_pool.dart';
import '../models/token_account.dart';
import 'solana_common.dart';

/// Service for Solana RPC calls and Helius API interactions
class RpcService {
  /// Test/screenshot hook: when set, every `RpcService()` returns this
  /// instance instead of constructing a new one. Subclasses constructed
  /// for screenshot mode should call the public [RpcService.real] constructor.
  static RpcService? testInstance;

  factory RpcService() => testInstance ?? RpcService.real();

  RpcService.real();

  final http.Client _client = http.Client();
  int _requestId = 0;

  /// Make a JSON-RPC request to Helius
  Future<dynamic> _rpc(String method, [List<dynamic>? params]) async {
    _requestId++;
    final body = jsonEncode({
      'jsonrpc': '2.0',
      'id': _requestId,
      'method': method,
      'params': params ?? [],
    });

    final response = await _client.post(
      Uri.parse(heliusRpcUrl),
      headers: {'Content-Type': 'application/json'},
      body: body,
    );

    if (response.statusCode != 200) {
      throw Exception('RPC error: ${response.statusCode}');
    }

    final json = jsonDecode(response.body);
    if (json['error'] != null) {
      throw Exception('RPC error: ${json['error']['message']}');
    }

    return json['result'];
  }

  /// Get latest blockhash for transaction building
  Future<String> getLatestBlockhash() async {
    final result = await _rpc('getLatestBlockhash', [
      {'commitment': 'finalized'},
    ]);
    return result['value']['blockhash'] as String;
  }

  /// Poll `getSignatureStatuses` until the tx hits `confirmed` (or better),
  /// or the deadline passes. Returns true if confirmed, false on timeout.
  /// Subsequent reads at `confirmed` commitment will see the tx's effects.
  Future<bool> confirmTransaction(
    String signature, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final result = await _rpc('getSignatureStatuses', [
        [signature],
        {'searchTransactionHistory': true},
      ]);
      final status = (result['value'] as List).first;
      if (status is Map) {
        final cs = status['confirmationStatus'] as String?;
        if (cs == 'confirmed' || cs == 'finalized') return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
  }

  /// Simulate a transaction (skips signature verification)
  Future<Map<String, dynamic>> simulateTransaction(Uint8List txBytes) async {
    final b64 = base64Encode(txBytes);
    final result = await _rpc('simulateTransaction', [
      b64,
      {
        'encoding': 'base64',
        'sigVerify': false,
        'replaceRecentBlockhash': true,
      },
    ]);
    return result['value'] as Map<String, dynamic>;
  }

  /// Get SOL balance for an address
  Future<BigInt> getBalance(String address) async {
    final result = await _rpc('getBalance', [address]);
    return BigInt.from(result['value'] as int);
  }

  /// Get account info (raw bytes)
  Future<Uint8List?> getAccountInfo(String address) async {
    final result = await _rpc('getAccountInfo', [
      address,
      {'encoding': 'base64'},
    ]);

    if (result == null || result['value'] == null) return null;
    final data = result['value']['data'];
    if (data is List && data.isNotEmpty) {
      return base64Decode(data[0] as String);
    }
    return null;
  }

  /// Get account info with lamports
  Future<({Uint8List? data, BigInt lamports, String? owner})?>
  getAccountInfoFull(String address) async {
    final result = await _rpc('getAccountInfo', [
      address,
      {'encoding': 'base64'},
    ]);

    if (result == null || result['value'] == null) return null;
    final value = result['value'] as Map<String, dynamic>;
    final data = value['data'];
    Uint8List? bytes;
    if (data is List && data.isNotEmpty) {
      bytes = base64Decode(data[0] as String);
    }
    return (
      data: bytes,
      lamports: BigInt.from(value['lamports'] as int),
      owner: value['owner'] as String?,
    );
  }

  /// Get token accounts by owner (SPL Token program)
  Future<List<TokenAccount>> getTokenAccountsByOwner(
    String owner, {
    bool token2022 = false,
  }) async {
    final programId = token2022 ? token2022ProgramId : splTokenProgramId;
    final result = await _rpc('getTokenAccountsByOwner', [
      owner,
      {'programId': programId},
      {'encoding': 'jsonParsed'},
    ]);

    final accounts = <TokenAccount>[];
    final value = result['value'] as List;

    for (final item in value) {
      final pubkey = item['pubkey'] as String;
      final accountData = item['account'] as Map<String, dynamic>;
      final lamports = accountData['lamports'] as int;
      final parsed =
          accountData['data']['parsed']['info'] as Map<String, dynamic>;
      final tokenAmount = parsed['tokenAmount'] as Map<String, dynamic>;

      accounts.add(
        TokenAccount(
          pubkey: pubkey,
          mint: parsed['mint'] as String,
          owner: parsed['owner'] as String,
          amount: BigInt.parse(tokenAmount['amount'] as String),
          decimals: tokenAmount['decimals'] as int,
          rentLamports: BigInt.from(lamports),
          isToken2022: token2022,
        ),
      );
    }

    return accounts;
  }

  /// Get all staking pools from the ChiefStaker program
  Future<List<StakingPool>> getAllStakingPools() async {
    final result = await _rpc('getProgramAccounts', [
      chiefStakerProgramId,
      {
        'encoding': 'base64',
        'filters': [
          {
            'memcmp': {'offset': 0, 'bytes': base58Encode(poolDiscriminator)},
          },
        ],
      },
    ]);

    final pools = <StakingPool>[];
    for (final item in result as List) {
      final pubkey = item['pubkey'] as String;
      final data = base64Decode((item['account']['data'] as List)[0] as String);
      final pool = StakingPool.deserialize(pubkey, data);
      if (pool != null) {
        // Get reward balance from account lamports
        final lamports = item['account']['lamports'] as int;
        // Pool lamports minus rent = reward balance (approximately)
        final rent = 3800000; // ~0.0038 SOL rent for pool account
        pool.rewardBalance = BigInt.from((lamports - rent).clamp(0, lamports));
        pools.add(pool);
      }
    }

    return pools;
  }

  /// Re-fetch a single staking pool's on-chain data
  Future<StakingPool?> getStakingPool(String address) async {
    final result = await _rpc('getAccountInfo', [
      address,
      {'encoding': 'base64'},
    ]);
    final value = result['value'];
    if (value == null) return null;
    final data = base64Decode((value['data'] as List)[0] as String);
    final pool = StakingPool.deserialize(address, data);
    if (pool != null) {
      final lamports = value['lamports'] as int;
      final rent = 3800000;
      pool.rewardBalance = BigInt.from((lamports - rent).clamp(0, lamports));
    }
    return pool;
  }

  /// Get member count for a pool by counting user stake accounts
  Future<int> getPoolMemberCount(String poolAddress) async {
    final result = await _rpc('getProgramAccounts', [
      chiefStakerProgramId,
      {
        'encoding': 'base64',
        'dataSlice': {'offset': 0, 'length': 0},
        'filters': [
          {
            'memcmp': {
              'offset': 0,
              'bytes': base58Encode(userStakeDiscriminator),
            },
          },
          {
            'memcmp': {'offset': 40, 'bytes': poolAddress},
          },
        ],
      },
    ]);
    return (result as List).length;
  }

  /// Get member counts for all pools in a single RPC call.
  /// Returns a map of pool address -> member count.
  Future<Map<String, int>> getAllMemberCounts() async {
    final result = await _rpc('getProgramAccounts', [
      chiefStakerProgramId,
      {
        'encoding': 'base64',
        'dataSlice': {'offset': 40, 'length': 32},
        'filters': [
          {
            'memcmp': {
              'offset': 0,
              'bytes': base58Encode(userStakeDiscriminator),
            },
          },
        ],
      },
    ]);

    final counts = <String, int>{};
    for (final item in result as List) {
      final data = base64Decode((item['account']['data'] as List)[0] as String);
      if (data.length >= 32) {
        final poolAddress = base58Encode(data.sublist(0, 32));
        counts[poolAddress] = (counts[poolAddress] ?? 0) + 1;
      }
    }
    return counts;
  }

  /// Get a user's stake account for a specific pool
  Future<UserStake?> getUserStake(
    String poolAddress,
    String userAddress,
  ) async {
    // Derive the user stake PDA
    // For now, we search by filters
    final result = await _rpc('getProgramAccounts', [
      chiefStakerProgramId,
      {
        'encoding': 'base64',
        'filters': [
          {
            'memcmp': {
              'offset': 0,
              'bytes': base58Encode(userStakeDiscriminator),
            },
          },
          {
            'memcmp': {'offset': 8, 'bytes': userAddress},
          },
          {
            'memcmp': {'offset': 40, 'bytes': poolAddress},
          },
        ],
      },
    ]);

    final accounts = result as List;
    if (accounts.isEmpty) return null;

    final data = base64Decode(
      (accounts[0]['account']['data'] as List)[0] as String,
    );
    return UserStake.deserialize(data);
  }

  /// Get all user stake accounts for a specific pool (for members leaderboard)
  Future<List<({String address, UserStake stake})>> getUserStakesForPool(
    String poolAddress,
  ) async {
    final results = <({String address, UserStake stake})>[];

    // Filter by discriminator + pool only — never by dataSize. UserStake has
    // grown over time (153 → 161 → 177 → 178 bytes as fields were added), and
    // accounts of every historical size coexist on-chain until they realloc.
    // A dataSize filter silently drops whichever sizes aren't listed (it was
    // missing the current 178-byte accounts). UserStake.deserialize tolerates
    // any size >= 153, so match all of them and let it parse.
    final result = await _rpc('getProgramAccounts', [
      chiefStakerProgramId,
      {
        'encoding': 'base64',
        'filters': [
          {
            'memcmp': {
              'offset': 0,
              'bytes': base58Encode(userStakeDiscriminator),
            },
          },
          {
            'memcmp': {'offset': 40, 'bytes': poolAddress},
          },
        ],
      },
    ]);

    for (final item in result as List) {
      final pubkey = item['pubkey'] as String;
      final data = base64Decode((item['account']['data'] as List)[0] as String);
      final stake = UserStake.deserialize(data);
      if (stake != null && stake.amount > BigInt.zero) {
        results.add((address: pubkey, stake: stake));
      }
    }

    return results;
  }

  /// Get assets by owner via Helius DAS API (for NFTs and domains)
  Future<List<Map<String, dynamic>>> getAssetsByOwner(
    String owner, {
    int page = 1,
    int limit = 1000,
  }) async {
    try {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': ++_requestId,
        'method': 'getAssetsByOwner',
        'params': {
          'ownerAddress': owner,
          'page': page,
          'limit': limit,
          'displayOptions': {'showFungible': false, 'showNativeBalance': false},
        },
      });

      final response = await _client.post(
        Uri.parse(heliusRpcUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode != 200) return [];
      final json = jsonDecode(response.body);
      if (json['error'] != null || json['result'] == null) return [];

      return (json['result']['items'] as List).cast<Map<String, dynamic>>();
    } catch (e) {
      debugPrint('getAssetsByOwner error: $e');
      return [];
    }
  }

  /// Get asset proof for compressed NFT burning
  Future<Map<String, dynamic>?> getAssetProof(String assetId) async {
    try {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': ++_requestId,
        'method': 'getAssetProof',
        'params': {'id': assetId},
      });

      final response = await _client.post(
        Uri.parse(heliusRpcUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json['error'] != null || json['result'] == null) return null;
      return json['result'] as Map<String, dynamic>;
    } catch (e) {
      debugPrint('getAssetProof error: $e');
      return null;
    }
  }

  /// Get sharing config account for a pump.fun token
  Future<Uint8List?> getSharingConfig(String mint) async {
    final (configAddr, _) = findProgramAddressFromStrings([
      utf8.encode('sharing-config'),
      base58Decode(mint),
    ], pumpFeesProgramId);
    return getAccountInfo(configAddr);
  }

  /// Get token metadata from Helius getAsset
  Future<TokenMetadata?> getAsset(String mint) async {
    try {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': ++_requestId,
        'method': 'getAsset',
        'params': {'id': mint},
      });

      final response = await _client.post(
        Uri.parse(heliusRpcUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode != 200) return null;
      final json = jsonDecode(response.body);
      if (json['error'] != null || json['result'] == null) return null;

      return TokenMetadata.fromHeliusAsset(
        json['result'] as Map<String, dynamic>,
      );
    } catch (e) {
      debugPrint('getAsset error: $e');
      return null;
    }
  }

  /// Batch get token metadata
  Future<Map<String, TokenMetadata>> getAssetBatch(List<String> mints) async {
    if (mints.isEmpty) return {};

    try {
      final body = jsonEncode({
        'jsonrpc': '2.0',
        'id': ++_requestId,
        'method': 'getAssetBatch',
        'params': {'ids': mints},
      });

      final response = await _client.post(
        Uri.parse(heliusRpcUrl),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode != 200) return {};
      final json = jsonDecode(response.body);
      if (json['error'] != null || json['result'] == null) return {};

      final result = <String, TokenMetadata>{};
      for (final item in json['result'] as List) {
        if (item != null) {
          final meta = TokenMetadata.fromHeliusAsset(
            item as Map<String, dynamic>,
          );
          if (meta.mint.isNotEmpty) {
            result[meta.mint] = meta;
          }
        }
      }
      return result;
    } catch (e) {
      debugPrint('getAssetBatch error: $e');
      return {};
    }
  }

  /// Get top token holders
  Future<List<TokenHolder>> getTopHolders(String mint, {int limit = 20}) async {
    try {
      final result = await _rpc('getTokenLargestAccounts', [mint]);
      final value = result['value'] as List;

      // Get total supply for percentage calculation
      final supplyResult = await _rpc('getTokenSupply', [mint]);
      final totalSupply = BigInt.parse(
        supplyResult['value']['amount'] as String,
      );

      final holders = <TokenHolder>[];
      for (final item in value.take(limit)) {
        final amount = BigInt.parse(item['amount'] as String);
        final percentage = totalSupply > BigInt.zero
            ? (amount * BigInt.from(10000) ~/ totalSupply).toDouble() / 100
            : 0.0;
        holders.add(
          TokenHolder(
            address: item['address'] as String,
            amount: amount,
            percentage: percentage,
          ),
        );
      }
      return holders;
    } catch (e) {
      debugPrint('getTopHolders error: $e');
      return [];
    }
  }

  /// Get recent transactions for an address
  Future<List<Map<String, dynamic>>> getSignaturesForAddress(
    String address, {
    int limit = 20,
  }) async {
    try {
      final result = await _rpc('getSignaturesForAddress', [
        address,
        {'limit': limit},
      ]);
      return (result as List).map((e) => e as Map<String, dynamic>).toList();
    } catch (e) {
      debugPrint('getSignatures error: $e');
      return [];
    }
  }

  void dispose() {
    _client.close();
  }
}
