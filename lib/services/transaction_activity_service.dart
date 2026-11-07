import '../models/transaction_activity.dart';
import '../models/token_account.dart';
import '../constants/solana_constants.dart';
import 'rpc_service.dart';

class TransactionActivityService {
  TransactionActivityService({RpcService? rpc}) : _rpc = rpc ?? RpcService();
  final RpcService _rpc;
  final _pending = <String, Future<TransactionActivity?>>{};
  final _metadata = <String, TokenMetadata>{};

  Future<TransactionActivity?> loadSolana(String signature, String owner) {
    final key = '$owner:$signature';
    return _pending.putIfAbsent(key, () async {
      try {
        final parsed = await _rpc
            .getParsedTransaction(signature)
            .timeout(const Duration(seconds: 15));
        if (parsed == null) return null;
        final activity = TransactionActivity.fromSolana(parsed, owner);
        final missing = activity.changes
            .map((c) => c.mint)
            .where((mint) => mint != wsolMint && !_metadata.containsKey(mint))
            .toSet()
            .toList();
        if (missing.isNotEmpty) {
          try {
            _metadata.addAll(
              await _rpc
                  .getAssetBatch(missing)
                  .timeout(const Duration(seconds: 8)),
            );
          } catch (_) {
            // A missing logo/name must not hide confirmed token movements.
          }
        }
        return TransactionActivity(
          kind: activity.kind,
          failed: activity.failed,
          fee: activity.fee,
          sender: activity.sender,
          recipient: activity.recipient,
          created: activity.created,
          changes: [
            for (final c in activity.changes)
              ActivityTokenChange(
                mint: c.mint,
                amount: c.amount,
                decimals: c.decimals,
                symbol: c.symbol ?? _metadata[c.mint]?.symbol,
                imageUrl: _metadata[c.mint]?.imageUrl,
              ),
          ],
        );
      } finally {
        _pending.remove(key);
      }
    });
  }

  void dispose() => _rpc.dispose();
}
