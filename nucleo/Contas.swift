// As poucas contas do Accelerate que o núcleo usa, escritas à mão para onde ele não existe (Windows).
// No Mac nada disto é compilado: lá continua valendo o Accelerate, mais rápido.
#if !canImport(Accelerate)

typealias vDSP_Length = UInt
typealias vDSP_Stride = Int

/// Soma dos quadrados.
func vDSP_svesq(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    var s: Float = 0
    for i in 0..<Int(n) { s += a[i * ia] * a[i * ia] }
    c.pointee = s
}

/// Produto escalar.
func vDSP_dotpr(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride,
                _ c: UnsafeMutablePointer<Float>, _ n: vDSP_Length) {
    var s: Float = 0
    for i in 0..<Int(n) { s += a[i * ia] * b[i * ib] }
    c.pointee = s
}

/// Soma de dois vetores, elemento a elemento.
func vDSP_vadd(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride,
               _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ n: vDSP_Length) {
    for i in 0..<Int(n) { c[i * ic] = a[i * ia] + b[i * ib] }
}

/// Transposta: `c` (m × n) recebe a transposta de `a` (n × m).
func vDSP_mtrans(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride,
                 _ m: vDSP_Length, _ n: vDSP_Length) {
    let m = Int(m), n = Int(n)
    for i in 0..<m { for j in 0..<n { c[(i * n + j) * ic] = a[(j * m + i) * ia] } }
}

/// Produto de matrizes: `c` (m × n) = `a` (m × p) · `b` (p × n).
func vDSP_mmul(_ a: UnsafePointer<Float>, _ ia: vDSP_Stride, _ b: UnsafePointer<Float>, _ ib: vDSP_Stride,
               _ c: UnsafeMutablePointer<Float>, _ ic: vDSP_Stride, _ m: vDSP_Length, _ n: vDSP_Length, _ p: vDSP_Length) {
    let m = Int(m), n = Int(n), p = Int(p)
    for i in 0..<m {
        for j in 0..<n {
            var s: Float = 0
            for k in 0..<p { s += a[(i * p + k) * ia] * b[(k * n + j) * ib] }
            c[(i * n + j) * ic] = s
        }
    }
}

#endif
