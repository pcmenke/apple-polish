# apple-polish

Tool to cleanup space on a Mac.

The goal is a native macOS (SwiftUI) app, since the tools need real UI (thumbnail grids, previews, selection).
`prototype/` holds throwaway Python versions used to learn the data model.

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
