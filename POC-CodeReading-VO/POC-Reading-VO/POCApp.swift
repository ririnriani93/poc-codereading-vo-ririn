//
//  POCApp.swift
//  MyApp
//
//  Created by Ririn Ayuning Riani on 18/10/26.
//


import SwiftUI
import AppKit
import ApplicationServices
import AVFoundation
import Combine


final class XcodeMonitor: ObservableObject {
    @Published var status = "Belum mulai"
    @Published var isReading = false
    @Published var lastLine = "-"
    @Published var voOn = false
    @Published var voInfo = "-"          // BARU: info cara deteksi VoiceOver
    @Published var autoToggleVO = true
    @Published var log: [String] = []

    private var timer: Timer?
    private let synth = AVSpeechSynthesizer()
    private var lastSpokenLine = ""
    private var wokenPid: pid_t = 0

    private let voiceOver = VoiceOverController()
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    init() {
        voiceOver.onLog = { [weak self] message in
            self?.addLog(message)
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.voiceOver.restoreIfNeeded()
        }
    }

    private func addLog(_ text: String) {
        log.append("\(timeFormatter.string(from: Date()))  \(text)")
        if log.count > 10 { log.removeFirst(log.count - 10) }
    }

    func emergencyVoiceOverOn() {
        voiceOver.emergencyOn()
    }

    // BARU: tombol tes Cmd+F5
    func testToggleVoiceOver() {
        voiceOver.testToggle()
    }

    func start() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else {
            status = "Izin Accessibility belum aktif. Aktifkan di System Settings > Privacy & Security > Accessibility, lalu klik Mulai lagi."
            return
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.check()
        }
        status = "Berjalan..."
        addLog("POC mulai")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        synth.stopSpeaking(at: .immediate)
        isReading = false
        status = "Berhenti"
        voiceOver.restoreIfNeeded()
        addLog("POC berhenti")
    }

    private func setReading(_ reading: Bool, _ message: String) {
        if isReading && !reading {
            synth.stopSpeaking(at: .immediate)
            lastSpokenLine = ""
        }
        isReading = reading
        status = message
        voiceOver.update(reading: reading)
    }

    private func copyAttr(_ el: AXUIElement, _ attr: String) -> (CFTypeRef?, AXError) {
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return (value, err)
    }

    private func errName(_ e: AXError) -> String {
        switch e {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .noValue: return "noValue"
        case .apiDisabled: return "apiDisabled (izin Accessibility bermasalah)"
        case .notImplemented: return "notImplemented"
        default: return "kode \(e.rawValue)"
        }
    }

    private func findTextArea(_ el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 14 { return nil }
        let (roleRef, _) = copyAttr(el, kAXRoleAttribute)
        if (roleRef as? String) == "AXTextArea" { return el }
        let (childrenRef, _) = copyAttr(el, kAXChildrenAttribute)
        guard let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findTextArea(child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func check() {
        // Perbarui status VoiceOver dan pengaturan otomatisnya
        let vo = voiceOver.isEnabled
        if vo != voOn { voOn = vo }
        let info = voiceOver.detectionInfo
        if info != voInfo { voInfo = info }
        voiceOver.autoToggle = autoToggleVO

        // 1. Xcode lagi di depan nggak?
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.apple.dt.Xcode" else {
            setReading(false, "Xcode tidak di depan")
            return
        }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        if wokenPid != app.processIdentifier {
            AXUIElementSetAttributeValue(axApp, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            wokenPid = app.processIdentifier
        }

        // 2. Cari elemen yang fokus, coba beberapa jalur
        var element: AXUIElement? = nil
        var notes: [String] = []

        let (f1, e1) = copyAttr(axApp, kAXFocusedUIElementAttribute)
        if e1 == .success, let f1 = f1 {
            element = (f1 as! AXUIElement)
        } else {
            notes.append("jalur app: \(errName(e1))")
        }

        if element == nil {
            let systemWide = AXUIElementCreateSystemWide()
            let (f2, e2) = copyAttr(systemWide, kAXFocusedUIElementAttribute)
            if e2 == .success, let f2 = f2 {
                element = (f2 as! AXUIElement)
                notes.append("fokus didapat lewat jalur system-wide")
            } else {
                notes.append("jalur system-wide: \(errName(e2))")
            }
        }

        if element == nil {
            let (w, e3) = copyAttr(axApp, kAXFocusedWindowAttribute)
            if e3 == .success, let w = w {
                element = findTextArea(w as! AXUIElement, depth: 0)
                notes.append(element == nil ? "window ada, tapi AXTextArea tidak ketemu" : "text area didapat lewat pencarian di window")
            } else {
                notes.append("jalur window: \(errName(e3))")
            }
        }

        guard let element = element else {
            setReading(false, "Tidak ada elemen yang fokus. Detail: " + notes.joined(separator: " | "))
            return
        }

        // 3. Itu halaman code (text area) nggak?
        let (roleRef, _) = copyAttr(element, kAXRoleAttribute)
        let role = roleRef as? String ?? "(kosong)"
        guard role == "AXTextArea" else {
            setReading(false, "Xcode di depan, tapi bukan halaman code (fokus: \(role))")
            return
        }

        // 4. Ambil isi code + posisi kursor
        let (valueRef, e4) = copyAttr(element, kAXValueAttribute)
        let (rangeRef, e5) = copyAttr(element, kAXSelectedTextRangeAttribute)
        guard e4 == .success, let text = valueRef as? String,
              e5 == .success, let rangeValue = rangeRef else {
            setReading(false, "Gagal membaca isi code (isi: \(errName(e4)), kursor: \(errName(e5)))")
            return
        }

        var cfRange = CFRange()
        AXValueGetValue(rangeValue as! AXValue, .cfRange, &cfRange)

        let ns = text as NSString
        let loc = min(max(cfRange.location, 0), ns.length)
        let lineRange = ns.lineRange(for: NSRange(location: loc, length: 0))
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)

        let extra = notes.isEmpty ? "" : " (" + notes.joined(separator: " | ") + ")"
        setReading(true, "Membaca halaman code" + extra)
        lastLine = line.isEmpty ? "(baris kosong)" : line

        // Kalau mode otomatis nyala, tunggu sampai VoiceOver benar-benar mati baru bersuara
        let canSpeak = !autoToggleVO || !voiceOver.isEnabled
        if canSpeak && !line.isEmpty && line != lastSpokenLine {
            lastSpokenLine = line
            synth.stopSpeaking(at: .immediate)
            synth.speak(AVSpeechUtterance(string: line))
        }
    }
}

