import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

/// Import an existing BIP-39 mnemonic from another wallet (Phantom,
/// Backpack, MetaMask, etc.) and upgrade it into a full MPC wallet.
///
/// Curve-driven, no path picker:
///   1. Mnemonic + passphrase + password + curve (Solana = ed25519,
///      EVM/BTC = secp256k1).
///   2. A 2FA share is verified (email or SMS → code → remoteKey).
///   3. The mnemonic is imported as a 1-of-1 wallet and then promoted
///      IN PLACE to the canonical `[StoreKey, RemoteKey, Password]`
///      committee — the wallet's address is preserved and it becomes a
///      2-of-3 MPC wallet. (Works for both Solana and EVM/BTC seeds.)
class InAppImportMnemonicScreen extends StatefulWidget {
  const InAppImportMnemonicScreen({super.key});

  @override
  State<InAppImportMnemonicScreen> createState() =>
      _InAppImportMnemonicScreenState();
}

enum _Step { input, verifyId, verifyCode, promoting, done, error }

enum _IdMode { email, phone }

class _InAppImportMnemonicScreenState extends State<InAppImportMnemonicScreen> {
  final _mnemonicCtrl = TextEditingController();
  final _passphraseCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _pwCtrl2 = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = PhoneController(
    initialValue: const PhoneNumber(isoCode: IsoCode.US, nsn: ''),
  );
  final _codeCtrl = TextEditingController();

  String _curve = 'ed25519';
  _Step _step = _Step.input;
  String? _error;
  bool _busy = false;

  Wallet? _result;

  // 2FA verification for the wallet's RemoteKey share.
  _IdMode _idMode = _IdMode.email;
  RemoteKeySession? _session;
  String? _remoteKey;
  String _sentTo = '';

  @override
  void dispose() {
    _mnemonicCtrl.dispose();
    _passphraseCtrl.dispose();
    _pwCtrl.dispose();
    _pwCtrl2.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    super.dispose();
  }

  /// Step 1: validate the mnemonic + password, then move to 2FA. The import
  /// itself is deferred to [_runPromote] so an abandoned flow leaves no
  /// stray wallet behind.
  void _continue() {
    final l10n = context.l10n;
    final mnemonic = _mnemonicCtrl.text.trim();
    final words = mnemonic.split(RegExp(r'\s+'));
    if (![12, 15, 18, 21, 24].contains(words.length)) {
      setState(() => _error = l10n.mnemonicInvalidWordCount);
      return;
    }
    if (_pwCtrl.text.length < 8) {
      setState(() => _error = l10n.mnemonicPasswordTooShort);
      return;
    }
    if (_pwCtrl.text != _pwCtrl2.text) {
      setState(() => _error = l10n.errPasswordsMismatch);
      return;
    }
    setState(() {
      _step = _Step.verifyId;
      _error = null;
    });
  }

