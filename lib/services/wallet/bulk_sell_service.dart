import 'package:libwallet/libwallet.dart' as lw;

import '../../constants/solana_constants.dart';
import '../../utils/amount.dart';
import '../jupiter_service.dart';
import '../rpc_service.dart';
import '../wallet_service.dart';

typedef BulkSellAccount = ({String id, String address, String networkId});

BulkSellAccount? bulkSellAccountFor(WalletService wallet) {
  final backend = wallet.libwallet;
  final network = backend.currentNetwork;
  final address = wallet.publicKey;
  final id = backend.accountId;
  if (!wallet.isConnected ||
      wallet.kind != WalletKind.inapp ||
      network == null ||
      network.type != lw.NetworkType.solana ||
      network.testNet ||
      !const {'mainnet', 'mainnet-beta'}.contains(network.chainId) ||
      network.id.isEmpty ||
      address == null ||
      address.isEmpty ||
      id == null ||
      id.isEmpty) {
    return null;
  }
  return (id: id, address: address, networkId: network.id);
}

class BulkSellLine {
  BulkSellLine(this.token, {this.quote, this.error});

  final TokenHolding token;
  final lw.SwapQuote? quote;
  final Object? error;

  BigInt get minimum => _lamports(quote?.minAmountOut) ?? BigInt.zero;
  BigInt? get networkFee => _lamports(quote?.networkFee);
}

class BulkSellReview {
  BulkSellReview(this.account, List<BulkSellLine> lines)
    : lines = List.unmodifiable(lines);

  final BulkSellAccount account;
  final List<BulkSellLine> lines;

  bool get hasQuotes =>
      lines.isNotEmpty && lines.every((line) => line.quote != null);
  bool get expired => lines.any((line) => line.quote?.isExpired ?? false);
  BigInt get minimum =>
      lines.fold(BigInt.zero, (sum, line) => sum + line.minimum);
  BigInt? get estimatedFees => lines.every((line) => line.networkFee != null)
      ? lines.fold<BigInt>(BigInt.zero, (sum, line) => sum + line.networkFee!)
      : null;
  BigInt get feeBudget {
    final baseFee = BigInt.from(5000);
    return lines.fold(BigInt.zero, (sum, line) {
      final fee = line.networkFee;
      return sum + (fee != null && fee > baseFee ? fee : baseFee);
    });
  }
}

enum BulkSellStatus { notSent, submitting, pending, sold, failed, expired }

typedef BulkSellOutcome = ({BulkSellStatus status, String? signature});

BigInt? _lamports(lw.Amount? amount) =>
    amount == null ? null : parseTokenAmount(amount.toString(), 9);

class BulkSellService {
  BulkSellService({
    required Future<lw.LibwalletClient> Function() client,
    JupiterService? jupiter,
    RpcService? rpc,
    Duration confirmationTimeout = const Duration(seconds: 25),
    Duration confirmationInterval = const Duration(seconds: 2),
  }) : _client = client,
       _jupiter = jupiter ?? JupiterService(),
       _rpc = rpc ?? RpcService(),
       _confirmationTimeout = confirmationTimeout,
       _confirmationInterval = confirmationInterval;

  final Future<lw.LibwalletClient> Function() _client;
  final JupiterService _jupiter;
  final RpcService _rpc;
  final Duration _confirmationTimeout;
  final Duration _confirmationInterval;

  Future<List<TokenHolding>> holdings(BulkSellAccount account) async {
    final all = await _jupiter
        .fetchHoldings(account.address, reserveSolForFees: false)
        .timeout(const Duration(seconds: 25));
    final tokens = <String, TokenHolding>{};
    for (final token in all) {
      if (token.mint == wsolMint || token.balance <= BigInt.zero) continue;
      final previous = tokens[token.mint];
      tokens[token.mint] = previous == null
          ? token
          : TokenHolding(
              mint: token.mint,
              symbol: token.symbol,
              name: token.name,
              imageUrl: token.imageUrl,
              balance: previous.balance + token.balance,
              decimals: token.decimals,
              uiBalance: previous.uiBalance + token.uiBalance,
            );
    }
    return tokens.values.toList();
  }

  Future<BigInt> feeBalance(BulkSellAccount account) =>
      _rpc.getBalance(account.address).timeout(const Duration(seconds: 10));

  Future<BulkSellReview> prepare(
    BulkSellAccount account,
    List<TokenHolding> tokens, {
    required bool Function() isCurrent,
  }) async {
    final client = await _client();
    final lines = <BulkSellLine>[];
    // Bound concurrent provider requests without changing review order.
    for (var i = 0; i < tokens.length && isCurrent(); i += 3) {
      lines.addAll(
        await Future.wait(
          tokens.skip(i).take(3).map((token) => _quote(client, account, token)),
        ),
      );
    }
    return BulkSellReview(account, lines);
  }

