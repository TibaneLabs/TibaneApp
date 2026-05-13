# ClawdWallet Pairing — Agent ↔ Mobile Handshake Contract

Locked contract for replacing the manual "paste agent_spot_id" field on the
**Create agent wallet** flow with a one-tap deep-link handshake.

This document defines what the agent host and the mobile app agree on at the
wire. Implementation locations are left to each project's owner.

---

## Why this exists

The mobile app needs the agent's Spot identity to assemble the canonical
peers list for the 3-party EdDSA keygen. Asking the user to copy/paste a
`k.<base64url>` string from the agent's terminal is error-prone and looks
unprofessional. Pairing replaces it with: agent emits a URL, user opens it
on phone, mobile verifies the agent over Spot, form is pre-filled.

The handshake also gives the agent a chance to introduce itself (suggested
wallet name, version, future capabilities) before the user commits.

---

## Roles

- **Agent host** — the machine running `clawdwallet`. Has a Spot identity.
  Generates the pairing URL.
- **Mobile** — the tibaneapp install. Has its own Spot identity (via
  libwallet). Receives the deep link, drives the handshake, then proceeds
  to `Crypto/WalletSign:newAgent` with the verified agent identity.
- **phplatform** is **not involved in pairing.** Pairing is purely
  agent ↔ mobile over Spot. phplatform only sees the result via the
  subsequent `:newAgent` call.

---

## URL format

```
tibane://pair?agent=<agent-spot-id>&token=<pairing-token>
```

- `agent` — the agent's Spot identity, in the standard `k.<base64url>` form.
- `token` — a one-shot pairing token, base64url-encoded, no padding,
  16 bytes of entropy. Generated fresh per `clawdwallet pair` invocation.

The URL is the only thing exchanged out-of-band. Everything else flows
over Spot. The token is the shared secret that authorizes the first Spot
message; the agent's Spot identity is in the URL so mobile knows where to
send.

The scheme is `tibane://` — a Tibane Labs-branded custom URL scheme
unique to the tibaneapp install. Generic short schemes like `clawd://`
are avoided because they're not registered and any other app on the
device could claim them. Universal HTTPS links (Android App Links / iOS
Universal Links) are deferred until we have a reason to add them; for
the Stage 1 demo the custom scheme is enough.

---

## Token lifecycle

- **Single-use.** Consumed on the first successful pairing response. Any
  subsequent attempt with the same token is rejected.
- **Time-bound.** Valid for 5 minutes from generation. Rejected after.
- **In-memory only.** Lost on agent restart. Surviving across restarts is
  not a goal — the user just runs `clawdwallet pair` again.
- **No reuse across agents.** A token is bound to the agent process that
  generated it; it doesn't authorize anything against another agent host.

---

## Spot handshake

Two messages, one round trip.

The agent registers a Spot handler named **`pair`**. Libwallet — running
inside the mobile, never exposed to the app — sends the request body to
recipient `<agent-spot-id>/pair` using Spot's synchronous request/response
primitive, and the agent's handler returns the response body inline. One
round trip, one return value. There is no separate reply endpoint, no
asynchronous notification, and no Spot surface on the Dart side: the app
calls libwallet's single pairing method (see the Mobile-side
implementation split section) and libwallet handles all Spot traffic
internally.

### 1. Mobile → Agent: pair request

Sent to recipient `<agent-spot-id>/pair`. Body shape:

```json
{
  "v": 1,
  "token": "<pairing-token from the URL>",
  "mobile_spot_id": "k.<base64url>"
}
```

- `v` — protocol version. Stage 1 is `1`. Bump when the body changes
  incompatibly.
- `token` — verbatim from the URL.
- `mobile_spot_id` — the mobile's own Spot identity. The agent records it
  for diagnostics and (Stage 2) optional rate-limiting / known-device
  tracking.

### 2. Agent → Mobile: pair response

Returned as the synchronous reply to the `pair` Query. Body shape:

```json
{
  "v": 1,
  "agent_spot_id": "k.<base64url>",
  "suggested_name": "<string, optional>",
  "agent_version": "<string, optional>",
  "capabilities": { }
}
```

- `agent_spot_id` — the agent's own Spot identity. **Mobile must verify
  this equals the `agent=` from the URL.** A mismatch is a hard error
  (someone redirected the URL).
- `suggested_name` — what the agent thinks this wallet should be called
  (e.g. its `moniker` from `clawdwallet init`). Optional; mobile uses it as
  the default value in the name field, user can edit.
- `agent_version` — informational (`git rev-parse --short HEAD` or release
  tag). Shown on the confirmation screen so the user can sanity-check.
- `capabilities` — reserved object for forward-compat. Stage 1 ignores any
  content; mobile MUST tolerate unknown keys. Likely Stage 2+ contents:
  supported curves, x402 versions, MCP tools list, recommended policy
  defaults.

### Error responses

If the agent rejects the request, it returns:

```json
{
  "v": 1,
  "error": "<machine-readable code>",
  "message": "<human-readable, optional>"
}
```

Codes (closed set for Stage 1):

| `error` | Meaning |
|---|---|
| `token_invalid` | Token not recognised by this agent. Typo, wrong agent, or never issued here. |
| `token_expired` | Token was valid but past its 5-minute TTL. |
| `token_consumed` | Token already used. A fresh `clawdwallet pair` is required. |
| `bad_request` | Body malformed, missing fields, or `v` unsupported. |

Mobile displays a sensible message for each and surfaces a "Try again"
button that takes the user back to the home screen so they can scan a
fresh URL.

---

