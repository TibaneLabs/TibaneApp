import 'dart:math' as math;

const List<String> kAccountAvatarAssets = [
  'assets/account_pfps/account_pfp_01.png',
  'assets/account_pfps/account_pfp_02.png',
  'assets/account_pfps/account_pfp_03.png',
  'assets/account_pfps/account_pfp_04.png',
  'assets/account_pfps/account_pfp_05.png',
  'assets/account_pfps/account_pfp_06.png',
  'assets/account_pfps/account_pfp_07.png',
  'assets/account_pfps/account_pfp_08.png',
  'assets/account_pfps/account_pfp_09.png',
  'assets/account_pfps/account_pfp_10.png',
  'assets/account_pfps/account_pfp_11.png',
  'assets/account_pfps/account_pfp_12.png',
  'assets/account_pfps/account_pfp_13.png',
];

String pickAccountAvatarAsset({
  Iterable<String> usedAssets = const [],
  math.Random? random,
}) {
  final used = usedAssets.toSet();
  final unused = kAccountAvatarAssets
      .where((asset) => !used.contains(asset))
      .toList(growable: false);
  final pool = unused.isEmpty ? kAccountAvatarAssets : unused;
  final rng = random ?? math.Random();
  return pool[rng.nextInt(pool.length)];
}

Map<String, String> ensureAccountAvatarAssignments({
  required Iterable<String> accountIds,
  required Map<String, String> existingAssignments,
  math.Random? random,
}) {
  final ids = accountIds.toList(growable: false);
  final allowedAssets = kAccountAvatarAssets.toSet();
  final assignments = <String, String>{};
  final used = <String>{};

  for (final id in ids) {
    final existing = existingAssignments[id];
    if (existing != null && allowedAssets.contains(existing)) {
      assignments[id] = existing;
      used.add(existing);
    }
  }

  final rng = random ?? math.Random();
  for (final id in ids) {
    if (assignments.containsKey(id)) continue;
    final asset = pickAccountAvatarAsset(usedAssets: used, random: rng);
    assignments[id] = asset;
    used.add(asset);
  }

  return assignments;
}
