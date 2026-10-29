import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var user = ""
    @State private var password = ""
    @State private var route = ""
    @State private var tailscale = ""
    @State private var connectionMode = NASConnectionMode.automatic
    @State private var working = false
    @State private var tmdbToken = ""
    @State private var savingToken = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://tu-nas.synology.me:5006/video/", text: $address).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("Usuario", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("Contraseña", text: $password).textContentType(.password)
                } header: { Text("Conexión al NAS") } footer: {
                    Text("Usa la carpeta compartida que contiene Películas, Series y Videos. La cuenta se guarda en el llavero de este iPhone.")
                }
                Section {
                    TextField("IP local (opcional)", text: $route).keyboardType(.numbersAndPunctuation)
                    TextField("IP Tailscale o nombre MagicDNS", text: $tailscale).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Ruta", selection: $connectionMode) { ForEach(NASConnectionMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                } header: { Text("Red local y Tailscale") } footer: {
                    Text("Mantén arriba el dominio HTTPS del certificado. Automática prueba la red local y después Tailscale; activa Tailscale en el iPhone fuera de casa.")
                }
                Section {
                    Button {
                        working = true
                        Task {
                            let success = await store.connect(root: address, user: user, password: password, route: route, tailscale: tailscale, mode: connectionMode)
                            working = false
                            if success { store.synchronize(); dismiss() }
                        }
                    } label: {
                        HStack { Text(working ? "Conectando…" : "Conectar y guardar"); Spacer(); if working { ProgressView() } }
                    }.disabled(working || store.busy)
                }
                if store.account != nil {
                    Section("Biblioteca") {
                        Button { store.synchronize() } label: {
                            HStack { Text(store.busy ? "Actualizando…" : "Actualizar biblioteca"); Spacer(); if store.busy { ProgressView() } }
                        }.disabled(store.busy)
                        Text(store.status).font(.caption).foregroundStyle(.secondary)
                        if let feedback = store.libraryFeedback { Text(feedback).font(.caption).foregroundStyle(.secondary) }
                    }
                    Section {
                        if store.hasTMDB {
                            LabeledContent("Clave de TMDB", value: "Guardada")
                            Button { store.enrichMetadata(refresh: true) } label: {
                                HStack { Text(store.enrichStatus ?? "Volver a buscar carátulas"); Spacer(); if store.enrichStatus != nil { ProgressView() } }
                            }.disabled(store.enrichStatus != nil)
                            Button("Quitar clave de TMDB", role: .destructive) { store.removeTMDB() }
                        } else {
                            SecureField("Token de lectura de la API", text: $tmdbToken).textInputAutocapitalization(.never).autocorrectionDisabled()
                            Button {
                                savingToken = true
                                Task { if await store.setTMDB(token: tmdbToken) { tmdbToken = "" }; savingToken = false }
                            } label: {
                                HStack { Text(savingToken ? "Comprobando…" : "Guardar clave"); Spacer(); if savingToken { ProgressView() } }
                            }.disabled(savingToken || tmdbToken.isEmpty)
                        }
                    } header: { Text("Carátulas e información (TMDB)") } footer: {
                        Text(store.hasTMDB ? "\(store.metadata.count) títulos con información. Los que no se encuentran se pueden renombrar en el NAS con el formato Título (Año)."
                             : "Crea una cuenta gratuita en themoviedb.org, ve a Ajustes → API y copia el «Token de acceso de lectura de la API». Se guarda en el llavero de este iPhone.")
                    }
                    Section { Button("Cerrar sesión", role: .destructive) { store.disconnect() } }
                }
            }
            .navigationTitle("Ajustes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .onAppear {
                guard let account = store.account else { return }
                address = account.root.absoluteString; user = account.username; password = account.password
                route = account.routeIP; tailscale = account.tailscaleHost ?? ""; connectionMode = account.connectionMode ?? .automatic
            }
        }
    }
}
