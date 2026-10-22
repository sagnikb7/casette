import SwiftUI

struct ArtistGroupRow: View {
    var artist: String
    var count: Int
    @AppStorage("artistPhotosEnabled") private var enabled = true
    @State private var photo: ArtistPhoto?
    @State private var credit = false
    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let photo = photo, let image = ThumbnailLoader.shared.image(photo.fileURL.path) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else { Image(systemName: "person.fill").foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(UIColor.secondarySystemBackground)) }
            }.frame(width: 44, height: 44).clipShape(Circle()).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) { Text(artist); Text("\(count) songs").font(.footnote).foregroundColor(.secondary) }
        }.frame(minHeight: 52)
        .task(id: enabled) {
            photo = nil
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let result = await ArtistPhotoStore.shared.photo(for: artist, includeDetails: false)
            if !Task.isCancelled { photo = result }
        }
        .contextMenu { if photo != nil { Button("Photo Credit", systemImage: "info.circle") { credit = true } } }
        .sheet(isPresented: $credit) {
            if let photo = photo {
                NavigationView {
                    Form {
                        Section("Creator / Artist") { Text(photo.creator) }
                        Section("Source / License") { Text(photo.license); Link("Source Terms", destination: photo.licenseURL) }
                        Section { Link("Original Image and Attribution", destination: photo.sourceURL) }
                        Section { Text("600×600 artist image cached for offline browsing.").font(.footnote) }
                    }.background(BackGestureSupport(rootBack: { credit = false })).navigationTitle("Photo Credit").navigationBarTitleDisplayMode(.inline)
                        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { credit = false } } }
                }.navigationViewStyle(.stack)
            }
        }
    }
}
