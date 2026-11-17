import AppKit
import AVFoundation
import SwiftUI

/// Toca o trecho de uma voz e avisa a janela qual está tocando (o botão vira "parar").
@MainActor
final class Reprodutor: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var tocando: String?
    private var player: AVAudioPlayer?
    private var parada: DispatchWorkItem?

    /// Toca a voz; se ela já estiver tocando, para.
    func alternar(_ s: Sessao, _ v: Sessao.Voz) {
        if tocando == v.id {
            parar()
            return
        }
        parar()
        let url = URL(fileURLWithPath: s.pasta).appendingPathComponent("outros.wav")
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.delegate = self
        p.currentTime = max(0, v.amostraInicio - s.atrasoOutros)
        p.play()
        player = p
        tocando = v.id
        let item = DispatchWorkItem { [weak self] in self?.parar() }
        parada = item
        DispatchQueue.main.asyncAfter(deadline: .now() + min(10, max(2, v.amostraFim - v.amostraInicio)), execute: item)
    }

    func parar() {
        parada?.cancel()
        player?.stop()
        player = nil
        tocando = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { MainActor.assumeIsolated { self.parar() } }
    }
}

/// Janela "Quem falou?": ouvir um trecho de cada voz e dar nome. Os nomes vão para a memória de vozes.
@MainActor
final class JanelaNomes {
    private var janela: NSWindow?
    private let reprodutor = Reprodutor()

    func abrir(_ sessao: Sessao, salvar: @escaping (String, [String: String]) -> Void, descartar: @escaping () -> Void) {
        janela?.close()
        reprodutor.parar()
        let view = NomesView(
            sessao: sessao,
            reprodutor: reprodutor,
            salvar: { [weak self] t, n in
                salvar(t, n)
                self?.fechar()
            },
            depois: { [weak self] in self?.fechar() },
            descartar: { [weak self] in
                descartar()
                self?.fechar()
            })
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = "Quem falou em “\(sessao.titulo)”?"
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        janela = w
    }

    private func fechar() {
        reprodutor.parar()
        janela?.close()
        janela = nil
    }
}

struct NomesView: View {
    let sessao: Sessao
    @ObservedObject var reprodutor: Reprodutor
    let salvar: (String, [String: String]) -> Void
    let depois: () -> Void
    let descartar: () -> Void
    @State private var titulo: String
    @State private var nomes: [String: String]

    /// Só vozes que valem um nome (fala suficiente), da que mais falou para a que menos falou.
    /// As já reconhecidas aparecem também, para você conferir.
    private var vozes: [Sessao.Voz] {
        sessao.vozes
            .filter { $0.nome != nil || ($0.segundos ?? .infinity) >= Sessao.segundosParaNomear }
            .sorted { ($0.segundos ?? 0) > ($1.segundos ?? 0) }
    }

    init(sessao: Sessao, reprodutor: Reprodutor, salvar: @escaping (String, [String: String]) -> Void,
         depois: @escaping () -> Void, descartar: @escaping () -> Void) {
        self.sessao = sessao
        self.reprodutor = reprodutor
        self.salvar = salvar
        self.depois = depois
        self.descartar = descartar
        _titulo = State(initialValue: sessao.titulo)
        // nome provável já vem preenchido: você só confere e salva
        _nomes = State(initialValue: Dictionary(uniqueKeysWithValues: sessao.vozes.map { ($0.id, $0.nome ?? $0.sugestao ?? "") }))
    }

    private static func duracao(_ s: Double) -> String {
        s >= 60 ? "\(Int((s / 60).rounded())) min de fala" : "\(Int(s)) s de fala"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Ouça cada voz e dê um nome. Nas próximas reuniões, o Frevo reconhece essas pessoas sozinho. As impressões de voz ficam só neste Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Reunião") {
                TextField("Nome da reunião", text: $titulo)
            }
            if !sessao.convidados.isEmpty && vozes.count > sessao.convidados.count {
                Label("\(vozes.count) vozes para \(sessao.convidados.count) convidados: falou alguém que não estava no convite. Confira quem é cada uma.",
                      systemImage: "person.badge.plus")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(vozes, id: \.id) { v in
                        HStack(alignment: .top, spacing: 10) {
                            Button { reprodutor.alternar(sessao, v) } label: {
                                Image(systemName: reprodutor.tocando == v.id ? "stop.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.plain)
                            .help(reprodutor.tocando == v.id ? "Parar" : "Ouvir um trecho desta voz")
                            VStack(alignment: .leading, spacing: 6) {
                                Text(v.reconhecida ? "\(v.rotulo) · reconhecida pela memória" : v.rotulo).font(.headline)
                                + Text(v.segundos.map { " · " + Self.duracao($0) } ?? "").font(.caption).foregroundColor(.secondary)
                                Text("“\(v.exemplo)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                if v.nome == nil, let s = v.sugestao, let m = v.motivo {
                                    Label("Sugestão: \(s), porque \(m). Confira ouvindo.", systemImage: "lightbulb")
                                        .font(.caption)
                                        .foregroundStyle(.orange)
                                }
                                HStack {
                                    TextField("Nome", text: Binding(get: { nomes[v.id] ?? "" }, set: { nomes[v.id] = $0 }))
                                    if !sessao.convidados.isEmpty {
                                        Menu("Convidados") {
                                            ForEach(sessao.convidados, id: \.self) { c in
                                                Button(c) { nomes[v.id] = c }
                                            }
                                        }
                                        .fixedSize()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 4) // folga para a borda dos campos não ser cortada pela rolagem
                .padding(.vertical, 2)
            }
            // a rolagem não tem altura própria: sem isto ela encolhe a zero numa janela que se ajusta ao conteúdo
            .frame(height: min(380, CGFloat(max(1, vozes.count)) * 112))
            HStack {
                Button("Não nomear esta chamada", role: .destructive, action: descartar)
                Spacer()
                Button("Depois", action: depois)
                Button("Salvar") { salvar(titulo, nomes) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
