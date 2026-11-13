import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart' show LibwalletException;

import '../../../l10n/l10n.dart';
import '../../../services/hardware/catcard_reader.dart';
import '../../../services/hardware/hardware_wallet_service.dart';
import '../../../services/ledger/ledger_transport.dart';
import '../../../services/wallet_service.dart';
import 'airgap_sign_sheet.dart';
import 'catcard_pairing_sheet.dart';
import 'ledger_connect_sheet.dart';

/// A Ledger transport failure, for a person.
String ledgerErrorText(BuildContext context, LedgerException e) {
  final l10n = context.l10n;
  return switch (e.code) {
    'NO_DEVICE' || 'DISCONNECTED' => l10n.hwErrLedgerMissing,
    'PERMISSION_DENIED' => l10n.hwErrUsbPermission,
    'BLUETOOTH_OFF' => l10n.hwLedgerBluetoothOff,
    _ => l10n.hwErrGeneric(e.message),
  };
}

/// Any hardware-wallet failure (ours, a transport's, or libwallet's), for a
/// person.
String hardwareErrorText(BuildContext context, Object e) {
  final l10n = context.l10n;
  if (e is HardwareWalletException) {
    return switch (e.code) {
      'catcard_missing' => l10n.hwErrCatcardMissing,
      'ledger_missing' => l10n.hwErrLedgerMissing,
      'ledger_app' => l10n.hwErrLedgerApp(e.detail ?? ''),
      _ => l10n.hwErrGeneric(e.code),
    };
  }
  if (e is LedgerException) return ledgerErrorText(context, e);
  if (e is CatCardReaderException) {
    return switch (e.code) {
      'NO_DEVICE' => l10n.hwErrCatcardMissing,
      'PERMISSION_DENIED' => l10n.hwErrUsbPermission,
      _ => l10n.hwErrGeneric(e.message ?? e.code),
    };
  }
  if (e is LibwalletException) {
    return switch (e.code) {
      '4001' => l10n.hwErrDeclined,
      '501' => l10n.hwErrUnsupported,
      _ => l10n.hwErrGeneric(e.message),
    };
  }
  return l10n.hwErrGeneric('$e');
}

/// Whether [e] is the person declining on the device (or cancelling a QR
/// request): no error to report, they know.
bool isHardwareDecline(Object e) => e is LibwalletException && e.code == '4001';

/// Wire the hardware-wallet hooks to the root navigator: CatCard pairing,
/// Ledger device picker, air-gapped QR requests, and progress as snack bars.
/// Called once when [WalletService] is created, so a signing call from any
/// screen reaches the person.
void installHardwareWalletUi(
  WalletService wallet,
  GlobalKey<NavigatorState> navigatorKey,
) {
  final hw = wallet.hardware;
  hw.confirmCatCardPairing = (pairing) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    return showCatCardPairingSheet(ctx, pairing.code);
  };
  hw.showAirgapRequest = (prompt) async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    return showAirgapSignSheet(ctx, prompt);
  };
  hw.connectLedgerDevice = () async {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return false;
    return showLedgerConnectSheet(ctx, hw.ledger);
  };
  hw.onStatus = (event) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    final l10n = ctx.l10n;
    final text = switch (event.status) {
      HardwareStatus.catcardQueued => l10n.hwStatusCatcardQueued,
      HardwareStatus.catcardDeciding => l10n.hwStatusCatcardDeciding,
      HardwareStatus.ledgerReview => l10n.hwStatusLedgerReview,
      HardwareStatus.ledgerOpeningApp => l10n.hwStatusLedgerOpening(
        event.detail ?? '',
      ),
    };
    ScaffoldMessenger.maybeOf(ctx)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(text), duration: const Duration(seconds: 4)),
      );
  };
}
