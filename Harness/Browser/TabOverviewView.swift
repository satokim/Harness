import SwiftUI

/// 열린 탭을 카드로 보여준다. 탭하면 전환, 옆으로 밀면 닫힌다.
struct TabOverviewView: View {
    let store: BrowserStore
    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 16)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.tabs) { tab in
                        TabCard(
                            tab: tab,
                            isSelected: tab.id == store.selectedTabID,
                            onSelect: {
                                store.selectedTabID = tab.id
                                dismiss()
                            },
                            onClose: { store.close(tab) }
                        )
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
                .padding()
                .animation(.spring(duration: 0.3), value: store.tabs.map(\.id))
            }
            .navigationTitle("탭 \(store.tabs.count)개")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        store.newTab()
                        dismiss()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 520)
        #endif
    }
}

private struct TabCard: View {
    let tab: BrowserTab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var offset: CGFloat = 0
    @State private var isClosing = false

    private let closeDistance: CGFloat = 100

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text(tab.displayTitle)
                    .font(.caption.bold())
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.bold())
                        .padding(4)
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.bar))

            Color.clear
                .frame(height: 210)
                .overlay(alignment: .top) { preview }
                .clipped()
        }
        .background(.background)
        .clipShape(.rect(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: isSelected ? 3 : 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
        .offset(x: offset)
        .opacity(1 - min(abs(offset) / 300, 0.6))
        .rotationEffect(.degrees(Double(offset) / 40))
        .contentShape(.rect)
        .onTapGesture(perform: onSelect)
        // 세로 스크롤은 살리고, 가로로 민 경우만 카드를 움직인다
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    guard !isClosing, abs(value.translation.width) > abs(value.translation.height) else { return }
                    offset = value.translation.width
                }
                .onEnded { value in
                    guard !isClosing else { return }
                    let predicted = value.predictedEndTranslation.width
                    if abs(offset) > closeDistance || abs(predicted) > closeDistance * 3 {
                        close(direction: (predicted == 0 ? offset : predicted) < 0 ? -1 : 1)
                    } else {
                        withAnimation(.spring(duration: 0.25)) { offset = 0 }
                    }
                }
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let snapshot = tab.snapshot {
            #if os(macOS)
            Image(nsImage: snapshot).resizable().scaledToFill()
            #else
            Image(uiImage: snapshot).resizable().scaledToFill()
            #endif
        } else {
            Image(systemName: tab.currentURL == nil && tab.requestedURL == nil ? "pawprint.fill" : "globe")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(height: 210)
        }
    }

    private func close() {
        close(direction: -1)
    }

    private func close(direction: CGFloat) {
        isClosing = true
        withAnimation(.easeIn(duration: 0.2)) {
            offset = direction * 500
        } completion: {
            onClose()
        }
    }
}
