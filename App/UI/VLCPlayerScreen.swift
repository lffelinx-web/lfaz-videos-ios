import SwiftUI

#if canImport(MobileVLCKit)
import MobileVLCKit

/// Drives VLC for formats AVPlayer can't open (MKV, AVI…).
///
/// libvlc calls that touch the input (tracks, seeking, stopping) can wait for the network
/// while VLC is buffering, so they run on `queue`; the main thread only reads cached values.
@MainActor
final class VLCController: ObservableObject {
    struct Track: Identifiable, Hashable { var id: Int32; var name: String }

    let player = VLCMediaPlayer()
    @Published private(set) var time: Double = 0
    @Published private(set) var length: Double = 0
    @Published private(set) var playing = false
    @Published private(set) var loading = true
    @Published private(set) var ended = false
    @Published private(set) var failed = false
    @Published private(set) var audioTracks: [Track] = []
    @Published private(set) var subtitleTracks: [Track] = []
    @Published private(set) var audioTrack: Int32 = -1
    @Published private(set) var subtitleTrack: Int32 = -1
    private let queue = DispatchQueue(label: "lfaz.vlc.control", qos: .userInitiated)
    private var timer: Timer?
    private var lastState: VLCMediaPlayerState?
    private var tracksLoaded = false
    private var loadingTracks = false

