import RoomyCore
import SwiftUI

struct ContentView: View {
    @State private var model = AppModel()

    var body: some View {
        VStack(spacing: 0) {
            DiskHeader(disk: model.disk)
            Divider()
            Group {
                switch model.phase {
                case .idle: IdleView(model: model)
                case .scanning: BusyView(title: "스캔 중", detail: model.status, progress: nil)
                case .results: ResultsView(model: model)
                case .cleaning: BusyView(title: "정리 중", detail: model.status, progress: model.progress)
                case .report: ReportView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.background)
    }
}

// MARK: - Header

struct DiskHeader: View {
    let disk: DiskStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Roomy").font(.title2.bold())
                Spacer()
                Text("\(disk.availableBytes.formattedBytes) 남음")
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(disk.usedFraction > 0.9 ? .red : .primary)
            }
            ProgressView(value: disk.usedFraction)
                .tint(disk.usedFraction > 0.9 ? .red : .accentColor)
            HStack {
                Text("\(disk.totalBytes.formattedBytes) 중 \(disk.usedBytes.formattedBytes) 사용")
                Spacer()
                if let trash = disk.trashBytes, trash > 0 {
                    Text("휴지통 \(trash.formattedBytes)")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
    }
}

// MARK: - Idle and busy

struct IdleView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("버튼 하나로 공간을 찾아드려요").font(.title2.weight(.semibold))
            Text("스캔은 읽기만 해요. 정리는 확인한 다음에, 휴지통으로만 옮겨요.")
                .foregroundStyle(.secondary)
            Button(action: model.scan) {
                Text("스캔").font(.title3.weight(.semibold)).frame(width: 180, height: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

struct BusyView: View {
    let title: String
    let detail: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress).frame(width: 320)
            } else {
                ProgressView().controlSize(.large)
            }
            Text(title).font(.title3.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).frame(maxWidth: 420)
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    let model: AppModel
    @State private var confirming = false

    var body: some View {
        if model.categories.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "sparkles").font(.system(size: 44)).foregroundStyle(.tint)
                Text("정리할 게 거의 없어요").font(.title3.weight(.semibold))
                Button("다시 스캔", action: model.scan)
            }
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text("정리할 수 있는 공간 \(model.foundBytes.formattedBytes)")
                        .font(.headline)
                    Spacer()
                    Text("스캔 \(Int(model.scanSeconds.rounded()))초").font(.caption).foregroundStyle(.secondary)
                    Button("다시 스캔", action: model.scan)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.categories) { CategoryCard(model: model, category: $0) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                }

                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("선택: \(model.selectedCount)개 항목").font(.callout)
                        Text("휴지통으로 옮기므로 되돌릴 수 있어요").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        confirming = true
                    } label: {
                        Text("한 번에 정리 · \(model.selectedBytes.formattedBytes)")
                            .font(.headline).padding(.horizontal, 10).frame(height: 30)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.selectedCount == 0)
                }
                .padding(20)
            }
            .confirmationDialog(
                "\(model.selectedCount)개 항목을 정리할까요?",
                isPresented: $confirming
            ) {
                Button("정리하기", action: model.clean)
                Button("취소", role: .cancel) {}
            } message: {
                Text(confirmMessage)
            }
        }
    }

    var confirmMessage: String {
        var lines = ["휴지통으로 옮긴 항목은 휴지통에서 되돌릴 수 있어요."]
        let ids = Set(model.selection.map(\.id))
        if ids.contains(.simulators) { lines.append("사용할 수 없는 시뮬레이터는 바로 삭제돼요.") }
        if ids.contains(.videos) { lines.append("영상 변환은 오래 걸릴 수 있어요.") }
        return lines.joined(separator: "\n")
    }
}

struct CategoryCard: View {
    let model: AppModel
    let category: ScanCategory
    @State private var expanded = false

