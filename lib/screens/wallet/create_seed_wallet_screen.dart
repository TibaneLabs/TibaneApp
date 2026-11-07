import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet/logical_wallet.dart';
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';

enum _Step { details, backup, password, done }

class CreateSeedWalletScreen extends StatefulWidget {
  const CreateSeedWalletScreen({super.key});

  @override
  State<CreateSeedWalletScreen> createState() => _CreateSeedWalletScreenState();
}

class _CreateSeedWalletScreenState extends State<CreateSeedWalletScreen>
    with WidgetsBindingObserver {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _passwordConfirmation = TextEditingController();
  List<String> _words = [];
  static const _wordCount = 12;
  _Step _step = _Step.details;
  bool _busy = false;
  bool _visible = false;
  bool _revealed = false;
  bool _saved = false;
  String? _error;
  LogicalWallet? _created;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) return;
    _password.clear();
    _passwordConfirmation.clear();
    if (mounted) setState(() => _visible = false);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _words = [];
    _name.dispose();
    _password.dispose();
    _passwordConfirmation.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (_busy) return;
    if (_name.text.trim().isEmpty) {
      setState(() => _error = context.l10n.inappCreateErrNoName);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final phrase = await context
          .read<WalletService>()
          .libwallet
          .generateRecoveryPhrase(words: _wordCount);
      if (!mounted) return;
      final words = phrase.trim().split(RegExp(r'\s+'));
      if (words.length != _wordCount) throw StateError('Invalid word count');
      setState(() {
        _words = words;
        _visible = false;
        _revealed = false;
        _saved = false;
        _step = _Step.backup;
      });
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error) {
    // Native exceptions may contain their input; never log the exception text.
    logError('[CreateSeedWallet] operation failed: ${error.runtimeType}');
    if (mounted) {
      setState(() => _error = walletErrorMessageForContext(context, error));
    }
  }

  Future<void> _create() async {
    if (_busy || _created != null || _step != _Step.password) return;
    final l10n = context.l10n;
    if (_password.text.length < 8) {
      setState(() => _error = l10n.mnemonicPasswordTooShort);
      return;
    }
    if (_password.text != _passwordConfirmation.text) {
      setState(() => _error = l10n.errPasswordsMismatch);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final created = await context
          .read<WalletService>()
          .libwallet
          .importMultichainMnemonicWallet(
            mnemonic: _words.join(' '),
            passphrase: '',
            name: _name.text.trim(),
            password: _password.text,
          );
      if (!mounted) return;
      _words = [];
      _password.clear();
      _passwordConfirmation.clear();
      setState(() {
        _created = created;
        _step = _Step.done;
      });
    } catch (error) {
      _showError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openWallet() async {
    if (_busy || _created == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final service = context.read<WalletService>();
      if (!await service.activateWalletGroup(_created!)) {
        throw StateError('Could not activate created wallet');
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.seedCreateOpenFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _back() {
    if (_busy) return;
    FocusScope.of(context).unfocus();
    _password.clear();
    _passwordConfirmation.clear();
    setState(() {
      _visible = false;
      _error = null;
      _step = switch (_step) {
        _Step.backup => _Step.details,
        _Step.password => _Step.backup,
        _ => _step,
      };
      if (_step == _Step.details) _words = [];
    });
  }

  Widget _intro(String text, {double fontSize = 16}) => Text(
    text,
    style: TextStyle(
      color: TibaneColors.textMuted,
      fontSize: fontSize,
      height: 1.4,
      letterSpacing: 0,
    ),
  );

  Widget _button(String key, String label, VoidCallback? action) =>
      FilledButton(
        key: Key(key),
        onPressed: _busy ? null : action,
        style: FilledButton.styleFrom(
          backgroundColor: TibaneColors.orange,
          foregroundColor: TibaneColors.black,
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
        ),
        child: Text(label, textAlign: TextAlign.center),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final title = switch (_step) {
      _Step.details => l10n.walletSetupSeedTitle,
      _Step.backup => l10n.seedCreateBackupTitle,
      _Step.password => l10n.mnemonicPasswordTitle,
      _Step.done => l10n.seedCreateDoneTitle,
    };
    final canLeave = !_busy && (_step == _Step.details || _step == _Step.done);
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(title),
          leading: canLeave
              ? null
              : BackButton(onPressed: _busy ? null : _back),
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            key: ValueKey(_step),
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...switch (_step) {
                  _Step.details => _details(),
                  _Step.backup => _backup(),
                  _Step.password => _passwordStep(),
                  _Step.done => _done(),
                },
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Text(
                    _error!,
                    style: const TextStyle(color: TibaneColors.error),
                  ),
                ],
                if (_busy) ...[
                  const SizedBox(height: 20),
                  const Center(child: CircularProgressIndicator()),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _details() {
    final l10n = context.l10n;
    return [
      _intro(l10n.seedCreateSetup),
      const SizedBox(height: 24),
      TextField(
        key: const Key('seed-create-name'),
        controller: _name,
        enabled: !_busy,
        maxLength: 64,
        textCapitalization: TextCapitalization.words,
        decoration: InputDecoration(
          labelText: l10n.labelWalletName,
          counterText: '',
        ),
      ),
      const SizedBox(height: 24),
      _button(
        'seed-create-generate',
        _busy ? l10n.seedCreateGenerating : l10n.mnemonicContinueButton,
        _generate,
      ),
    ];
  }

  List<Widget> _backup() {
    final l10n = context.l10n;
    return [
      _intro(l10n.seedCreateBackupBody, fontSize: 19.2),
      const SizedBox(height: 16),
      TextButton.icon(
        key: const Key('seed-create-reveal'),
        onPressed: () => setState(() {
          _visible = !_visible;
          _revealed = true;
        }),
        icon: Icon(
          _visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        ),
        label: Text(
          _visible ? l10n.seedCreateHideWords : l10n.seedCreateShowWords,
        ),
      ),
      if (_visible) ...[
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 340 ? 2 : 3;
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (var index = 0; index < _words.length; index++)
                  Container(
                    key: ValueKey('seed-create-word-$index'),
                    width: (constraints.maxWidth - (columns - 1) * 8) / columns,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: TibaneColors.card,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${index + 1}',
                          style: const TextStyle(
                            color: TibaneColors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                        Text(
                          _words[index],
                          style: const TextStyle(
                            color: TibaneColors.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ],
      const SizedBox(height: 16),
      CheckboxListTile(
        key: const Key('seed-create-saved'),
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: Text(l10n.seedCreateSavedWords),
        value: _saved,
        onChanged: !_revealed
            ? null
            : (value) => setState(() => _saved = value == true),
      ),
      const SizedBox(height: 20),
      _button(
        'seed-create-backup-next',
        l10n.mnemonicContinueButton,
        _saved && _revealed
            ? () => setState(() {
                _visible = false;
                _step = _Step.password;
              })
            : null,
      ),
    ];
  }

  List<Widget> _passwordStep() {
    final l10n = context.l10n;
    return [
      _intro(l10n.mnemonicPasswordHint),
      const SizedBox(height: 24),
      TextField(
        key: const Key('seed-create-password'),
        controller: _password,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        textInputAction: TextInputAction.next,
        decoration: InputDecoration(labelText: l10n.mnemonicPasswordLabel),
      ),
      const SizedBox(height: 16),
      TextField(
        key: const Key('seed-create-password-confirm'),
        controller: _passwordConfirmation,
        enabled: !_busy,
        obscureText: true,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        onSubmitted: (_) => _create(),
        decoration: InputDecoration(labelText: l10n.labelConfirmPassword),
      ),
      const SizedBox(height: 24),
      _button(
        'seed-create-submit',
        _busy ? l10n.seedCreateCreating : l10n.inappCreateButton,
        _create,
      ),
    ];
  }

  List<Widget> _done() {
    final l10n = context.l10n;
    return [
      const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Icon(
          Icons.check_circle_outline,
          size: 64,
          color: TibaneColors.cyan,
        ),
      ),
      Text(
        _created!.displayName(''),
        textAlign: TextAlign.center,
        style: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: 0,
        ),
      ),
      const SizedBox(height: 16),
      _intro(l10n.seedCreateDoneBody),
      const SizedBox(height: 24),
      _button('seed-create-open', l10n.seedCreateOpenWallet, _openWallet),
    ];
  }
}
