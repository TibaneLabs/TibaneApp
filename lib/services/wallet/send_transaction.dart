import 'package:libwallet/libwallet.dart';

/// One transfer description for both preflight and signing. EVM simulation
/// needs a public sender, while signing resolves the same account by its ID.
UnsignedTransaction buildSendTransaction({
  required Network network,
  required String accountId,
  required String senderAddress,
  required String recipient,
  required Amount amount,
  required String asset,
  required bool simulation,
  MaxSendableResult? maxPlan,
}) {
  if (network.type == NetworkType.evm) {
    final address = RegExp(r'^0x[0-9a-fA-F]{40}$');
    if (!address.hasMatch(senderAddress) || !address.hasMatch(recipient)) {
      throw const FormatException('Invalid EVM address');
    }
    final token = asset.split('.').last;
    final native = token.toUpperCase() == 'NATIVE';
    if (!native && !address.hasMatch(token)) {
      throw const FormatException('Invalid EVM token address');
    }
    final data = native
        ? '0x'
        : '0xa9059cbb${recipient.substring(2).toLowerCase().padLeft(64, '0')}'
              '${amount.value.toRadixString(16).padLeft(64, '0')}';
    if (amount.value.isNegative || amount.value.bitLength > 256) {
      throw const FormatException('Invalid transfer amount');
    }
    return UnsignedTransaction(
      type: 'evm',
      network: network.id,
      from: simulation ? senderAddress : accountId,
      to: native ? recipient : token,
      value: native ? amount : Amount(BigInt.zero, network.currencyDecimals),
      data: data,
      asset: asset,
    );
  }
  if (maxPlan != null) {
    if (network.type != NetworkType.bitcoin ||
        maxPlan.chain != 'bitcoin' ||
        amount.value * BigInt.from(10).pow(maxPlan.max.exp) !=
            maxPlan.max.value * BigInt.from(10).pow(amount.exp)) {
      throw StateError('Maximum spend plan no longer matches this transfer');
    }
    return UnsignedTransaction.maxSend(
      maxPlan,
      to: recipient,
      from: accountId,
      network: network.id,
    );
  }
  return UnsignedTransaction(
    type: network.type == NetworkType.bitcoin ? 'bitcoin_transfer' : 'transfer',
    network: network.id,
    to: recipient,
    from: accountId,
    amount: amount,
    asset: asset,
    priorityLevel: 'medium',
  );
}
