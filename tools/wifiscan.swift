import CoreWLAN
import Foundation

// Scan nearby Wi-Fi networks on modern macOS.
// The `airport` CLI was removed in macOS 14+; CoreWLAN still works.
//
// CURRENT_SSID needs Location Services permission for the calling terminal
// (System Settings > Privacy & Services > Location Services). Without it the
// SSID prints nil; everything else works fine.

guard let wifi = CWWiFiClient.shared().interface() else {
    print("NO_INTERFACE"); exit(1)
}
print("CURRENT_SSID: \(wifi.ssid() ?? "<nil - grant Location Services to terminal>")")
print("CURRENT_RSSI: \(wifi.rssiValue())")
print("CURRENT_TXRATE: \(wifi.transmitRate())")

do {
    let nets = try wifi.scanForNetworks(withName: nil)
    for n in nets.sorted(by: { $0.rssiValue > $1.rssiValue }) {
        let ssid = n.ssid ?? "<hidden>"
        let ch = n.wlanChannel?.channelNumber ?? 0
        // channels <=14 are 2.4GHz; 32-165 are 5GHz/6GHz
        let band = ch <= 14 ? "2.4" : (ch >= 32 && ch <= 165 ? "5" : "?")
        print("NET | \(ssid) | \(band)GHz ch\(ch) | rssi \(n.rssiValue)")
    }
    print("SCAN_COUNT: \(nets.count)")
} catch {
    print("SCAN_FAILED: \(error)")
}