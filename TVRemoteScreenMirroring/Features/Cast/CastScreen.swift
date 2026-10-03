import PhotosUI
import SwiftUI

/// Cast tab (design 12): selected TV, Photos, Videos, Screen mirroring. Nothing starts
/// automatically; each flow ends with an explicit "Show on TV".
struct CastScreen: View {
    @Environment(AppModel.self) private var model
    @State private var path: [AppModel.CastRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.m) {
                    ScreenHeader(title: L10n.tr("v2.cast.title"))
                    TVStatusCard()
                    if !model.connection.state.isConnected {
                        InlineNoticeView(kind: .info, text: L10n.tr("cast.connectFirst"), actionTitle: L10n.tr("remote.noTV.action")) {
                            if let device = model.devices.selectedDevice { model.connection.connect(to: device) } else { model.sheet = .discovery }
                        }
                    }
                    NavigationLink(value: AppModel.CastRoute.photos) {
                        CastEntry(icon: "icon-photo", title: L10n.tr("v2.media.photos"), subtitle: L10n.tr("v2.cast.photos.body"),
                                  state: model.checker.capabilities[.photos])
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cast.photos")
                    NavigationLink(value: AppModel.CastRoute.videos) {
                        CastEntry(icon: "icon-video", title: L10n.tr("v2.media.videos"), subtitle: L10n.tr("v2.cast.videos.body"),
                                  state: model.checker.capabilities[.video])
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cast.videos")
                    NavigationLink(value: AppModel.CastRoute.mirroring) {
                        MirroringEntry(state: model.checker.capabilities[.screenMirroring], isActive: model.mirroring.isActive)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("cast.mirroring")
                    Text(L10n.tr("v2.cast.nothingAutomatic"))
                        .font(.appFootnote)
                        .foregroundStyle(Color.appTextSecondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.l)
            }
            .appScreenBackground()
            .statusBarBackground()
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: AppModel.CastRoute.self) { route in
                switch route {
                case .photos: PhotoCastView()
                case .videos: VideoCastView()
                case .mirroring: MirroringView()
                }
            }
        }
        .onAppear(perform: consumeRequest)
        .onChange(of: model.castRequest) { _, _ in consumeRequest() }
    }

    /// Another tab asked for a Cast screen (Remote: "Cast photos").
    private func consumeRequest() {
        guard let route = model.castRequest else { return }
        model.castRequest = nil
        path = [route]
    }
}

/// Capability as a short, honest status line ("Ready", "Limited", "Not supported").
private func capabilityBadge(_ state: CapabilityState?) -> StatusBadge? {
    guard let state, state.support != .unknown else { return nil }
    switch state.support {
    case .supported: return StatusBadge(kind: .ready, text: L10n.tr("v2.status.ready"))
    case .limited: return StatusBadge(kind: .attention, text: L10n.tr("capability.status.limited"))
    case .unsupported: return StatusBadge(kind: .neutral, text: L10n.tr("capability.status.unsupported"))
    case .unknown: return nil
    }
}

private struct CastEntry: View {
    let icon: String
    let title: String
    let subtitle: String
    let state: CapabilityState?

    var body: some View {
        HStack(spacing: Spacing.m) {
            AppIconView(icon, size: 40).foregroundStyle(Color.appAccent)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(title).font(.appBannerTitle).foregroundStyle(Color.appTextPrimary)
                Text(subtitle).font(.appSecondary).foregroundStyle(Color.appTextSecondary).multilineTextAlignment(.leading)
                if let badge = capabilityBadge(state) { badge }
            }
            Spacer(minLength: 0)
            AppIconView("icon-chevron-right", size: 18).foregroundStyle(Color.appTextSecondary)
        }
        .padding(.vertical, Spacing.xs)
        .surfaceCard()
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// Large mirroring card with its setup state.
private struct MirroringEntry: View {
    let state: CapabilityState?
    let isActive: Bool

    private var pill: String {
        if isActive { return L10n.tr("v2.mirror.active") }
        switch state?.support {
        case .supported?: return L10n.tr("v2.status.ready")
        case .unsupported?: return L10n.tr("capability.status.unsupported")
        default: return L10n.tr("v2.cast.setupNeeded")
        }
    }