    var isOn: Bool { model.enabled.contains(category.id) }
    var cautionCount: Int { category.findings.filter { $0.caution != nil }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle("", isOn: Binding(get: { isOn }, set: { _ in model.toggle(category.id) }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                Image(systemName: category.id.symbol)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(category.id.title).font(.headline)
                        SafetyBadge(safety: category.id.safety)
                    }
                    Text(category.id.explanation)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if cautionCount > 0 {
                        Label("\(cautionCount)개는 확인이 필요해서 선택을 빼뒀어요", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(category.totalBytes.formattedBytes).font(.title3.monospacedDigit().weight(.semibold))
                    Text("\(category.findings.count)개").font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(.snappy) { expanded.toggle() }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("항목 보기")
            }
            .padding(14)
            .opacity(isOn ? 1 : 0.6)

            if expanded {
                Divider()
                VStack(spacing: 0) {
                    ForEach(category.findings.prefix(300)) { f in
                        FindingRow(model: model, finding: f, categoryOn: isOn)
                    }
                    if category.findings.count > 300 {
                        Text("외 \(category.findings.count - 300)개").font(.caption).foregroundStyle(.secondary).padding(8)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FindingRow: View {
    let model: AppModel
    let finding: Finding
    let categoryOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { !model.excluded.contains(finding.id) },
                set: { _ in model.toggle(finding) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!categoryOn)
            VStack(alignment: .leading, spacing: 1) {
                Text(finding.url.lastPathComponent).lineLimit(1)
                Text(finding.note.isEmpty ? finding.url.shortPath : "\(finding.note) · \(finding.url.shortPath)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let caution = finding.caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).lineLimit(2).truncationMode(.middle)
                }
            }
            Spacer()
            Text(finding.bytes.formattedBytes).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Button { model.reveal(finding.url) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.borderless)
                .help("Finder에서 보기")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

struct SafetyBadge: View {
    let safety: Safety

    var body: some View {
        Text(safety == .safe ? "안전" : "확인 필요")
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(safety == .safe ? Color.green : Color.orange)
            .background((safety == .safe ? Color.green : Color.orange).opacity(0.15), in: Capsule())
    }
}

// MARK: - Report

struct ReportView: View {
    let model: AppModel

    var body: some View {
        if let report = model.report {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("정리 완료").font(.headline).foregroundStyle(.secondary)
                        Text(report.totalBytes.formattedBytes)
                            .font(.system(size: 44, weight: .bold).monospacedDigit())
                    }

                    HStack(spacing: 12) {
                        StatTile(title: "바로 확보됨", value: report.freedNowBytes.formattedBytes)
                        StatTile(title: "휴지통 비우면 확보", value: report.inTrashBytes.formattedBytes)
                        StatTile(title: "남은 공간",
                                 value: "\(report.diskBefore.availableBytes.formattedBytes) → \(report.diskAfter.availableBytes.formattedBytes)")
                    }

                    if report.inTrashBytes > 0 {
                        Label("휴지통으로 옮긴 파일은 휴지통을 비워야 공간이 생겨요. 그 전까지는 되돌릴 수 있어요.",
                              systemImage: "info.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    VStack(spacing: 0) {
                        ForEach(report.lines) { line in
                            HStack {
                                Image(systemName: line.category.symbol).frame(width: 22).foregroundStyle(.tint)
                                Text(line.category.title)
                                Spacer()
                                if line.failed > 0 {
                                    Text("\(line.failed)개 건너뜀").font(.caption).foregroundStyle(.orange)
                                }
                                Text("\(line.succeeded)개").foregroundStyle(.secondary)
                                Text(line.bytes.formattedBytes).monospacedDigit().frame(width: 90, alignment: .trailing)
                            }
                            .padding(.vertical, 8)
                            .padding(.horizontal, 14)
                            Divider()
                        }
                    }
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))

                    if !report.failures.isEmpty {
                        DisclosureGroup("건너뛴 항목 \(report.failures.count)개") {
                            ForEach(report.failures) { o in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(o.finding.url.shortPath).font(.caption).lineLimit(1).truncationMode(.middle)
                                    Text(o.error ?? "").font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    HStack {
                        Button("보고서 저장…", action: model.saveReport)
                        Button("휴지통 열기", action: model.openTrash)
                        Spacer()
                        Button("다시 스캔", action: model.scan).buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
            }
        }
    }
}

struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
