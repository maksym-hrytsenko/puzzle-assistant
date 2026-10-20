import SwiftData
import SwiftUI

struct NewPuzzleView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var name = ""
    @State private var pieceCountText = "1000"
    @State private var prepared: ReferencePreparer.Result?
    @State private var useRectified = true
    @State private var quarterTurns = 0
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let presets = [500, 1000, 1500, 2000, 3000, 4000, 5000, 6000]

    private var pieceCount: Int { Int(pieceCountText.filter(\.isNumber)) ?? 0 }

    private var chosenImage: CGImage? {
        guard let prepared else { return nil }
        var image = useRectified ? (prepared.rectified ?? prepared.original) : prepared.original
        for _ in 0..<quarterTurns {
            if let rotated = ReferencePreparer.rotatedLeft(image) { image = rotated }
        }
        return image
    }

    private var grid: PuzzleGrid? {
        guard let image = chosenImage, pieceCount >= 4 else { return nil }
        return PuzzleGrid(pieceCount: pieceCount, width: image.width, height: image.height)
    }

    private var canSave: Bool { chosenImage != nil && pieceCount >= 4 && !isSaving }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    step(1, "Готова картинка", "Фото коробки чи постера або картинка з інтернету.") { pictureSection }
                    step(2, "Кількість шматків", "Потрібна, щоб поділити картинку на сітку — по клітинці на шматок.") { countSection }
                    step(3, "Назва", nil) {
                        TextField("Напр. «Чарівний ліс»", text: $name)
                            .padding(14)
                            .card()
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Новий пазл")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Скасувати") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button(action: save) {
                    if isSaving { ProgressView().tint(.white) } else { Text("Створити пазл") }
                }
                .buttonStyle(PrimaryButtonStyle(enabled: canSave))
                .disabled(!canSave)
                .padding()
                .background(.bar)
            }
            .alert("Помилка", isPresented: .constant(errorMessage != nil)) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    @ViewBuilder
    private var pictureSection: some View {
        if isProcessing {
            HStack { Spacer(); ProgressView("Вирівнюю картинку…"); Spacer() }
                .frame(height: 220)
                .card()
        } else if let image = chosenImage {
            VStack(spacing: 12) {
                let uiImage = UIImage(cgImage: image)
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .overlay { if let grid { GridOverlay(grid: grid) } }
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                HStack {
                    if prepared?.rectified != nil {
                        Picker("", selection: $useRectified) {
                            Text("Вирівняна").tag(true)
                            Text("Як є").tag(false)
                        }
                        .pickerStyle(.segmented)
                    }
                    Button {
                        quarterTurns = (quarterTurns + 1) % 4
                    } label: {
                        Label("Повернути", systemImage: "rotate.left")
                    }
                    .buttonStyle(.bordered)
                }
                Text("Поверніть картинку так, як вона виглядає на коробці.")
                    .font(.caption).foregroundStyle(.secondary)
                if prepared?.rectified == nil {
                    Label("Рамку картинки не знайдено — використаю фото як є. Обріжте його заздалегідь, якщо поруч є стіл.",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PhotoSourceButtons(cameraTitle: "Інше фото", libraryTitle: "Галерея",
                                   cameraHint: "Сфотографуйте всю картинку рівно, без відблисків", onImage: load)
            }
            .padding(12)
            .card()
        } else {
            PhotoSourceButtons(cameraHint: "Сфотографуйте всю картинку рівно, без відблисків", onImage: load)
        }
    }

    private var countSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Кількість", text: $pieceCountText)
                    .keyboardType(.numberPad)
                    .font(.title2.bold().monospacedDigit())
                Text("шматків").foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(presets, id: \.self) { value in
                        Button("\(value)") { pieceCountText = "\(value)" }
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(pieceCount == value ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                        in: Capsule())
                            .foregroundStyle(pieceCount == value ? .white : .primary)
                    }
                }
            }
            if let grid {
                Label("Сітка \(grid.columns) × \(grid.rows) = \(grid.cellCount) клітинок", systemImage: "grid")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .card()
    }

    private func step<Content: View>(_ number: Int, _ title: String, _ hint: String?,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("\(number)")
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(Theme.accentGradient, in: Circle())
                Text(title).font(.title3.bold())
            }
            if let hint {
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            content()
        }
    }

    private func load(_ image: UIImage) {
        isProcessing = true
        Task.detached(priority: .userInitiated) {
            let result = ReferencePreparer.prepare(image)
            await MainActor.run {
                prepared = result
                useRectified = result?.rectified != nil
                quarterTurns = 0
                isProcessing = false
                if result == nil { errorMessage = "Не вдалося відкрити зображення." }
            }
        }
    }

    private func save() {
        guard let image = chosenImage else { return }
        isSaving = true
        let id = UUID()
        let title = name.trimmingCharacters(in: .whitespaces).isEmpty ? "Пазл на \(pieceCount)" : name
        let count = pieceCount
        Task.detached(priority: .userInitiated) {
            let uiImage = UIImage(cgImage: image)
            do {
                let path = try ImageStore.shared.save(uiImage, named: "reference.jpg", in: id, quality: 0.92)
                let thumb = try ImageStore.shared.save(ImageStore.shared.makeThumbnail(of: uiImage, maxDimension: 800),
                                                       named: "reference_thumb.jpg", in: id)
                await MainActor.run {
                    let puzzle = Puzzle(id: id, name: title, referenceImagePath: path, referenceThumbnailPath: thumb,
                                        referenceWidth: image.width, referenceHeight: image.height, pieceCount: count)
                    modelContext.insert(puzzle)
                    Haptics.success()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    errorMessage = "Не вдалося зберегти картинку."
                }
            }
        }
    }
}
