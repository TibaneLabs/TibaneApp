/// Token account model for the incinerator
class TokenAccount {
  final String pubkey;
  final String mint;
  final String owner;
  final BigInt amount;
  final int decimals;
  final BigInt rentLamports;
  final bool isToken2022;

  // Metadata (enriched later)
  String? name;
  String? symbol;
  String? imageUrl;
  double? usdPrice;

  bool selected;

  TokenAccount({
    required this.pubkey,
    required this.mint,
    required this.owner,
    required this.amount,
    required this.decimals,
    required this.rentLamports,
    this.isToken2022 = false,
    this.name,
    this.symbol,
    this.imageUrl,
    this.usdPrice,
    this.selected = false,
  });

  double get displayAmount => amount.toDouble() / BigInt.from(10).pow(decimals).toDouble();

  double get rentSol => rentLamports.toDouble() / 1e9;

  String get displayName => name ?? symbol ?? 'Unknown Token';

  bool get isEmpty => amount == BigInt.zero;
}

/// Token metadata from Helius getAsset
class TokenMetadata {
  final String mint;
  final String? name;
  final String? symbol;
  final String? imageUrl;
  final int decimals;
  final double? pricePerToken;
  final BigInt supply;
  final BigInt burned;

  TokenMetadata({
    required this.mint,
    this.name,
    this.symbol,
    this.imageUrl,
    this.decimals = 6,
    this.pricePerToken,
    BigInt? supply,
    BigInt? burned,
  }) : supply = supply ?? BigInt.zero,
       burned = burned ?? BigInt.zero;

  TokenMetadata copyWith({
    String? name,
    String? symbol,
    String? imageUrl,
    int? decimals,
    double? pricePerToken,
    BigInt? supply,
    BigInt? burned,
  }) {
    return TokenMetadata(
      mint: mint,
      name: name ?? this.name,
      symbol: symbol ?? this.symbol,
      imageUrl: imageUrl ?? this.imageUrl,
      decimals: decimals ?? this.decimals,
      pricePerToken: pricePerToken ?? this.pricePerToken,
      supply: supply ?? this.supply,
      burned: burned ?? this.burned,
    );
  }

  factory TokenMetadata.fromHeliusAsset(Map<String, dynamic> json) {
    final content = json['content'] as Map<String, dynamic>?;
    final metadata = content?['metadata'] as Map<String, dynamic>?;
    final links = content?['links'] as Map<String, dynamic>?;
    final tokenInfo = json['token_info'] as Map<String, dynamic>?;

    return TokenMetadata(
      mint: json['id'] as String? ?? '',
      name: metadata?['name'] as String?,
      symbol: metadata?['symbol'] as String?,
      imageUrl: links?['image'] as String?,
      decimals: tokenInfo?['decimals'] as int? ?? 6,
      pricePerToken: (tokenInfo?['price_info'] as Map<String, dynamic>?)?['price_per_token'] as double?,
      supply: BigInt.tryParse('${tokenInfo?['supply'] ?? '0'}') ?? BigInt.zero,
    );
  }
}

/// NFT item for the incinerator
class NftItem {
  final String id;
  final String name;
  final String? image;
  final String? collection;
  final bool compressed;
  final String? mint;
  final String? tokenAccount;
  final String? treeAddress;
  final int? leafIndex;
  final String? dataHash;
  final String? creatorHash;
  final int rentLamports;

  bool selected;

  NftItem({
    required this.id,
    required this.name,
    this.image,
    this.collection,
    required this.compressed,
    this.mint,
    this.tokenAccount,
    this.treeAddress,
    this.leafIndex,
    this.dataHash,
    this.creatorHash,
    this.rentLamports = 0,
    this.selected = false,
  });

  factory NftItem.fromHeliusAsset(Map<String, dynamic> json) {
    final content = json['content'] as Map<String, dynamic>?;
    final metadata = content?['metadata'] as Map<String, dynamic>?;
    final links = content?['links'] as Map<String, dynamic>?;
    final compression = json['compression'] as Map<String, dynamic>?;
    final grouping = json['grouping'] as List?;

    final isCompressed = compression?['compressed'] == true;

    String? collectionName;
    if (grouping != null) {
      for (final g in grouping) {
        if (g['group_key'] == 'collection') {
          collectionName = g['group_value'] as String?;
          break;
        }
      }
    }

    return NftItem(
      id: json['id'] as String? ?? '',
      name: metadata?['name'] as String? ?? 'Unknown NFT',
      image: links?['image'] as String?,
      collection: collectionName,
      compressed: isCompressed,
      mint: isCompressed ? null : json['id'] as String?,
      tokenAccount: null, // Derived at burn time via ATA
      treeAddress: isCompressed ? (compression?['tree'] as String?) : null,
      leafIndex: isCompressed ? (compression?['leaf_id'] as int?) : null,
      dataHash: isCompressed ? (compression?['data_hash'] as String?) : null,
      creatorHash: isCompressed ? (compression?['creator_hash'] as String?) : null,
      rentLamports: isCompressed ? 0 : 15000000, // ~0.015 SOL for regular NFTs
    );
  }
}

/// Domain item for the incinerator
class DomainItem {
  final String id;
  final String name;
  final int rentLamports;

  bool selected;

  DomainItem({
    required this.id,
    required this.name,
    this.rentLamports = 3000000, // ~0.003 SOL typical
    this.selected = false,
  });
}

/// Token holder info
class TokenHolder {
  final String address;
  final BigInt amount;
  final double percentage;

  TokenHolder({
    required this.address,
    required this.amount,
    required this.percentage,
  });
}