    var body: some View {
        VStack(spacing: Spacing.s) {
            HStack(spacing: Spacing.xs) {
                AppIconView("icon-phone", size: 40).foregroundStyle(Color.appAccent)
                AppIconView("icon-cast", size: 22).foregroundStyle(Color.appAccent)
                AppIconView("icon-tv", size: 52).foregroundStyle(Color.appTextPrimary)
            }
            .accessibilityHidden(true)
            Text(L10n.tr("v2.cast.mirror")).font(.appBannerTitle).foregroundStyle(Color.appTextPrimary)
            Text(L10n.tr("v2.cast.mirror.body")).font(.appSecondary).foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
            Text(pill)
                .font(.appFootnote.weight(.medium))
                .foregroundStyle(isActive ? Color.appSuccess : Color.appTextSecondary)
                .padding(.horizontal, Spacing.s)
                .padding(.vertical, 6)
                .background(Color.appSurfaceRaised, in: Capsule())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s)
        .surfaceCard()
        .overlay(alignment: .trailing) {
            AppIconView("icon-chevron-right", size: 18).foregroundStyle(Color.appTextSecondary).padding(.trailing, Spacing.m)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Photos (design 13/14)

/// Photos are picked with the system picker (no library access needed). Cancelling the picker
/// with nothing chosen goes back without sending anything.
struct PhotoCastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var pickerShownOnce = false

    private var media: MediaCastController { model.media }
    /// Only photos belong to this screen; a video selection from the Videos screen isn't shown.
    private var photos: [MediaCastController.CastItem] { media.items.allSatisfy { !$0.isVideo } ? media.items : [] }

    var body: some View {
        @Bindable var media = model.media
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                PageHeader(title: L10n.tr("v2.cast.photos"))
                if let device = model.devices.selectedDevice {
                    Text(device.displayName).font(.appBody).foregroundStyle(Color.appTextSecondary)
                }
                if model.checker.capabilities[.photos].support == .unsupported, model.connection.state.isConnected {
                    InlineNoticeView(kind: .warning, text: L10n.tr("cast.photos.unsupported"))
                }
                if media.phase == .loading {
                    ProgressMessageView(title: L10n.tr("cast.loading"), message: L10n.tr("cast.loading.detail"),
                                        cancelTitle: L10n.tr("common.cancel")) { media.cancelLoading() }
                } else if photos.isEmpty {
                    emptyState
                } else {
                    preview
                }
                if case .failed(let error) = media.phase {
                    ErrorCard(error: error, feature: "media") { action in
                        switch action {
                        case .retry: if photos.isEmpty { media.clear() } else { media.showOnTV() }
                        case .chooseAnotherFile: showPicker = true
                        default: break
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            if !photos.isEmpty { bottomBar }
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.cast.photos"))
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !photos.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button(L10n.tr("cast.chooseOther")) { showPicker = true }
                }
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 20, matching: .images, preferredItemEncoding: .compatible)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            model.media.load(items)
            pickerItems = [] // so picking the same photos again is noticed
        }
        .onChange(of: showPicker) { _, open in
            // Picker cancelled on first entry with nothing chosen: back, nothing sent.
            if !open, photos.isEmpty, pickerItems.isEmpty, media.phase != .loading { dismiss() }
        }
        .onAppear {
            guard !pickerShownOnce else { return }
            pickerShownOnce = true
            if photos.isEmpty { showPicker = true }
        }
    }

    private var emptyState: some View {
        StateMessageView(systemImage: "icon-photo", title: L10n.tr("v2.cast.photos"), message: L10n.tr("cast.pickerPrivacy"),
                         primaryTitle: L10n.tr("cast.choose"), primaryAction: { showPicker = true })
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var preview: some View {
        @Bindable var media = model.media
        if let item = media.currentItem {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Color.black)
                if let thumbnail = item.thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: media.fitMode == .fill ? .fill : .fit)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if media.phase == .casting { OnTVBadge().padding(Spacing.s) }
            }
            .accessibilityLabel(L10n.tr("cast.preview.photo"))

            if photos.count > 1 {
                Text(L10n.tr("v2.media.position", "\(media.currentIndex + 1)", "\(photos.count)"))
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(maxWidth: .infinity)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(photos) { photo in
                            Button {
                                media.select(photo.id)
                            } label: {
                                Thumbnail(image: photo.thumbnail, selected: photo.id == item.id)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(L10n.tr("v2.media.position", "\((photos.firstIndex { $0.id == photo.id } ?? 0) + 1)", "\(photos.count)"))
                            .accessibilityAddTraits(photo.id == item.id ? .isSelected : [])
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                if photos.count > 1 {
                    ToggleRow(icon: "icon-slideshow", title: L10n.tr("v2.media.slideshow"),
                              detail: model.access.hasPro ? L10n.tr("cast.slideshow.every", model.settings.slideshowInterval) : L10n.tr("cast.slideshow.proOnly"),
                              isOn: Binding(get: { media.slideshowRunning }, set: { _ in media.toggleSlideshow() }),
                              isEnabled: model.access.hasPro && media.phase == .casting)
                    Divider().overlay(Color.appBorder).padding(.leading, 56)
                }
                ToggleRow(icon: "icon-fit", title: L10n.tr("v2.media.fit"),
                          detail: L10n.tr(media.fitMode == .fit ? "cast.fit.detail" : "cast.fill.detail"),
                          isOn: Binding(get: { media.fitMode == .fit }, set: { media.fitMode = $0 ? .fit : .fill }))
            }
            .background(Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).stroke(Color.appBorder.opacity(0.7), lineWidth: 1))
        }
    }

    private var bottomBar: some View {
        VStack(spacing: Spacing.xs) {
            if media.phase == .casting {
                Button {
                    media.stop()
                } label: {
                    Label { Text(L10n.tr("v2.cast.stop")) } icon: { ButtonIcon("icon-stop") }
                }
                .buttonStyle(.outline)
            } else {
                Button {
                    media.showOnTV()
                } label: {
                    if media.phase == .sending {
                        ProgressView().tint(.appOnAccent)
                    } else {
                        Label { Text(L10n.tr("v2.media.showTV")) } icon: { ButtonIcon("icon-cast") }
                    }
                }
                .buttonStyle(.primary)
                .disabled(model.connection.connectedDevice == nil || media.phase == .sending)
                .accessibilityIdentifier("cast.show")
            }
            Text(freeNote ?? L10n.tr("v2.media.onlySelected"))
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, Spacing.screen)
        .padding(.vertical, Spacing.s)
        .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
    }

    private var freeNote: String? {
        guard let device = model.connection.connectedDevice, !model.access.hasPro,
              case .diagnostic = model.access.decision(.photo, device: device.id) else { return nil }
        return L10n.tr("diagnostic.photo.available")
    }
}

// MARK: - Videos (design 15/16/46)

struct VideoCastView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var appending = false
    @State private var pickerShownOnce = false

