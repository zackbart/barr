import SwiftUI

struct ShelfView: View {
    @ObservedObject var model: ShelfModel

    var body: some View {
        Group {
            if !model.canCaptureScreen || !model.canUseAccessibility {
                permissions
            } else if model.isManaging {
                manager
            } else if model.barrItems.isEmpty {
                emptyShelf
            } else {
                shelf
            }
        }
        .background(
            Color(red: 0.075, green: 0.082, blue: 0.095).opacity(0.97),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.5)
        }
        .environment(\.colorScheme, .dark)
        .padding(5)
    }

    private var shelf: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                iconRow(items: model.barrItems, action: model.activate)
            }

            Divider()
                .frame(height: 24)

            Button {
                model.setManaging(true)
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 15, weight: .medium))
                    .frame(
                        width: MenuBarItem.iconHitTarget,
                        height: MenuBarItem.iconHitTarget
                    )
            }
            .buttonStyle(ShelfButtonStyle())
            .help("Choose menu bar apps")
        }
        .padding(.horizontal, 7)
    }

    private var manager: some View {
        VStack(spacing: 0) {
            laneHeader("In Barr", detail: "Click to return") {
                Button("Done") { model.setManaging(false) }
                    .controlSize(.small)
            }

            if model.barrItems.isEmpty {
                lanePlaceholder("Choose an app from the menu bar below")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    iconRow(items: model.barrItems, action: model.returnToMenuBar)
                }
                .frame(height: 48)
            }

            Divider()
                .padding(.horizontal, 10)

            laneHeader("Menu Bar", detail: "Click to move into Barr") {
                Toggle(
                    "System items",
                    isOn: Binding(
                        get: { model.showsSystemItems },
                        set: model.setShowsSystemItems
                    )
                )
                .font(.system(size: 10))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help("Include macOS system menu bar items")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                iconRow(
                    items: model.menuBarItems,
                    action: model.moveToBarr,
                    canInteract: { $0.isMovableByBarr }
                )
            }
            .frame(height: 48)
        }
        .padding(.vertical, 7)
    }

    private func laneHeader<Trailing: View>(
        _ title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(height: 25)
    }

    private func lanePlaceholder(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private func iconRow(
        items: [MenuBarItem],
        action: @escaping (MenuBarItem) -> Void,
        canInteract: @escaping (MenuBarItem) -> Bool = { _ in true }
    ) -> some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                Button {
                    action(item)
                } label: {
                    Group {
                        if let symbolName = item.systemSymbolName {
                            Image(systemName: symbolName)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                        } else if let image = item.image {
                            Image(nsImage: image)
                                .renderingMode(image.isTemplate ? .template : .original)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .foregroundStyle(.primary)
                        } else {
                            Image(systemName: "app.dashed")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(
                        width: item.renderedIconWidth,
                        height: MenuBarItem.visualIconHeight
                    )
                    .frame(
                        width: item.logicalWidth,
                        height: MenuBarItem.iconHitTarget
                    )
                    .contentShape(Rectangle())
                    .padding(.horizontal, 3)
                    .padding(.vertical, 5)
                    .opacity(
                        model.movingItemKeys.contains(item.storageKey) || !canInteract(item)
                            ? 0.35
                            : 1
                    )
                }
                .buttonStyle(ShelfButtonStyle())
                .disabled(!model.movingItemKeys.isEmpty || !canInteract(item))
                .help(
                    canInteract(item)
                        ? item.displayName
                        : "\(item.displayName) is fixed by macOS"
                )
                .accessibilityLabel(item.displayName)
                .accessibilityHint(canInteract(item) ? "" : "Fixed by macOS")
            }
        }
        .padding(.horizontal, 6)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .background(.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Two permissions, one private shelf")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Barr reads menu bar icons. Nothing leaves your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            permissionRow(
                title: "Screen Recording",
                detail: model.screenCaptureNeedsRestart ? "Restart after allowing" : "Mirror each icon",
                granted: model.canCaptureScreen,
                actionTitle: model.screenCaptureNeedsRestart ? "Restart Barr" : "Allow",
                action: model.screenCaptureNeedsRestart ? model.restartBarr : model.requestScreenCapture
            )
            permissionRow(
                title: "Accessibility",
                detail: "Open the original app menu",
                granted: model.canUseAccessibility,
                actionTitle: "Allow",
                action: model.requestAccessibility
            )

            HStack {
                Spacer()
                Button("Check again") { model.refresh() }
                    .controlSize(.small)
            }
        }
        .padding(16)
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(granted ? .green : .secondary)
            Text(title)
                .font(.system(size: 12, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            if !granted {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
    }

    private var emptyShelf: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isRefreshing ? "Looking for menu bar apps…" : "The shelf is empty")
                    .font(.system(size: 12, weight: .semibold))
                Text("Choose which apps live in Barr.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose Apps") { model.setManaging(true) }
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
    }
}

private struct ShelfButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed ? Color.white.opacity(0.20) : Color.white.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}
