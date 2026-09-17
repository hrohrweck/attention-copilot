# GOOGLE OAUTH — connect Google Calendar with your own client ID

Attention Copilot connects to Google Calendar through **your own** OAuth
client. **the app does not ship a client ID** and ships no client secret —
there is no shared credential, no quota shared with anyone else, and nothing
embedded in the app that Google could revoke for everyone at once.

The sign-in flow is the modern native-app flow: Authorization Code + **PKCE**
with a **loopback redirect** (`http://127.0.0.1:<port>`), so the app is a
*public client* and you never have to create or paste a client secret.

> **Android users:** skip this page. Google blocks loopback redirects for
> Android clients, so on Android the app reads Google calendars through the
> device's CalendarContract source instead — no OAuth at all. This walkthrough
> applies to the **desktop** builds (Linux, Windows, macOS).

## Prerequisites

- A Google account whose calendar you want to read.
- Access to the [Google Cloud Console](https://console.cloud.google.com/).
- ~10 minutes. No paid tier is required.

## Step 1 — Create a project

1. Open the [Google Cloud Console](https://console.cloud.google.com/).
2. In the project picker (top bar), click **New project**.
3. Name it (e.g. `attention-copilot`), pick an organization if asked, and
   click **Create**.

## Step 2 — Enable the Google Calendar API

1. With your project selected, go to **APIs & Services → Library**
   (or open the direct link
   `https://console.cloud.google.com/apis/library/calendar-json.googleapis.com`).
2. Search for **Google Calendar API** and click **Enable**.

## Step 3 — Configure the OAuth consent screen

1. Go to **APIs & Services → OAuth consent screen**.
2. Choose **External** (this is a personal-use integration) and click
   **Create**.
3. Fill in the app information:
   - **App name** — anything (e.g. `Attention Copilot`).
   - **User support email** — your own address.
   - **Developer contact information** — your own address (Google requires
     it and emails you there about policy changes).
4. On the **Scopes** screen click **Add or remove scopes** and add exactly
   these two — the narrowest read-only scopes, never the broad
   `calendar.readonly` scope and never any write scope:

   ```text
   https://www.googleapis.com/auth/calendar.events.readonly
   https://www.googleapis.com/auth/calendar.calendarlist.readonly
   ```

5. On the **Test users** screen, add your own Google account.
6. Click **Save and continue** through the remaining summary screen.

Because these calendar scopes are classified *sensitive* but **not**
*restricted*, the consent screen can stay **unverified** for personal use —
you will see Google's "Google hasn't verified this app" warning when you sign
in, which is expected and safe for your own client.

## Step 4 — Publish the consent screen to "In production"

> Do this **before** you sign in. It is the difference between reconnecting
> every 7 days and never reconnecting.

While an OAuth consent screen is in **Testing** status, Google expires the
refresh tokens it issues **after 7 days**. The app stores the refresh token
and uses it to renew access silently, so after those 7 days the Google source
fails with an "authorisation expired — reconnect" message and you must sign
in again.

Publishing moves you to long-lived refresh tokens:

1. Go to **APIs & Services → OAuth consent screen**.
2. Click **Publish app** and confirm.

You do **not** need Google verification for this: the app remains
"unverified" to Google, which for a personal, single-user client has no
effect on functionality — verification is only about removing the warning
screen and is not required to keep refresh tokens long-lived. Publishing to
*In production* (even unverified) is what makes refresh tokens long-lived.

## Step 5 — Create the OAuth client (Desktop app)

1. Go to **APIs & Services → Credentials**.
2. Click **+ Create credentials → OAuth client ID**.
3. Set **Application type** to **Desktop app**.
   - This is what makes the loopback flow work: Desktop clients accept
     loopback redirect URIs like `http://127.0.0.1:<port>` / `http://localhost`.
4. Name it (e.g. `attention-copilot-desktop`) and click **Create**.
5. Google shows a dialog with **Your Client ID** — a string ending in
   `.apps.googleusercontent.com`. Copy it. (The "Client secret" field in the
   same dialog is irrelevant: the app uses PKCE and never sends a secret —
   do not paste it anywhere.)

## Step 6 — Paste the client ID into the app

1. In Attention Copilot, open the onboarding wizard (or
   **Settings → Calendars → Google Calendar**).
2. Paste the client ID into the client-ID field and press **Connect**.
3. Your default browser opens a Google sign-in page. Sign in with the
   account from Step 3's test-user list (until the consent screen is
   published, that is the account allowed to sign in at all), and approve
   the read-only scopes.
4. The browser lands on a local "Authorisation complete" page. Close it and
   return to the app — the Google Calendar source shows **connected** and
   your events appear in the agenda.

The client ID is stored in your local settings; the resulting OAuth tokens
are stored in your operating system's keychain/credential store. Nothing is
sent to anyone but Google. See [Privacy](PRIVACY.md).

## What the app does with it (for the curious)

- First fetch: full `events.list` over a rolling 30-day window with
  `singleEvents=true`; the returned `nextSyncToken` becomes the incremental
  cursor.
- Later fetches: only the `syncToken` is sent — Google answers with just the
  changes. On `410 GONE` (Google invalidated the token) the app wipes the
  cursor and does exactly one full resync.
- On `401` the app refreshes the access token once and retries; if that
  fails, it surfaces "reconnect" instead of retrying forever.
- No push channels, no webhooks, no server: the app polls with incremental
  sync. See [Architecture](ARCHITECTURE.md#why-push-notifications-are-not-used).

## Troubleshooting

- **"Google hasn't verified this app"** — normal for your own unverified
  client; continue.
- **"Access blocked: authorization error"** — you used an account that is
  not on the consent screen's test-user list, or the screen is still in
  Testing. Add the account in Step 3, or publish (Step 4).
- **Google disconnects every ~7 days** — your consent screen is still in
  **Testing**. Publish it to **In production** (Step 4); unverified is fine.
- **"Authorisation expired — reconnect"** in the app — the stored refresh
  token is gone (7-day Testing expiry, or you revoked access at
  <https://myaccount.google.com/permissions>). Reconnect in Settings.
- **The browser never opens / the loopback times out** — see
  [Troubleshooting](TROUBLESHOOTING.md).