    private var media: MediaCastController { model.media }
    private var videos: [MediaCastController.CastItem] { media.items.allSatisfy(\.isVideo) ? media.items : [] }
    private var isPlaying: Bool {
        guard media.currentItem?.isVideo == true else { return false }
        switch media.phase {
        case .preparing, .casting: return true
        default: return false
        }
    }

    var body: some View {
        Group {
            if isPlaying {
                NowPlayingView()
            } else {
                list
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 10, matching: .videos, preferredItemEncoding: .compatible)
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            model.media.load(items, appending: appending && !videos.isEmpty)
            pickerItems = []
        }
        .onChange(of: showPicker) { _, open in
            if !open, videos.isEmpty, pickerItems.isEmpty, media.phase != .loading { dismiss() }
        }
        .onAppear {
            guard !pickerShownOnce else { return }
            pickerShownOnce = true
            if videos.isEmpty { appending = false; showPicker = true }
        }
    }

    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.s) {
                PageHeader(title: L10n.tr("v2.video.selected"))
                Text(L10n.tr("v2.video.selectedBody"))
                    .font(.appBody)
                    .foregroundStyle(Color.appTextSecondary)
                    .padding(.bottom, Spacing.xxs)
                if media.phase == .loading {
                    ProgressMessageView(title: L10n.tr("cast.loading"), message: L10n.tr("cast.loading.detail"),
                                        cancelTitle: L10n.tr("common.cancel")) { media.cancelLoading() }
                }
                ForEach(Array(videos.enumerated()), id: \.element.id) { index, video in
                    VideoRow(video: video, number: index + 1, selected: video.id == media.currentItem?.id,
                             onSelect: { media.select(video.id) }, onRemove: { media.remove(video.id) })
                }
                Button {
                    appending = true
                    showPicker = true
                } label: {
                    HStack(spacing: Spacing.m) {
                        AppIconView("icon-plus", size: 22)
                            .foregroundStyle(Color.appAccent)
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.appAccent, lineWidth: 1.5))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(L10n.tr("v2.video.add")).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                            Text(L10n.tr("cast.video.addDetail")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Color.appBorder, style: StrokeStyle(lineWidth: 1.2, dash: [6, 5])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if case .failed(let error) = media.phase {
                    ErrorCard(error: error, feature: "media") { action in
                        switch action {
                        case .retry: media.showOnTV()
                        case .chooseAnotherFile: appending = false; showPicker = true
                        default: break
                        }
                    }
                }
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            if !videos.isEmpty {
                VStack(spacing: Spacing.xs) {
                    Button {
                        media.showOnTV()
                    } label: {
                        if media.phase == .sending {
                            ProgressView().tint(.appOnAccent)
                        } else {
                            Label { Text(L10n.tr("v2.media.showTV")) } icon: { ButtonIcon("icon-play") }
                        }
                    }
                    .buttonStyle(.primary)
                    .disabled(model.connection.connectedDevice == nil || media.phase == .sending)
                    .accessibilityIdentifier("cast.show")
                    HStack(spacing: Spacing.xs) {
                        AppIconView("icon-shield", size: 16, relativeTo: .footnote)
                        Text(model.access.hasPro ? L10n.tr("v2.video.confirmFirst") : L10n.tr("cast.video.proOnly"))
                    }
                    .font(.appFootnote)
                    .foregroundStyle(Color.appTextSecondary)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.screen)
                .padding(.vertical, Spacing.s)
                .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
            }
        }
        .appScreenBackground()
        .pageNavigation(L10n.tr("v2.video.selected"))
        .toolbar(.visible, for: .navigationBar)
    }
}

