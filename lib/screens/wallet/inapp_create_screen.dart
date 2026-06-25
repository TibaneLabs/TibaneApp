import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:provider/provider.dart';

import '../../services/wallet/biometric.dart';
import '../../services/wallet/creation.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/keyboard_safe_form.dart';
import 'inapp_import_screen.dart';
import '../../utils/log.dart';

/// Three-step creation flow for the in-app MPC wallet:
///   1. Collect email or phone (international format) → libwallet sends a
///      verification code via mail or SMS, respectively.
///   2. Collect the verification code → libwallet returns a remoteKey.
///   3. Collect a password, then run the 2-of-3 wallet creation stream.
class InAppCreateScreen extends StatefulWidget {
  const InAppCreateScreen({super.key});

  @override
  State<InAppCreateScreen> createState() => _InAppCreateScreenState();
}

enum _Step { identifier, code, password, creating }

enum _IdMode { email, phone }

enum _CurveChoice { ed25519, secp256k1, both }

class _InAppCreateScreenState extends State<InAppCreateScreen> {
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = PhoneController(
    initialValue: const PhoneNumber(isoCode: IsoCode.US, nsn: ''),
  );
  final _codeCtrl = TextEditingController();
  final _nameCtrl = TextEditingController(text: 'My wallet');
  final _pwCtrl = TextEditingController();
  final _pwCtrl2 = TextEditingController();

  _Step _step = _Step.identifier;
  _IdMode _mode = _IdMode.email;
  _CurveChoice _curve = _CurveChoice.ed25519;
  bool _busy = false;
  String? _error;
  double? _progress;

  /// True when this device has no biometric (or FORCE_UNSAFE) → the wallet
  /// will be created with the D5 password-only committee. Drives the banner.
  bool _lowerSecurity = false;

  RemoteKeySession? _session;
  String? _remoteKey;

  /// The verification target shown back to the user on the code screen
  /// (email or `+E164` phone). Stored at send-time so the user editing
  /// the field afterward doesn't change what we say we sent to.
  String _sentTo = '';

  @override
  void initState() {
    super.initState();
    _checkSecurityLevel();
  }

  Future<void> _checkSecurityLevel() async {
    final mode = creationModeFor(
      hasBiometric: await Biometric.hasBiometric(),
      forceUnsafe: kForceUnsafeCreation,
    );
    if (!mounted) return;
    setState(() => _lowerSecurity = mode == CreationMode.passwordOnly);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _codeCtrl.dispose();
    _nameCtrl.dispose();
    _pwCtrl.dispose();
    _pwCtrl2.dispose();
    super.dispose();
  }

