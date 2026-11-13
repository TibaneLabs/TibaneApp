import 'package:flutter_test/flutter_test.dart';
import 'package:libwallet/libwallet.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tibaneapp/services/hardware/hardware_wallet_service.dart';
import 'package:tibaneapp/services/wallet/libwallet_backend.dart';

/// Answers libwallet `Ledger:*` routes from a script: [answers] maps a path
/// to a queue of answers (a value, or an exception to throw); the last one
/// repeats.
class _Transport implements Transport {
  final calls = <(String, Map<String, dynamic>)>[];
  final answers = <String, List<Object?>>{};

  @override
  Future<dynamic> request(
    String path,
    String verb, [
    Map<String, dynamic>? params,
  ]) async {
    calls.add((path, params ?? const {}));
    final queue = answers[path];
    if (queue == null || queue.isEmpty) return <String, dynamic>{};
    final a = queue.length > 1 ? queue.removeAt(0) : queue.first;
    if (a is Exception) throw a;
    return a;
  }

  List<String> get paths => [for (final c in calls) c.$1];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements LibwalletClient {
  _Client(Transport transport) : ledger = LedgerApi(transport);
  @override
  final LedgerApi ledger;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Backend extends LibwalletBackend {
  _Backend(this.client);
  final LibwalletClient client;
  @override
  Future<LibwalletClient> ensureClient() async => client;
}

Map<String, dynamic> _info(String app) => {
  'app': {'name': app, 'version': '1.0'},
  'dashboard': app == 'BOLOS',
};

const _missing = LibwalletException(
  code: '404',
  message: 'ledger: app "Solana" is not installed',
);

void main() {
  late _Transport transport;
  late HardwareWalletService hw;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    transport = _Transport();
    hw = HardwareWalletService(_Backend(_Client(transport)));
  });
  tearDown(() => hw.dispose());

  group('isLedgerAppMissing', () {
    test('only a missing app, not a missing device', () {
      expect(isLedgerAppMissing(_missing), isTrue);
      expect(
        isLedgerAppMissing(
          const LibwalletException(code: '404', message: 'ledger: no device'),
        ),
        isFalse,
      );
      expect(isLedgerAppMissing(StateError('x')), isFalse);
    });
  });

  test('LedgerProgress reads libwallet ledger:progress data', () {
    final p = LedgerProgress.fromJson({
      'op': 'install',
      'app': 'Solana',
      'type': 'progress',
      'progress': 0.25,
    });
    expect(p.op, 'install');
    expect(p.app, 'Solana');
    expect(p.progress, 0.25);
    expect(
      LedgerProgress.fromJson({
        'op': 'genuine',
        'type': 'warning',
        'message': 'm',
      }).message,
      'm',
    );
  });

  group('a missing app while opening it', () {
    test('is offered for install, installed, then opened', () async {
      transport.answers['Ledger:info'] = [
        _info('BOLOS'), // ensureLedgerApp
        _info('BOLOS'), // ensureLedgerDashboard before the install
        _info('Solana'), // after opening
      ];
      transport.answers['Ledger:openApp'] = [_missing, <String, dynamic>{}];
      String? offered;
      hw.offerLedgerAppInstall = (app) async {
        offered = app;
        await hw.installLedgerApp(app);
        return true;
      };
      await hw.ensureLedgerApp('Solana');
      expect(offered, 'Solana');
      expect(transport.paths, [
        'Ledger:info',
        'Ledger:openApp',
        'Ledger:info',
        'Ledger:installApp',
        'Ledger:openApp',
        'Ledger:info',
      ]);
      final install = transport.calls.firstWhere(
        (c) => c.$1 == 'Ledger:installApp',
      );
      expect(install.$2['Name'], 'Solana');
    });

    test(
      'declined: fails with ledger_app_missing, nothing installed',
      () async {
        transport.answers['Ledger:info'] = [_info('BOLOS')];
        transport.answers['Ledger:openApp'] = [_missing];
        hw.offerLedgerAppInstall = (_) async => false;
        await expectLater(
          hw.ensureLedgerApp('Solana'),
          throwsA(
            isA<HardwareWalletException>()
                .having((e) => e.code, 'code', 'ledger_app_missing')
                .having((e) => e.detail, 'detail', 'Solana'),
          ),
        );
        expect(transport.paths, isNot(contains('Ledger:installApp')));
      },
    );

    test('other open failures are not turned into an install offer', () async {
      transport.answers['Ledger:info'] = [_info('BOLOS')];
      transport.answers['Ledger:openApp'] = [
        const LibwalletException(code: '4001', message: 'refused'),
      ];
      var offered = false;
      hw.offerLedgerAppInstall = (_) async => offered = true;
      await expectLater(
        hw.ensureLedgerApp('Solana'),
        throwsA(isA<LibwalletException>()),
      );
      expect(offered, isFalse);
    });
  });

  test('management closes the open app first', () async {
    transport.answers['Ledger:info'] = [_info('Ethereum'), _info('BOLOS')];
    transport.answers['Ledger:apps'] = [
      [
        {'name': 'Solana', 'version': '1.4.0'},
      ],
    ];
    final apps = await hw.ledgerInstalledApps();
    expect(apps.single.name, 'Solana');
    expect(transport.paths, [
      'Ledger:info',
      'Ledger:quitApp',
      'Ledger:info',
      'Ledger:apps',
    ]);
  });

  test('status is still read when the device is in bootloader mode', () async {
    transport.answers['Ledger:info'] = [
      const LibwalletException(code: '502', message: 'no app query'),
    ];
    transport.answers['Ledger:status'] = [
      {'firmware': '1.0', 'bootloader': true},
    ];
    final st = await hw.ledgerStatus();
    expect(st.bootloader, isTrue);
  });

  test('a firmware update in bootloader mode is flashed until done', () async {
    transport.answers['Ledger:status'] = [
      {'firmware': '0.0', 'bootloader': true},
      {'model': 'Nano S', 'firmware': '2.1.0', 'bootloader': false},
    ];
    transport.answers['Ledger:firmwareFlash'] = [
      {'flashed': 'mcu'},
    ];
    final st = await hw.continueLedgerFirmware();
    expect(st.firmware, '2.1.0');
    expect(
      transport.paths.where((p) => p == 'Ledger:firmwareFlash'),
      hasLength(1),
    );
  });
}
