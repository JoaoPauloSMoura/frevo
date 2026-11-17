import Foundation

// frevo: versão de linha de comando do app (a barra de menu vem depois).
// Lê o microfone físico, limpa com o DeepFilterNet3 e entrega no "Frevo".

setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())

func opcao(_ nome: String) -> String? {
    guard let i = args.firstIndex(of: nome), i + 1 < args.count else { return nil }
    return args[i + 1]
}

func sair(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

if args.contains("--ajuda") || args.contains("-h") {
    print("""
    Uso: frevo [opções]
      --listar          mostra os microfones disponíveis
      --mic "nome"      usa o microfone cujo nome contém esse texto (padrão: o microfone padrão do Mac)
      --limite dB       quanto no máximo tirar de ruído (padrão 100 = sem limite)
      --sem-filtro      só repassa o áudio, para comparar
      --em-uso          diz se algum app está usando o Frevo agora (sai com 0 se estiver)
    Enquanto roda: Enter liga/desliga o filtro, Ctrl+C sai.
    """)
    exit(0)
}

// --em-uso: sai com 0 se algum app (Meet, Zoom…) está usando o microfone Frevo agora, ou seja, numa chamada
if args.contains("--em-uso") {
    let emUso = Audio.porUID(Audio.uidMic).map(Audio.emUso) ?? false
    print(emUso ? "Frevo em uso" : "Frevo livre")
    exit(emUso ? 0 : 1)
}

if args.contains("--listar") {
    let padrao = Audio.entradaPadrao()
    for d in Audio.microfones() {
        print("\(d.id == padrao ? "*" : " ") \(d.nome)  (\(d.canaisEntrada) canal(is), \(Int(Audio.taxa(d.id))) Hz)")
    }
    exit(0)
}

guard let feed = Audio.porUID(Audio.uidFeed) else {
    sair("O driver do Frevo não está instalado. Rode: scripts/instalar-driver.sh")
}

let microfones = Audio.microfones()
let mic: Dispositivo
if let parte = opcao("--mic") {
    guard let m = microfones.first(where: { $0.nome.localizedCaseInsensitiveContains(parte) }) else {
        sair("Nenhum microfone com \"\(parte)\" no nome. Veja a lista com --listar.")
    }
    mic = m
} else if let m = Audio.microfoneAutomatico(microfones) {
    mic = m
} else {
    sair("Nenhum microfone encontrado.")
}

guard Audio.definirTaxa(mic.id, Pipeline.taxa) else {
    sair("\(mic.nome) não aceitou 48 kHz (está em \(Int(Audio.taxa(mic.id))) Hz). Esta versão ainda não converte a taxa.")
}

let limite = Float(opcao("--limite") ?? "100") ?? 100
let pipe: Pipeline
do {
    let motor = try Motor(modelo: Motor.caminhoDoModelo(), limiteDb: limite)
    pipe = Pipeline(motor: motor, mic: mic.id, feed: feed)
    if args.contains("--sem-filtro") { pipe.filtroLigado.store(false, ordering: .relaxed) }
    try pipe.iniciar()
} catch {
    sair("Não consegui começar: \(error)")
}

print("Ouvindo \"\(mic.nome)\" → Frevo (filtro \(pipe.filtroLigado.load(ordering: .relaxed) ? "ligado" : "desligado"), limite \(Int(limite)) dB).")
print("No Zoom, Meet ou Teams, escolha \"Frevo\" como microfone. Enter liga/desliga o filtro, Ctrl+C sai.")

let relatorio = DispatchSource.makeTimerSource(queue: .main)
relatorio.schedule(deadline: .now() + 5, repeating: 5)
relatorio.setEventHandler { print(pipe.resumo()) }
relatorio.resume()

signal(SIGINT, SIG_IGN)
let ctrlC = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
ctrlC.setEventHandler {
    pipe.parar()
    print("\nParado.")
    exit(0)
}
ctrlC.resume()

// Enter alterna o filtro (bom para comparar ao vivo numa chamada de teste)
Thread.detachNewThread {
    while readLine() != nil {
        let novo = !pipe.filtroLigado.load(ordering: .relaxed)
        pipe.filtroLigado.store(novo, ordering: .relaxed)
        print(novo ? "Filtro ligado." : "Filtro desligado (áudio cru).")
    }
}

dispatchMain()
