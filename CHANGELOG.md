# Changelog

## 0.2.0 — 2026-11-06

- Prioritize foundational ORC format coverage: DECIMAL(1..38, scale), CHAR and VARCHAR parameterized schema and bidirectional codecs.
- Exact bounded decimal varints/scale RLE, Unicode code-point lengths, canonical CHAR API/padded wire representation and padding budgets.
- Add independent Apache ORC scalar type comparisons, malformed/boundary tests, runnable format example and staged standard-type roadmap.

- 稳定多列类型排序。
- 精确类型键稳定去重。
- 增加回归测试、独立可运行示例与 CI 示例步骤；详见 docs/EXPANSION_20261106.md。

## 0.1.0 — 2026-11-01

- 消费方字段契约检查：Schema::check_contract
- 保留源文件行号的选择扫描：Scanner::next_positioned
- 增加边界回归、可运行集成示例和CI步骤。

### Initial implementation

- Independent native ORC flat record encoding, nullable columns and multi-stripe files.
- NONE/ZLIB framing, RLEv1/v2 reads, direct and dictionary strings.
- Projection, exact three-valued filtering, source-row windows, opt-in trusted statistics pruning.
- Atomic incremental input writer, immutable batch operations, stream range and row-group metadata inspection.
- Independent Apache ORC oracle, cross-backend fixtures and tests, application scenarios and scale workload.
- Public namespace: oyjh0381/moonorc; reproducible compiler/core, Linux/Windows CI and history/package hygiene checks.
