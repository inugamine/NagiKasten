//
// ArtDecoChrome.swift
// Kasten
//
// アール・デコ様式のパネル外装（階段状の角と二重ヘアライン）。
// AI サジェストとエラー解析、どちらのパネルからも使えるよう独立させている。
//

import SwiftUI

/// 四隅を階段状（ジッグラト）に切り落とした矩形。
///
/// アール・デコの垂直・直線志向を、角丸ではなく段差で表現する。
/// `InsettableShape` に準拠しているのは `strokeBorder` を使うため。
/// これが無いと線幅の半分だけ外側にはみ出し、二重線の間隔が揃わない。
struct SteppedRectangle: Shape, InsettableShape {
    /// 段ひとつ分の大きさ。角は 2 段で切るので、実際に欠ける量はこの 2 倍。
    var step: CGFloat = 5
    /// `inset(by:)` で積み上がる内側へのオフセット量。
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> SteppedRectangle {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }

        // パネルが極端に小さいとき、段が辺の長さを食い潰して形が破綻する。
        // 短辺の 1/4 を上限にして、常に真っ当な矩形が残るようにする。
        let s = min(step, min(r.width, r.height) / 4)

        var p = Path()
        // 上辺（左上の段を抜けた位置から開始）
        p.move(to: CGPoint(x: r.minX + 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY))
        // 右上の段
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * s))
        // 右辺
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 2 * s))
        // 右下の段
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY))
        // 下辺
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY))
        // 左下の段
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2 * s))
        // 左辺
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2 * s))
        // 左上の段
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY + s))
        p.closeSubpath()
        return p
    }
}

/// パネルの外装（切り抜き＋縁取り）をまとめて当てるモディファイア。
///
/// 装飾時は階段角＋真鍮の二重ヘアライン、それ以外は従来の角丸のまま。
/// 切り抜きと縁取りで同じ形を使う必要があるため、両者をここで一体にしている。
struct PanelChrome: ViewModifier {
    var isOrnamented: Bool
    /// 装飾時の縁の色（テーマの真鍮）。
    var accent: Color
    /// 非装飾時の角丸半径。
    var cornerRadius: CGFloat = 12

    /// 外周と内周の間隔。狭すぎると一本に潰れ、広すぎると額縁が野暮ったくなる。
    private let hairlineGap: CGFloat = 3
    /// 外周の線幅。
    private let outerLineWidth: CGFloat = 1.5
    /// 内周の線幅。外周の半分に保つ。
    /// 同じ太さにすると意図した額縁ではなく、印刷ミスの二重線に見える。
    private let innerLineWidth: CGFloat = 0.75
    /// 内周の濃さ。
    private let innerOpacity: CGFloat = 0.5

    func body(content: Content) -> some View {
        if isOrnamented {
            let shape = SteppedRectangle()
            content
                .clipShape(shape)
                .overlay {
                    ZStack {
                        // 外周: はっきりした真鍮の線
                        shape.strokeBorder(accent, lineWidth: outerLineWidth)
                        // 内周: 一段落とした細線。二本一組で「額縁」に見せる
                        shape.inset(by: hairlineGap)
                            .strokeBorder(accent.opacity(innerOpacity), lineWidth: innerLineWidth)
                    }
                }
        } else {
            content
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
    }
}

extension View {
    /// パネル外装を当てる。`isOrnamented` が false のときは従来の角丸のみ。
    func panelChrome(isOrnamented: Bool, accent: Color, cornerRadius: CGFloat = 12) -> some View {
        modifier(PanelChrome(isOrnamented: isOrnamented,
                             accent: accent,
                             cornerRadius: cornerRadius))
    }
}
