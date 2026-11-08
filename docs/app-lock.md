# Optional App Lock

Settings > Security & Privacy contains a global app-lock switch. It is
available without any wallet, and applies equally to seed, imported-key,
MPC, external-wallet and onboarding screens.

Enabling verifies enrolled device biometrics before persisting the setting.
Unlocking and disabling use OS authentication with a device-passcode
fallback. No wallet password, recovery words or signing credentials are
stored or collected by this feature. Wallet transaction authorization
remains separate and unchanged.

The MaterialApp builder wraps the root Navigator. Until the saved setting
loads, protected content is hidden. When enabled, a cold launch or return
from the background requires authentication. Route pushes, dialogs,
deep links and app messages cannot cover the lock screen. Flutter content
is also obscured while inactive, without treating the OS biometric prompt
itself as another background lock.

Cancelled or failed authentication keeps the app locked, with an explicit
retry action and no prompt loop. A timed-out prompt is cancelled. An
authentication response from before a background transition cannot unlock
the new session. Configuration-loading failure hides content until retry.

This is an app UI access control, not wallet encryption, screenshot
prevention or a replacement for wallet recovery information. It is local
to the installation and independent of wallet removal. Hardware behavior
must be checked on a real device; automated tests inject OS authentication.
