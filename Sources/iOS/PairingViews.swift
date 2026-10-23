import PolishRemote
import SwiftUI

struct PairingView: View {
    @EnvironmentObject var model: ViewerModel
    @State private var text = ""
    @State private var scanning = false

    var body: some View {
        Form {
            Section {
                Button { scanning = true } label: { Label("Scan QR code from your Mac", systemImage: "qrcode.viewfinder") }
                    .font(.headline)
            } footer: { Text("Easiest: the Mac shows a QR code in Share to iPhone.") }
            Section {
                Text("On your Mac, open Apple Polish, click the iPhone button, turn on Share to iPhone, and copy the pairing key. Paste it here (Universal Clipboard carries it across).")
                    .font(.callout)
            }
            Section("Pairing key") {
                TextField("ABCD-EF01-…", text: $text, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("Paste from clipboard") { text = UIPasteboard.general.string ?? text }
                Button("Pair") { _ = model.pair(with: text) }.disabled(text.isEmpty)
            }
        }
        .navigationTitle("Pair with your Mac")
        .fullScreenCover(isPresented: $scanning) {
            ZStack(alignment: .topTrailing) {
                QRScannerView { code in
                    scanning = false
                    if let link = PairingLink(string: code) { model.handle(link: link) }
                    else { model.message = "That QR code isn't an Apple Polish pairing code." }
                }.ignoresSafeArea()
                Button("Cancel") { scanning = false }.buttonStyle(.borderedProminent).padding()
            }
        }
    }
}

struct ConnectView: View {
    @EnvironmentObject var model: ViewerModel
    @State private var host = ""
    @State private var port = ""

    var body: some View {
        Form {
            Section("Macs on this network") {
                if model.macs.isEmpty {
                    Label("Looking for your Mac…", systemImage: "wifi").foregroundStyle(.secondary)
                }
                ForEach(model.macs) { mac in
                    Button { Task { await model.connect(to: mac) } } label: { Label(mac.name, systemImage: "laptopcomputer") }
                }
            }
            Section("Or connect by address (VPN, Tailscale)") {
                TextField("Mac host name or IP", text: $host).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Port (shown in the Mac app)", text: $port).keyboardType(.numberPad)
                Button("Connect") { if let p = UInt16(port) { Task { await model.connect(host: host, port: p) } } }
                    .disabled(host.isEmpty || UInt16(port) == nil)
            }
            Section {
                Button("Forget pairing key", role: .destructive) { model.forgetPairing() }
            }
        }
        .overlay { if model.state == .connecting { ProgressView("Connecting…").padding().background(.regularMaterial, in: .rect(cornerRadius: 12)) } }
        .navigationTitle("Connect")
        .onAppear { host = model.lastManualHost }
    }
}
