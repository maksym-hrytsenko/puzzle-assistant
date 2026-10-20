import PhotosUI
import SwiftUI

/// "Take a photo" / "Choose from library" buttons that deliver a UIImage.
struct PhotoSourceButtons: View {
    var cameraTitle = "Сфотографувати"
    var libraryTitle = "З галереї"
    var cameraHint = "Тримайте телефон паралельно до столу"
    let onImage: (UIImage) -> Void

    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 12) {
            Button {
                showCamera = true
            } label: {
                Label(cameraTitle, systemImage: "camera.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(libraryTitle, systemImage: "photo.on.rectangle")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraCaptureView(instructions: cameraHint) { image in
                onImage(image)
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    onImage(image)
                }
                pickerItem = nil
            }
        }
    }
}