  Future<void> _sendCode() async {
    String identifier;
    if (_mode == _IdMode.email) {
      identifier = _emailCtrl.text.trim();
      if (!identifier.contains('@')) {
        setState(() => _error = 'Enter a valid email address');
        return;
      }
    } else {
      final phone = _phoneCtrl.value;
      if (!phone.isValid()) {
        setState(() => _error = 'Enter a valid phone number');
        return;
      }
      // E.164 — `+14045551234`. libwallet uses presence of `@` to route,
      // so phones must come through as a `+`-prefixed string.
      identifier = phone.international;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = context.read<WalletService>();
      final session = await wallet.libwallet.startVerification(identifier);
      if (!mounted) return;
      setState(() {
        _session = session;
        _sentTo = identifier;
        _step = _Step.code;
        _busy = false;
      });
    } catch (e) {
      logError('[InAppCreate._sendCode] send code error: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not send code: $e';
      });
    }
  }

  Future<void> _submitCode() async {
    final code = _codeCtrl.text.trim();
    final session = _session;
    if (session == null) return;
    if (code.length != session.length) {
      setState(() => _error = 'Code must be ${session.length} digits');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final wallet = context.read<WalletService>();
      final remoteKey = await wallet.libwallet.verifyEmailCode(
        session: session.session,
        code: code,
      );
      if (!mounted) return;
      setState(() {
        _remoteKey = remoteKey;
        _step = _Step.password;
        _busy = false;
      });
    } catch (e) {
      logError('[InAppCreate._submitCode] code verification error: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Code verification failed: $e';
      });
    }
  }

  Future<void> _createWallet() async {
    final pw = _pwCtrl.text;
    final remoteKey = _remoteKey;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Enter a wallet name');
      return;
    }
    if (pw.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters');
      return;
    }
    if (pw != _pwCtrl2.text) {
      setState(() => _error = 'Passwords do not match');
      return;
    }
    if (remoteKey == null) {
      setState(() => _error = 'Missing verified email share');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _step = _Step.creating;
      _progress = 0;
    });

    final wallet = context.read<WalletService>();
    final curves = switch (_curve) {
      _CurveChoice.ed25519 => const ['ed25519'],
      _CurveChoice.secp256k1 => const ['secp256k1'],
      _CurveChoice.both => const ['ed25519', 'secp256k1'],
    };
    try {
      await for (final fraction in wallet.libwallet.create(
        name: name,
        password: pw,
        remoteKey: remoteKey,
        curves: curves,
      )) {
        if (!mounted) return;
        setState(() => _progress = fraction);
      }
      await wallet.useLibwallet();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      logError('[InAppCreate._createWallet] create wallet error: $e');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _step = _Step.password;
        _error = e.toString();
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: const Text('Create in-app wallet')),
      body: SafeArea(
        child: switch (_step) {
          _Step.identifier => KeyboardSafeForm(child: _buildIdentifier()),
          _Step.code => KeyboardSafeForm(child: _buildCode()),
          _Step.password || _Step.creating => KeyboardSafeForm(
            child: _buildPassword(),
          ),
        },
      ),
    );
  }

  Widget _buildIdentifier() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Your keys are split into three shares: this device, a 2FA share '
          '(email or SMS), and a password. Any two can recover your wallet — '
          'no single point of failure.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 20),
        SegmentedButton<_IdMode>(
          segments: const [
            ButtonSegment(
              value: _IdMode.email,
              label: Text('Email'),
              icon: Icon(Icons.alternate_email, size: 18),
            ),
            ButtonSegment(
              value: _IdMode.phone,
              label: Text('Phone'),
              icon: Icon(Icons.phone_outlined, size: 18),
            ),
          ],
          selected: {_mode},
          onSelectionChanged: _busy
              ? null
              : (s) => setState(() {
                  _mode = s.first;
                  _error = null;
                }),
        ),
        const SizedBox(height: 20),
        if (_mode == _IdMode.email)
          TextField(
            controller: _emailCtrl,
            enabled: !_busy,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(labelText: 'Email'),
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
            decoration: const InputDecoration(labelText: 'Phone number'),
            validator: PhoneValidator.compose([
              PhoneValidator.required(context),
              PhoneValidator.valid(context),
            ]),
          ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const Spacer(),
        _primaryButton(
          label: _busy ? 'Sending…' : 'Send verification code',
          onPressed: _busy ? null : _sendCode,
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () async {
                  final ok = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (_) => const InAppImportScreen(),
                    ),
                  );
                  if (!mounted) return;
                  if (ok == true) Navigator.of(context).pop(true);
                },
          child: const Text('Import existing wallet'),
        ),
      ],
    );
  }

  Widget _buildCode() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'We sent a ${_session?.length ?? 6}-digit code '
          '${_sentTo.contains('@') ? 'to' : 'via SMS to'} $_sentTo. '
          'Enter it below to confirm.',
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeCtrl,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          autofocus: true,
          maxLength: _session?.length ?? 6,
          decoration: const InputDecoration(labelText: 'Verification code'),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const Spacer(),
        _primaryButton(
          label: _busy ? 'Verifying…' : 'Verify',
          onPressed: _busy ? null : _submitCode,
        ),
        TextButton(
          onPressed: _busy
              ? null
              : () => setState(() {
                  _step = _Step.identifier;
                  _codeCtrl.clear();
                  _session = null;
                  _error = null;
                }),
          child: const Text('Use a different email or phone'),
        ),
      ],
    );
  }

  Widget _buildPassword() {
    final creating = _step == _Step.creating;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_lowerSecurity) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TibaneColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: TibaneColors.warning.withValues(alpha: 0.4),
              ),
            ),
            child: const Text(
              'Lower-security wallet: this device has no biometric, so this '
              'wallet is protected by your password alone (with 2FA kept for '
              'recovery). Keep your password safe.',
              style: TextStyle(
                color: TibaneColors.warning,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        const Text(
          'Set a password. This is the third share — without it, your device '
          'and 2FA share alone cannot sign.',
          style: TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _nameCtrl,
          enabled: !creating,
          textInputAction: TextInputAction.next,
          decoration: const InputDecoration(
            labelText: 'Wallet name',
            helperText:
                'Shown in the wallet picker — purely for your reference.',
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          enabled: !creating,
          decoration: const InputDecoration(labelText: 'Password'),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl2,
          obscureText: true,
          enabled: !creating,
          decoration: const InputDecoration(labelText: 'Confirm password'),
        ),
        const SizedBox(height: 20),
        const Text(
          'Curves',
          style: TextStyle(color: TibaneColors.textDim, fontSize: 12),
        ),
        const SizedBox(height: 6),
        SegmentedButton<_CurveChoice>(
          segments: const [
            ButtonSegment(value: _CurveChoice.ed25519, label: Text('Solana')),
            ButtonSegment(
              value: _CurveChoice.secp256k1,
              label: Text('EVM/BTC'),
            ),
            ButtonSegment(value: _CurveChoice.both, label: Text('Both')),
          ],
          selected: {_curve},
          onSelectionChanged: creating
              ? null
              : (s) => setState(() => _curve = s.first),
        ),
        const SizedBox(height: 4),
        Text(switch (_curve) {
          _CurveChoice.ed25519 =>
            'ed25519 wallet — Solana account only. Fastest to generate (a few seconds).',
          _CurveChoice.secp256k1 =>
            'secp256k1 wallet — Ethereum / Bitcoin family. The keygen ceremony takes substantially longer than ed25519 (often a minute or more on mobile) because secp256k1 TSS requires expensive Paillier-key generation.',
          _CurveChoice.both =>
            'Both curves created in one keygen ceremony — Solana + Ethereum, no second verification code. Plan for the secp256k1 step to dominate the time (often a minute or more on mobile); keep the app open.',
        }, style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12)),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        if (creating) ...[
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          const Text(
            'Generating key shares…',
            style: TextStyle(color: TibaneColors.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
        const Spacer(),
        _primaryButton(
          label: creating ? 'Creating…' : 'Create wallet',
          onPressed: creating ? null : _createWallet,
        ),
      ],
    );
  }

  Widget _primaryButton({
    required String label,
    required VoidCallback? onPressed,
  }) {
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: TibaneColors.orange,
        foregroundColor: TibaneColors.black,
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    );
  }
}
