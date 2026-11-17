import AppKit

/// A sombrinha do Frevo em uma cor só, desenhada em código para a barra de menu e o painel: é a mesma do ícone
/// (barra/icone/Frevo.svg), em vetor, nítida em qualquer tela. Sai como imagem "modelo" (template): o macOS pinta
/// de preto ou branco conforme a barra de menu.
enum Glifo {
    enum Marca {
        case nenhuma
        /// bolinha no canto: está gravando a chamada
        case ponto
        /// risco na diagonal: filtro desligado
        case risco
    }

    static func sombrinha(lado: CGFloat = 18, marca: Marca = .nenhuma) -> NSImage {
        let imagem = NSImage(size: NSSize(width: lado, height: lado), flipped: true) { _ in
            guard let cg = NSGraphicsContext.current?.cgContext else { return false }
            cg.setFillColor(.black)
            cg.setStrokeColor(.black)
            cg.setLineCap(.round)

            cg.saveGState()
            // o desenho usa as coordenadas do SVG (1024 × 1024); o glifo mostra o recorte 190…830 × 200…840
            let escala = lado / 640
            cg.scaleBy(x: escala, y: escala)
            cg.translateBy(x: -190, y: -200)
            cg.translateBy(x: 512, y: 560)
            cg.rotate(by: -14 * .pi / 180) // inclinada, como na dança
            cg.translateBy(x: -512, y: -560)

            cg.setLineWidth(48) // cabo
            cg.move(to: CGPoint(x: 512, y: 520))
            cg.addLine(to: CGPoint(x: 512, y: 790))
            cg.strokePath()

            cg.addPath(copa)
            cg.fillPath()
            cg.setBlendMode(.clear) // vãos entre os gomos
            cg.setLineWidth(38)
            for m in meridianos { cg.addPath(m) }
            cg.strokePath()
            cg.setBlendMode(.normal)

            cg.fillEllipse(in: CGRect(x: 512 - 40, y: 293 - 22, width: 80, height: 44)) // tampa onde os gomos se encontram
            cg.setLineWidth(30)
            cg.move(to: CGPoint(x: 512, y: 295))
            cg.addLine(to: CGPoint(x: 512, y: 250))
            cg.strokePath()
            cg.fillEllipse(in: CGRect(x: 512 - 30, y: 244 - 30, width: 60, height: 60))
            cg.restoreGState()

            switch marca {
            case .nenhuma:
                break
            case .ponto:
                // bolinha no canto de cima à direita, com uma folga em volta para não grudar na copa
                let d = lado * 0.36, folga = lado * 0.1
                let r = CGRect(x: lado - d, y: 0, width: d, height: d)
                cg.setBlendMode(.clear)
                cg.fillEllipse(in: r.insetBy(dx: -folga, dy: -folga))
                cg.setBlendMode(.normal)
                cg.fillEllipse(in: r)
            case .risco:
                let a = CGPoint(x: lado * 0.1, y: lado * 0.08), b = CGPoint(x: lado * 0.9, y: lado * 0.92)
                cg.setBlendMode(.clear)
                cg.setLineWidth(lado * 0.2)
                cg.move(to: a)
                cg.addLine(to: b)
                cg.strokePath()
                cg.setBlendMode(.normal)
                cg.setLineWidth(lado * 0.085)
                cg.move(to: a)
                cg.addLine(to: b)
                cg.strokePath()
            }
            return true
        }
        imagem.isTemplate = true
        return imagem
    }

    // MARK: geometria (a mesma do SVG)

    /// Quarto de elipse com centro no meio da borda (512, 520), do topo (512, 286) até a borda em 512 ± rx.
    /// O SVG usa arcos; aqui vai uma curva cúbica, que cobre um quarto de elipse quase exato.
    private static func meridiano(_ rx: CGFloat, para lado: CGFloat, em p: CGMutablePath, doTopo: Bool) {
        let k: CGFloat = 0.5523, ry: CGFloat = 234
        let topo = CGPoint(x: 512, y: 286), borda = CGPoint(x: 512 + lado * rx, y: 520)
        if doTopo {
            p.addCurve(to: borda, control1: CGPoint(x: 512 + lado * k * rx, y: 286), control2: CGPoint(x: borda.x, y: 520 - k * ry))
        } else {
            p.addCurve(to: topo, control1: CGPoint(x: borda.x, y: 520 - k * ry), control2: CGPoint(x: 512 + lado * k * rx, y: 286))
        }
    }

    /// A copa inteira: o contorno de fora e a borda recortada em gomos.
    private static let copa: CGPath = {
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 512, y: 286))
        meridiano(300, para: -1, em: p, doTopo: true)
        let bordas: [(CGFloat, CGFloat, CGFloat)] = [(240.7, 509, 269.3), (344.3, 490, 419.3), (512, 483, 604.7),
                                                     (679.7, 490, 754.7), (783.4, 509, 812)]
        for (cx, cy, x) in bordas { p.addQuadCurve(to: CGPoint(x: x, y: 520), control: CGPoint(x: cx, y: cy)) }
        meridiano(300, para: 1, em: p, doTopo: false)
        p.closeSubpath()
        return p
    }()

    /// As quatro costuras entre os gomos (viram vãos).
    private static let meridianos: [CGPath] = [(242.7, -1), (92.7, -1), (92.7, 1), (242.7, 1)].map { rx, lado in
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 512, y: 286))
        meridiano(rx, para: lado, em: p, doTopo: true)
        return p
    }
}
