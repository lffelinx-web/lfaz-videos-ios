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
            Text("Tu foto y tu nombre se muestran en Inicio y solo se guardan en este iPhone.")
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
