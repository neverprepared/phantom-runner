import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            APITab()
                .tabItem { Label("API", systemImage: "network") }
            CapabilitiesTab()
                .tabItem { Label("Capabilities", systemImage: "cpu") }
            CredentialsTab()
                .tabItem { Label("Credentials", systemImage: "key.fill") }
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 480, height: 360)
        .environmentObject(state)
    }
}
