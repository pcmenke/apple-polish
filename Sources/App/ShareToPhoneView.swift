import PolishRemote
import SwiftUI

struct ShareToPhoneView: View {
    @ObservedObject var host: RemoteHost

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Share to iPhone", isOn: Binding(get: { host.isSharing }, set: { host.setSharing($0) }))
                .toggleStyle(.switch)
            Text(host.status).font(.callout).foregroundStyle(.secondary)
            if host.isSharing {
                Divider()
                Text("Scan to pair").font(.headline)
                if host.port != nil, let qr = QRCode.image(for: host.pairingLink.url.absoluteString, side: 220) {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit().frame(width: 220, height: 220)
                        .frame(maxWidth: .infinity)
                    Text("Open Apple Polish on your iPhone and tap Scan QR code, or point the Camera at this.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    ProgressView().controlSize(.small)
                }
                Divider()
                Text("Or type the key").font(.headline)
                Text(host.key.display)
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                HStack {
                    Button("Copy key") { host.copyKey() }
                    Button("New key…", role: .destructive) { host.regenerateKey() }
                }
                Text("On your iPhone, open Apple Polish Viewer and paste this key (Universal Clipboard works). "
                     + "Manual connection: \(host.hostAddress).")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Anyone on your network who has the key can browse your message media and move files to the Trash. "
                 + "Sharing stays on this network only; nothing goes through the internet.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 360)
    }
}
