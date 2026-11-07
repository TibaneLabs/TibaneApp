# Tibane App

Flutter app for Solana Seeker phone, providing Tibane Labs tools from tibane.net.

## Architecture

- **Theme**: `lib/theme/tibane_theme.dart` - Dark theme matching tibane.net (orange/gold accents, DM Sans font)
- **Services**: `lib/services/` - WalletService (MWA), RpcService (Helius RPC)
- **Models**: `lib/models/` - StakingPool, UserStake, TokenAccount deserialization matching on-chain layout
- **Screens**: Home, Incinerator, Staking Pools, Staking Detail, Token Info, About
- **Widgets**: CatLogo, TibaneCard, GradientButton, WalletButton

## Key Constants

- Helius RPC: `mainnet.helius-rpc.com` with API key in `solana_constants.dart`
- ChiefStaker Program: `3Ecf8gyRURyrBtGHS1XAVXyQik5PqgDch4VkxrH4ECcr`
- $ChiefPussy Mint: `DRtvTCzfiKGhCVREmBbZdN9sB8PHeq9KdRZ3VmFhpump`
- Reference site: `/Users/magicaltux/projects/tibanenet` (Vue 3 + TypeScript)

## Build

```bash
flutter pub get
flutter analyze
flutter build apk --debug
```

## Notes

- Wallet connection uses MWA (Mobile Wallet Adapter) for Seeker integration
- MWA stub in wallet_service.dart - needs `solana_mobile_client` package for production
- Account deserialization matches the TypeScript in tibanenet/src/lib/staker.ts
- App ID: `net.tibane.tibaneapp`