private struct VideoRow: View {
    let video: MediaCastController.CastItem
    let number: Int
    let selected: Bool
    let onSelect: () -> Void
    let onRemove: () -> Void

    private var detail: String {
        var parts: [String] = []
        if let duration = video.duration { parts.append(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond))) }
        if let height = video.pixelHeight { parts.append("\(height)p") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Spacing.s) {
            Button(action: onSelect) {
                HStack(spacing: Spacing.s) {
                    ZStack {
                        if let thumbnail = video.thumbnail {
                            Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Color.appSurfaceRaised
                        }
                        AppIconView("icon-play", size: 18)
                            .foregroundStyle(.white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .frame(width: 110, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("cast.video.number", number)).font(.appHeadline).foregroundStyle(Color.appTextPrimary)
                        if !detail.isEmpty {
                            Text(verbatim: detail).font(.appFootnote.monospacedDigit()).foregroundStyle(Color.appTextSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
            Button(action: onRemove) {
                AppIconView("icon-trash", size: 20)
                    .foregroundStyle(Color.appTextSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.appSurfaceRaised))
            }
            .accessibilityLabel(L10n.tr("cast.video.remove", number))
        }
        .padding(Spacing.s)
        .background(selected ? Color.appAccentTint : Color.appSurface, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .stroke(selected ? Color.appAccent.opacity(0.8) : Color.appBorder.opacity(0.7), lineWidth: selected ? 1.5 : 1))
    }
}

/// Now playing (design 16 / 46). Volume uses TV remote commands when the TV accepts them; no
/// invented level is shown because the current volume can't be read.
private struct NowPlayingView: View {
    @Environment(AppModel.self) private var model
    @State private var hold: KeyHoldController?

    private var media: MediaCastController { model.media }

    private func supports(_ command: RemoteCommand) -> Bool {
        model.connection.session?.supportedCommands.contains(command) ?? false
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TVStatusCard(showsMenu: false, compact: true)
                if let item = media.currentItem {
                    ZStack {
                        Color.black
                        if let thumbnail = item.thumbnail {
                            Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
                        }
                    }
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay(alignment: .bottomLeading) { OnTVBadge().padding(Spacing.s) }
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.tr("v2.video.onTV")).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                        Text(L10n.tr("cast.video.number", (media.items.firstIndex { $0.id == item.id } ?? 0) + 1))
                            .font(.appScreenTitle).foregroundStyle(Color.appTextPrimary)
                    }
                }
                transport
                volume
            }
            .padding(.horizontal, Spacing.screen)
            .padding(.bottom, Spacing.l)
        }
        .safeAreaInset(edge: .bottom) {
            Button {
                media.stop()
            } label: {
                Label { Text(L10n.tr("v2.cast.stop")) } icon: { ButtonIcon("icon-stop") }
            }
            .buttonStyle(.outline)
            .padding(.horizontal, Spacing.screen)
            .padding(.vertical, Spacing.s)
            .background(Color.appBackground.ignoresSafeArea(edges: .bottom))
            .accessibilityIdentifier("cast.stop")
        }
        .appScreenBackground()
        .navigationTitle(L10n.tr("v2.video.nowPlaying"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .onAppear {
            if hold == nil {
                hold = KeyHoldController(
                    send: { [model] command, action in model.sendCommand(command, action: action) },
                    supportsPressRelease: { [model] command in model.connection.supportsPressRelease(command) },
                    currentSessionID: { [model] in model.connection.sessionID }
                )
            }
        }
        .onDisappear { hold?.cancelAll() }
    }

    @ViewBuilder
    private var transport: some View {
        if case .preparing(let progress) = media.phase {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(L10n.tr("cast.preparing")).font(.appSecondary).foregroundStyle(Color.appTextPrimary)
                ProgressView(value: progress).tint(.appAccent)
            }
            .surfaceCard()
        } else if let state = media.transport {
            if let position = state.position, let duration = state.duration, duration > 0 {
                VStack(spacing: Spacing.xxs) {
                    ProgressView(value: min(position, duration), total: duration)
                        .tint(.appAccent)
                        .accessibilityLabel(L10n.tr("cast.video.progress"))
                    HStack {
                        Text(Duration.seconds(position).formatted(.time(pattern: .minuteSecond)))
                        Spacer()
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    }
                    .font(.appFootnote.monospacedDigit())
                    .foregroundStyle(Color.appTextSecondary)
                }
            }
            HStack(spacing: Spacing.xxl) {
                Button { media.seek(by: -10) } label: {
                    Image(systemName: "gobackward.10").font(.system(size: 30, weight: .regular)).frame(width: 56, height: 56)
                }
                .accessibilityLabel(L10n.tr("cast.video.back10"))
                .disabled(state.position == nil)
                Button { media.playPause() } label: {
                    AppIconView(state.state == .playing ? "icon-pause" : "icon-play", size: 30)
                        .foregroundStyle(Color.appOnAccent)
                        .frame(width: 76, height: 76)
                        .background(Circle().fill(Color.appAccent))
                }
                .accessibilityLabel(state.state == .playing ? L10n.tr("key.pause") : L10n.tr("key.play"))
                Button { media.seek(by: 10) } label: {
                    Image(systemName: "goforward.10").font(.system(size: 30, weight: .regular)).frame(width: 56, height: 56)
                }
                .accessibilityLabel(L10n.tr("cast.video.forward10"))
                .disabled(state.position == nil)
            }
            .foregroundStyle(Color.appTextPrimary)
            .frame(maxWidth: .infinity)
        } else {
            InfoNote(text: L10n.tr("cast.video.noStatus"), boxed: true)
        }
    }

    @ViewBuilder
    private var volume: some View {
        if let hold, model.connection.state.isConnected, supports(.volumeUp) {
            HStack(spacing: Spacing.xs) {
                RemoteKeyButton(command: .volumeDown, height: 64, hold: hold)
                RemoteKeyButton(command: .mute, height: 64, hold: hold, isEnabled: supports(.mute))
                RemoteKeyButton(command: .volumeUp, height: 64, hold: hold)
            }
            Text(L10n.tr("cast.volume.onTV"))
                .font(.appFootnote)
                .foregroundStyle(Color.appTextSecondary)
                .frame(maxWidth: .infinity)
        } else {
            InfoNote(text: L10n.tr("v2.video.volumeTVRemote"), icon: "icon-volume", boxed: true)
        }
    }
}

