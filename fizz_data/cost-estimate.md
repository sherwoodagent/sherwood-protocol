# Cost Estimate

Model: **sonnet** ($3.00/M input, $15.00/M output)
Mode: **automatic**
Selected contracts: **10**
Selected functions: **122** — scale 1.8x (xl)

| Stage                              | Count | Input    | Output  | Cost     |
|------------------------------------|-------|----------|---------|----------|
| Protocol Analyzer (conditional)    |     1 |      90k |   14.4k |    $0.49 |
| Discovery agents                   |     5 |     720k |    108k |    $3.78 |
| Synthesizer                        |     1 |      90k |   21.6k |    $0.59 |
| Implementers                       |     2 |     216k |     54k |    $1.46 |
| Report Writer                      |     1 |      54k |   14.4k |    $0.38 |
| Orchestrator overhead              |     1 |     450k |     72k |    $2.43 |
| TOTAL                              |       |    1620k |  284.4k |    $9.13 |

**Estimated total: $9.13** — expected range $6.39 – $13.69

These numbers are Anthropic list-price estimates for the subagents and a rough orchestrator overhead share. Actual cost varies with: coverage-iteration cycles (Step 8), re-runs after compile errors, handler complexity, whether x-ray skipped the Protocol Analyzer, and prompt-cache hit rate. Treat this as a ballpark, not a commitment.
