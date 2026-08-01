import SwiftUI
import SwiftData
import CoreImage

struct CreatePuzzleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var estimatedPieceCount = 1000
    @State private var isPresentingCamera = false
    @State private var correctedImage: UIImage?
    @State private var isProcessing = false
    @State private var didFallBackToUncorrected = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Puzzle") {
                    TextField("Name", text: $name)
                    Stepper("Estimated pieces: \(estimatedPieceCount)", value: $estimatedPieceCount, in: 50...6000, step: 50)
                }

                Section("Reference image") {
                    if let correctedImage {
                        Image(uiImage: correctedImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 240)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        if didFallBackToUncorrected {
                            Label("Couldn't confidently detect the image edges — using the photo as-is. You can retake it in better, even lighting.", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        Button("Retake Photo") { isPresentingCamera = true }
                    } else if isProcessing {
                        HStack {
                            Spacer()
                            ProgressView("Correcting perspective and color…")
                            Spacer()
                        }
                    } else {
                        Button {
                            isPresentingCamera = true
                        } label: {
                            Label("Take Reference Photo", systemImage: "camera")
                        }
                    }
                }
            }
            .navigationTitle("New Puzzle")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || correctedImage == nil)
                }
            }
            .fullScreenCover(isPresented: $isPresentingCamera) {
                CameraCaptureView(instructions: "Fit the whole puzzle box or reference image in frame, in even lighting.") { image in
                    process(image)
                }
            }
        }
    }

    private func process(_ image: UIImage) {
        isProcessing = true
        Task {
            let result = PerspectiveCorrector.correct(image)
            let ciImage: CIImage
            switch result {
            case .corrected(let corrected):
                ciImage = corrected
                didFallBackToUncorrected = false
            case .fallbackUncorrected(let original):
                ciImage = original
                didFallBackToUncorrected = true
            }

            let enhanced = ImageEnhancer.enhanceReferenceImage(ciImage)
            let context = CIContext()
            if let cgImage = context.createCGImage(enhanced, from: enhanced.extent) {
                correctedImage = UIImage(cgImage: cgImage)
            } else {
                correctedImage = image
            }
            isProcessing = false
        }
    }

    private func save() {
        guard let correctedImage else { return }
        let puzzle = Puzzle(name: name.trimmingCharacters(in: .whitespaces), estimatedPieceCount: estimatedPieceCount)
        puzzle.referenceImageWidth = Int(correctedImage.size.width)
        puzzle.referenceImageHeight = Int(correctedImage.size.height)
        modelContext.insert(puzzle)

        if let path = try? ImageStore.shared.save(correctedImage, named: "reference.jpg", in: puzzle.id) {
            puzzle.referenceImagePath = path
        }

        let event = SessionEvent(kind: .referenceMapCreated, summary: "Reference map created for \"\(puzzle.name)\".")
        event.puzzle = puzzle
        modelContext.insert(event)

        dismiss()
    }
}