## Mobile-side implementation split

**libwallet owns the agent-side handshake.** The Spot exchange, URL parse,
agent-identity verification, and error mapping all live in libwallet (Go
core, exposed via the Dart bindings). tibaneapp does not talk Spot directly.

**tibaneapp owns the UX.** Deep-link reception (Android intent filter for
the `tibane://` scheme), navigating to the Create agent wallet screen with
pre-filled fields, and surfacing pairing errors to the user. No
cryptographic work, no protocol logic.

The Dart API libwallet exposes is one call. It takes the URL from the
deep link, returns a verified result on success, throws on the closed set
of error codes from the contract. Shape (names are placeholders; the exact
path/method is libwallet's call):

- **Input**: the full `tibane://pair?...` URL as a string.
- **Output on success**: an object with `agent_spot_id`, `suggested_name`,
  `agent_version`, `capabilities`. The `agent_spot_id` returned has
  already been verified to match the URL's `agent` parameter — tibaneapp
  does not need to re-check.
- **Output on failure**: an exception carrying the contract error code
  (`token_invalid`, `token_expired`, `token_consumed`, `bad_request`,
  plus a transport-level `unreachable` / `timeout` for network errors)
  and a human-readable message.

libwallet is responsible for:

- Parsing the URL, validating the scheme and required params.
- Sending the pair-request message on the agent's `pair` Spot endpoint
  with the local Spot id as `mobile_spot_id`.
- Reading the pair-response, verifying `agent_spot_id == agent param
  from URL`, and mapping the response body (or error response) into the
  Dart return value.
- A sensible timeout (suggested: ~15 seconds; the handshake is one round
  trip).

tibaneapp's responsibilities collapse to:

- Register the `tibane://pair` intent filter (Android first).
- When the OS delivers a pair URL, call libwallet's pairing API with it.
- On success, push the Create agent wallet screen with `agent_spot_id`
  locked and `suggested_name` pre-filled in the name field.
- On failure, show the error message and let the user re-pair from
  scratch.

This mirrors the existing `Wallet:initiateKeygen` split — libwallet does
the protocol work, the app drives the user through it.

## Mobile flow after a successful handshake

On a successful pair response:

1. Mobile verifies `agent_spot_id == agent param from URL`. Mismatch →
   show error, abort.
2. Mobile navigates to the **Create agent wallet** screen with these
   fields pre-filled:
   - **Agent spot id** — populated and locked (read-only) so the user
     can't accidentally edit a verified value.
   - **Name** — pre-filled from `suggested_name` if present, editable.
   - **Per-tx / daily / allowlist** — left at defaults for the user to
     fill in.
3. User confirms → mobile calls `Crypto/WalletSign:newAgent` with the
   verified `agent_spot_id` and proceeds to keygen as documented today.

---

## Out of scope for Stage 1

- **Universal HTTPS links** (Android App Links / iOS Universal Links on a
  Tibane domain) — deferred. Adds domain-verification rigor but isn't
  needed for the Stage 1 demo; the custom scheme suffices.
- **QR code rendering** — the agent emits a clickable URL and prints it.
  Adding a terminal QR (`skip2/go-qrcode` or similar) is a nice-to-have,
  not a contract concern.
- **Multi-agent pairing** — Stage 1 is one pair URL → one wallet. Pairing
  a single mobile with multiple agents is a sequence of independent
  pairings.
- **Stored pairing trust** — the mobile does not remember "I've paired
  with this agent before" beyond the wallet it created. Re-running
  `clawdwallet pair` for the same agent is fine; each invocation is a
  fresh ceremony.
- **Authentication of the agent's identity claim** — pairing assumes the
  agent host is legitimate. If a hostile process emits a URL on the
  user's terminal, the user pairs with the wrong agent. Out of scope —
  the user is trusted to read what's on their screen.

---

## Failure semantics

| Situation | Behaviour |
|---|---|
| User scans URL after `clawdwallet pair` exited | `token_invalid` — token died with the process. User re-runs pair. |
| User waits > 5 min between scan and tap | `token_expired`. |
| User pairs twice with the same URL | First wins, second sees `token_consumed`. |
| Network drops mid-handshake | Mobile times out, surfaces a retry button. Token stays valid (not consumed) until the agent receives a successful first response or the TTL elapses. |
| `agent_spot_id` in response doesn't match URL | Mobile aborts loudly. Treat as a redirection attack. |
| Mobile is on a different Spot relay than agent | Same as any cross-relay Spot reachability issue — surfaces as a timeout. |

---

## Versioning

The `v` field in both messages is the contract version. Stage 1 is `v: 1`.
Future revisions:

- Add fields → no version bump if old clients tolerate unknown keys
  (which both sides MUST).
- Remove or rename fields, change semantics → bump `v`. Old clients that
  don't recognize the new `v` reply with `bad_request`.

---

## Open questions for implementers

These were resolved at the contract level but each project decides its
own answers:

- **Agent**: Where does the pair handler live (separate subcommand?
  always-on while daemon is running? both?), how is the URL displayed
  (stdout only? QR? both?), and how does the token in-memory store get
  cleaned up on expiry.
- **Mobile**: Android intent filter setup (Solana Seeker first), iOS
  Info.plist URL type (deferred until iOS demo lands), how the pre-fill
  state survives a process restart between scan and form-fill (likely
  doesn't need to — re-pair if backgrounded).
- **Terminal UX**: Whether the agent waits for the pair to complete
  before exiting, or returns to prompt immediately and pairs in the
  background. Either is fine as long as the user can tell what happened.
