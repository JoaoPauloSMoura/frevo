import Accelerate
import Synchronization

/// Volumes recentes do seu microfone antes e depois do filtro, um par a cada 10 ms, para a onda do painel.
/// A thread de áudio escreve; a tela lê sem trava (um valor pego no meio da escrita só entorta uma barra
/// por um quadro de animação, e a thread de áudio nunca espera).
final class Medidor: @unchecked Sendable {
    let capacidade: Int
    private let antes: UnsafeMutablePointer<Float>
    private let depois: UnsafeMutablePointer<Float>
    private let escritos = Atomic<Int>(0)

    init(capacidade: Int = 600) { // 6 s
        self.capacidade = capacidade
        antes = .allocate(capacity: capacidade)
        depois = .allocate(capacity: capacidade)
        antes.initialize(repeating: 0, count: capacidade)
        depois.initialize(repeating: 0, count: capacidade)
    }

    deinit {
        antes.deallocate()
        depois.deallocate()
    }

    /// Thread de áudio: um quadro (10 ms) antes e depois do filtro.
    func registrar(antes a: UnsafePointer<Float>, depois d: UnsafePointer<Float>, n: Int) {
        var ra: Float = 0, rd: Float = 0
        vDSP_rmsqv(a, 1, &ra, vDSP_Length(n))
        vDSP_rmsqv(d, 1, &rd, vDSP_Length(n))
        let i = escritos.load(ordering: .relaxed) % capacidade
        antes[i] = ra
        depois[i] = rd
        escritos.add(1, ordering: .releasing)
    }

    /// Os últimos `n` pares (o mais antigo primeiro), em amplitude RMS (0 a 1).
    func ultimos(_ n: Int) -> [(antes: Float, depois: Float)] { janela(n).pares }

    /// Os últimos `n` pares e quantos quadros já foram registrados até o mais novo deles (lidos juntos, para a
    /// onda saber a fase e andar suave entre um quadro de 10 ms e outro).
    func janela(_ n: Int) -> (pares: [(antes: Float, depois: Float)], total: Int) {
        let total = escritos.load(ordering: .acquiring)
        let k = min(n, capacidade)
        let pares = (0..<k).map { j -> (antes: Float, depois: Float) in
            let pos = total - k + j
            guard pos >= 0 else { return (0, 0) }
            let i = pos % capacidade
            return (antes[i], depois[i])
        }
        return (pares, total)
    }
}
