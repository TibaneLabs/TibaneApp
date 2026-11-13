import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ledger/ledger_transport.dart';
import '../wallet/hardware_wallet.dart';
import '../wallet/libwallet_backend.dart';
import 'catcard_reader.dart';

/// Something the person has to do on (or with) their hardware wallet, for the
/// UI to say. Mapped to localized text by `installHardwareWalletUi`.
enum HardwareStatus {
  /// The CatCard has the request queued: the person is in another menu.
  catcardQueued,

  /// The question is on the CatCard's screen.
  catcardDeciding,

  /// Review and approve on the Ledger.
  ledgerReview,

  /// Opening the named Ledger app ([HardwareStatusEvent.detail]).
  ledgerOpeningApp,
}

class HardwareStatusEvent {
  const HardwareStatusEvent(this.status, [this.detail]);

  final HardwareStatus status;
  final String? detail;
}

/// Why the app could not reach a hardware wallet, for the UI to explain.
class HardwareWalletException implements Exception {
  const HardwareWalletException(this.code, [this.detail]);

  /// `catcard_missing`, `ledger_missing`, `ledger_app`, `cancelled`.
  final String code;
  final String? detail;

  @override
  String toString() =>
      'HardwareWalletException($code${detail == null ? '' : ': $detail'})';
}

/// Progress of a Ledger management operation (libwallet `ledger:progress`).
class LedgerProgress {
  const LedgerProgress({
    required this.op,
    required this.type,
    this.app,
    this.progress,
    this.message,
  });

  factory LedgerProgress.fromJson(Map<String, dynamic> j) => LedgerProgress(
    op: j['op'] as String? ?? '',
    type: j['type'] as String? ?? '',
    app: j['app'] as String?,
    progress: (j['progress'] as num?)?.toDouble(),
    message: j['message'] as String?,
  );

  /// `install`, `uninstall`, `genuine`, `firmware` or `flash`.
  final String op;

  /// `opened`, `permissionRequested`, `permissionGranted`, `progress` or
  /// `warning`.
  final String type;

  /// The app being installed or removed.
  final String? app;

  /// 0..1 for `progress`.
  final double? progress;

  /// The text of a `warning`.
  final String? message;
}

/// Whether [e] is libwallet saying the Ledger app it was asked to open is
/// not installed (`404`, as opposed to `404` for no device at all).
bool isLedgerAppMissing(Object e) =>
    e is LibwalletException &&
    e.code == '404' &&
    e.message.contains('not installed');

/// An `airgap:sign` request: a libwallet signing call is waiting for the
/// air-gapped signer's answer. Show [request] (its [AirgapSignRequest.parts]
/// as an animated QR), scan the answer, and hand it to [submit]; or [cancel].
class AirgapSignPrompt {
  AirgapSignPrompt._(this._client, this.request);

  final LibwalletClient _client;
  final AirgapSignRequest request;

  LibwalletClient get client => _client;

  /// Hand the scanned answer (a completed decoder) to the waiting call.
  /// Throws when it is not this account's signature over this request.
  Future<AirgapSignedTransaction> submit(String decoderId) => _client.airgap
      .submitSignature(decoderId: decoderId, requestId: request.requestId);

  /// Give up: the waiting signing call fails with code 4001.
  Future<void> cancel() async {
    try {
      await _client.airgap.cancelSign(request.requestId);
    } catch (e) {
      debugPrint('[hardware] cancelSign: $e');
    }
  }
}

/// The device side of hardware wallets (libwallet 0.5.9). libwallet holds the
/// accounts and speaks every device protocol; the generic signing routes
/// (`Account:signTransaction`, swaps, dApp approvals, …) have the device sign
/// when the account is on one. On a phone the app must:
///
/// - carry CatCard APDUs to the device's CCID reader (`catcard.ccidBridge`),
/// - carry Ledger APDUs over USB-OTG or Bluetooth (`ledger.bridge`),
/// - show the CatCard pairing code for the person to compare,
/// - show an air-gapped request as QR codes and scan the signer's answer.
///
/// The UI parts are hooks set by `installHardwareWalletUi`, so a signing call
/// from any screen reaches the person.
class HardwareWalletService extends ChangeNotifier {
  HardwareWalletService(this._libwallet, {LedgerConnector? ledger})
    : ledger = ledger ?? LedgerConnector.instance {
    _libwallet.onClientReady(_attach);
    unawaited(_forgetLegacyCatCard());
  }

  final LibwalletBackend _libwallet;

  /// Ledger devices over USB-OTG / Bluetooth.
  final LedgerConnector ledger;

  final CatCardReader _catcard = CatCardReader();
  final List<StreamSubscription<dynamic>> _subs = [];
  LibwalletClient? _client;

