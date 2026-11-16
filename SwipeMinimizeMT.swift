// SwipeMinimizeMT.swift
// Swipe verso il basso con 3 dita => minimizza la finestra attiva (come il pulsante giallo).
// Legge i tocchi grezzi dal trackpad (framework privato MultitouchSupport).
//
// Compilazione:
//   swiftc -O SwipeMinimizeMT.swift -o SwipeMinimizeMT
// Avvio:
//   ./SwipeMinimizeMT

import Cocoa
import ApplicationServices

// MARK: - Struttura dei tocchi (layout del framework privato)

struct MTPoint { var x: Float; var y: Float }
struct MTVector { var position: MTPoint; var velocity: MTPoint }
struct MTTouch {
    var frame: Int32
    var timestamp: Double
    var identifier: Int32
    var state: Int32          // 4 = tocco iniziato, 5 = tocco in corso
    var fingerId: Int32
    var handId: Int32
    var normalized: MTVector  // position.x / position.y in 0...1 (y: 0 = vicino a te)
    var size: Float
    var zero1: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVector
    var zero2: Int32
    var zero3: Int32
    var density: Float
}

typealias MTContactCallback = @convention(c) (
    UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32
) -> Int32

typealias MTDeviceCreateListFn = @convention(c) () -> UnsafeMutableRawPointer?
typealias MTRegisterFn = @convention(c) (UnsafeMutableRawPointer, MTContactCallback) -> Void
typealias MTDeviceStartFn = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void

// MARK: - Parametri del gesto

let requiredFingers = 3
let minVerticalTravel: Float = 0.12     // quanto devono scendere le dita (0...1)
let maxHorizontalRatio: Float = 0.8     // il movimento orizzontale deve restare minore del verticale

// MARK: - Stato del gesto (accesso solo dal thread del callback)

var startY: Float = 0
var startX: Float = 0
var tracking = false
var fired = false

func minimizeFocusedWindow() {
    guard let app = NSWorkspace.shared.frontmostApplication else { return }
    let axApp = AXUIElementCreateApplication(app.processIdentifier)

    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
          let window = value else {
        print("Nessuna finestra attiva trovata (controlla il permesso di Accessibilità)")
        return
    }
    let result = AXUIElementSetAttributeValue(window as! AXUIElement,
                                              kAXMinimizedAttribute as CFString,
                                              kCFBooleanTrue)
    if result != .success { print("Impossibile minimizzare: \(result.rawValue)") }
}

let touchCallback: MTContactCallback = { _, touches, count, _, _ in
    guard let rawTouches = touches else { return 0 }
    let touches = rawTouches.assumingMemoryBound(to: MTTouch.self)

    // Considera solo i dita realmente appoggiate
    var active: [MTTouch] = []
    for i in 0..<Int(count) {
        let t = touches[i]
        if t.state == 4 || t.state == 5 { active.append(t) }
    }

    if active.count == 0 {
        tracking = false
        fired = false
        return 0
    }

    // Se il numero di dita non è esattamente 3, il gesto non è valido
    guard active.count == requiredFingers else {
        if active.count > requiredFingers { tracking = false; fired = true } // 4+ dita: ignora fino al rilascio
        else if !fired { tracking = false }
        return 0
    }

    let avgX = active.reduce(0) { $0 + $1.normalized.position.x } / Float(active.count)
    let avgY = active.reduce(0) { $0 + $1.normalized.position.y } / Float(active.count)

    if !tracking && !fired {
        tracking = true
        startX = avgX
        startY = avgY
        return 0
    }

    if tracking && !fired {
        let dy = startY - avgY            // positivo = dita scese verso di te
        let dx = abs(avgX - startX)
        if dy > minVerticalTravel && dx < dy * maxHorizontalRatio {
            fired = true
            tracking = false
            DispatchQueue.main.async { minimizeFocusedWindow() }
        }
    }
    return 0
}

// MARK: - Avvio

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        print("Accessibilità concessa: \(AXIsProcessTrustedWithOptions(opts))")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⬇︎"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Esci da SwipeMinimize",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        statusItem.menu = menu

        startMultitouch()
    }

    func startMultitouch() {
        let path = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport"
        guard let handle = dlopen(path, RTLD_NOW),
              let listSym = dlsym(handle, "MTDeviceCreateList"),
              let regSym = dlsym(handle, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(handle, "MTDeviceStart") else {
            print("Impossibile caricare MultitouchSupport")
            return
        }
        let createList = unsafeBitCast(listSym, to: MTDeviceCreateListFn.self)
        let register = unsafeBitCast(regSym, to: MTRegisterFn.self)
        let start = unsafeBitCast(startSym, to: MTDeviceStartFn.self)

        guard let listPtr = createList() else {
            print("Nessun trackpad trovato")
            return
        }
        let list = Unmanaged<CFArray>.fromOpaque(listPtr).takeRetainedValue()
        let n = CFArrayGetCount(list)
        print("Trackpad trovati: \(n)")
        for i in 0..<n {
            guard let ptr = CFArrayGetValueAtIndex(list, i) else { continue }
            let device = UnsafeMutableRawPointer(mutating: ptr)
            register(device, touchCallback)
            start(device, 0)
        }
        // Mantieni viva la lista dei dispositivi
        _ = Unmanaged.passRetained(list)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
