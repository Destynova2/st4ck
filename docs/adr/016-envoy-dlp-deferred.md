# ADR-016 : Envoy ext_proc DLP egress — differe (Gate 2+)

**Date** : 2026-03-09
**Statut** : Differe
**Decideurs** : Equipe plateforme

## Contexte

Detection de tokens/secrets dans le trafic sortant. Risque d'exfiltration de donnees via agents IA ou applications. Envoy sidecar + external processor gRPC pour scanning temps reel.

## Interet

- Inspection avant chiffrement TLS (ext_proc intercepte le plaintext)
- Integration service mesh (Envoy natif dans Cilium)
- Alerting temps reel (detection regex tokens, API keys, PII)
- Pattern DLP standard (Data Loss Prevention)

## Decision

**Differer.** Pas de cas d'usage IA egress aujourd'hui. La stack securite actuelle couvre les besoins :
- **Tetragon** (eBPF) : detection runtime, process + network observability
- **Kyverno** : admission policies, image verification
- **Cilium NetworkPolicy** : L7 filtering, DNS-aware egress rules

## Pre-requis pour implementation

1. Ollama/vLLM deployes (Gate 2 — IA legere, Gate 3 — IA GPU)
2. Traffic egress IA a surveiller (appels API externes)
3. Service gRPC ext_proc a developper et maintenir
4. Definition des patterns DLP (regex tokens, PII, secrets)

## Reconsiderer si

- Phase 2.2 IA legere deploye (Ollama + Open WebUI)
- Besoin compliance sur la prevention d'exfiltration de donnees
- Tetragon network observability ne suffit plus pour le DLP

## Note

Latence ~1-2ms par requete (ext_proc gRPC). Acceptable pour IA inference, problematique pour traffic temps reel haute frequence.