  /// Shows the pairing code and resolves true only when the person confirms
  /// the CatCard shows the same. Never accept automatically: the comparison
  /// is the whole defence against a relay between phone and device.
  Future<bool> Function(CatCardPairing pairing)? confirmCatCardPairing;

  /// Shows an air-gapped request and resolves once it was answered (true) or
  /// abandoned (false).
  Future<bool> Function(AirgapSignPrompt prompt)? showAirgapRequest;

  /// Lets the person pick and connect a Ledger. Resolves true once
  /// [LedgerConnector.current] is open.
  Future<bool> Function()? connectLedgerDevice;

  /// Offers to install the Ledger app [app] that an operation needs and the
  /// device lacks, and installs it (with [installLedgerApp]) on a yes.
  /// Resolves true once it is installed.
  Future<bool> Function(String app)? offerLedgerAppInstall;

  /// Progress for the person.
  void Function(HardwareStatusEvent event)? onStatus;

  final StreamController<LedgerProgress> _ledgerProgress =
      StreamController<LedgerProgress>.broadcast();

  /// Progress of Ledger installs, removals, genuine checks and firmware
  /// updates.
  Stream<LedgerProgress> get ledgerProgress => _ledgerProgress.stream;

  void _status(HardwareStatus s, [String? detail]) =>
      onStatus?.call(HardwareStatusEvent(s, detail));

  void _attach(LibwalletClient client) {
    _client = client;
    _subs
      ..add(client.catcard.ccidBridge(_catcard.transmit))
      ..add(client.catcard.pairing.listen(_onPairing))
      ..add(client.catcard.waiting.listen(_onWaiting))
      ..add(client.ledger.bridge(_ledgerExchange))
      ..add(
        client.events.where((e) => e.event == 'ledger:progress').listen((e) {
          if (!_ledgerProgress.isClosed) {
            _ledgerProgress.add(LedgerProgress.fromJson(e.data));
          }
        }),
      )
      ..add(
        client.events
            .where((e) => e.event == 'airgap:sign')
            .listen((e) => unawaited(_onAirgapSign(client, e.data))),
      );
  }

  Future<LibwalletClient> _ensureClient() async =>
      _client ?? await _libwallet.ensureClient();

  // ── CatCard ───────────────────────────────────────────────────────────────

  Future<void> _onPairing(CatCardPairing pairing) async {
    final client = _client;
    if (client == null) return;
    var accept = false;
    try {
      accept =
          await (confirmCatCardPairing?.call(pairing) ?? Future.value(false));
    } catch (e) {
      debugPrint('[hardware] pairing prompt failed: $e');
    }
    try {
      await client.catcard.confirmPairing(pairing, accept: accept);
    } catch (e) {
      debugPrint('[hardware] confirmPairing: $e');
    }
  }

  void _onWaiting(CatCardWaiting w) {
    _status(
      w.stage == 'queued'
          ? HardwareStatus.catcardQueued
          : HardwareStatus.catcardDeciding,
      w.what,
    );
  }

  /// Whether a CatCard is plugged in right now.
  Future<bool> catcardPresent() async =>
      (await CatCardReaders.list()).isNotEmpty;

  /// Read the account the person shares on the CatCard (they pick it on the
  /// device; pairing happens first when needed) and save it as a wallet.
  Future<CatCardImportResult> addCatCard({String? name}) async {
    if (!await catcardPresent()) {
      throw const HardwareWalletException('catcard_missing');
    }
    final client = await _ensureClient();
    final keys = await client.catcard.getKeys();
    return client.catcard.importKeys(keys, name: name ?? _catcardName(keys));
  }

  static String _catcardName(CatCardKeys keys) {
    final board = keys.device?.split(' ').first.toUpperCase();
    return board == null || board.isEmpty ? 'CatCard' : 'CatCard $board';
  }

  /// End the paired CatCard session, if any.
  Future<void> disconnectCatCard() async {
    try {
      final client = await _ensureClient();
      await client.catcard.disconnect();
    } catch (e) {
      debugPrint('[hardware] catcard disconnect: $e');
    }
    await _catcard.close();
  }

