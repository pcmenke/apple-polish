# apple-polish

Tool to cleanup space on a Mac.

The goal is a native macOS (SwiftUI) app, since the tools need real UI (thumbnail grids, previews, selection).
`prototype/` holds throwaway Python versions used to learn the data model.

## iPhone viewer

The iPhone app (`//:ApplePolishViewer`) is a viewer: it cannot read Messages itself (iOS sandboxing), so the Mac
app serves the media list and thumbnails and the phone browses them.

- Mac app: toolbar iPhone button, turn on **Share to iPhone** (off by default), copy the pairing key.
- Phone: paste the key, pick the Mac (Bonjour) or enter host + port (VPN/Tailscale works).
- Transport: TLS 1.2 with a pre-shared 128-bit key (`Sources/PolishRemote`), LAN only; peers without the key
  cannot complete the handshake. The key is kept in the Keychain on both devices.
- From the phone you can open a conversation in the phone's own Messages (to delete there, which is what clears
  iCloud) or send "Move to Trash" to the Mac.

Simulator build: `bazelisk build //:ApplePolishViewer --ios_multi_cpus=sim_arm64`. A real device needs a
provisioning profile for `com.pcmenke.applepolish.viewer` (not set up yet).

## Build (Bazel)

    bazelisk build //:ApplePolish        # -> Apple Polish.app (zip in bazel-bin/)
    bazelisk test  //:PolishCoreTests //:PolishRemoteTests    # unit tests
    bazelisk run   //:ApplePolish        # build and launch

- `Sources/PolishCore`: data model and the Messages-library reader (no UI, unit-tested).
- `Sources/App`: SwiftUI app (sidebar of conversations, thumbnail grid, selection totals).
- The app reads `~/Library/Messages`, so it needs **Full Disk Access** (System Settings, Privacy & Security).
  Unsigned/ad-hoc builds lose that grant on every rebuild. To keep it, sign with your own Apple Development
  identity: list it with `security find-identity -v -p codesigning`, then put this in `.bazelrc.user`
  (gitignored; keep your identity out of the repo):

      build --@rules_apple//apple/build_settings:signing_certificate_name="Apple Development: you@example.com (TEAMID)"

  `./scripts/install-app.sh` builds, installs to `~/Applications/Apple Polish.app` (a fixed path), and launches it.
  Grant Full Disk Access once to that copy.
- It only reads: nothing is modified or deleted. Delete from inside Messages.
- "Not linked to a message" lists attachment files on disk that no `chat.db` row points to
  (~8 GB of `.mov` files on the author's Mac). Their origin is not yet understood; do not treat them as junk.

## prototype/messages_media_browser.py

Builds a local gallery (`prototype/out/index.html`) of the largest iMessage attachments with thumbnails,
conversation, sender and date. Reads a private copy of `~/Library/Messages/chat.db` (needs Full Disk Access for the
terminal); modifies and uploads nothing. `out/` holds private thumbnails and is gitignored.

    python3 prototype/messages_media_browser.py --open

Notes for the app version:
- `attachment.filename` joins to `message_attachment_join` -> `message` -> `chat_message_join` -> `chat`; `message.date` is
  nanoseconds since 2001-01-01; names resolve through the AddressBook `ZABCDPHONENUMBER`/`ZABCDEMAILADDRESS` tables.
- Delete from inside Messages, not the Attachments folder.
- ~8 GB of `.mov` files in `~/Library/Messages/Attachments` are not referenced by `chat.db` (investigate before treating as junk).
