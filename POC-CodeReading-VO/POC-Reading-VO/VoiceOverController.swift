//
//  VoiceOverController.swift
//  MyApp
//
//  Created by Ririn Ayuning Riani on 18/10/26.
//


import AppKit
import ApplicationServices

// File ini: mengatur VoiceOver mati/nyala otomatis (lewat tombol Cmd+F5).
// VERSI DIAGNOSTIK: mendeteksi VoiceOver lewat 2 cara, dan menulis alasan di log.

final class VoiceOverController {
    var onLog: ((String) -> Void)?
    var autoToggle = true

    private var weTurnedOff = false
    private var stableRead = 0
    private var stableStop = 0
    private var cooldown = 0

    // Cara 1: bendera resmi dari macOS
    private var flagEnabled: Bool {
        NSWorkspace.shared.isVoiceOverEnabled
    }

    // Cara 2: cek apakah proses VoiceOver sedang berjalan
    private var processRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").isEmpty
    }

    // VoiceOver dianggap nyala kalau salah satu cara bilang nyala
    var isEnabled: Bool {
        flagEnabled || processRunning
    }

    // Tulisan untuk window, supaya kelihatan cara mana yang berhasil mendeteksi
    var detectionInfo: String {
        "bendera macOS = \(flagEnabled ? "NYALA" : "mati"), proses VoiceOver = \(processRunning ? "NYALA" : "mati")"
    }

    // Dipanggil tiap 0,5 detik dengan status "lagi membaca atau tidak"
    func update(reading: Bool) {
        guard autoToggle else { return }
        if cooldown > 0 { cooldown -= 1; return }

        let vo = isEnabled

        if reading {
            stableStop = 0
            stableRead += 1
            if stableRead == 2 && !vo {
                onLog?("Membaca stabil, tapi VoiceOver terdeteksi MATI -> tidak ada yang dimatikan")
            }
            // Harus stabil membaca 2 kali cek (~1 detik) sebelum VoiceOver dimatikan
            if stableRead >= 2 && vo {
                onLog?("Mulai membaca -> matikan VoiceOver")
                sendToggle()
                weTurnedOff = true
                cooldown = 4
            }
        } else {
            stableRead = 0
            stableStop += 1
            if weTurnedOff && vo {
                // VoiceOver sudah dinyalakan lagi oleh user
                weTurnedOff = false
            }
            // Harus stabil berhenti 4 kali cek (~2 detik) sebelum VoiceOver dinyalakan lagi
            if stableStop >= 4 && weTurnedOff && !vo {
                onLog?("Berhenti membaca -> nyalakan VoiceOver")
                sendToggle()
                weTurnedOff = false
                cooldown = 4
            }
        }
    }

    // Kembalikan VoiceOver kalau kita yang mematikannya
    func restoreIfNeeded() {
        if weTurnedOff && !isEnabled {
            sendToggle()
            onLog?("Mengembalikan VoiceOver")
        }
        weTurnedOff = false
    }

    // Tombol darurat
    func emergencyOn() {
        if !isEnabled {
            sendToggle()
            onLog?("DARURAT: menyalakan VoiceOver")
        }
        weTurnedOff = false
        cooldown = 4
    }

    // Tombol tes: kirim Cmd+F5 apa adanya (tanpa cek apa pun)
    func testToggle() {
        onLog?("TES: kirim Cmd+F5 (sebelum: \(detectionInfo))")
        sendToggle()
    }

    // Menekan Cmd+F5 (pintasan bawaan macOS untuk VoiceOver)
    private func sendToggle() {
        let src = CGEventSource(stateID: .hidSystemState)
        let keyCode: CGKeyCode = 96 // F5
        let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
        down?.flags = [.maskCommand, .maskSecondaryFn]
        up?.flags = [.maskCommand, .maskSecondaryFn]
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