  /// The app's own CatCard backend (before libwallet 0.5.9) kept one Solana
  /// account in preferences. libwallet holds CatCard wallets now; the device
  /// is added again from "Add hardware wallet".
  Future<void> _forgetLegacyCatCard() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final k in prefs.getKeys().where((k) => k.startsWith('catcard_'))) {
        await prefs.remove(k);
      }
    } catch (_) {}
  }

  // ── Ledger ────────────────────────────────────────────────────────────────

  Future<Uint8List> _ledgerExchange(Uint8List apdu) async {
    var transport = ledger.current;
    if (transport == null || !transport.isOpen) {
      final ok = await (connectLedgerDevice?.call() ?? Future.value(false));
      transport = ledger.current;
      if (!ok || transport == null || !transport.isOpen) {
        throw const HardwareWalletException('ledger_missing');
      }
    }
    // The transport reconnects by itself when the Ledger re-enumerates
    // (an app opening or quitting drops the link).
    return transport.exchange(apdu);
  }

  /// Make sure a Ledger is connected and runs [app] (`Ethereum`, `Bitcoin`,
  /// `Solana`), opening it from the dashboard when needed. The device may ask
  /// the person to allow opening it.
  Future<void> ensureLedgerApp(String app) async {
    final client = await _ensureClient();
    var info = await client.ledger.info();
    if (info.appName == app) return;
    _status(HardwareStatus.ledgerOpeningApp, app);
    if (!info.dashboard) {
      await client.ledger.quitApp();
      await Future<void>.delayed(const Duration(milliseconds: 1200));
    }
    try {
      await client.ledger.openApp(app);
    } catch (e) {
      if (!isLedgerAppMissing(e)) rethrow;
      final installed =
          await (offerLedgerAppInstall?.call(app) ?? Future.value(false));
      if (!installed) throw HardwareWalletException('ledger_app_missing', app);
      await client.ledger.openApp(app);
    }
    for (var attempt = 0; attempt < 10; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        info = await client.ledger.info();
        if (info.appName == app) return;
      } catch (e) {
        debugPrint('[hardware] ledger info while opening $app: $e');
      }
    }
    throw HardwareWalletException('ledger_app', app);
  }

  // ── Ledger device management (libwallet's manager routes) ────────────────

  /// Make sure a Ledger is connected and on its dashboard (no app open), which
  /// device management needs.
  Future<void> ensureLedgerDashboard() async {
    final client = await _ensureClient();
    var info = await client.ledger.info();
    if (info.dashboard) return;
    await client.ledger.quitApp();
    for (var attempt = 0; attempt < 10; attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      try {
        info = await client.ledger.info();
        if (info.dashboard) return;
      } catch (e) {
        debugPrint('[hardware] ledger info while quitting: $e');
      }
    }
    throw const HardwareWalletException('ledger_dashboard');
  }

  /// Model, firmware and the firmware update available, if any. Leaves the
  /// device on its dashboard, unless it is mid-update ([LedgerStatus.bootloader]
  /// or [LedgerStatus.updater]), when no app can run anyway.
  Future<LedgerStatus> ledgerStatus() async {
    final client = await _ensureClient();
    try {
      await ensureLedgerDashboard();
    } catch (e) {
      // A device in bootloader mode answers no app query: ask for its status
      // directly.
      debugPrint('[hardware] ledger dashboard before status: $e');
    }
    return client.ledger.status();
  }

  /// Whether the manufacturer vouches for the device. The device asks the
  /// person to allow the check.
  Future<bool> ledgerGenuineCheck() async {
    await ensureLedgerDashboard();
    return (await _ensureClient()).ledger.genuineCheck();
  }

  /// The installed apps. The device asks the person to allow the listing.
  Future<List<LedgerApp>> ledgerInstalledApps() async {
    await ensureLedgerDashboard();
    return (await _ensureClient()).ledger.installedApps();
  }

  /// The apps available for this device and firmware.
  Future<List<LedgerApp>> ledgerCatalog() async {
    await ensureLedgerDashboard();
    return (await _ensureClient()).ledger.catalog();
  }

  /// Install [app] (and what it needs). The device asks the person to allow
  /// it; progress arrives on [ledgerProgress].
  Future<void> installLedgerApp(String app) async {
    await ensureLedgerDashboard();
    await (await _ensureClient()).ledger.installApp(app);
  }

  /// Remove [app]. Keys and funds stay on the device.
  Future<void> uninstallLedgerApp(String app) async {
    await ensureLedgerDashboard();
    await (await _ensureClient()).ledger.uninstallApp(app);
  }

  /// Step 1 of a firmware update: install the updater. The person confirms
  /// on the device, which then restarts, so the link is closed here and has
  /// to be opened again before [continueLedgerFirmware]. Returns whether the
  /// device restarts in bootloader mode (older models: MCU / bootloader to
  /// flash next).
  Future<bool> startLedgerFirmwareUpdate(LedgerFirmwareUpdate update) async {
    await ensureLedgerDashboard();
    final flashMcu = await (await _ensureClient()).ledger.firmwareUpdate(
      update,
    );
    await ledger.closeCurrent();
    return flashMcu;
  }

  /// After the restart: flash the MCU / bootloader for as long as the device
  /// comes back in bootloader mode. Without [update] (the app was restarted
  /// mid-update) libwallet works out what the device needs. Returns the
  /// device's status at the end.
  Future<LedgerStatus> continueLedgerFirmware({
    LedgerFirmwareUpdate? update,
  }) async {
    final client = await _ensureClient();
    var st = await client.ledger.status();
    for (var round = 0; round < 4 && st.bootloader; round++) {
      await client.ledger.firmwareFlash(update: update);
      // Each flash restarts the device again.
      await ledger.closeCurrent();
      await Future<void>.delayed(const Duration(seconds: 4));
      st = await client.ledger.status();
    }
    return st;
  }

  /// Read the keys of [apps] in turn (each opened on the device) into one
  /// Ledger wallet, created by the first import that succeeds. An app that
  /// is missing or refused is reported in `failed` and the others still go
  /// in; `walletId` is null when none did.
  Future<({String? walletId, Map<String, Object> failed})> addLedger(
    List<String> apps, {
    String name = 'Ledger',
  }) async {
    final client = await _ensureClient();
    String? walletId;
    final failed = <String, Object>{};
    for (final app in apps) {
      try {
        await ensureLedgerApp(app);
        final keys = await client.ledger.getKeys();
        final result = await client.ledger.importKeys(
          keys,
          name: walletId == null ? name : null,
          wallet: walletId,
        );
        walletId ??= result.wallet.id;
      } on HardwareWalletException catch (e) {
        // No device at all: the remaining apps would fail the same way.
        if (e.code == 'ledger_missing') rethrow;
        failed[app] = e;
      } catch (e) {
        failed[app] = e;
      }
    }
    return (walletId: walletId, failed: failed);
  }

  // ── Air-gapped ────────────────────────────────────────────────────────────

  Future<void> _onAirgapSign(
    LibwalletClient client,
    Map<String, dynamic> data,
  ) async {
    final raw = data['request'];
    if (raw is! Map) return;
    final AirgapSignRequest request;
    try {
      request = AirgapSignRequest.fromJson(Map<String, dynamic>.from(raw));
    } catch (e) {
      debugPrint('[hardware] bad airgap:sign event: $e');
      return;
    }
    final prompt = AirgapSignPrompt._(client, request);
    var answered = false;
    try {
      answered = await (showAirgapRequest?.call(prompt) ?? Future.value(false));
    } catch (e) {
      debugPrint('[hardware] airgap prompt failed: $e');
    }
    if (!answered) await prompt.cancel();
  }

  /// Import an air-gapped signer's key export from a completed decoder.
  Future<AirgapImportResult> importAirgap({
    required String decoderId,
    String? name,
  }) async {
    final client = await _ensureClient();
    return client.airgap.importKeys(decoderId: decoderId, name: name);
  }

  // ── Before signing ────────────────────────────────────────────────────────

  /// Get the device ready to sign for an account of [accountType] on a
  /// [kind] wallet, before the signing call goes to libwallet: a CatCard must
  /// be plugged in, a Ledger connected and in the right app. An air-gapped
  /// signer needs nothing here (the request is shown when libwallet raises
  /// it). Throws [HardwareWalletException].
  Future<void> prepareToSign(HardwareKind kind, String? accountType) async {
    switch (kind) {
      case HardwareKind.catcard:
        if (!await catcardPresent()) {
          throw const HardwareWalletException('catcard_missing');
        }
      case HardwareKind.ledger:
        final app = accountType == null
            ? null
            : ledgerAppForAccountType(accountType);
        if (app != null) await ensureLedgerApp(app);
        _status(HardwareStatus.ledgerReview);
      case HardwareKind.airgap:
        break;
    }
  }

  /// Show [accountId]'s address on the device for the person to compare.
  /// Returns the address the device confirmed; throws when it shows another.
  Future<String> showAddressOnDevice(
    HardwareKind kind,
    String accountId,
    String accountType,
  ) async {
    final client = await _ensureClient();
    switch (kind) {
      case HardwareKind.catcard:
        if (!await catcardPresent()) {
          throw const HardwareWalletException('catcard_missing');
        }
        return client.catcard.showAddress(accountId);
      case HardwareKind.ledger:
        final app = ledgerAppForAccountType(accountType);
        if (app != null) await ensureLedgerApp(app);
        return client.ledger.showAddress(accountId);
      case HardwareKind.airgap:
        throw UnsupportedError('an air-gapped signer has no link to the phone');
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      unawaited(s.cancel());
    }
    _subs.clear();
    unawaited(_catcard.close());
    unawaited(_ledgerProgress.close());
    super.dispose();
  }
}
