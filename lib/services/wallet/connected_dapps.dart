import 'package:libwallet/libwallet.dart'
    show LibwalletClient, WcSession, Web3Connection;

import '../wallet_service.dart';
import 'logical_wallet.dart';

typedef ConnectedAccount = ({String id, String chain, String address});

List<ConnectedAccount> connectedAccountsFor(
  WalletService wallet,
  String walletId,
) {
  final accounts = wallet.accountsService;
  final groups = buildLogicalWallets(
    accounts.walletsById.values,
    attachedWalletParents: accounts.attachedWalletParents,
    walletGroups: accounts.walletGroups,
  );
  final walletIds = <String>{walletId};
  for (final group in groups) {
    if (group.containsWallet(walletId)) {
      walletIds.addAll(group.wallets.map((w) => w.id));
      break;
    }
  }
  return [
    for (final account in accounts.rawAccounts)
      if (walletIds.contains(account.wallet))
        (id: account.id, chain: account.type, address: account.address),
  ];
}

bool walletConnectSessionMatches(
  WcSession session,
  Iterable<ConnectedAccount> accounts,
) {
  final expiry = session.expiry;
  if (!session.isActive ||
      session.topic.isEmpty ||
      (expiry != null && !expiry.isAfter(DateTime.now()))) {
    return false;
  }
  for (final namespace in session.namespaces.values.whereType<Map>()) {
    final approved = namespace['accounts'];
    if (approved is! List) continue;
    for (final caip10 in approved.whereType<String>()) {
      final parts = caip10.split(':');
      if (parts.length != 3 || parts[1].isEmpty || parts[2].isEmpty) continue;
      for (final account in accounts) {
        final chain = switch (account.chain) {
          'ethereum' => 'eip155',
          'solana' => 'solana',
          'bitcoin' => 'bip122',
          _ => null,
        };
        if (chain != parts[0] || account.address.isEmpty) continue;
        if (chain == 'eip155'
            ? account.address.toLowerCase() == parts[2].toLowerCase()
            : account.address == parts[2]) {
          return true;
        }
      }
    }
  }
  return false;
}

class ConnectedDapp {
  ConnectedDapp.site(Web3Connection site)
    : id = site.id,
      name = site.host,
      created = site.created,
      isSession = false;

  ConnectedDapp.session(WcSession session)
    : id = session.topic,
      name = session.peerName.isNotEmpty
          ? session.peerName
          : session.peerMetadata['url'] is String
          ? session.peerMetadata['url'] as String
          : '',
      created = session.created,
      isSession = true;

  final String id;
  final String name;
  final DateTime? created;
  final bool isSession;

  Future<void> revoke(LibwalletClient client) => isSession
      ? client.walletConnect.disconnect(id)
      : client.web3Connections.delete(id);
}

Future<List<ConnectedDapp>> listConnectedDapps(
  LibwalletClient client,
  List<ConnectedAccount> accounts,
) async {
  if (accounts.isEmpty) return [];
  final ids = accounts.map((a) => a.id).toSet();
  final (sites, sessions) = await (
    client.web3Connections.list(),
    client.walletConnect.sessions(),
  ).wait;
  return [
    for (final site in sites)
      if (ids.contains(site.account)) ConnectedDapp.site(site),
    for (final session in sessions)
      if (walletConnectSessionMatches(session, accounts))
        ConnectedDapp.session(session),
  ]..sort(
    (a, b) => (b.created?.millisecondsSinceEpoch ?? 0).compareTo(
      a.created?.millisecondsSinceEpoch ?? 0,
    ),
  );
}
