import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart'
    show
        AddNetworkRequest,
        ChainSwitchRequest,
        MessageSignRequest,
        Network,
        Account;

import '../../theme/tibane_theme.dart';

Future<bool> showConnectSheet(
  BuildContext context, {
  required String host,
  required String accountAddress,
}) async {
  return await _show(
    context,
    title: 'Connect wallet',
    host: host,
    approveLabel: 'Connect',
    body: _KeyValue('Account', accountAddress),
  ) ??
      false;
}

Future<bool> showSignSheet(
  BuildContext context, {
  required String host,
  required String verb,
  required Uint8List payload,
  required String accountAddress,
}) async {
  final preview = _previewPayload(payload);
  return await _show(
        context,
        title: verb,
        host: host,
        approveLabel: 'Approve',
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _KeyValue('Account', accountAddress),
            const SizedBox(height: 12),
            const Text(
              'Payload',
              style: TextStyle(color: TibaneColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: TibaneColors.darker,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                preview,
                style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
              ),
            ),
          ],
        ),
      ) ??
      false;
}

/// Renders a [MessageSignRequest] approval sheet that adapts to the shape
/// of the message:
///   • EIP-712 typed data — shows domain, primaryType and the message
///     struct rather than the raw bytes
///   • SIWE / SIWS — shows the parsed "Sign in to `<domain>`" fields
///   • Plain personal_sign — shows the message as text (or hex preview)
Future<bool> showMessageSignSheet(
  BuildContext context, {
  required MessageSignRequest req,
  required String accountAddress,
}) async {
  final host = req.host.isEmpty ? '(unknown)' : req.host;
  final verb = _verbForMethod(req.method);
  final Widget body;
  if (req.structuredData != null) {
    body = _typedDataBody(req, accountAddress);
  } else if (req.isSiwe || req.isSiws) {
    body = _siweBody(req, accountAddress);
  } else {
    body = _plainMessageBody(req, accountAddress);
  }
  return await _show(
        context,
        title: verb,
        host: host,
        approveLabel: 'Sign',
        body: body,
      ) ??
      false;
}

String _verbForMethod(String method) {
  switch (method) {
    case 'eth_signTypedData':
    case 'eth_signTypedData_v3':
    case 'eth_signTypedData_v4':
      return 'Sign typed data';
    case 'personal_sign':
      return 'Sign message';
    case 'solana_signMessage':
      return 'Sign message';
    case 'mpurse_signMessage':
      return 'Sign message';
    default:
      return method.isEmpty ? 'Sign message' : method.replaceAll('_', ' ');
  }
}

Widget _typedDataBody(MessageSignRequest req, String accountAddress) {
  final domain = req.structuredDomain ?? const <String, dynamic>{};
  final primary = req.structuredPrimaryType;
  final message =
      (req.structuredData?['message'] as Map?)?.cast<String, dynamic>() ??
          const <String, dynamic>{};
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _KeyValue('Account', accountAddress),
      if (primary.isNotEmpty) ...[
        const SizedBox(height: 12),
        _KeyValue('Type', primary),
      ],
      if (domain.isNotEmpty) ...[
        const SizedBox(height: 14),
        const _SectionLabel('Domain'),
        const SizedBox(height: 6),
        _StructBox(map: domain),
      ],
      if (message.isNotEmpty) ...[
        const SizedBox(height: 14),
        const _SectionLabel('Message'),
        const SizedBox(height: 6),
        _StructBox(map: message),
      ],
      if (req.warnings.isNotEmpty) ...[
        const SizedBox(height: 14),
        for (final w in req.warnings) _WarningRow(text: w.message),
      ],
    ],
  );
}

