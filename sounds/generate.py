import wave, struct, math

SR = 48000

def marimba(freq, t, dur):
    """One marimba strike: partials at 1, 4 and 10 times the fundamental,
    near-instant attack and exponential decay."""
    parciais = [(1.0, 1.00), (4.0, 0.22), (9.8, 0.07)]
    ataque = 0.004
    env = (t / ataque) if t < ataque else math.exp(-(t - ataque) / (dur * 0.28))
    return env * sum(a * math.sin(2 * math.pi * freq * m * t) for m, a in parciais)

def render(notas, nome, total=1.0, pico=0.34):
    n = int(SR * total)
    amostras = [0.0] * n
    for freq, inicio, dur in notas:
        i0 = int(inicio * SR)
        for i in range(i0, min(n, i0 + int(dur * SR))):
            amostras[i] += marimba(freq, (i - i0) / SR, dur)
    maior = max(abs(x) for x in amostras) or 1.0
    ganho = pico / maior
    # final ramp so the cut does not click
    fade = int(0.02 * SR)
    quadros = []
    for i, x in enumerate(amostras):
        v = x * ganho
        if i > n - fade:
            v *= (n - i) / fade
        s = int(max(-1.0, min(1.0, v)) * 32767)
        quadros.append(struct.pack('<hh', s, s))
    w = wave.open(nome, 'wb')
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(SR)
    w.writeframes(b''.join(quadros)); w.close()
    print(f"{nome}: {total}s")

LA4, MI5 = 440.00, 659.25
# start: rising (A -> E). stop: falling (E -> A).
render([(LA4, 0.00, 0.70), (MI5, 0.13, 0.80)], 'start.wav')
render([(MI5, 0.00, 0.70), (LA4, 0.13, 0.80)], 'stop.wav')