  /// Step 2a: send the 2FA verification code to the chosen email / phone.
  /// The resulting remoteKey becomes the wallet's RemoteKey share.
  Future<void> _sendCode() async {
    final l10n = context.l10n;
    String identifier;
    if (_idMode == _IdMode.email) {
      identifier = _emailCtrl.text.trim();
      if (!identifier.contains('@')) {
        setState(() => _error = l10n.mnemonicInvalidEmail);
        return;
      }
    } else {
      final phone = _phoneCtrl.value;
      if (!phone.isValid()) {
        setState(() => _error = l10n.mnemonicInvalidPhone);
        return;
      }
      identifier = phone.international;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ws = context.read<WalletService>();
      final session = await ws.libwallet.startVerification(identifier);
      if (!mounted) return;
      setState(() {
        _session = session;
        _sentTo = identifier;
        _step = _Step.verifyCode;
        _busy = false;
      });
    } catch (e) {
      logError('[InAppImportMnemonic._sendCode] send code error: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = WalletError.from(e).message;
      });
    }
  }

  /// Step 2b: verify the code → remoteKey, then import + promote.
  Future<void> _submitCode() async {
    final l10n = context.l10n;
    final code = _codeCtrl.text.trim();
    final session = _session;
    if (session == null) return;
    if (code.length != session.length) {
      setState(() => _error = l10n.mnemonicCodeLength(session.length));
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final ws = context.read<WalletService>();
      final remoteKey = await ws.libwallet.verifyEmailCode(
        session: session.session,
        code: code,
      );
      if (!mounted) return;
      _remoteKey = remoteKey;
      setState(() => _busy = false);
      await _runPromote();
    } catch (e) {
      logError('[InAppImportMnemonic._submitCode] code verification error: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = WalletError.from(e).message;
      });
    }
  }

  /// Step 3: import the mnemonic as the chosen curve and promote it in place
  /// to a `[StoreKey, RemoteKey, Password]` committee (the backend also
  /// persists the device share so the wallet is unlockable afterwards).
  Future<void> _runPromote() async {
    final remoteKey = _remoteKey;
    if (remoteKey == null) return;
    // Wallet name passed to libwallet — not translated (stored on-chain /
    // in the backend; the user can rename it later).
    final name = _curve == 'ed25519'
        ? 'Imported Solana wallet'
        : 'Imported EVM/BTC wallet';
    setState(() {
      _step = _Step.promoting;
      _error = null;
    });
    try {
      final ws = context.read<WalletService>();
      final wallet = await ws.libwallet.importAndPromoteMnemonic(
        mnemonic: _mnemonicCtrl.text.trim(),
        passphrase: _passphraseCtrl.text,
        curve: _curve,
        name: name,
        password: _pwCtrl.text,
        remoteKey: remoteKey,
      );
      if (!mounted) return;
      setState(() {
        _result = wallet;
        _step = _Step.done;
      });
    } catch (e) {
      logError('[InAppImportMnemonic._runPromote] import/promote error: $e');
      if (!mounted) return;
      setState(() {
        _error = WalletError.from(e).message;
        _step = _Step.error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.mnemonicTitle)),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: switch (_step) {
            _Step.input => _buildInput(),
            _Step.verifyId => _buildVerifyId(),
            _Step.verifyCode => _buildVerifyCode(),
            _Step.promoting => _buildBusy(l10n.mnemonicImporting),
            _Step.done => _buildDone(),
            _Step.error => _buildError(),
          },
        ),
      ),
    );
  }

  Widget _buildInput() {
    final l10n = context.l10n;
    return ListView(
      children: [
        Text(
          l10n.mnemonicInputHint,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _mnemonicCtrl,
          minLines: 3,
          maxLines: 5,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.mnemonicFieldLabel,
          ),
          style: monoStyle(fontSize: 13),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _passphraseCtrl,
          obscureText: true,
          autocorrect: false,
          decoration: InputDecoration(
            labelText: l10n.mnemonicPassphraseLabel,
          ),
        ),
        const SizedBox(height: 20),
        Text(
          l10n.mnemonicWalletTypeLabel,
          style: const TextStyle(color: TibaneColors.textDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SegmentedButton<String>(
          segments: const [
            // 'Solana' and 'EVM/BTC' are proper nouns / technical terms —
            // not translated.
            ButtonSegment(value: 'ed25519', label: Text('Solana')),
            ButtonSegment(value: 'secp256k1', label: Text('EVM/BTC')),
          ],
          selected: {_curve},
          onSelectionChanged: (s) => setState(() {
            _curve = s.first;
            _error = null;
          }),
        ),
        const SizedBox(height: 4),
        Text(
          _curve == 'ed25519'
              ? l10n.mnemonicCurveHintSolana
              : l10n.mnemonicCurveHintEvm,
          style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.mnemonicPasswordLabel,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl2,
          obscureText: true,
          decoration: InputDecoration(labelText: l10n.labelConfirmPassword),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _continue,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            l10n.mnemonicContinueButton,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildVerifyId() {
    final l10n = context.l10n;
    return ListView(
      children: [
        Text(
          l10n.mnemonicVerifyIdHint,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        SegmentedButton<_IdMode>(
          segments: [
            ButtonSegment(
              value: _IdMode.email,
              label: Text(l10n.labelEmail),
              icon: const Icon(Icons.alternate_email, size: 18),
            ),
            ButtonSegment(
              value: _IdMode.phone,
              label: Text(l10n.labelPhone),
              icon: const Icon(Icons.phone_outlined, size: 18),
            ),
          ],
          selected: {_idMode},
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                  _idMode = s.first;
                  _error = null;
                }),
        ),
        const SizedBox(height: 20),
        if (_idMode == _IdMode.email)
          TextField(
            controller: _emailCtrl,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            decoration: InputDecoration(labelText: l10n.labelEmail),
          )
        else
          PhoneFormField(
            controller: _phoneCtrl,
            enabled: !_busy,
            countryButtonStyle: const CountryButtonStyle(
              showDialCode: true,
              showIsoCode: false,
              showFlag: true,
            ),
            decoration: InputDecoration(labelText: l10n.labelPhoneNumber),
            validator: PhoneValidator.compose([
              PhoneValidator.required(context),
              PhoneValidator.valid(context),
            ]),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          onPressed: _busy ? null : _sendCode,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy ? l10n.mnemonicSendingCode : l10n.actionSendVerificationCode,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _step = _Step.input;
                  _error = null;
                }),
          child: Text(l10n.actionBack),
        ),
      ],
    );
  }

  Widget _buildVerifyCode() {
    final l10n = context.l10n;
    final digits = _session?.length ?? 6;
    return ListView(
      children: [
        Text(
          _sentTo.contains('@')
              ? l10n.mnemonicCodeSentEmail(digits, _sentTo)
              : l10n.mnemonicCodeSentSms(digits, _sentTo),
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeCtrl,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          autofocus: true,
          maxLength: digits,
          decoration: InputDecoration(labelText: l10n.labelVerificationCode),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _submitCode,
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            _busy ? l10n.commonVerifying : l10n.mnemonicVerifyImportButton,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _step = _Step.verifyId;
                  _codeCtrl.clear();
                  _session = null;
                  _error = null;
                }),
          child: Text(l10n.mnemonicChangeSenderButton),
        ),
      ],
    );
  }

  Widget _buildBusy(String message) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 56,
            height: 56,
            child: CircularProgressIndicator(
              color: TibaneColors.orange,
              strokeWidth: 3,
            ),
          ),
          const SizedBox(height: 24),
          Text(
            message,
            style: Theme.of(context).textTheme.titleMedium,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDone() {
    final l10n = context.l10n;
    final w = _result;
    return ListView(
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle, color: TibaneColors.cyan, size: 28),
            const SizedBox(width: 12),
            Text(
              l10n.mnemonicDoneTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          l10n.mnemonicDoneBody,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        if (w != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: TibaneColors.darker,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.shield_outlined,
                  color: TibaneColors.orange,
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        w.name,
                        style: const TextStyle(color: TibaneColors.text),
                      ),
                      Text(
                        '${w.curve} · ${w.pubkey.length > 14 ? "${w.pubkey.substring(0, 6)}…${w.pubkey.substring(w.pubkey.length - 6)}" : w.pubkey}',
                        style: monoStyle(
                          fontSize: 11,
                          color: TibaneColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            l10n.actionDone,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(Icons.error_outline, color: TibaneColors.error, size: 24),
            const SizedBox(width: 10),
            Text(
              l10n.mnemonicImportFailed,
              style: const TextStyle(
                color: TibaneColors.text,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SelectableText(
          _error ?? l10n.sendUnknownError,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const Spacer(),
        FilledButton(
          onPressed: () => setState(() {
            _step = _Step.input;
            _error = null;
          }),
          style: FilledButton.styleFrom(
            backgroundColor: TibaneColors.orange,
            foregroundColor: TibaneColors.black,
            padding: const EdgeInsets.symmetric(vertical: 14),
          ),
          child: Text(
            l10n.mnemonicStartOver,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
