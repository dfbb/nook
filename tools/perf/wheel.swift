#!/usr/bin/env swift
import ApplicationServices
import Foundation

enum Mode: String { case fling, constant }

let arguments = CommandLine.arguments
let mode = arguments.dropFirst().first.flatMap(Mode.init(rawValue:)) ?? .fling
let eventSource = CGEventSource(stateID: .hidSystemState)
var posted = 0

func post(
    delta: Int32,
    phase: CGScrollPhase?,
    momentum: CGMomentumScrollPhase = .none
) {
    guard let event = CGEvent(
        scrollWheelEvent2Source: eventSource,
        units: .pixel,
        wheelCount: 1,
        wheel1: delta,
        wheel2: 0,
        wheel3: 0
    ) else { return }
    event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
    event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
    event.post(tap: .cghidEventTap)
    posted += 1
}

guard AXIsProcessTrusted() else {
    fputs("Accessibility permission is required. Keep Nook frontmost, grant this shell/Terminal access, then retry.\n", stderr)
    exit(2)
}

switch mode {
case .constant:
    post(delta: -18, phase: .began)
    for _ in 0..<180 {
        post(delta: -18, phase: .changed)
        usleep(16_667)
    }
    post(delta: 0, phase: .ended)
case .fling:
    post(delta: -100, phase: .began)
    for _ in 0..<8 {
        post(delta: -100, phase: .changed)
        usleep(16_667)
    }
    post(delta: 0, phase: .ended)
    var velocity = 96.0
    var first = true
    while velocity >= 1 {
        // Momentum events carry no gesture phase and use CGMomentumScrollPhase
        // (begin=1, continue=2, end=3), not CGScrollPhase (ended=4).
        post(delta: -Int32(velocity.rounded()), phase: nil, momentum: first ? .begin : .continuous)
        first = false
        velocity *= 0.90
        usleep(16_667)
    }
    post(delta: 0, phase: nil, momentum: .end)
}

print("wheel.events posted=\(posted) mode=\(mode.rawValue)")