    func load(_ url: URL, start: Double) {
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=3000")
        if start > 0 { media.addOption(":start-time=\(Int(start))") }
        player.media = media
        let player = player
        queue.async { player.play() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func refresh() {
        time = Double(player.time.intValue) / 1000
        let total = Double(player.media?.length.intValue ?? 0) / 1000
        if total > 0 { length = total }
        let state = player.state
        playing = state == .playing || (state == .buffering && player.isPlaying)
        switch state {
        case .opening, .buffering: loading = !playing
        case .ended: ended = true; loading = false
        case .error: failed = true; loading = false
        default: loading = false
        }
        // Track lists change when streams appear; read them off the main thread.
        if !tracksLoaded || (state != lastState && (state == .playing || state == .esAdded)) { loadTracks() }
        lastState = state
    }

    func loadTracks() {
        guard !loadingTracks else { return }
        loadingTracks = true
        let player = player
        queue.async { [weak self] in
            let audio = Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
            let subtitles = Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
            let currentAudio = player.currentAudioTrackIndex, currentSubtitle = player.currentVideoSubTitleIndex
            Task { @MainActor in
                guard let self else { return }
                self.audioTracks = audio; self.subtitleTracks = subtitles
                self.audioTrack = currentAudio; self.subtitleTrack = currentSubtitle
                self.tracksLoaded = !audio.isEmpty
                self.loadingTracks = false
            }
        }
    }

    nonisolated private static func tracks(names: [Any]?, indexes: [Any]?) -> [Track] {
        let names = (names ?? []).map { "\($0)" }
        let indexes = (indexes ?? []).compactMap { ($0 as? NSNumber)?.int32Value }
        return zip(indexes, names).map { Track(id: $0, name: $1) }
    }

    private func control(_ action: @escaping (VLCMediaPlayer) -> Void) {
        let player = player
        queue.async { action(player) }
    }

    func togglePlay() {
        let wasPlaying = playing
        playing.toggle()
        control { wasPlaying ? $0.pause() : $0.play() }
    }
    func jump(_ seconds: Int32) {
        time = max(0, min(length, time + Double(seconds)))
        control { seconds > 0 ? $0.jumpForward(seconds) : $0.jumpBackward(-seconds) }
    }
    func seek(to fraction: Double) {
        let value = Float(min(max(fraction, 0), 1))
        time = Double(value) * length; loading = true
        control { $0.position = value }
    }
    func selectAudio(_ id: Int32) { audioTrack = id; control { $0.currentAudioTrackIndex = id } }
    func selectSubtitle(_ id: Int32) { subtitleTrack = id; control { $0.currentVideoSubTitleIndex = id } }

    /// Stopping waits for VLC's network thread; never block the screen while it closes.
    func stop() {
        timer?.invalidate(); timer = nil
        control { $0.stop() }
    }
}

struct VLCVideoView: UIViewRepresentable {
    let player: VLCMediaPlayer
    func makeUIView(context: Context) -> UIView {
        let view = UIView(); view.backgroundColor = .black
        // VLC adds its own rendering subview, which would swallow taps meant for the controls.
        view.isUserInteractionEnabled = false
        player.drawable = view
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct VLCPlayerScreen: View {
    let request: PlaybackRequest
    let url: URL
    var onProgress: (Double, Double) -> Void
    var onClose: () -> Void
    @StateObject private var controller = VLCController()
    @State private var controlsVisible = true
    @State private var scrubbing: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var showTracks = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(player: controller.player).ignoresSafeArea().allowsHitTesting(false)
            Color.clear.ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { controlsVisible.toggle(); scheduleHide() }
                // Swiping down closes the player, as in the native one.
                .gesture(DragGesture(minimumDistance: 40).onEnded { if $0.translation.height > 120 && abs($0.translation.width) < 80 { close() } })
            if controller.loading { ProgressView().controlSize(.large).tint(.white) }
            if controller.failed {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("No se pudo reproducir este video.").font(.headline)
                    Button("Cerrar", action: close).buttonStyle(.borderedProminent)
                }.foregroundStyle(.white)
            }
            if controlsVisible && !controller.failed { controls.transition(.opacity) }
            if showTracks { tracksPanel.transition(.move(edge: .trailing).combined(with: .opacity)) }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .animation(.easeInOut(duration: 0.2), value: showTracks)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(controlsVisible ? .automatic : .hidden)
        .onAppear {
            AudioSession.activateForMovies()
            Orientation.allowRotation(true, preferLandscape: true)
            // The first request can arrive before the cover finishes presenting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { Orientation.allowRotation(true, preferLandscape: true) }
            controller.load(url, start: request.start)
            scheduleHide()
        }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in report() }
        .onChange(of: controller.ended) { _, ended in if ended { close() } }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.7), .clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea().allowsHitTesting(false)
            VStack {
                HStack(spacing: 14) {
                    Button(action: close) { Image(systemName: "xmark").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                        .accessibilityLabel("Cerrar")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.title).font(.headline).lineLimit(1)
                        if !request.subtitle.isEmpty { Text(request.subtitle).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1) }
                    }
                    Spacer()
                    trackMenu
                }
                Spacer()
                HStack(spacing: 48) {
                    Button { controller.jump(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.title) }
                        .accessibilityLabel("Retroceder 10 segundos")
                    Button { controller.togglePlay(); scheduleHide() } label: {
                        Image(systemName: controller.playing ? "pause.fill" : "play.fill").font(.system(size: 44))
                    }.accessibilityLabel(controller.playing ? "Pausar" : "Reproducir")
                    Button { controller.jump(10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.title) }
                        .accessibilityLabel("Avanzar 10 segundos")
                }
                Spacer()
                VStack(spacing: 4) {
                    Slider(value: Binding(
                        get: { scrubbing ?? (controller.length > 0 ? controller.time / controller.length : 0) },
                        set: { scrubbing = $0 }
                    ), in: 0...1) { editing in
                        if !editing, let value = scrubbing { controller.seek(to: value); scrubbing = nil }
                        scheduleHide()
                    }
                    HStack {
                        Text(clockText(scrubbing.map { $0 * controller.length } ?? controller.time))
                        Spacer()
                        Text("-" + clockText(max(0, controller.length - (scrubbing.map { $0 * controller.length } ?? controller.time))))
                    }.font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.8))
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .foregroundStyle(.white)
        .tint(Palette.accent)
    }

    private var trackMenu: some View {
        Button {
            controller.loadTracks()
            showTracks = true; hideTask?.cancel()
        } label: {
            Image(systemName: "captions.bubble").font(.title3).frame(width: 44, height: 44)
        }.accessibilityLabel("Audio y subtítulos")
    }

    /// A side panel instead of a `Menu`: menus inside VLC's full-screen cover didn't open.
    private var tracksPanel: some View {
        HStack {
            Spacer()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        Text("Audio y subtítulos").font(.headline)
                        Spacer()
                        Button { showTracks = false; scheduleHide() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                            .accessibilityLabel("Cerrar")
                    }
                    trackSection("Audio", tracks: controller.audioTracks, selected: controller.audioTrack) { controller.selectAudio($0) }
                    trackSection("Subtítulos", tracks: controller.subtitleTracks, selected: controller.subtitleTrack) { controller.selectSubtitle($0) }
                }.padding(20)
            }
            .frame(width: 320)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24))
            .padding(12)
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }

    private func trackSection(_ title: String, tracks: [VLCController.Track], selected: Int32, select: @escaping (Int32) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            if tracks.isEmpty {
                Text("Este video no tiene pistas de \(title.lowercased()).").font(.footnote).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(tracks) { track in
                Button { select(track.id) } label: {
                    HStack {
                        Text(track.name).lineLimit(2).multilineTextAlignment(.leading)
                        Spacer()
                        if track.id == selected { Image(systemName: "checkmark").foregroundStyle(Palette.accent) }
                    }
                    .padding(.vertical, 10).padding(.horizontal, 12)
                    .background(track.id == selected ? Color.white.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard controlsVisible else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled && controller.playing && scrubbing == nil && !showTracks { controlsVisible = false }
        }
    }

    private func report() { if controller.length > 0 { onProgress(controller.time, controller.length) } }

    private func close() {
        report()
        hideTask?.cancel()
        controller.stop()
        Orientation.allowRotation(false)
        onClose()
    }
}
#else
/// Shown for MKV and other non-native formats until the VLC engine is added to the project.
struct VLCPlayerScreen: View {
    let request: PlaybackRequest
    let url: URL
    var onProgress: (Double, Double) -> Void
    var onClose: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack").font(.system(size: 44)).foregroundStyle(Palette.accent)
            Text(request.title).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
            Text("Los archivos \(request.file.format) necesitan el reproductor VLC, que llegará en la próxima versión. Los MP4, M4V y MOV ya se pueden ver.")
                .font(.subheadline).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
            Button("Cerrar", action: onClose).buttonStyle(.borderedProminent).padding(.top, 6)
        }
        .padding(32).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.background.ignoresSafeArea())
    }
}
#endif
