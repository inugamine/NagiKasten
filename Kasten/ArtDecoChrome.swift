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

/// 四隅にだけ現れる「三本目の線」。
///
/// アール・デコは角に向かって装飾が積み上がる様式なので、
/// 縁取りを全周で厚くするのではなく、角だけを厚くする。
/// `SteppedRectangle` と同じ幾何を使うため、内側へ寄せても形が破綻しない。
struct SteppedCornerMarks: Shape, InsettableShape {
    /// 段ひとつ分の大きさ。`SteppedRectangle` と揃えること。
    var step: CGFloat = 5
    /// 角から各辺へ伸ばす腕の長さ。ここが長いと四隅が繋がって普通の枠になる。
    var arm: CGFloat = 10
    var insetAmount: CGFloat = 0

    func inset(by amount: CGFloat) -> SteppedCornerMarks {
        var copy = self
        copy.insetAmount += amount
        return copy
    }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        guard r.width > 0, r.height > 0 else { return Path() }

        let s = min(step, min(r.width, r.height) / 4)
        // 腕が伸びすぎて隣の角と繋がらないよう、辺の残り半分を上限にする。
        let a = max(0, min(arm, (min(r.width, r.height) - 4 * s) / 2 - 2))

        var p = Path()

        // 左上
        p.move(to: CGPoint(x: r.minX, y: r.minY + 2 * s + a))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s + a, y: r.minY))

        // 右上
        p.move(to: CGPoint(x: r.maxX - 2 * s - a, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * s))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY + 2 * s + a))

        // 右下
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - 2 * s - a))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.maxX - s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - 2 * s - a, y: r.maxY))

        // 左下
        p.move(to: CGPoint(x: r.minX + 2 * s + a, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + 2 * s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - s))
        p.addLine(to: CGPoint(x: r.minX + s, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2 * s))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY - 2 * s - a))

        return p
    }
}

fileprivate extension Color {
    /// 色を白（正）または黒（負）へ寄せる。真鍮の照り返しを作るために使う。
    ///
    /// 不透明度をいじる方法だと下地の材質が透けて色味が濁るので、
    /// AppKit の混色で「明るい真鍮／沈んだ真鍮」そのものを作る。
    func shifted(by fraction: CGFloat) -> Color {
        guard fraction != 0,
              let base = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let target: NSColor = fraction > 0 ? .white : .black
        guard let blended = base.blended(withFraction: min(abs(fraction), 1), of: target) else {
            return self
        }
        return Color(nsColor: blended)
    }
}

/// パネルを閉じるボタン。
///
/// 装飾時も「塗り潰された円」の形は崩さない。
/// ここを階段状の枠にすると周りの装飾と同化してしまい、
/// 「押せるもの」として読めなくなる。形は機能の合図、色だけをテーマに揃える。
struct PanelCloseButton: View {
    var isOrnamented: Bool
    /// 装飾時の円の色。パネル側のアクセントをそのまま受け取る。
    var accent: Color
    /// 円から ✕ を抜く色。テーマの地色を渡す。
    var knockout: Color
    var action: () -> Void

    @State private var isHovering = false

    /// 円の直径。従来の xmark.circle.fill と同じ見かけの大きさに揃える。
    private let diameter: CGFloat = 16

    var body: some View {
        Button(action: action) {
            if isOrnamented {
                ZStack {
                    // 常時しっかり塗る。この面が無いとボタンに見えない。
                    Circle()
                        .fill(accent.opacity(isHovering ? 1 : 0.8))
                    Text(verbatim: "✕")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(knockout)
                }
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
            } else {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// パネルの外装（切り抜き＋縁取り）をまとめて当てるモディファイア。
///
/// 装飾時は階段角＋真鍮の二重ヘアライン＋四隅の補強線、それ以外は従来の角丸のまま。
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
    /// 四隅の補強線の太さ。内周より僅かに太くして、角に重心を置く。
    private let cornerLineWidth: CGFloat = 1.0
    /// 四隅の補強線の濃さ。
    private let cornerOpacity: CGFloat = 0.75

    /// 外周の照り返し。左上を明るく、右下を沈ませて板金の厚みを出す。
    private var outerSheen: LinearGradient {
        LinearGradient(colors: [accent.shifted(by: 0.4),
                                accent,
                                accent.shifted(by: -0.3)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    /// 内周の照り返し。外周とは逆向きに光らせるのが肝。
    ///
    /// 同じ向きに揃えると単に線が二本並んでいるようにしか見えないが、
    /// 逆向きにすると二本の間が彫り込まれた溝のように読める。
    private var innerSheen: LinearGradient {
        LinearGradient(colors: [accent.shifted(by: -0.3).opacity(innerOpacity),
                                accent.opacity(innerOpacity),
                                accent.shifted(by: 0.4).opacity(innerOpacity)],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    func body(content: Content) -> some View {
        if isOrnamented {
            let shape = SteppedRectangle()
            content
                .clipShape(shape)
                .overlay {
                    ZStack {
                        // 外周: はっきりした真鍮の線
                        shape.strokeBorder(outerSheen, lineWidth: outerLineWidth)
                        // 内周: 一段落とした細線。二本一組で「額縁」に見せる
                        shape.inset(by: hairlineGap)
                            .strokeBorder(innerSheen, lineWidth: innerLineWidth)
                        // 四隅: 三本目の線。角だけに現れ、辺の途中で消える
                        SteppedCornerMarks()
                            .inset(by: hairlineGap * 2)
                            .stroke(accent.opacity(cornerOpacity), lineWidth: cornerLineWidth)
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
