import SwiftUI
import OfflineResearchCore

struct ContentView: View {
    @StateObject private var model = AnswerModel()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 6) {
                            Image(systemName: "wifi.slash")
                            Text(model.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if model.answer.isEmpty {
                            Text("Ask a question. Everything runs on this device.")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .padding(.top, 40)
                        } else {
                            Text(model.answer)
                                .font(.body)
                                .textSelection(.enabled)
                        }

                        if !model.citations.isEmpty {
                            Divider()
                            Text("Sources").font(.headline)
                            ForEach(model.citations) { citation in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("[\(citation.index)] \(citation.title)")
                                        .font(.subheadline.weight(.semibold))
                                    if let url = citation.url, let link = URL(string: url) {
                                        Text(link.absoluteString)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                }

                HStack(spacing: 8) {
                    TextField("Question", text: $model.question)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.ask() }
                    Button("Ask") { model.ask() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.question.trimmingCharacters(in: .whitespaces).isEmpty || model.busy)
                }
                .padding()
                .background(.bar)
            }
            .navigationTitle("Offline Research")
        }
    }
}
