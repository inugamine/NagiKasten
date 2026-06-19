//
// ShellIntegrationParser.swift
// Kasten
//
// Created by inugaminé on 2026/06/20.
//
  

import Foundation

/// シェル統合パーサが検出したコマンド境界イベント。
enum ShellIntegrationEvent: Equatable {
    case promptStart                       // OSC 133;A プロンプト開始
    case commandStart                      // OSC 133;B コマンド入力開始
    case outputStart                       // OSC 133;C 出力開始
    case commandFinished(exitCode: Int?)   // OSC 133;D 終了（終了コード付き）
}

/// OSC 133 を検出するストリーミング状態機械。
/// pty のバイトストリームを覗き、マーカーだけを拾ってイベント化する。
/// 描画には一切関与しない。
final class ShellIntegrationParser {
    
    private enum State: Equatable {
        case ground          // ESC待ち
        case escReceived     // ESC受信。次が ] なら OSC
        case collectingOSC   // OSCパラメータ蓄積中
        case oscEscReceived  // OSC内でESC受信。次が \ なら終端
    }
    
    private var state: State = .ground
    private var oscBuffer: [UInt8] = []
    private let maxOSCLength = 256
    
    private static let ESC: UInt8 = 0x1b
    private static let BEL: UInt8 = 0x07
    private static let OSC_INTRODUCER: UInt8 = 0x5d  // ']'
    private static let ST_FINAL: UInt8 = 0x5c        // '\'
    
    init() {}
    
    func feed(_ bytes: ArraySlice<UInt8>) -> [ShellIntegrationEvent] {
        var events: [ShellIntegrationEvent] = []
        for byte in bytes {
            if let event = step(byte) { events.append(event) }
        }
        return events
    }
    
    func feed(_ bytes: [UInt8]) -> [ShellIntegrationEvent] { feed(bytes[...]) }
    
    private func step(_ byte: UInt8) -> ShellIntegrationEvent? {
        switch state {
        case .ground:
            if byte == Self.ESC { state = .escReceived }
            return nil
            
        case .escReceived:
            if byte == Self.OSC_INTRODUCER {
                state = .collectingOSC
                oscBuffer.removeAll(keepingCapacity: true)
            } else if byte == Self.ESC {
                state = .escReceived
            } else {
                state = .ground
            }
            return nil
            
        case .collectingOSC:
            if byte == Self.BEL {
                let event = finishOSC(); state = .ground; return event
            } else if byte == Self.ESC {
                state = .oscEscReceived; return nil
            } else {
                oscBuffer.append(byte)
                if oscBuffer.count > maxOSCLength {
                    state = .ground
                    oscBuffer.removeAll(keepingCapacity: true)
                }
                return nil
            }
            
        case .oscEscReceived:
            if byte == Self.ST_FINAL {
                let event = finishOSC(); state = .ground; return event
            } else if byte == Self.ESC {
                state = .escReceived
                oscBuffer.removeAll(keepingCapacity: true)
                return nil
            } else {
                state = .ground
                oscBuffer.removeAll(keepingCapacity: true)
                return nil
            }
        }
    }
    
    private func finishOSC() -> ShellIntegrationEvent? {
        defer { oscBuffer.removeAll(keepingCapacity: true) }
        guard let payload = String(bytes: oscBuffer, encoding: .utf8) else { return nil }
        
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts[0] == "133" else { return nil }
        
        switch parts[1] {
        case "A": return .promptStart
        case "B": return .commandStart
        case "C": return .outputStart
        case "D":
            if parts.count >= 3, let code = Int(parts[2]) {
                return .commandFinished(exitCode: code)
            }
            return .commandFinished(exitCode: nil)
        default: return nil
        }
    }
    
    func reset() {
        state = .ground
        oscBuffer.removeAll(keepingCapacity: true)
    }
}