Widget _siweBody(MessageSignRequest req, String accountAddress) {
  final f = req.siweFields;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _KeyValue('Account', accountAddress),
      const SizedBox(height: 12),
      _KeyValue('Sign in to', f['domain'] ?? '(unknown)'),
      if ((f['uri'] ?? '').isNotEmpty) ...[
        const SizedBox(height: 8),
        _KeyValue('URI', f['uri']!),
      ],
      if ((f['chainid'] ?? '').isNotEmpty) ...[
        const SizedBox(height: 8),
        _KeyValue('Chain', f['chainid']!),
      ],
      if ((f['expirationtime'] ?? '').isNotEmpty) ...[
        const SizedBox(height: 8),
        _KeyValue('Expires', f['expirationtime']!),
      ],
      if (req.warnings.isNotEmpty) ...[
        const SizedBox(height: 14),
        for (final w in req.warnings) _WarningRow(text: w.message),
      ],
    ],
  );
}

Widget _plainMessageBody(MessageSignRequest req, String accountAddress) {
  final preview = req.messageText.isNotEmpty
      ? req.messageText
      : _previewPayload(req.messageBytes);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _KeyValue('Account', accountAddress),
      const SizedBox(height: 12),
      const _SectionLabel('Message'),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: TibaneColors.darker,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          preview,
          style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
        ),
      ),
      if (req.warnings.isNotEmpty) ...[
        const SizedBox(height: 14),
        for (final w in req.warnings) _WarningRow(text: w.message),
      ],
    ],
  );
}

String _previewPayload(Uint8List bytes) {
  try {
    final text = utf8.decode(bytes, allowMalformed: false);
    if (text.runes.every(_isPrintable)) return text;
  } catch (_) {}
  final n = bytes.length.clamp(0, 128);
  final hex = bytes.sublist(0, n).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  final tail = bytes.length > n ? '  …(+${bytes.length - n} bytes)' : '';
  return '${bytes.length} bytes\n$hex$tail';
}

bool _isPrintable(int rune) =>
    rune == 0x0a || rune == 0x09 || (rune >= 0x20 && rune != 0x7f);

Future<bool?> _show(
  BuildContext context, {
  required String title,
  required String host,
  required String approveLabel,
  required Widget body,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TibaneColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(ctx).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TibaneColors.textDim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(ctx).textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(host,
              style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13)),
          const SizedBox(height: 16),
          body,
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TibaneColors.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  style: FilledButton.styleFrom(
                    backgroundColor: TibaneColors.orange,
                    foregroundColor: TibaneColors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    approveLabel,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _KeyValue extends StatelessWidget {
  final String k;
  final String v;
  const _KeyValue(this.k, this.v);

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 72,
          child: Text(
            k,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
          ),
        ),
        Expanded(
          child: Text(
            v,
            style: monoStyle(fontSize: 12, color: TibaneColors.text),
          ),
        ),
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: monoStyle(fontSize: 10, color: TibaneColors.textDim),
    );
  }
}

/// Renders an EIP-712 struct (domain or message) as a flat indented list
/// of key→value lines. Nested maps recurse one level deep; deeper structs
/// fall back to JSON encoding.
class _StructBox extends StatelessWidget {
  final Map<String, dynamic> map;
  const _StructBox({required this.map});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TibaneColors.darker,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final entry in map.entries) _row(entry.key, entry.value),
        ],
      ),
    );
  }

  Widget _row(String key, dynamic value) {
    String rendered;
    if (value is Map || value is List) {
      try {
        rendered = const JsonEncoder.withIndent('  ').convert(value);
      } catch (_) {
        rendered = value.toString();
      }
    } else {
      rendered = '$value';
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        text: TextSpan(
          style: monoStyle(fontSize: 11, color: TibaneColors.text),
          children: [
            TextSpan(
              text: '$key: ',
              style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
            ),
            TextSpan(text: rendered),
          ],
        ),
      ),
    );
  }
}

