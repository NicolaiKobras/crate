import SwiftUI

struct SystemStoppedView: View {
    @EnvironmentObject private var vm: ContainerViewModel
    @State private var isStarting = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shippingbox")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            Text("Container service is not running")
                .font(.title2)
                .bold()

            Text("Start the system to manage containers, images, and volumes.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button {
                isStarting = true
                vm.startSystem()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    isStarting = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isStarting {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "play.fill")
                    }
                    Text(isStarting ? "Starting…" : "Start System")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isStarting)
            .help("Start the container system service")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

struct SystemLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text("Checking container service…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
