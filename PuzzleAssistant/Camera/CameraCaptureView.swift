import SwiftUI
import AVFoundation

struct CameraCaptureView: View {
    let instructions: LocalizedStringKey
    let onCapture: (UIImage) -> Void

    @StateObject private var controller = CameraController()
    @Environment(\.dismiss) private var dismiss
    @State private var authorizationDenied = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                Color.black.ignoresSafeArea()

                if authorizationDenied {
                    VStack(spacing: 12) {
                        Text("Потрібен доступ до камери")
                            .font(.headline)
                            .foregroundStyle(.white)
                        Text("Дозвольте доступ до камери в Параметрах, щоб фотографувати пазл.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .padding()
                } else {
                    CameraPreviewView(session: controller.session) { layer in
                        controller.attach(previewLayer: layer)
                    }
                    .ignoresSafeArea()
                }

                VStack(spacing: 16) {
                    Text(instructions)
                        .font(.subheadline)
                        .padding(10)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .padding(.horizontal)

                    Button {
                        controller.capturePhoto { image in
                            if let image {
                                onCapture(image)
                                dismiss()
                            }
                        }
                    } label: {
                        Circle()
                            .fill(.white)
                            .frame(width: 72, height: 72)
                            .overlay(Circle().stroke(.black.opacity(0.2), lineWidth: 2))
                    }
                    .disabled(authorizationDenied)
                    .padding(.bottom, 24)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Скасувати") { dismiss() }
                        .tint(.white)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .task { await requestAccessAndStart() }
        .onDisappear { controller.stop() }
    }

    private func requestAccessAndStart() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            controller.configure()
            controller.start()
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if granted {
                controller.configure()
                controller.start()
            } else {
                authorizationDenied = true
            }
        default:
            authorizationDenied = true
        }
    }
}