// MARK: - Shared pieces

private struct OnTVBadge: View {
    var body: some View {
        Label {
            Text(L10n.tr("v2.video.onTV"))
        } icon: {
            AppIconView("icon-tv", size: 16, relativeTo: .footnote)
        }
        .font(.appFootnote.weight(.medium))
        .foregroundStyle(Color.appTextPrimary)
        .padding(.horizontal, Spacing.s)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct Thumbnail: View {
    let image: UIImage?
    let selected: Bool

    var body: some View {
        ZStack {
            Color.appSurfaceRaised
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
        }
        .frame(width: 104, height: 78)
        .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            .stroke(selected ? Color.appAccent : .clear, lineWidth: 2.5))
    }
}

/// Settings-style row with an icon, title, optional detail and a switch.
struct ToggleRow: View {
    let icon: String
    let title: String
    var detail: String?
    @Binding var isOn: Bool
    var isEnabled = true

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Spacing.s) {
                AppIconView(icon, size: 24).foregroundStyle(Color.appTextPrimary).frame(width: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.appBody).foregroundStyle(Color.appTextPrimary)
                    if let detail {
                        Text(detail).font(.appFootnote).foregroundStyle(Color.appTextSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Color.appAccent)
        .disabled(!isEnabled)
        .padding(.horizontal, Spacing.m)
        .padding(.vertical, Spacing.s)
        .frame(minHeight: HitTarget.row)
    }
}
