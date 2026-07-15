import 'package:flutter/material.dart';
import 'package:libwallet/libwallet.dart';
import 'package:phone_form_field/phone_form_field.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet/biometric.dart';
import '../../services/wallet/creation.dart';
import '../../services/wallet_service.dart';
import '../../theme/tibane_theme.dart';
import '../../widgets/keyboard_safe_form.dart';
import 'inapp_import_screen.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

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
    final l10n = context.l10n;
    String identifier;
    if (_mode == _IdMode.email) {
      identifier = _emailCtrl.text.trim();
      if (!identifier.contains('@')) {
        setState(() => _error = l10n.inappCreateErrInvalidEmail);
        return;
      }
    } else {
      final phone = _phoneCtrl.value;
      if (!phone.isValid()) {
        setState(() => _error = l10n.inappCreateErrInvalidPhone);
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
        _error = WalletError.from(e).message;
      });
    }
  }

  Future<void> _submitCode() async {
    final l10n = context.l10n;
    final code = _codeCtrl.text.trim();
    final session = _session;
    if (session == null) return;
    if (code.length != session.length) {
      setState(() => _error = l10n.inappCreateErrCodeLength(session.length.toString()));
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
        _error = WalletError.from(e).message;
      });
    }
  }

  Future<void> _createWallet() async {
    final l10n = context.l10n;
    final pw = _pwCtrl.text;
    final remoteKey = _remoteKey;
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      setState(() => _error = l10n.inappCreateErrNoName);
      return;
    }
    if (pw.length < 8) {
      setState(() => _error = l10n.inappCreateErrPasswordShort);
      return;
    }
    if (pw != _pwCtrl2.text) {
      setState(() => _error = l10n.errPasswordsMismatch);
      return;
    }
    if (remoteKey == null) {
      setState(() => _error = l10n.inappCreateErrMissingShare);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _step = _Step.creating;
      _progress = 0;
    });

    final wallet = context.read<WalletService>();
    try {
      await for (final fraction in wallet.libwallet.create(
        name: name,
        password: pw,
        remoteKey: remoteKey,
        curves: const ['ed25519', 'secp256k1'],
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
        _error = WalletError.from(e).message;
        _progress = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: TibaneColors.black,
      appBar: AppBar(title: Text(l10n.inappCreateTitle)),
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
    final l10n = context.l10n;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.inappCreateIdentifierIntro,
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
            decoration: InputDecoration(labelText: l10n.inappCreateEmailLabel),
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
        const Spacer(),
        _primaryButton(
          label: _busy ? l10n.commonSending : l10n.actionSendVerificationCode,
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
          child: Text(l10n.inappCreateImportLink),
        ),
      ],
    );
  }

  Widget _buildCode() {
    final l10n = context.l10n;
    final length = (_session?.length ?? 6).toString();
    final isEmail = _sentTo.contains('@');
    final introText = isEmail
        ? l10n.inappCreateCodeIntroEmail(length, _sentTo)
        : l10n.inappCreateCodeIntroSms(length, _sentTo);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          introText,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _codeCtrl,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          autofocus: true,
          maxLength: _session?.length ?? 6,
          decoration: InputDecoration(labelText: l10n.labelVerificationCode),
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const Spacer(),
        _primaryButton(
          label: _busy ? l10n.commonVerifying : l10n.inappCreateVerify,
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
          child: Text(l10n.inappCreateChangeDest),
        ),
      ],
    );
  }

  Widget _buildPassword() {
    final l10n = context.l10n;
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
            child: Text(
              l10n.inappCreateLowerSecurityWarning,
              style: const TextStyle(
                color: TibaneColors.warning,
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          l10n.inappCreatePasswordIntro,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 24),
        TextField(
          controller: _nameCtrl,
          enabled: !creating,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(
            labelText: l10n.labelWalletName,
            helperText: l10n.inappCreateWalletNameHelper,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl,
          obscureText: true,
          enabled: !creating,
          decoration: InputDecoration(labelText: l10n.labelPassword),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _pwCtrl2,
          obscureText: true,
          enabled: !creating,
          decoration: InputDecoration(labelText: l10n.labelConfirmPassword),
        ),
        const SizedBox(height: 20),
        Text(
          l10n.inappCreateKeygenNote,
          style: const TextStyle(color: TibaneColors.textMuted, fontSize: 12),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        if (creating) ...[
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text(
            l10n.inappCreateGenerating,
            style: const TextStyle(color: TibaneColors.textMuted),
            textAlign: TextAlign.center,
          ),
        ],
        const Spacer(),
        _primaryButton(
          label: creating ? l10n.inappCreateCreating : l10n.inappCreateButton,
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