  Future<BulkSellLine> _quote(
    lw.LibwalletClient client,
    BulkSellAccount account,
    TokenHolding token,
  ) async {
    try {
      final quote = await client.swap
          .quote(
            tokenIn: lw.SwapTokenRef(
              address: token.mint,
              decimals: token.decimals,
            ),
            tokenOut: const lw.SwapTokenRef(address: 'NATIVE', decimals: 9),
            amountIn: token.balance.toString(),
            from: account.id,
            network: account.networkId,
            slippageBps: 100,
          )
          .timeout(const Duration(seconds: 15));
      final minimum = _lamports(quote.minAmountOut);
      final output = _lamports(quote.amountOut);
      if (quote.quoteId.isEmpty ||
          !quote.isExecutable ||
          quote.isExpired ||
          quote.chain != 'solana' ||
          quote.tokenIn.address != token.mint ||
          (quote.tokenOut.address != 'NATIVE' &&
              quote.tokenOut.address != wsolMint) ||
          quote.amountIn != lw.Amount(token.balance, token.decimals) ||
          minimum == null ||
          minimum <= BigInt.zero ||
          output == null ||
          output < minimum) {
        return BulkSellLine(token);
      }
      return BulkSellLine(token, quote: quote);
    } catch (error) {
      return BulkSellLine(token, error: error);
    }
  }

  Future<void> execute(
    BulkSellReview review,
    List<lw.SigningKey> keys, {
    required bool Function() canSubmit,
    required bool Function() isOpen,
    required void Function(String mint, BulkSellOutcome outcome) onUpdate,
  }) async {
    if (!review.hasQuotes || keys.isEmpty || !canSubmit()) return;
    final api = (await _client()).swap;
    final submitted = <String, String>{};
    for (final line in review.lines) {
      if (!canSubmit()) break;
      final mint = line.token.mint;
      final quote = line.quote!;
      if (quote.isExpired) {
        onUpdate(mint, (status: BulkSellStatus.expired, signature: null));
        continue;
      }
      onUpdate(mint, (status: BulkSellStatus.submitting, signature: null));
      try {
        final result = await api.execute(
          closeTokenAccount: false,
          quoteId: quote.quoteId,
          keys: keys,
          from: review.account.id,
        );
        final signature = result.hash.isEmpty ? null : result.hash;
        if (signature != null) submitted[mint] = signature;
        onUpdate(mint, (status: BulkSellStatus.pending, signature: signature));
      } on lw.SwapError catch (error) {
        final status = switch (error.code) {
          'quote_expired' || 'quote_not_found' => BulkSellStatus.expired,
          'invalid_request' || 'slippage_exceeded' => BulkSellStatus.failed,
          _ => BulkSellStatus.pending,
        };
        onUpdate(mint, (status: status, signature: null));
      } catch (_) {
        // A transport error can happen after broadcast. Never retry blindly.
        onUpdate(mint, (status: BulkSellStatus.pending, signature: null));
      }
    }
    await _confirm(submitted, isOpen, onUpdate);
  }

  Future<void> _confirm(
    Map<String, String> pending,
    bool Function() isOpen,
    void Function(String, BulkSellOutcome) onUpdate,
  ) async {
    final deadline = DateTime.now().add(_confirmationTimeout);
    while (pending.isNotEmpty &&
        isOpen() &&
        DateTime.now().isBefore(deadline)) {
      final entries = pending.entries.toList();
      for (var i = 0; i < entries.length && isOpen(); i += 256) {
        final batch = entries.skip(i).take(256).toList();
        try {
          final statuses = await _rpc
              .getSignatureStatuses(batch.map((entry) => entry.value).toList())
              .timeout(const Duration(seconds: 5));
          for (var j = 0; j < batch.length; j++) {
            final status = statuses[j];
            if (status == SolanaSignatureStatus.pending) continue;
            final entry = batch[j];
            pending.remove(entry.key);
            onUpdate(entry.key, (
              status: status == SolanaSignatureStatus.confirmed
                  ? BulkSellStatus.sold
                  : BulkSellStatus.failed,
              signature: entry.value,
            ));
          }
        } catch (_) {
          // Unavailable RPC leaves submissions pending, never confirmed.
        }
      }
      if (pending.isNotEmpty && isOpen()) {
        await Future<void>.delayed(_confirmationInterval);
      }
    }
  }

  void dispose() {
    _jupiter.dispose();
    _rpc.dispose();
  }
}
