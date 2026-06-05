import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';
import 'package:tibaneapp/services/wallet/secure_keystore.dart';

/// Phase 6 + 7 unit tests for the QR device-transfer feature.
///
/// The full receive (`importViaDeviceTransfer` / `activateAfterTransfer`) and
/// send (`startDeviceTransferExport` / `confirmDeviceTransferExport`) paths
/// need a live libwallet client + the broker + two devices, so they're
/// validated on-device. What's unit-testable is the pure send-route decision
/// (Phase 7) and the per-wallet device-share isolation the receive flow relies
/// on to ADD a wallet without clobbering the active one (Phase 6).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('deviceTransferSendRoute (Phase 7)', () {
    test('target is the active, unlocked wallet -> exportDirectly', () {
      expect(
        LibwalletBackend.deviceTransferSendRoute(
          activeWalletId: 'wlt-A',
          targetWalletId: 'wlt-A',
          isUnlocked: true,
        ),
        DeviceTransferSendRoute.exportDirectly,
      );
    });

    test('target is active but locked -> unlockFirst', () {
      expect(
        LibwalletBackend.deviceTransferSendRoute(
          activeWalletId: 'wlt-A',
          targetWalletId: 'wlt-A',
          isUnlocked: false,
        ),
        DeviceTransferSendRoute.unlockFirst,
      );
    });

    test('target is a different wallet -> switchFirst', () {
      expect(
        LibwalletBackend.deviceTransferSendRoute(
          activeWalletId: 'wlt-A',
          targetWalletId: 'wlt-B',
          isUnlocked: true,
        ),
        DeviceTransferSendRoute.switchFirst,
      );
    });

    test('different wallet wins even when the active one is locked', () {
      // The active wallet being locked is irrelevant when the target differs —
      // we must switch (which unlocks the target) regardless.
      expect(
        LibwalletBackend.deviceTransferSendRoute(
          activeWalletId: 'wlt-A',
          targetWalletId: 'wlt-B',
          isUnlocked: false,
        ),
        DeviceTransferSendRoute.switchFirst,
      );
    });

    test('no active wallet yet -> switchFirst', () {
      expect(
        LibwalletBackend.deviceTransferSendRoute(
          activeWalletId: null,
          targetWalletId: 'wlt-B',
          isUnlocked: false,
        ),
        DeviceTransferSendRoute.switchFirst,
      );
    });
  });

  group('validateTransferAcceptance (Phase 6 acceptance gate)', () {
    const goodKeys = {
      'Password': 'pw-key',
      'StoreKey': 'store-key',
      'RemoteKey': 'remote-key',
    };

    test('accepts a Solana wallet whose StoreKey share travelled', () {
      expect(
        LibwalletBackend.validateTransferAcceptance(
          curve: 'ed25519',
          keyIdsByType: goodKeys,
          deviceShareKeyIds: {'store-key'},
        ),
        'store-key',
      );
    });

    test('rejects a non-Solana (non-ed25519) wallet', () {
      expect(
        () => LibwalletBackend.validateTransferAcceptance(
          curve: 'secp256k1',
          keyIdsByType: goodKeys,
          deviceShareKeyIds: {'store-key'},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('not a Solana'),
          ),
        ),
      );
    });

    test('rejects a wallet missing the Password share', () {
      expect(
        () => LibwalletBackend.validateTransferAcceptance(
          curve: 'ed25519',
          keyIdsByType: const {'StoreKey': 'store-key'},
          deviceShareKeyIds: {'store-key'},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('missing required key shares'),
          ),
        ),
      );
    });

    test('rejects a wallet missing the StoreKey share', () {
      expect(
        () => LibwalletBackend.validateTransferAcceptance(
          curve: 'ed25519',
          keyIdsByType: const {'Password': 'pw-key'},
          deviceShareKeyIds: const <String>{},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('rejects when the device share for the StoreKey did not travel', () {
      // Wallet metadata is complete, but the transfer payload carried a share
      // for some other key id — the StoreKey device share is absent, so the
      // wallet would not be signable here.
      expect(
        () => LibwalletBackend.validateTransferAcceptance(
          curve: 'ed25519',
          keyIdsByType: goodKeys,
          deviceShareKeyIds: {'some-other-key'},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains("did not include this wallet's device share"),
          ),
        ),
      );
    });
  });

  group('friendlyTransferError mapping', () {
    test('passes StateError messages through verbatim', () {
      expect(
        LibwalletBackend.friendlyTransferError(
          StateError('Transferred wallet is not a Solana (ed25519) wallet'),
        ),
        'Transferred wallet is not a Solana (ed25519) wallet',
      );
    });

    // The wire code arrives inside LibwalletException.message.
    LibwalletException exc(String wireCode) =>
        LibwalletException(message: wireCode, code: '500');

    test('maps malformed / invalid codes to a "not a valid code" message', () {
      for (final code in ['url_malformed', 'token_invalid']) {
        expect(
          LibwalletBackend.friendlyTransferError(exc(code)),
          contains('not a valid device-transfer code'),
        );
      }
    });

    test('maps expiry, decline, timeout, unreachable, missing-session codes',
        () {
      String map(String c) => LibwalletBackend.friendlyTransferError(exc(c));
      expect(map('token_expired'), contains('expired'));
      expect(map('declined'), contains('declined'));
      expect(map('timeout'), contains('did not confirm'));
      expect(map('peer_unreachable'), contains("Couldn't reach"));
      expect(map('session_not_found'), contains('no longer active'));
    });

    test('maps local_offline (0.4.48) to an offline-device message', () {
      expect(
        LibwalletBackend.friendlyTransferError(exc('local_offline')),
        contains("isn't connected to the transfer network"),
      );
    });

    test('falls back to "Transfer failed: <message>" for unknown codes', () {
      expect(
        LibwalletBackend.friendlyTransferError(exc('some_unmapped_code')),
        'Transfer failed: some_unmapped_code',
      );
    });
  });

  group('receive adds without clobbering the active wallet (Phase 6)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    });

    test(
      'activating a received wallet writes its share under the new id and '
      'leaves the active wallet\'s share intact',
      () async {
        // Mirrors the persistence the receive flow performs: the active wallet
        // already has a per-wallet device share; activateAfterTransfer writes
        // the received wallet's share under its OWN id (different password is
        // fine — each wallet is encrypted independently).
        final ks = SecureKeystore();
        await ks.writeDeviceShare(
          walletId: 'active-wallet',
          value: 'active-share',
          password: 'active-pw',
        );
        // Received wallet, activated with its own wallet password.
        await ks.writeDeviceShare(
          walletId: 'received-wallet',
          value: 'received-share',
          password: 'received-pw',
        );

        // The active wallet is untouched — no clobber.
        expect(
          await ks.readDeviceShare(
            walletId: 'active-wallet',
            password: 'active-pw',
          ),
          'active-share',
        );
        // The received wallet is independently usable.
        expect(
          await ks.readDeviceShare(
            walletId: 'received-wallet',
            password: 'received-pw',
          ),
          'received-share',
        );
      },
    );

    test('abandoning a received wallet leaves the active wallet usable',
        () async {
      // If the user backs out before entering the password, only the received
      // wallet's (never-written) share is absent; the active one stays.
      final ks = SecureKeystore();
      await ks.writeDeviceShare(
        walletId: 'active-wallet',
        value: 'active-share',
        password: 'active-pw',
      );
      // received-wallet share was never written (abandoned pre-activate).
      await ks.deleteDeviceShare('received-wallet');

      expect(await ks.hasDeviceShare('active-wallet'), isTrue);
      expect(await ks.hasDeviceShare('received-wallet'), isFalse);
      expect(
        await ks.readDeviceShare(
          walletId: 'active-wallet',
          password: 'active-pw',
        ),
        'active-share',
      );
    });
  });
}