struct POCView: View {
    @StateObject private var monitor = XcodeMonitor()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("POC v3.1 (diagnostik): VoiceOver Otomatis").font(.headline)

            HStack {
                Button("Mulai") { monitor.start() }
                Button("Stop") { monitor.stop() }
                Button("Tes kirim Cmd+F5") { monitor.testToggleVoiceOver() }
                Button("Darurat: nyalakan VoiceOver") { monitor.emergencyVoiceOverOn() }
            }

            Toggle("Matikan VoiceOver otomatis saat membaca code", isOn: $monitor.autoToggleVO)

            Text("Status: \(monitor.status)")
            Text("Lagi membaca: \(monitor.isReading ? "YA" : "TIDAK")")
                .foregroundColor(monitor.isReading ? .green : .red)
            Text("VoiceOver nyala: \(monitor.voOn ? "YA" : "TIDAK")")
                .foregroundColor(monitor.voOn ? .orange : .gray)
            Text("Deteksi VoiceOver: \(monitor.voInfo)")
                .font(.system(.caption, design: .monospaced))
            Text("Baris terakhir: \(monitor.lastLine)")
                .font(.system(.body, design: .monospaced))

            Divider()
            Text("Log kejadian:").font(.subheadline)
            ForEach(Array(monitor.log.enumerated()), id: \.offset) { _, entry in
                Text(entry).font(.system(.caption, design: .monospaced))
            }
            Spacer()
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 480)
    }
}
