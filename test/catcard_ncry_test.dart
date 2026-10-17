
import 'package:flutter_test/flutter_test.dart';
import 'package:tibaneapp/services/catcard/ncry.dart';
import 'package:tibaneapp/services/catcard/wire.dart';

/// The v2 known-answer vector shared with the firmware's
/// `ncry::tests::known_answer_pins_the_wire_format`, `tools/ncry.py --selftest`
/// and docs/PHONE-APP.md §4.5. Same scalars, same bytes, or this side has
/// diverged from the device.
const _hostPriv =
    '77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a';
const _hostPub =
    '8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a';
const _commit =
    '41b5c26ca1226fb39c62a654157393a96c0179a91af67a6f62f7bd9ad72f144a';
const _devicePriv =
    '5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb';
const _devicePub =
    'de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f';
const _code = 398660;
const _sealedCatcard = '80a853252814c6dd77e16e59d98cf64481bf28f853b316';
const _sealedConfirm = 'a7c96031987b403d35728dfcb775d969c2a8';

void main() {
  test('the host key, its commitment, and the code', () async {
    final init = await PairingInitiator.create(privateKey: bytesOfHex(_hostPriv));
    expect(hexOf(init.publicKey), _hostPub);
    expect(hexOf(init.commit), _commit);
    final session = await init.finish(bytesOfHex(_devicePub));
    expect(session.code, _code);
    expect(session.codeText, '398 660');
  });

  test('sealing under counter 0 matches the firmware byte for byte', () async {
    final init = await PairingInitiator.create(privateKey: bytesOfHex(_hostPriv));
    final a = await init.finish(bytesOfHex(_devicePub));
    expect(hexOf(await a.seal('catcard'.codeUnits)), _sealedCatcard);
    final b = await init.finish(bytesOfHex(_devicePub));
    expect(hexOf(await b.seal([0x44, 0x00])), _sealedConfirm);
  });

  test('the device side opens what the host seals, and counters advance', () async {
    final host = await PairingInitiator.create(privateKey: bytesOfHex(_hostPriv));
    final hostSession = await host.finish(bytesOfHex(_devicePub));
    // The device computes the same schedule from its own scalar; simulate it
    // with the same initiator maths and swapped keys.
    final device = await PairingInitiator.create(
      privateKey: bytesOfHex(_devicePriv),
    );
    expect(hexOf(device.publicKey), _devicePub);
    final deviceSession = (await _deviceSession(device, host)).swapped();
    expect(deviceSession.code, _code);

    final r1 = await hostSession.seal([1, 2, 3]);
    final r2 = await hostSession.seal([4, 5]);
    expect(await deviceSession.open(r1), [1, 2, 3]);
    expect(await deviceSession.open(r2), [4, 5]);
    final back = await deviceSession.seal([9]);
    expect(await hostSession.open(back), [9]);
  });

  test('a tampered record is refused', () async {
    final init = await PairingInitiator.create(privateKey: bytesOfHex(_hostPriv));
    final a = await init.finish(bytesOfHex(_devicePub));
    final b = (await init.finish(bytesOfHex(_devicePub))).swapped();
    final record = await a.seal([1, 2, 3]);
    record[0] ^= 0x01;
    expect(() => b.open(record), throwsA(isA<NcryAuthException>()));
  });

  test('a replayed record is refused: the nonce has moved on', () async {
    final init = await PairingInitiator.create(privateKey: bytesOfHex(_hostPriv));
    final a = await init.finish(bytesOfHex(_devicePub));
    final b = (await init.finish(bytesOfHex(_devicePub))).swapped();
    final record = await a.seal([1]);
    expect(await b.open(record), [1]);
    expect(() => b.open(record), throwsA(isA<NcryAuthException>()));
  });

  test('a fresh initiator has a random key and a matching commitment', () async {
    final x = await PairingInitiator.create();
    final y = await PairingInitiator.create();
    expect(x.publicKey, isNot(equals(y.publicKey)));
    expect(x.commit, await pairingCommitment(x.publicKey));
    expect(x.publicKey, hasLength(32));
  });

  test('the code is shown zero padded in two groups', () {
    expect(pairingCodeText(7), '000 007');
    expect(pairingCodeText(123456), '123 456');
  });
}

/// The session the device derives: X25519 with its scalar against the host's
/// key over the same transcript. The schedule is symmetric in the shared
/// secret, so this is the host's view; `swapped()` turns it around.
Future<NcrySession> _deviceSession(
  PairingInitiator device,
  PairingInitiator host,
) async => NcrySession.fromHandshake(
  shared: await device.sharedSecretWith(host.publicKey),
  commit: host.commit,
  devicePub: device.publicKey,
  hostPub: host.publicKey,
);
