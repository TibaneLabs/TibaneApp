# Multichain Audit: LibWallet 0.5.5

**Follow-up - 2026-10-23:** The ETH/ERC-20 SEND preflight adapter has been
corrected and its loopback-native regressions now run by default. EVM MPC
signing and Bitcoin-family external history limitations remain. See
[current app fix status](app-audit-fixes-2026-10-23.md).
The original audit snapshot follows.

Date: 2026-10-21. Scope: Ethereum, Bitcoin, Bitcoin Cash, Litecoin and Dogecoin.
This is a verification report, not a statement that all chains are production-ready.
No application signing logic or official SDK files were changed for this audit.

## Safety And Method

- Existing automated tests, native-library integration tests, and code review.
- New native tests use temporary databases, local RPC fixtures and public test vectors only.
- Live requests are read-only: chain identity/height, balances, ERC-20 decimals,
  ModChain asset discovery and Coinbase spot quotes. No signing or broadcasting.
- No user private keys or simulator database were opened; the simulator was not restarted.
- The SDK resolves its default RPC at runtime. Empty/`auto` RPC configuration fields
  are not missing endpoints; the audit uses `Network:resolveRPC`.

## Passed Checks

- Final routine suite: 590 passed, 13 opt-in checks skipped. The explicitly
  enabled audit run passed 17 checks and reproduced two failing EVM adapter
  checks; those failures are not included as successful validations.
- All 583 pre-existing tests passed, including Ethereum private-key import,
  ETH balance handling, Ethereum account backup/restore and distinct BTC/BCH/LTC/DOGE addresses.
- Live ModChain RPC reads succeeded on ETH, BTC, BCH, LTC and DOGE.
- Live ERC-20 `eth_call` returned USDC's six decimals on Ethereum.
- Live `modchain_assets` returned asset lists for public fixture addresses on all four Bitcoin-family chains.
- Coinbase's actual app price service returned a positive USD quote for all five native currencies.
- Local native-library fixtures preserved eight-decimal Bitcoin-family balances and reserved an ETH fee for MAX.
- A control test with a correctly formed low-level EVM `from`/`value` request succeeded.

## Confirmed Findings

### P1: Ethereum SEND Preflight Uses The Wrong Request Shape

`LibwalletBackend.simulateSend` sends an account ID as `from`, a high-level `amount`,
and `asset` to the simulator. With official 0.5.5, the EVM RPC receives
`from: acct-...` instead of the public `0x...` address and no native `value`.
For ERC-20, it also receives the recipient as `to` and empty `data` instead of
the token contract and encoded `transfer(recipient, units)` call.

Reproduced through the app backend wrapper with the official native library.
Both strict checks fail. This is an app/native integration mismatch, not evidence
that ModChain is down. The app needs a chain-aware preflight adapter, or an SDK
builder that expands these high-level transfer fields before simulation.
Do not bypass simulation or convert a failure into an approval.

### P1: Bitcoin-Family MAX Discards Its Spend Plan

Code review: `SendScreen._setMax` keeps only `result.max`. The later simulation
and send recreate a generic transaction without `bitcoinUtxos` or
`bitcoinFeeRate`. The official `MaxSendableResult`/`UnsignedTransaction.maxSend`
contract requires preserving those values to avoid fee/coin-selection drift.
Thus successful MAX calculation does not establish that a subsequent full-balance
send will succeed. No real spend was attempted to force this failure.

### P2: Bitcoin-Family Preview Is Not Full Spend Validation

Native fixture tests show `chain: bitcoin`, `willRevert: false`, but no fee,
inputs or outputs for the app's unbuilt high-level transfer shape. The simulator
does not consult UTXOs on this path. The review UI correctly avoids inventing a
zero fee, but this preview cannot certify affordability or the final transaction.
Build/validate the actual unsigned spend before presenting its fees and outputs.

### P2: Bitcoin-Family Incoming History Has No SDK Provider

Default BTC/BCH/LTC/DOGE networks expose an empty `txHistoryProvider`, consistent
with the SDK contract. Local transactions can still appear, but historical and
incoming transactions are not automatically reconstructed by this provider.
This requires an indexer/SDK history implementation, not a UI refresh alone.

## Additional Code-Review Risks

- `SendScreen._send` still converts entered amounts through `double` before
  constructing a BigInt. This can round 18-decimal ETH/ERC-20 amounts. Use the
  existing exact `parseTokenAmount` helper for the submitted units.
- Activity enrichment/classification is implemented for Solana only. EVM swaps
  may be displayed as simple sent/received transactions. The list's `_isSend`
  comparison is case-sensitive despite EVM checksum/lowercase address variants.
- History is scoped by address but not current network in `getTransactions`;
  one EVM address used on several chains can mix their local transaction rows.
- SDK network metadata defaults to 18 decimals even for Bitcoin-family networks;
  the tested app paths avoid it by using native `Amount.exp` or the family fallback.

## Reproduction

From the TibaneApp project directory:

```bash
flutter test
flutter test test/multichain_native_audit_test.dart --dart-define=MULTICHAIN_LIVE_RPC=true
flutter test test/multichain_transfer_audit_test.dart --dart-define=MULTICHAIN_STRICT_TRANSFERS=true
```

Live checks are opt-in to keep normal tests deterministic and offline. The two
strict EVM preflight reproductions are separately opt-in and intentionally fail
until the adapter is corrected; their skips are not a claim that the bugs passed.

## Not Validated

Real fee-market changes, signed/broadcast transfers, confirmations, production
MPC recovery, live EVM swap quotes/execution/allowances, large token discovery
coverage, and custom/test networks. BNB/Polygon/Tron were not certified by this
five-network audit. An end-to-end release check should use dedicated funded test
wallets/testnets after the preflight and MAX issues are fixed.
