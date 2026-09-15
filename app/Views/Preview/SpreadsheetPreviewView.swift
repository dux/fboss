import SwiftUI

struct SpreadsheetPreviewView: View {
    let url: URL
    @State private var state: LoadState = .loading

    private enum LoadState {
        case loading
        case loaded(SpreadsheetPreviewLoader.Document)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            PreviewHeader(title: "Spreadsheet preview", icon: "tablecells", color: .green)
            Divider()

            switch state {
            case .loading:
                ProgressView("Loading spreadsheet...")
                    .textStyle(.buttons)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .loaded(let document):
                SpreadsheetWebView(document: document)
            case .failed(let message):
                Text(message)
                    .textStyle(.buttons)
                    .foregroundColor(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            state = .loading
            do {
                let document = try await SpreadsheetPreviewLoader().load(url: url)
                try Task.checkCancellation()
                state = .loaded(document)
            } catch is CancellationError {
                return
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
