import SwiftUI
import PhotosUI

/// The viewer's name and photo, kept on this iPhone.
@MainActor
final class Profile: ObservableObject {
    static let shared = Profile()
    @Published var image: UIImage?
    @AppStorage("profileName") var name = ""
    private let file = Files.root.appendingPathComponent("profile.jpg")

    init() { image = UIImage(contentsOfFile: file.path) }

    func setPhoto(_ data: Data) {
        guard let original = UIImage(data: data) else { return }
        // A square crop at 600 px is plenty for the avatar.
        let side = min(original.size.width, original.size.height)
        let crop = CGRect(x: (original.size.width - side) / 2, y: (original.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let square = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 600), format: format).image { _ in
            original.draw(in: CGRect(x: -crop.minX * 600 / side, y: -crop.minY * 600 / side, width: original.size.width * 600 / side, height: original.size.height * 600 / side))
        }
        _ = try? Files.folder("")
        try? square.jpegData(compressionQuality: 0.85)?.write(to: file, options: .atomic)
        image = square
    }

    func removePhoto() { try? FileManager.default.removeItem(at: file); image = nil }

    var firstName: String? { name.split(separator: " ").first.map(String.init) }

    var initials: String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
}

struct ProfileAvatar: View {
    @ObservedObject private var profile = Profile.shared
    var size: CGFloat
    var body: some View {
        ZStack {
            if let image = profile.image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if !profile.initials.isEmpty {
                LinearGradient(colors: [Palette.accent, Color(red: 0.12, green: 0.24, blue: 0.62)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Text(profile.initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            } else {
                Color.white.opacity(0.08)
                Image(systemName: "person.fill").font(.system(size: size * 0.42)).foregroundStyle(.white.opacity(0.85))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
    }
}

/// The profile tab: photo and name, then Mi lista and Descargas.
struct ProfileView: View {
    enum Page: Hashable { case list, downloads }

    @EnvironmentObject var store: AppStore
    @ObservedObject private var profile = Profile.shared
    var openSettings: () -> Void
    @State private var page = Page.list

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ScreenHeader(title: nil, subtitle: nil) { EmptyView() }.padding(.top, 8)
                VStack(spacing: 12) {
                    ProfileAvatar(size: 104)
                    Text(profile.name.isEmpty ? "Tu perfil" : profile.name).font(.title2.weight(.bold))
                    Button(action: openSettings) {
                        Label("Editar perfil", systemImage: "pencil").font(.subheadline.weight(.medium))
                            .padding(.horizontal, 18).frame(height: 38).liquidBar()
                    }
                    .buttonStyle(.plain).environment(\.colorScheme, .dark)
                }
                .frame(maxWidth: .infinity)
                LiquidChips(items: [(id: Page.list, title: "Mi lista"), (id: Page.downloads, title: "Descargas")], selection: $page)
                    .padding(.horizontal, 20)
                content.padding(.horizontal, 20)
            }
            .padding(.bottom, BarInset.bottom)
        }
        .background(Palette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder private var content: some View {
        switch page {
        case .list:
            let ids = store.watchlist.filter { store.card($0) != nil }.sorted()
            if ids.isEmpty {
                empty("plus.circle", "Tu lista está vacía", "Toca «Añadir» en una película o serie para guardarla aquí.")
            } else { TitleGrid(ids: ids) }
        case .downloads:
            let ids = store.downloadedTitles
            if ids.isEmpty {
                empty("arrow.down.circle", "Sin descargas", "Descarga películas o episodios para verlos sin conexión.")
            } else { TitleGrid(ids: ids) }
        }
    }

    private func empty(_ symbol: String, _ title: String, _ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 36)).foregroundStyle(Palette.secondaryText)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(Palette.secondaryText).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 30)
    }
}

/// "Perfil" at the top of Ajustes: photo, name and a greeting preview.
struct ProfileSection: View {
    @ObservedObject private var profile = Profile.shared
    @State private var pick: PhotosPickerItem?

    var body: some View {
        Section {
            HStack(spacing: 16) {
                ProfileAvatar(size: 72)
                VStack(alignment: .leading, spacing: 8) {
                    PhotosPicker(selection: $pick, matching: .images) {
                        Label(profile.image == nil ? "Elegir foto" : "Cambiar foto", systemImage: "photo.on.rectangle")
                    }
                    if profile.image != nil {
                        Button("Quitar foto", role: .destructive) { profile.removePhoto() }.font(.subheadline)
                    }
                }
            }
            .padding(.vertical, 4)
            TextField("Tu nombre", text: $profile.name).textContentType(.name)
        } header: { Text("Perfil") } footer: {
            Text("Tu foto y tu nombre se muestran en Inicio y en tu perfil, y solo se guardan en este iPhone.")
        }
        .onChange(of: pick) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { profile.setPhoto(data) }
                pick = nil
            }
        }
    }
}
