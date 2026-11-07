import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/l10n.dart';
import '../../services/wallet_service.dart';
import '../../services/wallet/libwallet_backend.dart'
    show PrivateKeyAccountExistsException;
import '../../services/wallet/logical_wallet.dart';
import '../../services/wallet/unified_account.dart' show chainLabel;
import '../../theme/tibane_theme.dart';
import '../../utils/log.dart';
import '../../utils/wallet_error.dart';
import '../../utils/context_extensions.dart';

/// Import recovery words as a normal single-key wallet, protected by a local
/// password. Imported wallets are never promoted to MPC.
class InAppImportMnemonicScreen extends StatefulWidget {
  const InAppImportMnemonicScreen({super.key});

  @override
  State<InAppImportMnemonicScreen> createState() =>
      _InAppImportMnemonicScreenState();
}

enum _Step { input, password, importing, done, error }

class _InAppImportMnemonicScreenState extends State<InAppImportMnemonicScreen> {
  static const _wordCounts = [12, 15, 18, 21, 24];
  final _wordCtrls = List.generate(24, (_) => TextEditingController());
  final _wordFocus = List.generate(24, (_) => FocusNode());
  int _wordCount = 12;
  final _passphraseCtrl = TextEditingController();
  final _pwCtrl = TextEditingController();
  final _pwCtrl2 = TextEditingController();

  _Step _step = _Step.input;
  String? _error;
  bool _busy = false;
  bool _openingWallet = false;
  bool _activated = false;

  LogicalWallet? _result;

  @override
  void dispose() {
    for (final controller in _wordCtrls) {
      controller.dispose();
    }
    for (final focus in _wordFocus) {
      focus.dispose();
    }
    _passphraseCtrl.dispose();
    _pwCtrl.dispose();
    _pwCtrl2.dispose();
    super.dispose();
  }

  String get _mnemonic => _wordCtrls
      .take(_wordCount)
      .map((controller) => controller.text.trim())
      .join(' ');

  void _changeWordCount(int count) {
    setState(() {
      for (final controller in _wordCtrls.skip(count)) {
        controller.clear();
      }
      _wordCount = count;
      _error = null;
    });
  }

  void _wordChanged(String value) {
    final words = value.trim().split(RegExp(r'\s+'));
    if (words.length <= 1) {
      if (_error != null) setState(() => _error = null);
      return;
    }
    // A whole phrase pasted in any slot replaces the grid in its original order.
    if (_wordCounts.contains(words.length)) {
      setState(() {
        _wordCount = words.length;
        for (var i = 0; i < _wordCtrls.length; i++) {
          _wordCtrls[i].text = i < words.length ? words[i] : '';
        }
        _error = null;
      });
      FocusScope.of(context).unfocus();
    } else {
      setState(() => _error = context.l10n.mnemonicInvalidWordCount);
    }
  }

