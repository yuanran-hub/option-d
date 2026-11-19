import SwiftUI

struct CenteredWordList: View {
    let words: [String]
    @Binding var selection: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var position = ScrollPosition(edge: .top)
    @StateObject private var motion = WheelMotion()
    @State private var isHandScrolling = false
    @State private var handSelection: String?
    private let rowHeight: CGFloat = 33

    var body: some View {
        GeometryReader { viewport in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(words, id: \.self) { word in
                        Button {
                            isHandScrolling = false
                            selection = word
                        } label: {
                            Text(word).font(.system(size: 15, weight: .medium))
                                .lineLimit(1).padding(.horizontal, 21)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: rowHeight).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection == word ? .isSelected : [])
                    }
                }
                // End padding lets the first and last rows reach the same center as every other row.
                .padding(.vertical, max(0, (viewport.size.height - rowHeight) / 2))
                .background(WheelScrollAttachment(motion: motion))
            }
            .background {
                if selection != nil {
                    Color.clear.frame(height: rowHeight)
                        .glassEffect(.regular, in: Capsule())
                        .padding(.horizontal, 7)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: Int.self, of: { row(at: $0) }) { _, index in
                if isHandScrolling { selectRow(index) }
            }
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting, .decelerating:
                    motion.stop()
                    isHandScrolling = true
                case .idle where isHandScrolling:
                    let index = row(at: context.geometry)
                    isHandScrolling = false
                    selectRow(index)
                    center(animated: true)
                default: break
                }
            }
            .onChange(of: selection) { old, new in
                if isHandScrolling && handSelection == new { return }
                isHandScrolling = false
                center(animated: old != nil && new != nil)
            }
            .onChange(of: viewport.size.height, initial: true) { center(animated: false) }
            .onChange(of: words) { isHandScrolling = false; center(animated: false) }
            .onDisappear { motion.stop() }
            .accessibilityLabel("单词列表")
        }
    }

    private func row(at geometry: ScrollGeometry) -> Int {
        let y = geometry.contentOffset.y + geometry.contentInsets.top
        return min(max(Int((y / rowHeight).rounded()), 0), words.count - 1)
    }

    private func selectRow(_ index: Int) {
        guard words.indices.contains(index) else { return }
        handSelection = words[index]
        if selection != words[index] { selection = words[index] }
    }

    private func center(animated: Bool) {
        guard let selection, let index = words.firstIndex(of: selection) else { motion.stop(); return }
        let y = CGFloat(index) * rowHeight
        if animated && !reduceMotion && motion.move(to: y) { return }
        motion.stop()
        position.scrollTo(y: y)
    }
}