/// Sheet for `AddNetworkRequest` — dApp wants the wallet to register a new
/// network without activating it. Returns true on approve.
Future<bool> showAddNetworkSheet(
  BuildContext context, {
  required AddNetworkRequest req,
}) async {
  final n = req.network;
  if (n == null) return false;
  final body = Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _KeyValue('Name', n.name),
      const SizedBox(height: 8),
      _KeyValue('Type', n.type.name),
      const SizedBox(height: 8),
      _KeyValue('Chain ID', n.chainId),
      if (n.rpc.isNotEmpty) ...[
        const SizedBox(height: 8),
        _KeyValue('RPC', n.rpc),
      ],
      if (n.currencySymbol.isNotEmpty) ...[
        const SizedBox(height: 8),
        _KeyValue('Currency', n.currencySymbol),
      ],
      if (req.alreadyExists) ...[
        const SizedBox(height: 14),
        _WarningRow(
          text: 'This network is already in your wallet — approval is a no-op.',
        ),
      ],
      if (!req.isKnown) ...[
        const SizedBox(height: 14),
        _WarningRow(
          text: 'Chain ID ${n.chainId} is not in libwallet\'s known-chain '
              'registry. Verify the network is legitimate before approving.',
        ),
      ],
      if (req.nameMismatch) ...[
        const SizedBox(height: 14),
        _WarningRow(
          text: 'Chain ID ${n.chainId} is registered as "${req.knownName}". '
              'This dApp is proposing a different name — possible phishing.',
        ),
      ],
    ],
  );
  return await _show(
        context,
        title: 'Add network',
        host: req.host.isEmpty ? '(unknown)' : req.host,
        approveLabel: 'Add',
        body: body,
      ) ??
      false;
}

/// Sheet for `WatchAssetRequest` (EIP-747 wallet_watchAsset) — dApp wants
/// us to add a token to the wallet's tracked-assets list. Returns true on
/// approve.
Future<bool> showWatchAssetSheet(
  BuildContext context, {
  required WatchAssetRequest req,
}) async {
  final isNft = req.assetType == 'ERC721' || req.assetType == 'ERC1155';
  final preview = req.address.length > 14
      ? '${req.address.substring(0, 8)}…${req.address.substring(req.address.length - 6)}'
      : req.address;
  final body = Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          if (req.image.isNotEmpty)
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.network(
                req.image,
                width: 40,
                height: 40,
                errorBuilder: (_, __, ___) => const _AssetIconFallback(),
              ),
            )
          else
            const _AssetIconFallback(),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  req.symbol.isEmpty ? '(no symbol)' : req.symbol,
                  style: const TextStyle(
                    color: TibaneColors.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  req.assetType,
                  style: monoStyle(
                    fontSize: 11,
                    color: TibaneColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      const SizedBox(height: 16),
      _KeyValue('Contract', preview),
      if (!isNft) ...[
        const SizedBox(height: 8),
        _KeyValue('Decimals', req.decimals.toString()),
      ],
      if (req.tokenId.isNotEmpty) ...[
        const SizedBox(height: 8),
        _KeyValue('Token ID', req.tokenId),
      ],
      if (req.addressLooksInvalid) ...[
        const SizedBox(height: 14),
        _WarningRow(
          text: 'The contract address does not parse as a valid EVM '
              'address. Approving could add a phishing token — verify the '
              'address before continuing.',
        ),
      ],
      if (req.isAlreadyTracked) ...[
        const SizedBox(height: 14),
        _WarningRow(
          text: 'This token is already tracked in your wallet. Approving '
              'is a no-op.',
        ),
      ],
    ],
  );
  return await _show(
        context,
        title: isNft ? 'Add NFT collection' : 'Add token',
        host: req.host.isEmpty ? '(unknown)' : req.host,
        approveLabel: 'Add',
        body: body,
      ) ??
      false;
}

class _AssetIconFallback extends StatelessWidget {
  const _AssetIconFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: TibaneColors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(
        Icons.token_outlined,
        color: TibaneColors.orange,
        size: 22,
      ),
    );
  }
}

class ChainSwitchResult {
  final String? networkId;
  final String? accountId;
  const ChainSwitchResult({this.networkId, this.accountId});
}

/// Sheet for `ChainSwitchRequest` — either a confirm sheet for a specific
/// target network (`targetNetwork` non-null) or a picker over
/// `candidateNetworks`. Returns the picked network/account on approve, or
/// `null` on reject.
Future<ChainSwitchResult?> showChainSwitchSheet(
  BuildContext context, {
  required ChainSwitchRequest req,
}) async {
  return showModalBottomSheet<ChainSwitchResult?>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TibaneColors.card,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => _ChainSwitchSheet(req: req),
  );
}

