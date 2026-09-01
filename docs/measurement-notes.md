# Measurement notes

These figures were recorded during development. They describe a small experiment, not a reproducible benchmark or a forecast for another project.

## Recorded observations

| Item | Recorded result |
| --- | --- |
| Initial index generation | An application with 218 source files; approximately 100 seconds and 1.3 million tokens. |
| Exploration comparison | Two questions, three paired runs with and without an index. |
| Reported token reductions | 25%, 39%, and 28%; approximately 31% as an unweighted average. |
| Answer content | Pitfalls recorded in the entries appeared in the indexed runs' answers. No systematic accuracy score was recorded here. |

## Limits of these figures

This repository does not include the benchmark application, exact prompts, raw session transcripts, model versions, or absolute token totals for each comparison. The token accounting does not specify how input, output, cache reads, and cache writes were combined. The generation figure should therefore not be used to infer billed tokens or dollar costs.

The sample is too small to establish how results vary across repositories or tasks. Without per-run totals and model pricing, neither the unweighted percentage average nor the generation total establishes a monetary saving or a break-even number of questions. Ongoing index reads and refreshes also need to be included in any cost comparison.

The session guidance itself changes as the plugin evolves. Its token count depends on the current text, tokenizer, plugin installation path, and whether pending files are reported. A fixed token count would not describe all installations.

## For a reproducible comparison

A future benchmark should publish the project revision and source selection, exact prompts, Claude Code and model versions, index contents, repeated runs from equivalent session states, and separate token totals for input, output, cache reads, and cache writes. It should account for generation and refresh work as well as exploration, and assess answer correctness alongside token use.
