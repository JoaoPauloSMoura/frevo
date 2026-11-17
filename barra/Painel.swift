import AppKit
import SwiftUI

/// O painel que abre ao clicar no ícone da barra de menu (no lugar do menu nativo).
@MainActor
final class Painel {
    private let popover = NSPopover()

    init(estado: EstadoDoApp) {
        let host = NSHostingController(rootView: PainelView(estado: estado))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient
        popover.animates = true
        // sempre escuro, como a ilha do notch: no tema claro o fundo translúcido deixa o texto acinzentado
        popover.appearance = NSAppearance(named: .darkAqua)
    }

    var aberto: Bool { popover.isShown }

    func alternar(de botao: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: botao.bounds, of: botao, preferredEdge: .minY)
        }
    }

    func fechar() { popover.performClose(nil) }
}

private let verde = Color(red: 0.11, green: 0.62, blue: 0.46)

struct PainelView: View {
    @ObservedObject var estado: EstadoDoApp

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            cabecalho
            if let p = estado.problema {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if estado.atualizacao != nil || estado.atualizando || estado.erroDeAtualizacao != nil { cartaoAtualizacao }
            cartaoAudio
            if estado.transcrevendo != nil || estado.baixandoModelo != nil || estado.erroDeTranscricao != nil { cartaoTranscrevendo }
            if !estado.proximas.isEmpty || !estado.agendaLiberada { cartaoAgenda }
            if !estado.pendentes.isEmpty || !estado.recentes.isEmpty { cartaoTranscricoes }
        }
        .padding(12)
        .frame(width: 340)
        .environment(\.colorScheme, .dark)
    }

    // MARK: cabeçalho

    private var cabecalho: some View {
        HStack(spacing: 8) {
            Image(nsImage: Glifo.sombrinha(lado: 16)).renderingMode(.template).accessibilityHidden(true)
            Text("Frevo").font(.system(size: 14, weight: .semibold))
            Spacer()
            Selo(estado: estado)
            Menu {
                Picker("Microfone", selection: Binding(get: { estado.micEscolhido ?? "" },
                                                       set: { estado.escolherMic($0.isEmpty ? nil : $0) })) {
                    Text("Automático").tag("")
                    ForEach(estado.microfones) { Text($0.nome).tag($0.uid) }
                }
                Toggle("Transcrever chamadas por padrão", isOn: Binding(get: { estado.transcreverPadrao }, set: { estado.definirPadrao($0) }))
                Toggle("Cancelar o eco do alto-falante", isOn: Binding(get: { estado.cancelarEco }, set: { estado.definirEco($0) }))
                Toggle("Perguntar na ilha quem está falando", isOn: Binding(get: { estado.perguntarQuemFala }, set: { estado.definirPerguntarQuemFala($0) }))
                Toggle("Abrir ao iniciar o Mac", isOn: Binding(get: { estado.abrirAoIniciar }, set: { estado.definirAbrirAoIniciar($0) }))
                Divider()
                Button("Abrir transcrições") { estado.abrirTranscricoes() }
                if !estado.acessibilidadeLiberada { Button("Permitir ler o mudo da chamada…") { estado.permitirAcessibilidade() } }
                Divider()
                Button("Procurar atualizações") { estado.procurarAtualizacao() }
                Text("Frevo \(estado.versao)")
                Divider()
                Button("Sair do Frevo") { estado.sair() }
            } label: {
                Image(systemName: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Ajustes")
        }
    }

    // MARK: atualização

    private var cartaoAtualizacao: some View {
        Cartao {
            VStack(alignment: .leading, spacing: 6) {
                if estado.atualizando {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Atualizando o Frevo…").font(.system(size: 13, weight: .semibold))
                    }
                    Text("Leva uns 2 minutos. O Frevo fecha e abre sozinho; se houver uma chamada, ele espera ela acabar.")
                        .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if let a = estado.atualizacao {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill").foregroundStyle(verde)
                        Text("Nova versão: \(a.versao)").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        Button("Atualizar") { estado.atualizar() }
                            .controlSize(.small)
                            .disabled(estado.chamada != nil)
                    }
                    if !a.notas.isEmpty {
                        Text(a.notas).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(5)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if estado.chamada != nil {
                        Text("Dá para atualizar quando a chamada acabar.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                if let e = estado.erroDeAtualizacao {
                    Text(e).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: áudio

    private var cartaoAudio: some View {
        Cartao {
            VStack(alignment: .leading, spacing: 8) {
                if let c = estado.chamada {
                    HStack(spacing: 4) {
                        Text(c.titulo).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if let app = c.app { Text("· \(app)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
                    }
                } else {
                    Text(estado.limpando ? "Limpando sua voz" : "Aguardando uma chamada").font(.system(size: 13, weight: .semibold))
                    if !estado.limpando {
                        Text("No Meet, Zoom ou Teams, escolha \"Frevo\" como microfone.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }

                if estado.limpando {
                    OndaAntesDepois(medidor: estado.medidor, filtroLigado: estado.filtroLigado)
                        .frame(height: 46)
                    // legenda presa a cada metade: o que o microfone ouve | filtro | o que a chamada recebe
                    ZStack {
                        HStack {
                            Text("Seu microfone")
                            Spacer()
                            Text(estado.filtroLigado ? "Na chamada" : "Sem filtro").foregroundStyle(estado.filtroLigado ? verde : .secondary)
                        }
                        if estado.filtroLigado {
                            RuidoTirado(medidor: estado.medidor, curto: true)
                                .foregroundStyle(.primary)
                                .help("Quanto ruído de fundo o filtro está tirando agora")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                Divider().padding(.vertical, 2)
                Linha("Cancelamento de ruído") {
                    Toggle("Cancelamento de ruído", isOn: Binding(get: { estado.filtroLigado }, set: { _ in estado.alternarFiltro() }))
                        .toggleStyle(Interruptor())
                }
                if let c = estado.chamada {
                    Linha("Transcrever esta chamada") {
                        Toggle("Transcrever esta chamada", isOn: Binding(get: { c.transcrever }, set: { estado.definirTranscricao($0) }))
                            .toggleStyle(Interruptor())
                    }
                }
                rodapeAudio
            }
        }
    }

    private var rodapeAudio: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic").font(.system(size: 10))
            Text(estado.microfone ?? "Nenhum microfone").lineLimit(1)
            if let c = estado.chamada {
                switch c.mudo {
                case .mudo: Text("· no mudo").foregroundStyle(.orange)
                case .aberto: Text("· aberto na chamada")
                case .desconhecido: EmptyView()
                }
            }
            Spacer()
            if estado.limpando && estado.filtroLigado { Text(String(format: "%.0f%% CPU", estado.cpu)).monospacedDigit() }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }

    // MARK: transcrição em andamento

    private var cartaoTranscrevendo: some View {
        Cartao {
            VStack(alignment: .leading, spacing: 6) {
                if let b = estado.baixandoModelo {
                    Text("Baixando o modelo de transcrição (1,6 GB)").font(.system(size: 12, weight: .medium))
                    ProgressView(value: b).controlSize(.small)
                } else if let t = estado.transcrevendo {
                    Text("Transcrevendo “\(t.titulo)”").font(.system(size: 12, weight: .medium)).lineLimit(1)
                    ProgressView(value: t.fracao).controlSize(.small)
                }
                if let e = estado.erroDeTranscricao {
                    Text(e).font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: agenda

    private var cartaoAgenda: some View {
        Cartao {
            VStack(alignment: .leading, spacing: 6) {
                Text("Próximas reuniões").font(.system(size: 11)).foregroundStyle(.secondary)
                if !estado.agendaLiberada {
                    Button("Permitir ler a agenda") { estado.permitirAgenda() }.controlSize(.small)
                }
                ForEach(estado.proximas.prefix(3)) { r in
                    HStack(spacing: 8) {
                        Text(r.inicio, format: .dateTime.hour().minute())
                            .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                        Text(r.titulo).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let link = r.link, r.naHora {
                            Button("Entrar") { NSWorkspace.shared.open(link) }.controlSize(.small)
                        } else {
                            Text(EstadoDoApp.falta(ate: r.inicio)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    // MARK: transcrições

    private var cartaoTranscricoes: some View {
        Cartao {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Transcrições").font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Abrir pasta") { estado.abrirTranscricoes() }.buttonStyle(.link).font(.system(size: 11))
                }
                ForEach(estado.pendentes.prefix(3)) { p in
                    HStack {
                        Image(systemName: "person.wave.2").foregroundStyle(.orange).font(.system(size: 11))
                        Text("\(p.titulo) · \(p.vozes) \(p.vozes == 1 ? "voz" : "vozes") sem nome").font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 6)
                        Button("Nomear") { estado.nomear(p.id) }.controlSize(.small)
                    }
                }
                ForEach(estado.recentes.prefix(3)) { a in
                    Button { NSWorkspace.shared.open(a.url) } label: {
                        HStack {
                            Image(systemName: "doc.text").font(.system(size: 11)).foregroundStyle(.secondary)
                            Text(a.titulo).font(.system(size: 12)).lineLimit(1)
                            Spacer()
                            Text(a.data, format: .relative(presentation: .named)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: peças

/// Estado num selo: gravando (com o tempo), limpando, filtro desligado, aguardando ou problema.
private struct Selo: View {
    @ObservedObject var estado: EstadoDoApp

    var body: some View {
        Group {
            if estado.problema != nil {
                rotulo("Problema", cor: .orange)
            } else if let desde = estado.chamada?.gravandoDesde {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    rotulo("● Gravando \(EstadoDoApp.tempo(desde: desde))", cor: .red)
                }
            } else if estado.transcrevendo != nil {
                rotulo("Transcrevendo", cor: .purple)
            } else if estado.limpando {
                rotulo(estado.filtroLigado ? "Limpando" : "Filtro desligado", cor: estado.filtroLigado ? verde : .secondary)
            } else {
                rotulo("Aguardando", cor: .secondary)
            }
        }
    }

    private func rotulo(_ t: String, cor: Color) -> some View {
        Text(t)
            .font(.system(size: 11, weight: .medium)).monospacedDigit()
            .foregroundStyle(cor)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(cor.opacity(0.12)))
    }
}

private struct Cartao<Conteudo: View>: View {
    @ViewBuilder var conteudo: Conteudo

    var body: some View {
        conteudo
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

private struct Linha<Controle: View>: View {
    let titulo: String
    @ViewBuilder var controle: Controle

    init(_ titulo: String, @ViewBuilder controle: () -> Controle) {
        self.titulo = titulo
        self.controle = controle()
    }

    var body: some View {
        HStack {
            Text(titulo).font(.system(size: 13))
            Spacer()
            controle
        }
    }
}