  /// No wallet is created until the password is confirmed.
  void _confirmWords() {
    if (_wordCtrls
        .take(_wordCount)
        .any(
          (controller) =>
              controller.text.trim().isEmpty ||
              RegExp(r'\s').hasMatch(controller.text.trim()),
        )) {
      setState(() => _error = context.l10n.mnemonicCompleteWords);
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _step = _Step.password;
      _error = null;
    });
  }

  Future<void> _continuePassword() async {
    if (_step != _Step.password) return;
    final l10n = context.l10n;
    if (_pwCtrl.text.length < 8) {
      setState(() => _error = l10n.mnemonicPasswordTooShort);
      return;
    }
    if (_pwCtrl.text != _pwCtrl2.text) {
      setState(() => _error = l10n.errPasswordsMismatch);
      return;
    }
    FocusScope.of(context).unfocus();
    await _runImport();
  }

  void _back() {
    if (_busy || _step == _Step.importing) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      switch (_step) {
        case _Step.password:
          _pwCtrl.clear();
          _pwCtrl2.clear();
          _step = _Step.input;
        default:
          break;
      }
    });
  }

  Future<void> _runImport() async {
    // Persisted display name; the user can rename the wallet later.
    final name = context.l10n.mnemonicImportedName;
    setState(() {
      _step = _Step.importing;
      _error = null;
      _busy = true;
    });
    try {
      final ws = context.read<WalletService>();
      final wallet = await ws.libwallet.importMultichainMnemonicWallet(
        mnemonic: _mnemonic,
        passphrase: _passphraseCtrl.text,
        name: name,
        password: _pwCtrl.text,
      );
      if (!mounted) return;
      for (final controller in _wordCtrls) {
        controller.clear();
      }
      _passphraseCtrl.clear();
      _pwCtrl.clear();
      _pwCtrl2.clear();
      setState(() {
        _result = wallet;
        _step = _Step.done;
      });
      await _openWallet(finish: false);
    } catch (e) {
      logError(
        '[InAppImportMnemonic._runImport] import failed: ${e.runtimeType}',
      );
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is PrivateKeyAccountExistsException
            ? context.l10n.privateKeyAlreadyImportedBody
            : walletErrorMessageForContext(context, e);
        _step = _Step.error;
      });
    }
  }

  Future<void> _openWallet({bool finish = true}) async {
    if (_openingWallet || _result == null) return;
    if (_activated && finish) {
      Navigator.of(context).pop(true);
      return;
    }
    _openingWallet = true;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final opened = await context.read<WalletService>().activateWalletGroup(
        _result!,
      );
      if (!mounted) return;
      if (!opened) {
        setState(() => _error = context.l10n.mnemonicOpenFailed);
        return;
      }
      _activated = true;
      if (finish) Navigator.of(context).pop(true);
    } catch (_) {
      if (mounted) setState(() => _error = context.l10n.mnemonicOpenFailed);
    } finally {
      _openingWallet = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final canLeave =
        !_busy &&
        (_step == _Step.input || _step == _Step.done || _step == _Step.error);
    return PopScope(
      canPop: canLeave,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        backgroundColor: TibaneColors.black,
        appBar: AppBar(
          title: Text(
            _step == _Step.password
                ? l10n.mnemonicPasswordTitle
                : l10n.mnemonicTitle,
          ),
          leading: canLeave
              ? null
              : BackButton(
                  onPressed: _busy || _step == _Step.importing ? null : _back,
                ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: switch (_step) {
              _Step.input => _buildInput(),
              _Step.password => _buildPassword(),
              _Step.importing => _buildBusy(l10n.mnemonicImporting),
              _Step.done => _buildDone(),
              _Step.error => _buildError(),
            },
          ),
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
        DropdownButtonFormField<int>(
          key: const Key('mnemonic-word-count'),
          initialValue: _wordCount,
          decoration: InputDecoration(labelText: l10n.mnemonicWordCountLabel),
          items: _wordCounts
              .map(
                (count) => DropdownMenuItem(
                  value: count,
                  child: Text(l10n.mnemonicWordCount(count)),
                ),
              )
              .toList(),
          onChanged: (count) {
            if (count != null) _changeWordCount(count);
          },
        ),
        const SizedBox(height: 16),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth < 340 ? 2 : 3;
            return Wrap(
              spacing: 10,
              runSpacing: 12,
              children: List.generate(
                _wordCount,
                (index) => SizedBox(
                  width: (constraints.maxWidth - (columns - 1) * 10) / columns,
                  child: TextField(
                    key: ValueKey('mnemonic-word-$index'),
                    controller: _wordCtrls[index],
                    focusNode: _wordFocus[index],
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.visiblePassword,
                    inputFormatters: [
                      TextInputFormatter.withFunction((oldValue, newValue) {
                        // Preserve word boundaries before the single-line filter.
                        return newValue.copyWith(
                          text: newValue.text.replaceAll(
                            RegExp(r'[\r\n\u2028\u2029]'),
                            ' ',
                          ),
                        );
                      }),
                    ],
                    textInputAction: index == _wordCount - 1
                        ? TextInputAction.done
                        : TextInputAction.next,
                    style: monoStyle(fontSize: 14),
                    decoration: InputDecoration(
                      labelText: l10n.mnemonicWord(index + 1),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 16,
                      ),
                    ),
                    onChanged: _wordChanged,
                    onSubmitted: (_) {
                      if (index < _wordCount - 1) {
                        _wordFocus[index + 1].requestFocus();
                      } else {
                        _confirmWords();
                      }
                    },
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 20),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('mnemonic-confirm-words'),
          onPressed: _confirmWords,
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

  Widget _buildPassword() {
    final l10n = context.l10n;
    return ListView(
      children: [
        Text(
          l10n.mnemonicPasswordHint,
          style: const TextStyle(color: TibaneColors.textMuted, height: 1.4),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('mnemonic-password'),
          controller: _pwCtrl,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.next,
          decoration: InputDecoration(labelText: l10n.mnemonicPasswordLabel),
        ),
        const SizedBox(height: 12),
        TextField(
          key: const Key('mnemonic-confirm-password'),
          controller: _pwCtrl2,
          obscureText: true,
          autocorrect: false,
          enableSuggestions: false,
          onSubmitted: (_) => _continuePassword(),
          decoration: InputDecoration(labelText: l10n.labelConfirmPassword),
        ),
        const SizedBox(height: 12),
        ExpansionTile(
          key: const Key('mnemonic-extra-password'),
          tilePadding: EdgeInsets.zero,
          title: Text(l10n.mnemonicExtraPasswordTitle),
          children: [
            Text(
              l10n.mnemonicExtraPasswordHint,
              style: const TextStyle(color: TibaneColors.textMuted),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _passphraseCtrl,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: l10n.mnemonicPassphraseLabel,
              ),
            ),
            const SizedBox(height: 12),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
        ],
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('mnemonic-confirm-password-step'),
          onPressed: _continuePassword,
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
        TextButton(onPressed: _back, child: Text(l10n.actionBack)),
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
            style: context.textTheme.titleMedium,
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
            Expanded(
              child: Text(
                l10n.mnemonicDoneTitle,
                key: const Key('mnemonic-done-title'),
                style: context.textTheme.titleLarge,
              ),
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
                        w.displayName(''),
                        style: const TextStyle(color: TibaneColors.text),
                      ),
                      Text(
                        w.chains.map(chainLabel).join(' / '),
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
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: TibaneColors.error)),
          const SizedBox(height: 12),
        ],
        FilledButton(
          key: const Key('mnemonic-open-wallet'),
          onPressed: _busy ? null : _openWallet,
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
            const Icon(
              Icons.error_outline,
              color: TibaneColors.error,
              size: 24,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.mnemonicImportFailed,
                style: const TextStyle(
                  color: TibaneColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
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