class _ChainSwitchSheet extends StatefulWidget {
  final ChainSwitchRequest req;
  const _ChainSwitchSheet({required this.req});

  @override
  State<_ChainSwitchSheet> createState() => _ChainSwitchSheetState();
}

class _ChainSwitchSheetState extends State<_ChainSwitchSheet> {
  Network? _pickedNetwork;
  Account? _pickedAccount;

  @override
  void initState() {
    super.initState();
    _pickedNetwork = widget.req.targetNetwork ??
        (widget.req.candidateNetworks.isNotEmpty
            ? widget.req.candidateNetworks.first
            : null);
    final accts = widget.req.candidateAccounts;
    if (accts.isNotEmpty) _pickedAccount = accts.first;
  }

  @override
  Widget build(BuildContext context) {
    final req = widget.req;
    final pickerMode = req.targetNetwork == null;
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        top: 20,
        bottom: 20 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: TibaneColors.textDim,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            req.isNewNetwork ? 'Add and switch network' : 'Switch network',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(
            req.host.isEmpty ? '(unknown)' : req.host,
            style: const TextStyle(color: TibaneColors.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          if (req.currentNetwork != null)
            _KeyValue('Current', req.currentNetwork!.name),
          const SizedBox(height: 12),
          if (pickerMode) ...[
            const _SectionLabel('Pick a network'),
            const SizedBox(height: 6),
            for (final n in req.candidateNetworks)
              RadioListTile<String>(
                value: n.id,
                groupValue: _pickedNetwork?.id,
                onChanged: (id) {
                  setState(() {
                    _pickedNetwork =
                        req.candidateNetworks.firstWhere((x) => x.id == id);
                  });
                },
                title: Text(
                  n.name,
                  style: const TextStyle(color: TibaneColors.text),
                ),
                subtitle: Text(
                  'chainId ${n.chainId}',
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                activeColor: TibaneColors.orange,
                dense: true,
              ),
          ] else ...[
            _KeyValue('Switch to', req.targetNetwork!.name),
            const SizedBox(height: 8),
            _KeyValue('Chain ID', req.targetNetwork!.chainId),
            if (req.isNewNetwork) ...[
              const SizedBox(height: 14),
              _WarningRow(
                text: 'This network is not in your wallet yet. Approving will '
                    'add it and make it active in one step.',
              ),
            ],
          ],
          if (req.candidateAccounts.length > 1) ...[
            const SizedBox(height: 12),
            const _SectionLabel('Pick an account'),
            const SizedBox(height: 6),
            for (final a in req.candidateAccounts)
              RadioListTile<String>(
                value: a.id,
                groupValue: _pickedAccount?.id,
                onChanged: (id) {
                  setState(() {
                    _pickedAccount =
                        req.candidateAccounts.firstWhere((x) => x.id == id);
                  });
                },
                title: Text(
                  a.name.isEmpty ? a.type : a.name,
                  style: const TextStyle(color: TibaneColors.text),
                ),
                subtitle: Text(
                  a.address,
                  overflow: TextOverflow.ellipsis,
                  style: monoStyle(fontSize: 11, color: TibaneColors.textMuted),
                ),
                activeColor: TibaneColors.orange,
                dense: true,
              ),
          ] else if (_pickedAccount != null) ...[
            const SizedBox(height: 8),
            _KeyValue('Account', _pickedAccount!.address),
          ],
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.pop(context),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: TibaneColors.textMuted,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: const Text('Reject'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _pickedNetwork == null || _pickedAccount == null
                      ? null
                      : () => Navigator.pop(
                            context,
                            ChainSwitchResult(
                              networkId: pickerMode ? _pickedNetwork!.id : null,
                              accountId: _pickedAccount!.id,
                            ),
                          ),
                  style: FilledButton.styleFrom(
                    backgroundColor: TibaneColors.orange,
                    foregroundColor: TibaneColors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child: Text(
                    req.isNewNetwork ? 'Add and switch' : 'Switch',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  final String text;
  const _WarningRow({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded,
              color: TibaneColors.gold, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(color: TibaneColors.gold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
